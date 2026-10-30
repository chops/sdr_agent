defmodule SdrAgent.PrototypeGateFixtures do
  @moduledoc """
  D-237 slice S2 test fixtures (interfaces r6 IF-4): the partitioned
  admission, release and basis paths in prototype runtime. Synthetic data
  only; no model call, no network, no witness store.

  Every row is built through real APIs, never with a fabricated success:

    * `bound!/1` binds a prototype with S1's
      `SdrAgent.PrototypeFixtures.bind/1` (`enter_runtime: false`), creates a
      human admin, saves the offering profile a business run needs (C4-R8)
      and registers the agent definition **before** prototype runtime is
      entered (user and settings administration are refused inside it);
      `enter!/1` then enters prototype runtime with the bound snapshot;
    * `prototype!/1` is `bound!/1`, `enter!/1`, then the one funded grant
      through `SdrAgent.Agents.provision_prototype_grant/2`, as the operator,
      with the owner100 worksheet whose exact receipt it writes (0600)
      under S1's owned scratch root (`PrototypeFixtures.scratch_dir!/1`);
    * `pre_runtime!/1` is `bound!/1` plus a completed ClaudeCLI invocation
      reserved through the ordinary domain path before prototype runtime is
      entered: it records no prototype authority, so the prototype gate
      must never release it (for the checks that precede the authority);
    * `run!/2` starts an assignment run (with its `research_lead`
      Operation) in the bound tenant as the agent runtime;
    * `completed!/3` reserves a generation-2 ClaudeCLI call through
      `SdrAgent.Agents.reserve_model_invocation/3`, launches it through
      `SdrAgent.Agents.admit_launch/3` and completes it, all from the test
      process, with the store root unset;
    * `finalize/4` calls `SdrAgent.Agents.ResultGate.finalize/4` with an
      outcome (by default the absent store's `{:ok, absent_receipt()}`).

  Prototype tests are `async: false` (`SdrAgent.PrototypeCase`).
  """

  import ExUnit.Assertions
  import SdrAgent.AuditCase, only: [human: 2, system_actor: 2, events_of_type: 2, tamper!: 2]

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.OwnerAllowanceFixtures
  alias SdrAgent.PrototypeFixtures

  @doc "The absent store's reconcile receipt (`Witness.reconcile/2` with no root, under a gate)."
  def absent_receipt, do: %{status: :skipped, link_id: nil, cause_id: nil, codes: []}

  @doc """
  A bound prototype in prototype runtime with its provisioned grant:
  S1's fixture map plus `grant:`, `agent:` (the tenant's agent runtime),
  `admin:` (a human admin created before runtime) and `definition:`.
  Options are passed to `PrototypeFixtures.bind/1`.
  """
  def prototype!(opts \\ []) do
    fx = bound!(opts)
    enter!(fx)
    Map.put(fx, :grant, provision!(fx))
  end

  @doc """
  A bound prototype NOT yet in prototype runtime: S1's fixture map plus
  `admin:` (a human admin), the saved offering profile and `definition:`,
  all arranged in ordinary runtime (prototype runtime refuses user and
  settings administration), and `agent:`. Enter runtime with `enter!/1`.
  """
  def bound!(opts \\ []) do
    result = PrototypeFixtures.bind(Keyword.put(opts, :enter_runtime, false))
    assert match?({:ok, %{}}, result), "the prototype binding fixture failed: #{inspect(result)}"
    {:ok, fx} = result

    admin = human(:admin, fx.tenant)
    :ok = AgentsFixtures.ensure_offering!(fx.tenant)
    definition = AgentsFixtures.definition!(fx.tenant)

    Map.merge(fx, %{
      admin: admin,
      definition: definition,
      agent: system_actor(:agent_runtime, fx.tenant)
    })
  end

  @doc "Enters prototype runtime with the bound snapshot (S1's test seam)."
  def enter!(fx), do: assert(PrototypeFixtures.enter_runtime(fx.snapshot) == :ok)

  @doc """
  A bound prototype in prototype runtime holding a completed generation-2
  ClaudeCLI invocation that was reserved, sent and completed BEFORE
  prototype runtime was entered, through the ordinary domain path (an
  admin's ordinary grant, the ordinary admission gate): `run:`,
  `invocation:` and `grant:` (the ordinary grant) are added. Its reservation
  event records no prototype authority, so the prototype gate must never
  release it; the tests that use it exercise the checks that come before
  the authority (binding, observation, known evidence, interrupted and
  timed-out gates). Provisioning is not needed.
  """
  def pre_runtime!(opts \\ []) do
    fx = bound!(opts)
    grant = AgentsFixtures.grant!(fx.tenant, %{}, fx.admin)
    run = run!(fx)
    key = "d237-s2-pre-#{System.unique_integer([:positive])}"
    invocation = AgentsFixtures.claude_completed!(run, fx.agent, key)
    enter!(fx)
    Map.merge(fx, %{grant: grant, run: run, invocation: invocation})
  end

  @doc "Provisions the one funded grant as the operator (S1's API); returns it."
  def provision!(fx) do
    root = PrototypeFixtures.scratch_dir!()
    bytes = Jason.encode!(worksheet(root))

    result =
      Agents.provision_prototype_grant(
        %{worksheet: bytes, worksheet_sha256: sha(bytes)},
        actor: fx.actor,
        evidence_root: root
      )

    assert match?({:ok, %{id: _}}, result), "provisioning failed: #{inspect(result)}"
    {:ok, grant} = result
    # The provisioned grant with its allocations (S1 returns them unloaded).
    Ash.load!(grant, :allocations, authorize?: false)
  end

  defp worksheet(root), do: OwnerAllowanceFixtures.worksheet(root)

  @doc "Lowercase hex sha256 of `bytes`."
  def sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc """
  A running run of the bound tenant, started as the agent runtime with a
  running `research_lead` Operation. Options: `usage_origin:` (default
  `:assignment`).
  """
  def run!(fx, opts \\ []) do
    key = "d237-s2-run:#{System.unique_integer([:positive])}"

    {:ok, operation} =
      SdrAgent.Operations.create_operation(
        %{
          kind: :research_lead,
          queue: :research,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: Ecto.UUID.generate(),
          idempotency_key: key,
          correlation_id: Ecto.UUID.generate(),
          max_attempts: 1
        },
        actor: fx.agent
      )

    {:ok, operation} = SdrAgent.Operations.start_operation(operation, actor: fx.agent)

    attrs =
      fx.definition
      |> AgentsFixtures.run_attrs(opts)
      |> Map.put(:operation_id, operation.id)

    {:ok, run} = Agents.create_run(attrs, actor: fx.agent)
    {:ok, run} = Agents.start_run(run, actor: fx.agent)
    run
  end

  @doc "The reservation attributes of a ClaudeCLI call (`overrides` merged)."
  def call_attrs(overrides \\ %{}) do
    "d237-s2-call-#{System.unique_integer([:positive])}"
    |> AgentsFixtures.claude_attrs()
    |> Map.merge(Map.new(overrides))
  end

  @doc "`Agents.reserve_model_invocation/3` of a ClaudeCLI call in `run`."
  def reserve(fx, run, overrides \\ %{}),
    do: Agents.reserve_model_invocation(run, call_attrs(overrides), actor: fx.agent)

  @doc "`Agents.admit_launch/3` of `invocation` under its own profile."
  def launch(fx, invocation),
    do: Agents.admit_launch(invocation.id, invocation.profile_id, actor: fx.agent)

  @doc """
  A completed generation-2 ClaudeCLI invocation of `run`, reserved and
  launched through the prototype path. Options: `attrs:` (reservation
  overrides), `completion:` (default `AgentsFixtures.completion/0`).
  """
  def completed!(fx, run, opts \\ []) do
    reserved = reserve(fx, run, Keyword.get(opts, :attrs, %{}))
    assert match?({:ok, %ModelInvocation{}}, reserved), "reservation: #{inspect(reserved)}"
    {:ok, reserved} = reserved

    sent = launch(fx, reserved)
    assert match?({:ok, %ModelInvocation{status: :sent}}, sent), "launch: #{inspect(sent)}"
    {:ok, sent} = sent

    completion = Keyword.get(opts, :completion, AgentsFixtures.completion())
    {:ok, done} = Agents.complete_model_invocation(sent, completion, actor: fx.agent)
    done
  end

  @doc "The gate of `run`: `%{run_id:, operation_id:}`."
  def gate(run), do: %{run_id: run.id, operation_id: run.operation_id}

  @doc "`ResultGate.finalize/4` of `invocation` in `run` with `outcome`."
  def finalize(invocation, run, outcome \\ {:ok, absent_receipt()}, opts \\ []),
    do: ResultGate.finalize(invocation, gate(run), outcome, opts)

  @doc "The 14-key authority IF-4 records for `invocation` of `fx`'s binding."
  def expected_authority(fx, invocation) do
    s = fx.snapshot

    %{
      "policy_id" => "d237-prototype/1",
      "entry_sha256" => s.policy_entry_sha256,
      "funding_id" => "d237-funding/1",
      "binding_id" => s.id,
      "instance_id" => s.instance_id,
      "tenant_id" => s.tenant_id,
      "operator_user_id" => s.operator_user_id,
      "dataset_class" => "real_prototype",
      "profile_id" => Atom.to_string(invocation.profile_id),
      "purpose" => Atom.to_string(invocation.purpose),
      "grant_id" => invocation.grant_id,
      "grant_revision" => fx.grant.revision,
      "allocation_id" => invocation.allocation_id,
      "witness_mode" => "absent"
    }
  end

  @doc "The `model.invocation.reserved` events of `invocation`."
  def reserved_events(fx, invocation) do
    fx.tenant
    |> events_of_type("model.invocation.reserved")
    |> Enum.filter(&(&1.subject_id == invocation.id))
  end

  @doc "Rewrites one key of the reserved event's recorded authority behind the application."
  def forge_authority!(fx, invocation, key, value) do
    [event] = reserved_events(fx, invocation)

    tamper!(
      "UPDATE audit_events SET payload = jsonb_set(payload, $2, $3::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(event.id), ["arguments", "prototype_authority", key], Jason.encode!(value)]
    )
  end

  @doc "Rewrites columns of the provisioned grant behind the application."
  def tamper_grant!(fx, set, params \\ []) do
    tamper!(
      "UPDATE model_call_grants SET #{set} WHERE id = $1",
      [Ecto.UUID.dump!(fx.grant.id) | params]
    )
  end

  @doc "Drifts the live database identity away from the binding (`check_live/0` then fails)."
  def drift! do
    assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok
  end

  @doc "The release of `invocation` (kernel read), or nil."
  def release(invocation) do
    SdrAgent.Agents.ModelResultRelease
    |> Ash.Query.filter(model_invocation_id == ^invocation.id)
    |> Ash.read_one!(SdrAgent.Audit.Kernel.opts(invocation.tenant_id))
  end

  @doc "The events of `type` whose subject is `release`."
  def release_events(fx, type, release) do
    fx.tenant |> events_of_type(type) |> Enum.filter(&(&1.subject_id == release.id))
  end

  @doc "Every invocation of `fx`'s tenant (any provider)."
  def invocations(fx) do
    ModelInvocation
    |> Ash.Query.filter(tenant_id == ^fx.tenant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  @doc "Every invocation charged to the provisioned grant (attempts are never refunded)."
  def charged(fx) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^fx.grant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  ## RED-b2c (Codex 3122b0d4): the own-context basis and value-free results

  @doc "The lowercase hex `sdr-canonical-json/1` SHA256 of `term`."
  def canonical_hex(term),
    do: Base.encode16(SdrAgent.Audit.Canonical.sha256(term), case: :lower)

  @doc """
  The `d237-basis/1` the gate would build for the completed `invocation` of
  `fx` decided at `decided_at`: the dictionary pinned by
  `ProvisionedReleaseTest` (the boot snapshot, the compiled entries, the
  charged grant and the stored invocation and run), recomputed here from the
  stored rows. Test data only: it never decides anything by itself.
  """
  def expected_basis(fx, invocation, decided_at) do
    inv = Ash.get!(ModelInvocation, invocation.id, authorize?: false)
    run = Ash.get!(SdrAgent.Agents.AgentRun, inv.agent_run_id, authorize?: false)
    s = fx.snapshot
    hex = &Base.encode16(&1, case: :lower)

    %{
      "schema" => "d237-basis/1",
      "policy" => %{
        "id" => "d237-prototype/1",
        "acceptance_ref" => "D-249",
        "entry_sha256" => s.policy_entry_sha256
      },
      "funding" => %{
        "id" => "d237-funding/1",
        "sha256" => "d56308736c6c5ef7a4521b9b442ec85298ab06f82d8ea447de35637e45d6349a",
        "grant_id" => fx.grant.id,
        "grant_revision" => fx.grant.revision,
        "allocation_id" => inv.allocation_id,
        "operator_user_id" => s.operator_user_id
      },
      "prototype" => %{
        "binding_id" => s.id,
        "instance_id" => s.instance_id,
        "tenant_id" => s.tenant_id,
        "dataset_class" => s.dataset_class,
        "database" => s.database,
        "database_oid" => s.database_oid,
        "system_identifier" => Integer.to_string(s.system_identifier)
      },
      "window" => %{
        "starts_at" => "2026-10-28T02:38:32.000000Z",
        "expires_at" => "2026-11-07T07:00:00.000000Z",
        "decided_at" => Calendar.strftime(decided_at, "%Y-%m-%dT%H:%M:%S.%fZ")
      },
      "invocation" => %{
        "id" => inv.id,
        "run_id" => inv.agent_run_id,
        "lead_id" => run.lead_id,
        "usage_origin" => Atom.to_string(run.usage_origin),
        "purpose" => Atom.to_string(inv.purpose),
        "request_sha256" => hex.(inv.request_sha256),
        "response_sha256" => hex.(inv.response_sha256),
        "output_schema_sha256" => hex.(inv.output_schema_sha256)
      },
      "identity" => %{
        "provider" => "claude_cli",
        "cli_version" => inv.provider_version,
        "profile_id" => Atom.to_string(inv.profile_id),
        "model_id" => inv.model_id,
        "prompt_builder" => inv.model_catalog_entry["prompt_builder"],
        "ledger_generation" => inv.ledger_generation
      },
      "observation" => %{"witness_mode" => "absent", "classification" => "store_unconfigured"},
      "assurance" => "unverified",
      "label" => "UNVERIFIED (PROTOTYPE)"
    }
  end

  @doc """
  A `released_unverified` decision of `invocation` with the caller-built
  `extra` (`basis:`, `basis_sha256:`) under a Prelocked context with the
  prototype gate's finalizer, taking the gate's release-branch locks first
  (the run `FOR UPDATE`, its Operation, the invocation `FOR SHARE`, the
  charged grant and allocation, then the head). A finalizer stand-in for
  the action's own contract; it never stands in for the gate's decision.
  The transaction's result: `{:ok, release}` or `{:error, error}`.
  """
  def decide_own(fx, run, invocation, extra) do
    tenant_id = invocation.tenant_id

    SdrAgent.Audit.transaction(fn ->
      {:ok, locked_run} =
        ResultGate.lock(SdrAgent.Agents.AgentRun, run.id, tenant_id, "FOR UPDATE")

      :ok = ResultGate.lock_operation(locked_run, tenant_id)
      {:ok, held} = ResultGate.lock(ModelInvocation, invocation.id, tenant_id, "FOR SHARE")
      :ok = SdrAgent.Agents.Admission.lock_charge(held)
      {:ok, _head} = SdrAgent.Audit.Kernel.lock_head(tenant_id)

      bindings = %{
        tenant_id: tenant_id,
        model_invocation_id: invocation.id,
        finalizer: :prototype_gate
      }

      SdrAgent.Agents.ReleaseDecision.Prelocked.run(
        bindings,
        &unverified_or_rollback(fx, invocation, extra, &1)
      )
    end)
  end

  defp unverified_or_rollback(fx, invocation, extra, prelocked) do
    attrs =
      Map.merge(
        %{
          model_invocation_id: invocation.id,
          disposition: :released_unverified,
          reason: :owner_prototype_unverified
        },
        extra
      )

    case Agents.decide_result_release(attrs, actor: fx.agent, prelocked: prelocked) do
      {:ok, release} -> release
      {:error, error} -> SdrAgent.Repo.rollback(error)
    end
  end

  @state_probe "SELECT 1"

  @doc """
  The pinned first statement of `ReleasedScope.run/3`: one raw read-only
  state probe of the current transaction (Codex 79819840 R2; ab4320ae).
  """
  def state_probe, do: @state_probe

  @doc """
  The R2 oracle over SQL captured by `SdrAgent.GateFixtures.capture/1` around
  an owning `Audit.transaction`: right after the FIRST observed `abort`
  statement come exactly the state probe and then exactly the owner's
  rollback (`"rollback"`, DBConnection's transaction log entry), and nothing
  else. A business statement, a second probe, a savepoint, release or commit,
  or a missing probe fails it. Pinned by `StateProbeOracleTest`'s controls.
  """
  def probe_then_owner_rollback?(sql, abort \\ "SELECT 1/0") do
    match?([^abort, @state_probe, "rollback"], Enum.drop_while(sql, &(&1 != abort)))
  end

  @doc """
  A value-free shape of the statements after the first `abort` for failure
  messages (Codex 4809c027: never print raw SQL): each statement as the
  closed category `:probe`, `:rollback` or `:other`, in order.
  """
  def after_abort_shape(sql, abort \\ "SELECT 1/0") do
    sql
    |> Enum.drop_while(&(&1 != abort))
    |> Enum.drop(1)
    |> Enum.map(fn
      @state_probe -> :probe
      "rollback" -> :rollback
      _other -> :other
    end)
  end

  @doc """
  TF-1 RED (plan r2 section 5): in prototype runtime, through real APIs
  only, a synthetic `.test` lead assigned with `SdrAgent.SDR.assign_lead/2`
  (its Oban job bound to the run's Operation by `oban_job_id`), the
  Operation and the run started, and one completed ClaudeCLI call:
  `%{run:, operation:, job:, invocation:}`. The ICP, sequence and campaign
  are created as the bound admin (no new user inside prototype runtime).
  """
  def assigned!(fx) do
    campaign = SdrAgent.SalesFixtures.active_campaign!(fx.tenant)
    lead = SdrAgent.SalesFixtures.lead!(fx.tenant)

    assigned = SdrAgent.SDR.assign_lead(lead, campaign_id: campaign.id, actor: fx.admin)
    assert match?({:ok, %{run: _, operation: _, job: _}}, assigned), "prerequisite: assign"
    {:ok, %{run: run, operation: operation, job: job}} = assigned

    {:ok, operation} = SdrAgent.Operations.start_operation(operation, actor: fx.agent)
    {:ok, run} = Agents.start_run(run, actor: fx.agent)
    %{run: run, operation: operation, job: job, invocation: completed!(fx, run)}
  end

  @doc """
  Makes the assignment's job not live through Oban's own API
  (`Oban.cancel_job/1`) and freezes the clock past the sweeper's grace, so
  `SdrAgent.SDR.StaleRunSweeper.sweep/1` judges the run abandoned.
  """
  def abandon!(assigned) do
    :ok = Oban.cancel_job(assigned.job.id)
    run = Ash.get!(SdrAgent.Agents.AgentRun, assigned.run.id, authorize?: false)
    stale = SdrAgent.SDR.StaleRunSweeper.stale_after_seconds() + 1
    SdrAgent.Clock.freeze(DateTime.add(run.started_at, stale, :second))
  end

  @doc """
  A value-free summary of a result for assertion messages (Codex 3122b0d4
  R5: no basis, output or raw error dumps): the result's tag and, for an
  error, each error's module and field. Never a value or a message. A
  closed atom reason is kept as is; any other non-struct leaf is the fixed
  `:term` (Codex 79819840: no BadMapError from a technical reason).
  """
  def summary({:ok, %{__struct__: module}}), do: {:ok, module}
  def summary({:ok, _value}), do: {:ok, :value}
  def summary({:error, reason}) when is_atom(reason), do: {:error, reason}

  def summary({:error, error}) do
    errors =
      case error do
        %{__struct__: _module, errors: errors} when is_list(errors) -> errors
        error -> [error]
      end

    {:error, Enum.map(errors, &leaf/1)}
  end

  def summary({tag, %{__struct__: module}, _rest}) when is_atom(tag), do: {tag, module}
  def summary(other) when is_atom(other), do: other
  def summary(_other), do: :other

  defp leaf(%{__struct__: module} = error), do: {module, Map.get(error, :field)}
  defp leaf(reason) when is_atom(reason), do: reason
  defp leaf(_term), do: :term
end
