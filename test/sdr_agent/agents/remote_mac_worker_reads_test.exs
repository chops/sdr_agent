defmodule SdrAgent.Agents.RemoteMacWorkerReadsTest do
  @moduledoc """
  S-B2 RED addendum B (Codex 2026-10-31 B2 GO, correlation
  m_1793429567352697084_19d14d30): the `:mac_worker` actor type grants no
  read at any of the eight existing `authorize_if actor_present()` read
  sites.

  For each of AgentRun, Decision, ModelInvocation, ToolInvocation,
  AgentDefinition, WireWitnessLink, `SdrAgent.Audit.Tenant` and
  `SdrAgent.Audit.ProvenanceSnapshot`, in ordinary runtime (the remote
  tests' runtime) and in prototype runtime (also covered by the
  any-present-actor oracle in `SdrAgent.Prototype.OperatorGatesTest`):

  - control: real rows exist, and the oracle's present actor (a forged
    `:prototype_operator` struct of the tenant) reads a non-empty list, so
    the denial below is not vacuous;
  - denial: a `:mac_worker` actor (a real enrolled worker's id and
    tenant, as in `SdrAgent.Agents.RemoteScopeTest`) reading the same
    resource gets `Ash.Error.Forbidden` or `{:ok, []}`, zero rows.

  AgentRun's strict mac_worker denial already exists (regression); the
  other seven are intended-missing until the shared-check change.

  Synthetic data only; no model, no CLI, no network.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.AuditCase, only: [system_actor: 2]

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.RemoteCallFixtures, as: F

  @resources [
    SdrAgent.Agents.AgentRun,
    SdrAgent.Agents.Decision,
    SdrAgent.Agents.ModelInvocation,
    SdrAgent.Agents.ToolInvocation,
    SdrAgent.Agents.AgentDefinition,
    SdrAgent.Agents.WireWitnessLink,
    SdrAgent.Audit.Tenant,
    SdrAgent.Audit.ProvenanceSnapshot
  ]

  setup do
    fx = F.world!()
    key = "sb2-mac-reads-#{System.unique_integer([:positive])}"
    invocation = AgentsFixtures.claude_completed!(fx.run, fx.agent, key)
    AgentsFixtures.reconciled_link!(invocation, system_actor(:reconciler, fx.tenant))

    {:ok, _tool} =
      Agents.start_tool_invocation(
        fx.run,
        %{
          action_module: "SdrAgent.Actions.Research",
          action_version: "1",
          input: ~s({"q":"acme"}),
          idempotency_key: key <> "-tool"
        },
        actor: fx.agent
      )

    {:ok, _decision} =
      Agents.record_decision(
        %{
          agent_run_id: fx.run.id,
          kind: :research_caps,
          mode: :deterministic,
          rule_id: "sb2.mac_reads",
          rule_version: "1",
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: fx.run.lead_id || Ecto.UUID.generate(),
          idempotency_key: key <> "-decision",
          inputs: %{"run" => fx.run.id},
          outcome: "within_caps"
        },
        actor: fx.agent
      )

    %{worker: worker} = F.enrol!(fx)
    mac = struct(Actor, type: :mac_worker, id: worker.id, tenant_id: fx.tenant.id)
    present = %Actor{type: :prototype_operator, id: Ecto.UUID.generate(), tenant_id: fx.tenant.id}
    %{fx: fx, mac: mac, present: present}
  end

  defp enter_runtime!(:ordinary, _fx), do: :ok
  defp enter_runtime!(:prototype, fx), do: G.enter!(fx)

  defp hidden?(result),
    do: result == {:ok, []} or match?({:error, %Ash.Error.Forbidden{}}, result)

  for resource <- @resources, runtime <- [:ordinary, :prototype] do
    @resource resource
    @runtime runtime

    test "#{inspect(resource)} (#{runtime} runtime): a :mac_worker actor reads no rows",
         %{fx: fx, mac: mac, present: present} do
      resource = @resource

      assert Ash.read!(resource, authorize?: false) != [],
             "prerequisite: #{inspect(resource)} rows"

      enter_runtime!(@runtime, fx)

      control = F.safely(fn -> Ash.read(resource, actor: present) end)

      assert match?({:ok, [_ | _]}, control),
             "control: the present actor cannot read #{inspect(resource)}: " <>
               inspect(control, limit: 3)

      result = F.safely(fn -> Ash.read(resource, actor: mac) end)

      assert hidden?(result),
             "#{inspect(resource)}: a :mac_worker actor read rows: #{inspect(result, limit: 3)}"
    end
  end
end
