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
      with a counts-only worksheet whose evidence files it writes (0600)
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
  alias SdrAgent.PrototypeFixtures

  @routes ~w(prototype_binding owner_dev owner_calibration hosted other_owner)

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
    grant
  end

  defp worksheet(root) do
    routes =
      for route <- @routes do
        %{
          "route" => route,
          "basis" =>
            if(route == "prototype_binding", do: "agent_receipt", else: "owner_attestation"),
          "consumed" => 0,
          "evidence" => evidence!(root, "#{route}.receipt")
        }
      end

    %{
      "schema" => "d237-budget-worksheet/1",
      "shared_total" => 60,
      "window_starts_at" => "2026-10-28T02:38:32.000000Z",
      "as_of" => "2026-10-29T12:00:00Z",
      "routes" => routes,
      "previous_bindings" => %{"consumed" => 0, "evidence" => evidence!(root, "previous.receipt")}
    }
  end

  defp evidence!(root, name) do
    body = "synthetic counts-only receipt #{name}\n"
    path = Path.join(root, name)
    File.write!(path, body)
    File.chmod!(path, 0o600)
    %{"path" => name, "sha256" => sha(body)}
  end

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
      "UPDATE audit_events SET payload = jsonb_set(payload, $2, $3::jsonb) WHERE id = $1",
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
end
