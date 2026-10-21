defmodule SdrAgent.Agents.Witness do
  @moduledoc """
  Wire-witness reconciliation of terminal ClaudeCLI invocations against the
  independent local proxy store (S12 step 6; ADR-0005 S12 amendment; entity
  conditions C1–C8, plan P1/P2/P7).

  `reconcile/2` (REC only):

    1. reads the invocation's exchanges with the bounded, read-only
       `SdrAgent.Agents.Witness.Store` and — only when a message exchange
       exists — the stored application bodies through the audited, scoped
       `SdrAgent.Agents.read_reconciliation_payloads/2`. File I/O and these
       reads happen before any database lock;
    2. classifies every observed exchange: exactly one complete
       `/v1/messages` exchange is the `primary` (several are `ambiguous`); a
       complete `count_tokens` exchange whose response has no content is
       `ancillary`; everything else — unknown routes, open start markers,
       other count_tokens — is `unclassified`. The primary is compared with
       `SdrAgent.Agents.Witness.Projection`: request grammar v2, then v3
       when v2 does not apply to the request, then v1. Only for a
       v3-selected request whose v3 result passed its evidence contract and
       is v3's response-layout refusal does projection v4 apply
       (`Projection.compare_v4/4`, D-182): an eligible v4 result replaces
       it, with its own exact contract (`WitnessEvidence.exact_v4_group?/1`;
       a failure is `evidence_contract_invalid` with no projection, never a
       v3 fallback); an ineligible one leaves the v3 result unchanged. v4
       is never tried first and never for a v2-admitted request. Its
       evidence names the
       evaluated projection and `projections_inapplicable`. Unsupported proxy versions,
       content encodings, incomplete captures and bad blobs never reach a
       comparison;
    3. in one transaction that first locks the invocation row, appends
       `WireWitnessLink`s (only changed observations: a replay is a no-op; a
       mismatch is superseded only by an evaluated comparison under a
       different projection, and never by a v4 one) and keeps operator
       attention current: at most one live critical Failure (mismatch) and
       one live warning (missing, open, ambiguous, unclassified,
       unsupported, unreadable store) per invocation, resolving a warning
       whose condition changed or cleared. An unreadable inventory
       downgrades current non-mismatch links with an `inferred` successor.

  A match is `reconciled` only for an exact runtime allowlist entry
  (`reconciled_methods`; R0-07 REQ-07-1, ADR-0005 R0 amendment item 1):
  exactly `%{provider:, cli_version:, profile_id:, model_id:,
  projection_version:, method:}` and no other key, compared with the
  invocation's recorded identity and the projection and method evaluated for
  the exchange (`allowlisted?/3`). `profile_id: nil` names generation-1 rows
  only (written before R0, without a profile); a profiled entry matches only
  generation-2 rows of that profile, so a Sonnet call never matches an Opus
  entry. Only reviewed `config/*.exs` changes define entries; there is no
  stage key. Anything else is `inferred` with `method_not_enabled`. A
  per-call `:methods` override (a bare method atom or exact entries) is
  honoured only when `allow_method_override` is configured (test
  configuration only). The model is never called again.

  **Result gate (R0-07 slice C).** `gate: %{run_id, operation_id}` is
  passed only by the facade gate step and run recovery; it must be the
  invocation's own run and that run's Operation (`{:error, :invalid_gate}`
  otherwise). The persist step then locks the Operation `FOR SHARE` before
  the invocation `FOR UPDATE` and the chain head, every Failure it opens
  carries `operation_id`, and the result carries a `receipt: %{status,
  link_id, cause_id, codes}` — the single current primary link evaluated,
  the live gate cause opened or found (critical for a mismatch, else the
  warning), and the bounded observation and link reason codes. An unconfigured store under `gate:` is `:skipped` with an empty
  receipt. Without `gate:` (the scan) nothing changes.

  `status/1` (used by `SdrAgent.Agents.witness_status/2`) is the C1
  invocation answer over current links. `enqueue/2` writes a
  `reconcile_model` Operation and its Oban job in one transaction.
  Configuration: `config :sdr_agent, SdrAgent.Agents.Witness, store_root:,
  reconciled_methods:, allow_method_override:` (`store_root: nil` keeps
  reconciliation inert).
  """

  require Ash.Query

  alias Ash.Error.Forbidden
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.Witness.GateEvidence
  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.Witness.ReconcileWorker
  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Repo

  @method :propagated_id
  @proxy_versions ["0.2.0"]
  @terminal [:completed, :failed, :unknown]
  @messages "/anthropic/v1/messages"
  @count_tokens "/anthropic/v1/messages/count_tokens"
  @subject "SdrAgent.Agents.ModelInvocation"
  @max_generations 4

  ## Configuration

  @doc """
  The configured proxy blob directory, or nil (unset: reconciliation inert).
  A configured value is returned as is. Every store read revalidates it
  (`Store.validate_root/1`), so a configured root that fails takes the
  unreadable-store downgrade path; it is never treated as unset.
  """
  def store_root, do: Keyword.get(config(), :store_root)

  @doc """
  Boot check (called from `SdrAgent.Application.start/2`): an explicitly
  configured root that is missing or untrusted refuses to start. The fixed
  message names only the error code, never the path. Unset is `:ok`.
  """
  def check_configured_root! do
    case store_root() do
      nil ->
        :ok

      root ->
        case Store.validate_root(root) do
          {:ok, _root} ->
            :ok

          {:error, code} ->
            raise "wire witness store root refused at boot (#{code}); " <>
                    "fix or unset SDR_WITNESS_STORE_ROOT"
        end
    end
  end

  @entry_keys [:cli_version, :method, :model_id, :profile_id, :projection_version, :provider]

  @doc """
  Exact entries whose matching proof may be labelled reconciled (R0-07
  REQ-07-1): maps with exactly the six keys `provider`, `cli_version`,
  `profile_id` (nil only for generation 1), `model_id`,
  `projection_version` and `method`, each of its type; any other shape —
  the pre-R0 four-key entry, an extra key such as a stage — is dropped. Dev
  and prod ship the generation-1 2.1.291 entry and the two promoted
  generation-2 2.1.294 tuples (Opus and Sonnet, R0-06); the test
  environment configures none.
  """
  def reconciled_methods do
    # Runtime entries must be exact proofs; a bare method atom is accepted
    # only through the test-only per-call override.
    config() |> Keyword.get(:reconciled_methods, []) |> Enum.filter(&exact_entry?/1)
  end

  defp exact_entry?(entry) when is_map(entry) and not is_struct(entry),
    do: Enum.sort(Map.keys(entry)) == @entry_keys and typed_entry?(entry)

  defp exact_entry?(_entry), do: false

  # `profile_id` may be nil (generation 1); every other value is required.
  defp typed_entry?(%{provider: provider, method: method} = entry)
       when is_atom(provider) and not is_nil(provider) and is_atom(method) and not is_nil(method),
       do:
         is_binary(entry.cli_version) and is_atom(entry.profile_id) and
           is_binary(entry.model_id) and is_binary(entry.projection_version)

  defp typed_entry?(_entry), do: false

  @doc """
  The exact per-call override for the calibration harness (R0-07 item 8):
  `{:ok, entries}` when `entries` is a non-empty list of exact six-key
  entries, otherwise `{:error, :inexact_override}` — a bare method atom, a
  partial map, the pre-R0 four-key shape or an extra key is refused. Being
  a test build is never spend authority; the bare-atom override remains for
  hermetic legacy fixtures only.
  """
  def exact_overrides([_ | _] = entries) do
    if Enum.all?(entries, &exact_entry?/1),
      do: {:ok, entries},
      else: {:error, :inexact_override}
  end

  def exact_overrides(_entries), do: {:error, :inexact_override}

  @doc """
  True when the shipped allowlist (`reconciled_methods/0`) holds an exact
  entry for `invocation`'s recorded identity (provider, CLI version,
  profile, model, ledger generation) together with the evaluated
  `projection_version` and `method`. Never consults a test override.
  """
  def allowlisted?(invocation, projection_version, method),
    do:
      Enum.any?(reconciled_methods(), &entry_matches?(&1, invocation, projection_version, method))

  @doc """
  The pre-call admission predicate (R0-07 slice B, row B2): true when
  `entries` (default: the shipped allowlist, `reconciled_methods/0`; never
  a per-call override) hold an exact six-key entry for the generation-2
  runtime identity `identity` (`provider`, `provider_version`,
  `profile_id`, `model_id`, `ledger_generation`), with the propagated
  method and a projection id of `Projection.current_versions/0`, compared
  literally. It establishes an eligible promoted runtime identity, never
  that the call's evaluated projection is proven: the result gate enforces
  the exact projection and method actually evaluated. A nil-profile
  (generation-1) entry never promotes a generation-2 identity.
  """
  def promoted?(identity, entries \\ reconciled_methods())

  def promoted?(%{ledger_generation: 2, profile_id: profile_id} = identity, entries)
      when is_list(entries) and not is_nil(profile_id) do
    current = Projection.current_versions()

    Enum.any?(entries, fn entry ->
      exact_entry?(entry) and entry.method == @method and entry.projection_version in current and
        entry_matches?(entry, identity, entry.projection_version, @method)
    end)
  end

  def promoted?(_identity, _entries), do: false

  # A match is labelled reconciled only for an exact allowlisted entry — or,
  # under the test-only override, a bare method atom.
  defp enabled?(entries, invocation, projection) do
    Enum.any?(entries, fn
      @method -> true
      entry -> exact_entry?(entry) and entry_matches?(entry, invocation, projection, @method)
    end)
  end

  # Every key is compared. A nil profile names generation-1 rows only; a
  # profiled entry, generation-2 rows of that profile only.
  defp entry_matches?(entry, invocation, projection, method) do
    entry.provider == invocation.provider and entry.cli_version == invocation.provider_version and
      entry.profile_id == invocation.profile_id and entry.model_id == invocation.model_id and
      entry.projection_version == projection and entry.method == method and
      invocation.ledger_generation == if(is_nil(entry.profile_id), do: 1, else: 2)
  end

  defp config, do: Application.get_env(:sdr_agent, __MODULE__, [])

  ## Reconciliation

  @doc """
  Reconciles one invocation (REC). Options: `actor:`, `store_root:`
  (default `store_root/0`), `methods:` (test-only override). Returns
  `{:ok, %{status:, links:, attention:}}`, `{:ok, %{status: :skipped}}` when
  unconfigured or not a terminal ClaudeCLI invocation, or `{:error, reason}`.
  """
  def reconcile(invocation_id, opts) do
    actor = Keyword.get(opts, :actor)
    meta = %{resource: Agents.WireWitnessLink, action: :reconcile, subject_id: invocation_id}

    Guard.run(meta, actor, fn ->
      with :ok <- authorize(actor),
           {:ok, methods} <- methods(opts),
           {:ok, hook} <- test_hook(opts),
           {:ok, tamper} <- tamper_hook(opts),
           {:ok, gate} <- gate_option(opts) do
        root = Keyword.get(opts, :store_root, store_root())
        do_reconcile(invocation_id, root, methods, actor, {hook, tamper, gate})
      end
    end)
  end

  # Unconfigured and no gate: inert, exactly as before (no read).
  defp do_reconcile(_invocation_id, nil, _methods, _actor, {_hook, _tamper, nil}),
    do: {:ok, %{status: :skipped}}

  defp do_reconcile(invocation_id, root, methods, actor, {hook, tamper, gate}) do
    with {:ok, invocation} <- GuardedCall.get(ModelInvocation, invocation_id, actor: actor),
         :ok <- own_gate(gate, invocation),
         :ok <- configured(root),
         :ok <- eligible(invocation),
         {:ok, observation} <- observe(invocation, root, actor, hook, tamper) do
      persist(invocation, observation, methods, actor, gate)
    else
      :skip -> {:ok, skipped(gate)}
      other -> other
    end
  end

  defp configured(nil), do: :skip
  defp configured(_root), do: :ok

  defp skipped(nil), do: %{status: :skipped}

  defp skipped(_gate),
    do: %{status: :skipped, receipt: %{status: :skipped, link_id: nil, cause_id: nil, codes: []}}

  ## The result gate's reconcile (R0-07 slice C)

  # `gate: %{run_id, operation_id}` — passed only by the facade gate step and
  # run recovery. `operation_id` is nil only for a run without an Operation
  # (a reply run; its gate-cause provenance is pending entity review).
  defp gate_option(opts) do
    case Keyword.fetch(opts, :gate) do
      :error ->
        {:ok, nil}

      {:ok, %{run_id: run_id, operation_id: operation_id}}
      when is_binary(run_id) and (is_binary(operation_id) or is_nil(operation_id)) ->
        {:ok, %{run_id: run_id, operation_id: operation_id}}

      {:ok, _other} ->
        {:error, :invalid_gate}
    end
  end

  # The gate is the invocation's own run and that run's Operation.
  defp own_gate(nil, _invocation), do: :ok

  defp own_gate(gate, invocation) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(id == ^gate.run_id and tenant_id == ^invocation.tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %AgentRun{id: run_id, operation_id: operation_id}}
      when run_id == invocation.agent_run_id and operation_id == gate.operation_id ->
        :ok

      _ ->
        {:error, :invalid_gate}
    end
  end

  # The receipt: the primary link the gate evaluated (the single current
  # primary, if any) and the live gate cause it opened or found — the
  # critical item for a mismatch, else the warning.
  defp receipt(links, status, live, codes) do
    link_id =
      case Enum.filter(links, &(&1.evidence["classification"] == "primary")) do
        [primary] -> primary.id
        _ -> nil
      end

    severity = if status == :mismatch, do: :critical, else: :warning
    cause = Enum.find(live, &(&1.severity == severity))
    # `codes`: the observation's bounded warning codes, and the evaluated
    # primary link's reason codes (metadata only) for the typed
    # classification of a withheld outcome (R0-07 slice C, G2).
    link_codes =
      case Enum.find(links, &(&1.id == link_id)) do
        nil -> []
        link -> link.evidence["reason_codes"] || []
      end

    %{
      status: status,
      link_id: link_id,
      cause_id: cause && cause.id,
      codes: Enum.uniq(codes ++ link_codes)
    }
  end

  defp eligible(%{provider: :claude_cli, status: status}) when status in @terminal, do: :ok
  defp eligible(_invocation), do: :skip

  defp authorize(%Actor{type: :reconciler, tenant_id: tenant_id}) when is_binary(tenant_id),
    do: :ok

  defp authorize(_actor), do: {:error, Forbidden.exception([])}

  # Test-only hook run after the observation, before persistence (stale
  # observation tests); refused unless test overrides are configured.
  defp test_hook(opts) do
    case Keyword.fetch(opts, :after_observe) do
      :error ->
        {:ok, fn -> :ok end}

      {:ok, hook} when is_function(hook, 0) ->
        if overrides?(), do: {:ok, hook}, else: {:error, :method_override_forbidden}

      {:ok, _other} ->
        {:error, :invalid_option}
    end
  end

  # Test-only seam rewriting the derived v2/v3 context group before it is
  # validated (contract-failure tests); refused unless test overrides are on.
  defp tamper_hook(opts) do
    case Keyword.fetch(opts, :evidence_tamper) do
      :error ->
        {:ok, & &1}

      {:ok, fun} when is_function(fun, 1) ->
        if overrides?(), do: {:ok, fun}, else: {:error, :method_override_forbidden}

      {:ok, _other} ->
        {:error, :invalid_option}
    end
  end

  defp overrides?, do: Keyword.get(config(), :allow_method_override, false)

  defp methods(opts) do
    case Keyword.fetch(opts, :methods) do
      :error ->
        {:ok, reconciled_methods()}

      {:ok, methods} ->
        if Keyword.get(config(), :allow_method_override, false),
          do: {:ok, methods},
          else: {:error, :method_override_forbidden}
    end
  end

  ## Observation (no database locks held)

  # The observation identity (record metadata plus the metadata of every raw
  # blob the records name) is captured before any content is read, and is
  # re-checked under the invocation lock (`fresh/2`).
  defp observe(invocation, root, actor, hook, tamper) do
    records = Store.fingerprint(root, invocation.id)

    result =
      case Store.inventory(root, invocation.id) do
        {:ok, %{exchanges: exchanges}} ->
          digests = blob_digests(exchanges)
          blobs = blob_identities(root, digests)

          with {:ok, observation} <- evaluate(invocation, root, exchanges, actor, tamper),
               do: {:ok, Map.merge(observation, %{digests: digests, blobs: blobs})}

        {:error, reason} ->
          reason = Atom.to_string(reason)
          {:ok, %{error: reason, exchanges: [], warnings: [reason], digests: [], blobs: []}}
      end

    hook.()

    with {:ok, observation} <- result,
         do: {:ok, Map.merge(observation, %{root: root, fingerprint: records})}
  end

  defp blob_digests(exchanges) do
    exchanges
    |> Enum.flat_map(&[&1.record["request_sha256"], &1.record["response_sha256"]])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp blob_identities(root, digests), do: Enum.map(digests, &Store.blob_identity(root, &1))

  defp evaluate(invocation, root, exchanges, actor, tamper) do
    primaries =
      Enum.filter(exchanges, &(&1.state == :terminal and &1.record["route"] == @messages))

    with {:ok, app} <- app_payloads(primaries, invocation, actor) do
      inventory = inventory_digest(exchanges)

      evaluated =
        Enum.map(exchanges, fn exchange ->
          exchange
          |> classify(length(primaries), invocation, root, {app, tamper})
          |> Map.merge(%{exchange: exchange, inventory: inventory})
        end)

      warnings =
        Enum.flat_map(evaluated, & &1.warnings) ++
          if(primaries == [], do: ["no_primary_exchange"], else: [])

      {:ok, %{error: nil, exchanges: evaluated, warnings: Enum.uniq(warnings)}}
    end
  end

  defp app_payloads([], _invocation, _actor), do: {:ok, nil}

  defp app_payloads(_primaries, invocation, actor),
    do: Agents.read_reconciliation_payloads(invocation, actor: actor)

  defp classify(%{state: :open}, _primaries, _invocation, _root, _app),
    do: result(:inferred, "unclassified", ["exchange_open"], warn: true)

  defp classify(
         %{record: %{"route" => @count_tokens} = record},
         _primaries,
         _invocation,
         root,
         _app
       ) do
    with nil <- gate(record),
         {:ok, body} <- Store.blob(root, record["response_sha256"]),
         {:ok, %{"input_tokens" => tokens} = response} when is_integer(tokens) <-
           Jason.decode(body),
         true <- Map.keys(response) == ["input_tokens"] do
      result(:inferred, "ancillary", [], [])
    else
      reason when is_binary(reason) ->
        result(:inferred, "unclassified", ["unclassified_exchange", reason], warn: true)

      _ ->
        result(:inferred, "unclassified", ["unclassified_exchange"], warn: true)
    end
  end

  defp classify(%{record: %{"route" => @messages}}, primaries, _invocation, _root, _app)
       when primaries > 1,
       do: result(:inferred, "ambiguous", ["multiple_primary_exchanges"], warn: true)

  defp classify(%{record: %{"route" => @messages} = record}, 1, invocation, root, {app, tamper}),
    do: primary(record, invocation, root, app, tamper)

  defp classify(_exchange, _primaries, _invocation, _root, _app),
    do: result(:inferred, "unclassified", ["unclassified_exchange"], warn: true)

  defp primary(record, invocation, root, app, tamper) do
    with nil <- gate(record),
         {:ok, request} <- Store.blob(root, record["request_sha256"]),
         {:ok, response} <- Store.blob(root, record["response_sha256"]) do
      request_grammars(invocation, app, {request, response}, tamper)
    else
      reason when is_binary(reason) -> result(:inferred, "primary", [reason], warn: true)
      {:error, reason} -> result(:inferred, "primary", [blob_reason(reason)], warn: true)
    end
  end

  # Request grammars in order: v2 (the observed CLI shape), then v3 (v2
  # plus the bounded proof 1/2 relaxations) when v2 is inapplicable to the
  # *request*, then v1. A request that a grammar admits is evaluated and
  # labelled under it, even when its response is unsupported.
  # `projections_inapplicable` records which grammars did not apply. Each
  # derived context group must be exactly that version's group: a contract
  # failure (incomplete, extra or invalid keys) is a conservative fallback
  # without any projection (so it never corrects a mismatch), never a proof
  # with dropped fields. Projection v4 (D-182; plan r5 section 6.2, choice
  # (a)) is tried only after v3 was selected, passed its contract and is
  # :unsupported (`v3_selected/4`).
  defp request_grammars(invocation, app, {request, response}, tamper) do
    grammars = [
      {"v2", &Projection.compare_v2/4, Projection.version_v2()},
      {"v3", &Projection.compare_v3/4, Projection.version_v3()}
    ]

    Enum.reduce_while(grammars, [], fn {label, compare, version}, inapplicable ->
      case compare.(invocation, app, request, response) do
        {:unsupported, %{extras: nil}} ->
          {:cont, inapplicable ++ [label]}

        evaluated when label == "v3" ->
          inputs = {invocation, app, request, response}
          {:halt, {inapplicable, v3_selected(evaluated, version, tamper, inputs)}}

        evaluated ->
          {:halt, {inapplicable, cli_projection(evaluated, version, tamper)}}
      end
    end)
    |> case do
      {inapplicable, evaluated} ->
        Map.put(evaluated, :inapplicable, inapplicable)

      inapplicable ->
        Projection.compare(invocation, app, request, response)
        |> project()
        |> Map.put(:inapplicable, inapplicable)
    end
  end

  # A v3 result stands unless it passed its contract, its verdict is
  # :unsupported and `compare_v4/4` is eligible: a contract-invalid v3
  # result is never healed by v4.
  defp v3_selected({verdict, _proof} = evaluated, version, tamper, inputs) do
    case cli_projection(evaluated, version, tamper) do
      %{projection: ^version} = v3 when verdict == :unsupported -> v4_fallback(v3, inputs, tamper)
      v3 -> v3
    end
  end

  defp v4_fallback(v3, {invocation, app, request, response}, tamper) do
    case Projection.compare_v4(invocation, app, request, response) do
      :ineligible -> v3
      evaluated -> v4_projection(evaluated, tamper)
    end
  end

  # v4's own contract: the same tamper hook, then the layout-aware exact
  # group, then validation. A failure has no projection and never falls
  # back to v3.
  defp v4_projection({verdict, proof}, tamper) do
    extras = tamper.(proof.extras)

    with true <- WitnessEvidence.exact_v4_group?(extras),
         {:ok, extras} <- WitnessEvidence.validate(extras) do
      evaluated = project({verdict, proof})

      %{
        evaluated
        | projection: Projection.version_v4(),
          extras: extras,
          reasons: Enum.uniq(evaluated.reasons ++ proof.reasons)
      }
    else
      _invalid -> result(:inferred, "primary", ["evidence_contract_invalid"], warn: true)
    end
  end

  defp cli_projection({verdict, proof}, version, tamper) do
    extras = tamper.(proof.extras)

    with true <- WitnessEvidence.exact_context_group?(extras, version),
         {:ok, extras} <- WitnessEvidence.validate(extras) do
      evaluated = project({verdict, proof})

      %{
        evaluated
        | projection: version,
          extras: extras,
          reasons: Enum.uniq(evaluated.reasons ++ proof.reasons)
      }
    else
      _invalid -> result(:inferred, "primary", ["evidence_contract_invalid"], warn: true)
    end
  end

  defp blob_reason(reason) do
    reason = Atom.to_string(reason)
    if String.starts_with?(reason, "blob_"), do: reason, else: "blob_" <> reason
  end

  # Gates every terminal exchange must pass before it can count: a reviewed
  # proxy version, no content encoding, a complete capture.
  defp gate(record) do
    cond do
      record["proxy_version"] not in @proxy_versions -> "proxy_version_unsupported"
      is_binary(record["response_content_encoding"]) -> "content_encoding_unsupported"
      not complete?(record) -> "capture_incomplete"
      true -> nil
    end
  end

  defp project({:match, proof}),
    do: %{
      result(:match, "primary", [], [])
      | digests: proof.digests,
        projection: Projection.version()
    }

  defp project({:mismatch, proof}) do
    %{
      result(:mismatch, "primary", proof.reasons, [])
      | digests: proof.digests,
        projection: Projection.version()
    }
  end

  defp project({:unsupported, proof}) do
    %{
      result(:inferred, "primary", proof.reasons, warn: true)
      | digests: proof.digests,
        projection: Projection.version()
    }
  end

  defp result(status, classification, reasons, opts) do
    %{
      status: status,
      classification: classification,
      reasons: reasons,
      warnings: if(Keyword.get(opts, :warn, false), do: reasons, else: []),
      digests: %{},
      projection: nil,
      extras: nil,
      inapplicable: nil
    }
  end

  defp complete?(record) do
    record["outcome"] == "complete" and record["http_status"] == 200 and
      record["request_capture_complete"] == true and record["response_capture_complete"] == true and
      is_binary(record["request_sha256"]) and is_binary(record["response_sha256"]) and
      (record["route"] != @messages or record["stream_complete"] == true)
  end

  defp inventory_digest(exchanges) do
    exchanges
    |> Enum.map(&[&1.record_id, Atom.to_string(&1.state), &1.record["outcome"]])
    |> Enum.sort()
    |> Canonical.encode!()
    |> then(&(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower)))
  end

  ## Persistence (one transaction; invocation row lock first)

  # Lock order (R0-07 slice C): the gate's Operation `FOR SHARE` (only with
  # `gate:`), the invocation `FOR UPDATE`, then the chain head (appends).
  defp persist(invocation, observation, methods, actor, gate) do
    Audit.transaction(fn ->
      with :ok <- lock_gate_operation(gate, invocation.tenant_id),
           {:ok, _locked} <- lock(invocation),
           :ok <- scan_may_write(gate, invocation),
           :ok <- fresh(invocation, observation),
           {:ok, current} <- Agents.current_wire_witness_links(invocation.id, actor: actor),
           :ok <- write_links(invocation, observation, current, methods, actor),
           {:ok, links} <- Agents.current_wire_witness_links(invocation.id, actor: actor),
           :ok <- attention(invocation, links, observation.warnings, actor, gate) do
        result = %{status: status(links), links: links, attention: observation.warnings}
        with_receipt(result, gate, invocation)
      else
        # Never completed work: the caller (worker) retries with a fresh
        # observation; nothing was written.
        :stale -> Repo.rollback(:stale_observation)
        :deferred -> %{status: :deferred_to_gate}
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  # Row G3 (R0-07 slice C), rechecked under the invocation FOR UPDATE lock
  # (plain read, no lock clause): without `gate:`, a completed generation-2
  # ClaudeCLI invocation with no ModelResultRelease is the gate's (running
  # run) or run recovery's (terminal run) — never the scan's. Nothing is
  # written. The gate's reconcile holds this lock and finalization holds the
  # invocation FOR SHARE while it writes the release, so this read sees the
  # committed outcome of either.
  defp scan_may_write(nil, invocation),
    do: if(gate_owned?(invocation), do: :deferred, else: :ok)

  defp scan_may_write(_gate, _invocation), do: :ok

  @doc """
  Whether `invocation` is owned by the result gate or run recovery (row G3):
  a completed generation-2 ClaudeCLI invocation with no `ModelResultRelease`.
  A read error counts as owned (the scan then writes nothing).
  """
  @spec gate_owned?(struct()) :: boolean()
  def gate_owned?(
        %ModelInvocation{provider: :claude_cli, ledger_generation: 2, status: :completed} =
          invocation
      ) do
    decided? =
      ModelResultRelease
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^invocation.tenant_id and model_invocation_id == ^invocation.id
      )
      |> Ash.exists?()

    not decided?
  rescue
    _error -> true
  end

  def gate_owned?(_invocation), do: false

  # Under the invocation lock, a metadata-only re-check (lstat of at most 64
  # record entries and of the blobs they name, no content read) that the
  # store still holds what was observed; an older observation must not
  # overwrite the outcome of a newer one. A changed store returns
  # `{:error, :stale_observation}` and writes nothing.
  defp fresh(invocation, %{root: root, fingerprint: fingerprint, digests: digests, blobs: blobs}) do
    if Store.fingerprint(root, invocation.id) == fingerprint and
         blob_identities(root, digests) == blobs,
       do: :ok,
       else: :stale
  end

  defp lock_gate_operation(%{operation_id: id}, tenant_id) when is_binary(id) do
    Operation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one()
    |> case do
      {:ok, %Operation{}} -> :ok
      _ -> {:error, :invalid_gate}
    end
  end

  defp lock_gate_operation(_gate, _tenant_id), do: :ok

  defp with_receipt(result, nil, _invocation), do: result

  defp with_receipt(result, _gate, invocation) do
    case live_failures(invocation) do
      {:ok, live} ->
        Map.put(result, :receipt, receipt(result.links, result.status, live, result.attention))

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp lock(invocation) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(id == ^invocation.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
  end

  defp write_links(invocation, %{error: nil, exchanges: exchanges}, current, methods, actor) do
    heads = Map.new(current, &{&1.proxy_record_ref, &1})
    observed = MapSet.new(exchanges, & &1.exchange.record_id)

    observed_writes =
      Enum.map(exchanges, fn evaluated ->
        desired = desired_link(invocation, evaluated, methods)
        {Map.get(heads, desired.proxy_record_ref), desired, "reconciliation_rerun"}
      end)

    # An exchange linked before but absent from the current inventory can no
    # longer support assurance: downgrade it (mismatches are kept).
    vanished_writes =
      for head <- current, not MapSet.member?(observed, head.proxy_record_ref) do
        {head, downgraded(head, "exchange_missing"), "exchange_missing"}
      end

    put_all(observed_writes ++ vanished_writes, actor)
  end

  # An unreadable inventory: downgrade every current non-mismatch link.
  defp write_links(_invocation, %{error: reason}, current, _methods, actor) do
    current
    |> Enum.map(&{&1, downgraded(&1, reason), "store_unreadable"})
    |> put_all(actor)
  end

  defp put_all(writes, actor) do
    Enum.reduce_while(writes, :ok, fn {head, desired, reason}, :ok ->
      case put_link(head, desired, reason, actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp downgraded(head, reason) do
    evidence =
      head.evidence
      |> Map.delete("supersede_reason")
      |> Map.delete("projection_version")
      |> Map.put(
        "reason_codes",
        Enum.take(Enum.uniq([reason | head.evidence["reason_codes"] || []]), 16)
      )

    %{
      model_invocation_id: head.model_invocation_id,
      proxy_record_ref: head.proxy_record_ref,
      proxy_request_sha256: head.proxy_request_sha256,
      proxy_response_sha256: head.proxy_response_sha256,
      link_status: :inferred,
      method: head.method,
      evidence: evidence
    }
  end

  defp put_link(nil, desired, _reason, actor),
    do: desired |> Map.delete(:compared?) |> Agents.link_wire_witness(actor: actor)

  defp put_link(head, desired, reason, actor) do
    {compared?, desired} = Map.pop(desired, :compared?, false)

    cond do
      same?(head, desired) ->
        {:ok, :unchanged}

      # C3: only an evaluated comparison (match or mismatch) under a
      # different projection may correct a mismatch; weaker or unsupported
      # observations never do, whatever projection label they carry (a v1
      # fallback labels its unsupported result v1). A v4 observation never
      # supersedes a mismatch, whatever its status (D-182; plan r5 6.5).
      head.link_status == :mismatch and
          (not compared? or not is_binary(desired.evidence["projection_version"]) or
             head.evidence["projection_version"] == desired.evidence["projection_version"] or
             desired.evidence["projection_version"] == Projection.version_v4()) ->
        {:ok, :mismatch_kept}

      true ->
        desired
        |> Map.put(:supersedes_id, head.id)
        |> Map.update!(:evidence, &Map.put(&1, "supersede_reason", reason))
        |> Agents.link_wire_witness(actor: actor)
    end
  end

  defp same?(head, desired) do
    head.link_status == desired.link_status and head.method == desired.method and
      head.proxy_request_sha256 == desired.proxy_request_sha256 and
      head.proxy_response_sha256 == desired.proxy_response_sha256 and
      Map.delete(head.evidence, "supersede_reason") == desired.evidence
  end

  defp desired_link(invocation, evaluated, methods) do
    %{exchange: %{record_id: record_id, record: record}} = evaluated

    {status, reasons} =
      case evaluated.status do
        :match ->
          if enabled?(methods, invocation, evaluated.projection),
            do: {:reconciled, evaluated.reasons},
            else: {:inferred, ["method_not_enabled" | evaluated.reasons]}

        other ->
          {other, evaluated.reasons}
      end

    %{
      model_invocation_id: invocation.id,
      proxy_record_ref: record_id,
      proxy_request_sha256: decode_hex(record["request_sha256"]),
      proxy_response_sha256: decode_hex(record["response_sha256"]),
      link_status: status,
      method: @method,
      evidence: evidence(invocation, evaluated, record, reasons),
      # Internal (popped before the action): an evaluated comparison.
      compared?: evaluated.status in [:match, :mismatch]
    }
  end

  defp evidence(invocation, evaluated, record, reasons) do
    candidate =
      %{
        "witness_schema" => record["schema_version"],
        "proxy_version" => record["proxy_version"],
        "cli_version" => invocation.provider_version,
        "route" => record["route"],
        "http_method" => record["method"],
        "http_status" => record["http_status"],
        "outcome" => record["outcome"],
        "started_at" => record["started_at"],
        "completed_at" => record["completed_at"],
        "request_bytes_seen" => record["request_bytes_seen"],
        "response_bytes_seen" => record["response_bytes_seen"],
        "request_capture_complete" => record["request_capture_complete"],
        "response_capture_complete" => record["response_capture_complete"],
        "stream_complete" => record["stream_complete"],
        "response_content_encoding" => record["response_content_encoding"],
        "classification" => evaluated.classification,
        "projection_version" => evaluated.projection,
        "app_request_sha256" => hex(invocation.request_sha256),
        "app_response_sha256" => hex(invocation.response_sha256),
        "inventory_sha256" => evaluated.inventory,
        "reason_codes" => reasons |> Enum.uniq() |> Enum.take(16),
        "projections_inapplicable" => evaluated.inapplicable
      }
      |> Map.merge(evaluated.digests)
      # R0-07 item 7: a gated parent's identity; generation 1 stays legacy.
      |> Map.merge(WitnessEvidence.identity(invocation))

    # Untrusted proxy metadata: keep only values the allowlist accepts. The
    # v2/v3 context group was validated as a whole (exact keys) and is merged
    # unfiltered; it cannot overwrite these keys.
    candidate
    |> Enum.filter(fn {key, value} ->
      not is_nil(value) and match?({:ok, _}, WitnessEvidence.validate(%{key => value}))
    end)
    |> Map.new()
    |> Map.merge(evaluated.extras || %{})
  end

  ## Attention (same transaction)

  # Row G4 (R0-07 slice C): after a withheld release, the cause its event
  # binds is protected (`SdrAgent.Agents.Witness.GateEvidence`). Read here,
  # under the invocation FOR UPDATE lock, whatever the caller: a gate-mode
  # reconcile that observed before a competing finalizer, or is called
  # after the release, honours it too (review MF3).
  defp attention(invocation, links, warnings, actor, gate) do
    with {:ok, live} <- live_failures(invocation),
         {:ok, protection} <- GateEvidence.protection(invocation) do
      critical? = Enum.any?(links, &(&1.link_status == :mismatch))
      warnings = if critical?, do: [], else: Enum.sort(warnings)
      {criticals, live_warnings} = Enum.split_with(live, &(&1.severity == :critical))

      with :ok <-
             ensure_critical(critical?, criticals, {invocation, links, protection}, actor, gate),
           :ok <-
             ensure_warning(warnings, live_warnings, {invocation, links, protection}, actor, gate) do
        GateEvidence.note(protection, invocation, links, actor)
      end
    end
  end

  # A protected critical (live) is already in `criticals`; a resolved one is
  # not reopened for the same mismatch, only for a distinct later one.
  defp ensure_critical(true, [], {invocation, links, protection}, actor, gate) do
    if is_nil(protection) or GateEvidence.distinct_mismatch?(protection, links),
      do: open(invocation, :critical, "mismatch", actor, gate),
      else: :ok
  end

  defp ensure_critical(_needed, _live, _held, _actor, _gate), do: :ok

  defp ensure_warning(warnings, live, {invocation, links, protection}, actor, gate) do
    message = message(warnings)
    {protected, live} = Enum.split_with(live, &(protection && &1.id == protection.cause_id))
    {keep, stale} = Enum.split_with(live, &(warnings != [] and &1.message == message))

    with :ok <- resolve_all(stale, actor) do
      if warnings == [] or keep != [] or protected != [] or unchanged?(protection, links),
        do: :ok,
        else: open(invocation, :warning, Enum.join(warnings, ","), actor, gate)
    end
  end

  defp unchanged?(nil, _links), do: false
  defp unchanged?(protection, links), do: not GateEvidence.changed?(protection, links)

  defp message([]), do: nil
  defp message(warnings), do: message_for(Enum.join(warnings, ","))

  defp message_for(reasons),
    do: "wire witness #{reasons}: model invocation needs operator review"

  # With `gate:`, the opened cause carries the run's Operation (R0-07 slice C).
  defp open(invocation, severity, reasons, actor, gate) do
    attrs = %{
      subject_resource: @subject,
      subject_id: invocation.id,
      class: :reconciliation_required,
      severity: severity,
      message: message_for(reasons),
      retryable: false
    }

    attrs = if gate, do: Map.put(attrs, :operation_id, gate.operation_id), else: attrs

    case Operations.open_failure(attrs, actor: actor) do
      {:ok, _failure} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_all(failures, actor) do
    Enum.reduce_while(failures, :ok, fn failure, :ok ->
      case Operations.resolve_failure(
             failure,
             %{resolution_note: "witness condition changed or cleared on reconciliation"},
             actor: actor
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp live_failures(invocation) do
    Failure
    |> Ash.Query.for_read(:attention, %{}, Kernel.opts(invocation.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^invocation.tenant_id and subject_resource == ^@subject and
        subject_id == ^invocation.id and class == :reconciliation_required
    )
    |> Ash.read()
  end

  ## Invocation answer (C1)

  @doc """
  The invocation-level witness status over its current links:
  `:unwitnessed` (none), `:mismatch` (any current mismatch), `:reconciled`
  (exactly one current reconciled primary and every other current link
  ancillary) or `:inferred`.
  """
  def status([]), do: :unwitnessed

  def status(links) do
    {primaries, others} = Enum.split_with(links, &(&1.evidence["classification"] == "primary"))

    cond do
      Enum.any?(links, &(&1.link_status == :mismatch)) ->
        :mismatch

      match?([%{link_status: :reconciled}], primaries) and
          Enum.all?(others, &(&1.evidence["classification"] == "ancillary")) ->
        :reconciled

      true ->
        :inferred
    end
  end

  ## Scheduling

  @doc """
  REC: enqueues reconciliation `generation` (default 1) of an invocation —
  an Oban job on the `reconciliation` queue and its `reconcile_model`
  Operation (key `reconcile_model:<id>:<generation>`) in one transaction.
  Idempotent: an existing Operation for the key is returned.
  """
  def enqueue(invocation_id, opts) do
    actor = Keyword.get(opts, :actor)
    generation = Keyword.get(opts, :generation, 1)
    meta = %{resource: Operation, action: :enqueue_reconcile_model, subject_id: invocation_id}

    # Through the guard, so a refused auditor mutation is audited (S2).
    Guard.run(meta, actor, fn ->
      with :ok <- authorize(actor),
           :ok <- valid_generation(generation),
           {:ok, invocation} <- reconcilable(invocation_id, actor) do
        do_enqueue(invocation.id, generation, actor)
      end
    end)
  end

  defp do_enqueue(invocation_id, generation, actor) do
    key = "reconcile_model:#{invocation_id}:#{generation}"

    with {:ok, nil} <- find_operation(key, actor),
         {:error, error} <- insert(invocation_id, generation, key, actor) do
      recover_race(key, actor, error)
    else
      {:ok, %Operation{} = operation} -> {:ok, operation}
      other -> other
    end
  end

  @doc "Maximum reconciliation generations per invocation (initial pass + re-drives)."
  def max_generations, do: @max_generations

  defp valid_generation(generation)
       when is_integer(generation) and generation in 1..@max_generations,
       do: :ok

  defp valid_generation(_generation), do: {:error, :invalid_generation}

  # Only a terminal ClaudeCLI invocation of the actor's tenant is scheduled.
  defp reconcilable(invocation_id, actor) when is_binary(invocation_id) do
    with {:ok, invocation} <- GuardedCall.get(ModelInvocation, invocation_id, actor: actor) do
      if eligible(invocation) == :ok, do: {:ok, invocation}, else: {:error, :not_reconcilable}
    end
  rescue
    _invalid_id -> {:error, :not_reconcilable}
  end

  defp reconcilable(_invocation_id, _actor), do: {:error, :not_reconcilable}

  # A concurrent enqueue won the (tenant, idempotency_key) identity; ours
  # rolled back with its job.
  defp recover_race(key, actor, error) do
    case find_operation(key, actor) do
      {:ok, %Operation{} = existing} -> {:ok, existing}
      _ -> {:error, error}
    end
  end

  defp insert(invocation_id, generation, key, actor) do
    Audit.transaction(fn ->
      args = %{
        "tenant_id" => actor.tenant_id,
        "model_invocation_id" => invocation_id,
        "generation" => generation
      }

      with {:ok, job} <- Oban.insert(ReconcileWorker.new(args)),
           {:ok, operation} <-
             Operations.create_operation(
               %{
                 kind: :reconcile_model,
                 queue: :reconciliation,
                 oban_job_id: job.id,
                 subject_resource: @subject,
                 subject_id: invocation_id,
                 idempotency_key: key,
                 correlation_id: invocation_id,
                 max_attempts: ReconcileWorker.max_attempts()
               },
               actor: actor
             ) do
        operation
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @doc "The reconcile_model Operations of an invocation, oldest first."
  def operations(invocation_id, actor) do
    Operation
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(kind == :reconcile_model and subject_id == ^invocation_id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read()
  end

  defp find_operation(key, actor) do
    Operation
    |> GuardedCall.read_query(actor: actor)
    |> Ash.Query.filter(idempotency_key == ^key)
    |> Ash.read_one()
  end

  @doc "True when the invocation has a live warning attention condition."
  def live_warning?(invocation) do
    case live_failures(invocation) do
      {:ok, failures} -> Enum.any?(failures, &(&1.severity == :warning))
      _ -> false
    end
  end

  defp hex(nil), do: nil
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp decode_hex(nil), do: nil
  defp decode_hex(hex), do: Base.decode16!(hex, case: :lower)
end
