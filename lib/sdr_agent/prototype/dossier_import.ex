defmodule SdrAgent.Prototype.DossierImport do
  @moduledoc """
  The above-domain import coordinator of D-237 dossier rows (interfaces r6
  IF-6; supplement 1 r2 §5, Codex R9): `prepare/5`, `import/2`,
  `import_row/2` and `cap_used/1`. Sales sits below Research and never
  calls it, so the import is composed here, above both domains: the Sales
  import APIs (`SdrAgent.Sales.import_prototype_account/2`,
  `import_prototype_contact/2`, `import_prototype_lead/2`), the Research
  APIs (`SdrAgent.Research.record_dossier_entry/2`,
  `record_dossier_source/2`) and the operator's scoped Payload store
  (`SdrAgent.Audit.Payload` `:store_prototype_input`, authorized only by
  `SdrAgent.Audit.Checks.PrototypeInputScope`). Each domain owns its
  actions and policies; nothing here writes a row directly, mutates a
  struct or bypasses a policy.

  Both write entries, `import/2` and `import_row/2`, first re-check the
  caller, before any write: prototype runtime (`:not_prototype_runtime`),
  the live binding (`SdrAgent.Prototype.check_live/0`, `:binding_mismatch`)
  and the live operator (`SdrAgent.Prototype.operator_actor/1`, called
  fresh, must resolve the actor's own delegation to exactly the same actor;
  anything else is `:forbidden`). An empty `rows` list is no bypass: the
  caller is checked first. `import_row/2` never relies on `import/2`
  having been called.

  - `prepare/5` is pure: `DossierParser.select/4` (which validates EVERY
    flagged row, selected or not, and refuses the whole input on any), then
    `DossierParser.import_plan/4` per selected row, composed and never
    re-implemented. Rows keep the selection order, each row's original
    index in the dossier, and the exact dossier and manifest digests; a
    parser refusal is returned unchanged. No database, network, evaluation
    or write; only the parser's own bounded artifact reads.
  - `import/2` runs the precheck in its own `SdrAgent.Audit.transaction/1`
    under the binding lock: `used` (distinct imported contacts) plus `new`
    (the rows that are not identical replays) over the policy entry's
    `max_contacts` refuses with `:contact_cap_exceeded` before any write. It
    reserves no slot. Then `import_row/2` per row in selection order,
    stopping at the first failure: committed rows stay, and the same
    command resumes (they replay, the failed row is retried).
  - `import_row/2` runs ONE `SdrAgent.Audit.transaction/1` per row:
    1. lock the live binding row (`FOR UPDATE`; a lock only);
    2. replay: an existing entry for `(dossier_sha256, row_id)` with the
       same manifest, claims and notes digests returns its own entry and
       lead ids, writes nothing and uses no slot (its importing delegation
       stays the historical one); different content is `:dossier_conflict`;
       the same domain or address already imported from any row or dossier
       is `:dossier_conflict`;
    3. the authoritative cap recheck (`:contact_cap_exceeded`);
    4. the claims, notes and source-excerpt Payloads, through the scoped
       store with the exact digests of the bytes being stored;
    5. the account, contact and lead (Sales);
    6. the entry and its verified-excerpt sources (Research).

    Every error inside the callback calls `SdrAgent.Repo.rollback/1`, so a
    failed row leaves no Sales or Research row, no Payload and no slot.
    Denial records of the guarded Sales calls are appended by
    `SdrAgent.Audit.transaction/1` after the rollback, and so are kept.

  Results carry codes, row ids and ids only, never values; the codes are
  members of `SdrAgent.Prototype.SafeLog.reasons(:import)`.

  Stage (D-237 S3): `cap_used/1` still returns 0, never a measured cap,
  until its own RED with the import task.
  """

  require Ash.Query

  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Checks.PrototypeInputScope
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload
  alias SdrAgent.Operations.PrototypeDatabaseBinding
  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.DossierParser
  alias SdrAgent.Repo
  alias SdrAgent.Research
  alias SdrAgent.Research.DossierEntry
  alias SdrAgent.Sales
  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Contact

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @source_types %{
    "company_site" => :company_site,
    "person_authored" => :person_authored,
    "attributed_third_party" => :attributed_third_party,
    "directory" => :directory,
    "third_party" => :third_party
  }

  @doc "The import rows of `row_ids` (at most 3), or the parser's refusal."
  @spec prepare(map(), String.t(), map(), [String.t()], Path.t()) ::
          {:ok, [map()]} | {:error, term()}
  def prepare(dossier, dossier_sha256, manifest, row_ids, artifacts_dir) do
    with {:ok, rows} <- DossierParser.select(dossier, manifest, row_ids, artifacts_dir) do
      collect(rows, &prepared(&1, dossier, dossier_sha256, manifest, artifacts_dir))
    end
  end

  defp prepared(row, dossier, dossier_sha256, manifest, artifacts_dir) do
    row_id = row["row_id"]

    with {:ok, plan} <- DossierParser.import_plan(dossier, manifest, row_id, artifacts_dir) do
      {:ok,
       %{
         row_id: row_id,
         row_index: Enum.find_index(dossier["companies"], &(&1["row_id"] == row_id)),
         dossier_sha256: dossier_sha256,
         spotcheck_sha256: manifest.sha256,
         plan: plan
       }}
    end
  end

  # {:ok, values} in input order, or the first error unchanged.
  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  @doc "Imports `rows` in order; see the moduledoc."
  @spec import([map()], SdrAgent.Actor.t()) :: {:ok, map()} | {:error, map()}
  def import(rows, actor) when is_list(rows) do
    with :ok <- live(actor),
         :ok <- precheck(rows, actor) do
      Enum.reduce_while(rows, {:ok, %{imported: [], replayed: []}}, &import_next(&1, &2, actor))
    else
      {:error, code} -> {:error, %{code: code, failed_row: nil, imported: [], replayed: []}}
    end
  end

  defp import_next(row, {:ok, acc}, actor) do
    case import_row(row, actor) do
      {:ok, :imported, _ids} ->
        {:cont, {:ok, %{acc | imported: acc.imported ++ [row.row_id]}}}

      {:ok, :replay, _ids} ->
        {:cont, {:ok, %{acc | replayed: acc.replayed ++ [row.row_id]}}}

      {:error, code} ->
        {:halt, {:error, Map.merge(acc, %{code: code, failed_row: row.row_id})}}
    end
  end

  @doc "Imports one row in one transaction; see the moduledoc."
  @spec import_row(map(), SdrAgent.Actor.t()) :: {:ok, atom(), map()} | {:error, atom()}
  def import_row(row, actor), do: run_row(row, actor, [])

  if @test_seams do
    @doc false
    # Test-seam builds only: `after_sales:`, a 0-arity function, runs inside
    # the row's transaction between the Sales and the Research writes.
    def import_row(row, actor, seams) when is_list(seams), do: run_row(row, actor, seams)
  end

  defp run_row(row, actor, seams) do
    with :ok <- live(actor) do
      fn -> write_row(row, actor, seams) end
      |> Audit.transaction()
      |> case do
        {:ok, {status, ids}} -> {:ok, status, ids}
        {:error, code} when is_atom(code) -> {:error, code}
      end
    end
  end

  @doc "Distinct imported contacts of the binding."
  @spec cap_used(SdrAgent.Actor.t()) :: non_neg_integer()
  def cap_used(_actor), do: red(0)

  # The fresh real resolver must return exactly this actor (type, delegation
  # id and tenant), after the live binding check; nothing is taken from the
  # map or its type alone.
  defp live(%SdrAgent.Actor{type: :prototype_operator, id: id, tenant_id: tenant_id} = actor)
       when is_binary(id) and is_binary(tenant_id) do
    with :prototype <- Prototype.runtime(),
         :ok <- Prototype.check_live(),
         {:ok, ^actor} <- Prototype.operator_actor(id) do
      :ok
    else
      :ordinary -> {:error, :not_prototype_runtime}
      {:error, :binding_mismatch} -> {:error, :binding_mismatch}
      {:error, :not_prototype_runtime} -> {:error, :not_prototype_runtime}
      _ -> {:error, :forbidden}
    end
  end

  defp live(_actor) do
    if Prototype.runtime() == :prototype,
      do: {:error, :forbidden},
      else: {:error, :not_prototype_runtime}
  end

  ## The binding lock and the cap

  # Early refusal only: it reserves nothing, the per-row recheck decides.
  defp precheck(rows, actor) do
    fn ->
      lock_binding!(actor)
      new = Enum.count(rows, &(replay_of(&1, actor) != :replay))
      if used(actor) + new > max_contacts!(), do: Repo.rollback(:contact_cap_exceeded)
      :ok
    end
    |> Audit.transaction()
    |> case do
      {:ok, :ok} -> :ok
      {:error, code} when is_atom(code) -> {:error, code}
    end
  end

  # SELECT ... FOR UPDATE of the live binding row: a lock only (its
  # append-only trigger fires on UPDATE), so imports serialize.
  defp lock_binding!(actor) do
    with {:ok, %{id: binding_id}} <- Prototype.binding(),
         {:ok, [_binding]} <-
           PrototypeDatabaseBinding
           |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
           |> Ash.Query.filter(id == ^binding_id and tenant_id == ^actor.tenant_id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read() do
      :ok
    else
      _ -> Repo.rollback(:binding_mismatch)
    end
  end

  # The compiled policy entry's binding-wide cap.
  defp max_contacts! do
    case Prototype.policy_entry() do
      {:ok, %{max_contacts: max}} when is_integer(max) and max >= 0 -> max
      _ -> Repo.rollback(:binding_mismatch)
    end
  end

  # Distinct imported contacts: every entry is an operator import into the
  # binding's one tenant. A kernel read, tenant-filtered.
  defp used(actor) do
    entries(actor)
    |> Ash.Query.select([:contact_id])
    |> Ash.read!()
    |> MapSet.new(& &1.contact_id)
    |> MapSet.size()
  end

  defp entries(actor) do
    DossierEntry
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
    |> Ash.Query.filter(tenant_id == ^actor.tenant_id)
  end

  # :new, :replay or :conflict, by the row key `(dossier_sha256, row_id)`.
  defp replay_of(row, actor) do
    case existing(row, actor) do
      nil -> :new
      entry -> if identical?(entry, row), do: :replay, else: :conflict
    end
  end

  defp existing(row, actor) do
    row_id = row.row_id

    entries(actor)
    |> Ash.Query.filter(dossier_sha256 == ^row.dossier_sha256 and row_id == ^row_id)
    |> Ash.read_one!()
  end

  defp identical?(entry, row) do
    entry.spotcheck_sha256 == row.spotcheck_sha256 and
      entry.claims_sha256 == digest(claims_bytes(row)) and
      entry.notes_sha256 == digest(notes_bytes(row))
  end

  ## One row (inside its transaction)

  defp write_row(row, actor, seams) do
    lock_binding!(actor)
    entry = existing(row, actor)

    cond do
      entry == nil -> new_row(row, actor, seams)
      identical?(entry, row) -> {:replay, %{entry_id: entry.id, lead_id: entry.lead_id}}
      true -> Repo.rollback(:dossier_conflict)
    end
  end

  defp new_row(%{plan: plan} = row, actor, seams) do
    with :ok <- no_conflict(plan, actor),
         :ok <- cap_recheck(actor),
         {:ok, claims} <- store(claims_bytes(row), :dossier_claims, actor),
         {:ok, notes} <- store(notes_bytes(row), :dossier_notes, actor),
         {:ok, account} <-
           coded(Sales.import_prototype_account(account_attrs(plan), actor: actor)),
         {:ok, contact} <-
           coded(Sales.import_prototype_contact(contact_attrs(plan, account), actor: actor)),
         {:ok, lead} <-
           coded(
             Sales.import_prototype_lead(%{account_id: account.id, contact_id: contact.id},
               actor: actor
             )
           ),
         :ok <- seam(seams, :after_sales),
         {:ok, entry} <-
           coded(
             Research.record_dossier_entry(
               entry_attrs(row, account, contact, lead, claims, notes),
               actor: actor
             )
           ),
         :ok <- sources(plan.sources, entry, lead, actor) do
      {:imported, %{entry_id: entry.id, lead_id: lead.id}}
    else
      {:error, code} -> Repo.rollback(code)
    end
  end

  # No reset: the same domain or address from another row or dossier.
  defp no_conflict(plan, actor) do
    host = plan.account.domain
    address = plan.contact.email

    if taken?(Ash.Query.filter(Account, domain == ^host), actor) or
         taken?(Ash.Query.filter(Contact, email == ^address), actor),
       do: {:error, :dossier_conflict},
       else: :ok
  end

  # A kernel read in the actor's tenant (the operator has no Sales read).
  defp taken?(query, actor) do
    query
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(actor.tenant_id))
    |> Ash.Query.filter(tenant_id == ^actor.tenant_id)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> Enum.any?()
  end

  defp cap_recheck(actor) do
    if used(actor) + 1 > max_contacts!(),
      do: {:error, :contact_cap_exceeded},
      else: :ok
  end

  defp sources(sources, entry, lead, actor) do
    Enum.reduce_while(sources, :ok, fn source, :ok ->
      with {:ok, content} <- store(source.content, :dossier_excerpts, actor),
           {:ok, _source} <-
             coded(
               Research.record_dossier_source(source_attrs(source, entry, lead, content),
                 actor: actor
               )
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # A test seam of `import_row/3` (test builds only); none in production.
  defp seam(seams, name) do
    case Keyword.get(seams, name) do
      fun when is_function(fun, 0) -> fun.()
      nil -> :ok
    end

    :ok
  end

  ## Payloads: canonical bytes, the scoped store

  defp claims_bytes(row), do: Canonical.encode!(%{"claims" => row.plan.claims})
  defp notes_bytes(row), do: Canonical.encode!(row.plan.notes)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes)

  defp store(bytes, purpose, actor) do
    scope = %{
      tenant_id: actor.tenant_id,
      delegation_id: actor.id,
      purpose: purpose,
      sha256s: [digest(bytes)]
    }

    Payload
    |> Ash.Changeset.for_create(
      :store_prototype_input,
      %{content: bytes, content_type: content_type(purpose)},
      actor: actor,
      context: PrototypeInputScope.context(scope)
    )
    |> Ash.create()
    |> coded()
    |> case do
      {:ok, payload} -> {:ok, payload.sha256}
      error -> error
    end
  end

  defp content_type(:dossier_excerpts), do: "text/plain"
  defp content_type(_purpose), do: "application/json"

  ## Domain calls: codes only

  defp coded({:ok, value}), do: {:ok, value}
  defp coded({:error, %Ash.Error.Forbidden{}}), do: {:error, :forbidden}
  defp coded({:error, _invalid}), do: {:error, :import_failed}

  defp account_attrs(plan),
    do: %{
      name: plan.account.name,
      domain: plan.account.domain,
      website_url: plan.account.website_url
    }

  defp contact_attrs(plan, account), do: Map.put(plan.contact, :account_id, account.id)

  defp entry_attrs(row, account, contact, lead, claims, notes) do
    Map.merge(row.plan.entry, %{
      dossier_sha256: row.dossier_sha256,
      row_id: row.row_id,
      spotcheck_sha256: row.spotcheck_sha256,
      account_id: account.id,
      contact_id: contact.id,
      lead_id: lead.id,
      claims_sha256: claims,
      notes_sha256: notes
    })
  end

  defp source_attrs(source, entry, lead, content) do
    %{
      entry_id: entry.id,
      lead_id: lead.id,
      source_id: source.source_id,
      original_url: source.original_url,
      final_url: source.final_url,
      source_type: Map.fetch!(@source_types, source.source_type),
      retrieved_on: source.retrieved_on,
      checked_at: source.checked_at,
      content_sha256: content
    }
  end

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
