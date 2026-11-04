defmodule SdrAgent.Prototype.Output do
  @moduledoc """
  The one standalone serializer of D-237 prototype business output
  (interfaces r6 IF-5, must-fix R2, Q1; amendment item 8 "Serialization").

  Two channels, never mixed:

    * the content-free channel is `SdrAgent.Prototype.SafeLog` (codes,
      counts, UUIDs and closed atoms only);
    * the ONE content-bearing channel is the private labelled bundle,
      `write_bundle/3`: a JSON file exclusive-created with mode 0600 in a
      0700 directory, never overwritten, reported only by its UUID and item
      count.

  A view is `%{"schema" => "d237-output/2", "prototype" => block, "kind" =>
  kind, "id" => uuid, "fields" => fields}` with closed `fields` per kind
  (`:run`, `:pending_revision`, `:approval`, `:receipt`). Outside prototype
  runtime `view/3` and `write_bundle/3` return
  `{:error, :not_prototype_runtime}` and serialize nothing.

  The two digests are typed and never interchangeable:

    * `check_revision/1`: the canonical `{subject, body_text}` digest
      (`SdrAgent.Audit.Canonical`, the current canonicalization version)
      equals `DraftRevision.content_sha256`;
    * `check_approval/2`: the approval names that revision, its
      `revision_content_sha256` equals the revision's `content_sha256`, and
      the revision's own check passes;
    * `check_receipt/2`: the bytes are a rendered RFC 5322 message (a header
      block, a blank line, a body) and `sha256(bytes)` equals
      `DeliveryReceipt.rendered_sha256`.

  A mismatch is `{:error, :digest_mismatch}`. Neither byte stream is
  altered, and the label never enters either.

  `task_refusal/1` is the prototype-runtime gate of Mix tasks (Codex S4 RED
  ruling 6): a CLOSED allow-list of exact names
  (`sdr.prototype.{setup,provision,import,op,serve}` and
  `sdr.audit.export`) is `:ok`; with the switch present at all
  (`SDR_PROTOTYPE` or `SDR_PROTOTYPE_INSTANCE`, even partial, empty or
  malformed) or in prototype runtime, every other task is
  `{:error, :prototype_task_refused}`. Allow-list membership grants no
  authority: each allowed task still runs its own process-kind, boot and
  operator checks. Every `run/1` clause of every other task of `lib/mix/tasks` begins
  with this terminal check, outside any rescue.

  Every view resolves the operator and live binding afresh. Receipt bytes
  are read through the scoped Payload action, which records AuditAccess.
  Bundle input is validated in full before creating a file. A failed I/O
  attempt may leave its private, exclusively created file; it is never
  reported as a successful bundle or overwritten on retry.

  The run's `release_decision` is `"not_in_review_scope"`: IF-5 names
  the field, but supplement 2 r2 explicitly excludes model-release reads
  from operator review authority. This is not a claim that no release
  exists. `stop_reason` is the run's existing `status_reason`.
  """

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Outreach.Approval
  alias SdrAgent.Outreach.DeliveryReceipt
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Prototype

  @type kind :: :run | :pending_revision | :approval | :receipt
  @type view_error ::
          :not_prototype_runtime | :binding_mismatch | :forbidden | :not_found | :digest_mismatch

  @kinds [:run, :pending_revision, :approval, :receipt]

  @allowed_tasks [
    "sdr.prototype.setup",
    "sdr.prototype.provision",
    "sdr.prototype.import",
    "sdr.prototype.op",
    "sdr.prototype.serve",
    "sdr.audit.export"
  ]

  @switch ["SDR_PROTOTYPE", "SDR_PROTOTYPE_INSTANCE"]

  @doc "The closed set of view kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "The closed allow-list of Mix tasks that may start with the prototype switch set."
  @spec allowed_tasks() :: [String.t()]
  def allowed_tasks, do: @allowed_tasks

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    alias SdrAgent.Actor
    alias SdrAgent.Agents
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Checks.PrototypeReviewScope
    alias SdrAgent.Audit.Payload
    alias SdrAgent.Outreach
    alias SdrAgent.Outreach.Draft
    alias SdrAgent.Sales

    @doc "One labelled view of `kind` for record `id`, read as `actor`."
    @spec view(kind(), Ecto.UUID.t(), SdrAgent.Actor.t()) :: {:ok, map()} | {:error, view_error()}
    def view(kind, id, actor) do
      with :ok <- authorized(actor),
           :ok <- view_identity(kind, id),
           {:ok, fields} <- fields(kind, id, actor),
           :ok <- authorized(actor),
           {:ok, assurance} <- Prototype.assurance() do
        {:ok,
         %{
           "schema" => "d237-output/2",
           "prototype" => assurance,
           "kind" => Atom.to_string(kind),
           "id" => id,
           "fields" => fields
         }}
      else
        {:error, error} -> {:error, view_reason(error)}
      end
    end

    @doc "Writes the private labelled bundle `bundle_id` holding the views of `items`."
    @spec write_bundle([{kind(), Ecto.UUID.t()}], SdrAgent.Actor.t(), Ecto.UUID.t()) ::
            {:ok, %{bundle_id: Ecto.UUID.t(), items: non_neg_integer()}} | {:error, term()}
    def write_bundle(items, actor, bundle_id) do
      with :ok <- authorized(actor),
           true <- canonical_uuid?(bundle_id),
           {:ok, views} <- views(items, actor),
           :ok <- authorized(actor),
           {:ok, assurance} <- Prototype.assurance(),
           {:ok, bytes} <- Jason.encode(%{"prototype" => assurance, "items" => views}),
           {:ok, directory} <- bundle_directory(),
           :ok <- private_directory(directory),
           :ok <- write_private(Path.join(directory, bundle_id <> ".json"), bytes) do
        {:ok, %{bundle_id: bundle_id, items: length(views)}}
      else
        {:error, error} when error in [:binding_mismatch, :not_prototype_runtime] ->
          {:error, error}

        {:error, error} when error in [:forbidden, :not_found, :digest_mismatch] ->
          {:error, error}

        _ ->
          {:error, :bundle_write_failed}
      end
    end

    defp authorized(actor) do
      with :ok <- prototype_runtime(),
           :ok <- Prototype.check_live() do
        if match?(%Actor{type: :prototype_operator}, actor) and Prototype.operator?(actor),
          do: :ok,
          else: {:error, :forbidden}
      end
    end

    defp view_identity(kind, id) do
      if kind in @kinds and canonical_uuid?(id), do: :ok, else: {:error, :not_found}
    end

    defp canonical_uuid?(id) when is_binary(id), do: Ecto.UUID.cast(id) == {:ok, id}
    defp canonical_uuid?(_id), do: false

    defp fields(:pending_revision, id, actor) do
      with {:ok, draft} <- Outreach.fetch(Draft, id, actor: actor),
           :ok <- pending(draft),
           {:ok, revision} <-
             Outreach.fetch(DraftRevision, draft.current_revision_id, actor: actor),
           true <- revision.draft_id == draft.id,
           :ok <- check_revision(revision),
           {:ok, contact} <- Sales.fetch(Sales.Contact, draft.recipient_contact_id, actor: actor) do
        {:ok,
         %{
           "revision_id" => revision.id,
           "draft_id" => draft.id,
           "revision_number" => revision.revision_number,
           "subject" => revision.subject,
           "body_text" => revision.body_text,
           "revision_content_sha256" => hex(revision.content_sha256),
           "canonicalization_version" => revision.canonicalization_version,
           "recipient_contact_id" => contact.id,
           "recipient_email" => to_string(contact.email),
           "state" => "pending_review"
         }}
      else
        false -> {:error, :digest_mismatch}
        error -> error
      end
    end

    defp fields(:approval, id, actor) do
      with {:ok, approval} <- Outreach.fetch(Approval, id, actor: actor),
           {:ok, revision} <-
             Outreach.fetch(DraftRevision, approval.draft_revision_id, actor: actor),
           :ok <- check_approval(approval, revision),
           {:ok, metadata} <- approval_metadata(approval, actor) do
        {:ok,
         %{
           "id" => approval.id,
           "verdict" => text(approval.verdict),
           "approval_mode" => metadata["approval_mode"],
           "delegation_id" => metadata["delegation_id"],
           "draft_revision_id" => revision.id,
           "revision_content_sha256" => hex(approval.revision_content_sha256)
         }}
      end
    end

    defp fields(:receipt, id, actor) do
      with {:ok, receipt} <- Outreach.fetch(DeliveryReceipt, id, actor: actor),
           {:ok, bytes} <- receipt_bytes(receipt, actor),
           :ok <- check_receipt(receipt, bytes) do
        {:ok,
         %{
           "id" => receipt.id,
           "status" => text(receipt.kind),
           "operation_id" => receipt.delivery_operation_id,
           "rendered_sha256" => hex(receipt.rendered_sha256),
           "rendered_bytes" => bytes
         }}
      end
    end

    defp fields(:run, id, actor) do
      with {:ok, run} <- Agents.get_run(id, actor: actor) do
        {:ok,
         %{
           "id" => run.id,
           "status" => text(run.status),
           "stop_reason" => text(run.status_reason),
           "release_decision" => "not_in_review_scope"
         }}
      end
    end

    defp approval_metadata(approval, actor) do
      with {:ok, binding} <- Prototype.binding(),
           true <-
             approval.verdict == :approved and approval.approver_id == binding.operator_user_id do
        scope = %{
          tenant_id: actor.tenant_id,
          delegation_id: actor.id,
          approval_id: approval.id,
          anchor_id: binding.operator_user_id
        }

        Audit.read_prototype_approval_grant(approval.id,
          actor: actor,
          context: %{sdr_prototype_approval_grant_scope: scope}
        )
      else
        _ -> {:error, :not_found}
      end
    end

    defp receipt_bytes(%DeliveryReceipt{rendered_sha256: <<_::256>> = sha}, actor) do
      context =
        PrototypeReviewScope.context(%{
          tenant_id: actor.tenant_id,
          delegation_id: actor.id,
          sha256s: [sha]
        })

      Payload
      |> Ash.ActionInput.for_action(:read_prototype_review_content, %{sha256: sha},
        actor: actor,
        context: context
      )
      |> Ash.run_action()
    end

    defp receipt_bytes(_receipt, _actor), do: {:error, :digest_mismatch}

    defp pending(%Draft{status: :pending_review}), do: :ok
    defp pending(_draft), do: {:error, :forbidden}

    defp views([_ | _] = items, actor), do: collect_views(items, actor, [])
    defp views(_items, _actor), do: {:error, :forbidden}

    defp collect_views([], _actor, acc), do: {:ok, Enum.reverse(acc)}

    defp collect_views([{kind, id} | rest], actor, acc) do
      with {:ok, view} <- view(kind, id, actor), do: collect_views(rest, actor, [view | acc])
    end

    defp collect_views(_malformed, _actor, _acc), do: {:error, :forbidden}

    defp bundle_directory do
      default =
        Path.join([System.user_home!(), ".local", "state", "sdr-agent", "d237", "bundles"])

      directory =
        Application.get_env(:sdr_agent, __MODULE__, []) |> Keyword.get(:bundle_dir, default)

      if is_binary(directory) and Path.type(directory) == :absolute and
           Path.expand(directory) == directory,
         do: {:ok, directory},
         else: {:error, :bundle_write_failed}
    end

    defp private_directory(directory) do
      with :ok <- File.mkdir_p(Path.dirname(directory)) do
        case File.mkdir(directory) do
          :ok -> File.chmod(directory, 0o700)
          {:error, :eexist} -> check_directory(directory)
          _ -> {:error, :bundle_write_failed}
        end
      end
    end

    defp check_directory(directory) do
      case File.lstat(directory) do
        {:ok, %File.Stat{type: :directory, mode: mode}} ->
          if Bitwise.band(mode, 0o777) == 0o700,
            do: :ok,
            else: {:error, :bundle_write_failed}

        _ ->
          {:error, :bundle_write_failed}
      end
    end

    # Only this exclusively created handle receives bytes, after the empty
    # file is private. Neither an existing file nor a symlink can be opened.
    defp write_private(path, bytes) do
      case :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
        {:ok, handle} ->
          result =
            with :ok <- File.chmod(path, 0o600),
                 :ok <- :file.write(handle, bytes),
                 do: :file.sync(handle)

          closed = :file.close(handle)
          if result == :ok and closed == :ok, do: :ok, else: {:error, :bundle_write_failed}

        _ ->
          {:error, :bundle_write_failed}
      end
    end

    defp view_reason(error)
         when error in [
                :not_prototype_runtime,
                :binding_mismatch,
                :forbidden,
                :not_found,
                :digest_mismatch
              ],
         do: error

    defp view_reason(%Ash.Error.Query.NotFound{}), do: :not_found
    defp view_reason(_error), do: :forbidden

    defp hex(bytes), do: Base.encode16(bytes, case: :lower)
    defp text(nil), do: nil
    defp text(value) when is_atom(value), do: Atom.to_string(value)

    defp prototype_runtime do
      if prototype_runtime?(), do: :ok, else: {:error, :not_prototype_runtime}
    end
  else
    @doc "Refused: no prototype output authority in an ordinary production build."
    @spec view(kind(), Ecto.UUID.t(), SdrAgent.Actor.t()) :: {:error, :not_prototype_runtime}
    def view(_kind, _id, _actor), do: {:error, :not_prototype_runtime}

    @doc "Refused: no private bundle can be written in an ordinary production build."
    @spec write_bundle([{kind(), Ecto.UUID.t()}], SdrAgent.Actor.t(), Ecto.UUID.t()) ::
            {:error, :not_prototype_runtime}
    def write_bundle(_items, _actor, _bundle_id), do: {:error, :not_prototype_runtime}
  end

  @doc "The revision-content digest check (see the moduledoc)."
  @spec check_revision(struct()) :: :ok | {:error, :digest_mismatch}
  def check_revision(%DraftRevision{
        subject: subject,
        body_text: body,
        content_sha256: <<_::256>> = digest,
        canonicalization_version: version
      })
      when is_binary(subject) and is_binary(body) do
    if version == Canonical.version() and
         Canonical.sha256(%{subject: subject, body_text: body}) == digest,
       do: :ok,
       else: {:error, :digest_mismatch}
  end

  def check_revision(_revision), do: {:error, :digest_mismatch}

  @doc "The approval's bound digest equals its revision's `content_sha256` (see the moduledoc)."
  @spec check_approval(struct(), struct()) :: :ok | {:error, :digest_mismatch}
  def check_approval(
        %Approval{draft_revision_id: revision_id, revision_content_sha256: <<_::256>> = bound},
        %DraftRevision{id: revision_id, content_sha256: bound} = revision
      ),
      do: check_revision(revision)

  def check_approval(_approval, _revision), do: {:error, :digest_mismatch}

  @doc "The rendered-message digest check (see the moduledoc)."
  @spec check_receipt(struct(), binary()) :: :ok | {:error, :digest_mismatch}
  def check_receipt(%DeliveryReceipt{rendered_sha256: <<_::256>> = digest}, rendered)
      when is_binary(rendered) do
    if rendered_message?(rendered) and :crypto.hash(:sha256, rendered) == digest,
      do: :ok,
      else: {:error, :digest_mismatch}
  end

  def check_receipt(_receipt, _rendered), do: {:error, :digest_mismatch}

  @doc "`:ok` when Mix task `task` may run; `{:error, :prototype_task_refused}` otherwise."
  @spec task_refusal(String.t()) :: :ok | {:error, :prototype_task_refused}
  def task_refusal(task) when is_binary(task) do
    if task in @allowed_tasks or not prototype_switch?(),
      do: :ok,
      else: {:error, :prototype_task_refused}
  end

  def task_refusal(_task), do: {:error, :prototype_task_refused}

  # Startup intent is refusal-only: any presence of either switch variable,
  # even partial, empty or malformed, refuses; boot verification has not run.
  defp prototype_switch? do
    prototype_runtime?() or Enum.any?(@switch, &(System.get_env(&1) != nil))
  end

  # `runtime/0` is `:ordinary | :prototype`. Asking "not ordinary" is the same
  # question, and the production build (whose facade is always `:ordinary`)
  # compiles it without a comparison the type checker knows is always false.
  defp prototype_runtime?, do: Prototype.runtime() != :ordinary

  defp rendered_message?(bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, _body] -> Regex.match?(~r/\A[A-Za-z][A-Za-z0-9-]*: [^\r\n]*(\r\n|\z)/, headers)
      _ -> false
    end
  end
end
