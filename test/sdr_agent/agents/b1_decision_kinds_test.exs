defmodule SdrAgent.Agents.B1DecisionKindsTest do
  @moduledoc """
  B1-04 and B1-05 entity delta (plan
  `claude-b1-research-draft-plan-r2.md`, Decision row): two new Decision
  kinds, `:research_caps` (the research caps applied to one extraction
  call) and `:draft_shape_validation` (the deterministic subject/body shape
  rule). Both are recorded only by the agent runtime and only as
  deterministic decisions (protected kinds: the model never decides them);
  every other system actor type (`SdrAgent.Actor.types/0`) and every
  human role (admin, reviewer, auditor) is refused, as for the existing
  kinds.

  RED: neither kind exists, so the agent runtime's recording is refused as
  invalid input.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures

  @kinds [:research_caps, :draft_shape_validation]

  setup do
    tenant = bootstrap!()
    base = AgentsFixtures.running_run(tenant)

    {:ok, invocation} =
      Agents.reserve_model_invocation(base.run, AgentsFixtures.model_attrs("b1-kinds"),
        actor: base.agent
      )

    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: base.agent)

    {:ok, invocation} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: base.agent)

    Map.merge(base, %{tenant: tenant, invocation: invocation})
  end

  defp rule_attrs(ctx, kind, overrides \\ %{}) do
    Map.merge(
      %{
        agent_run_id: ctx.run.id,
        kind: kind,
        mode: :deterministic,
        subject_resource: "SdrAgent.Sales.Lead",
        subject_id: Ecto.UUID.generate(),
        inputs: %{"limits" => %{"research_max_sources" => 6}},
        rule_id: "sdr.#{kind}",
        rule_version: "1",
        outcome: "passed"
      },
      overrides
    )
  end

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  # Every system actor type but the agent runtime, and every human role.
  defp other_actors(ctx) do
    systems =
      for type <- Actor.types(), type != :agent_runtime, do: system_actor(type, ctx.tenant)

    systems ++ for(role <- [:admin, :reviewer, :auditor], do: human(role, ctx.tenant))
  end

  defp label(%Actor{type: type}), do: "system actor #{type}"
  defp label(user), do: "human #{user.role}"

  test "only the agent runtime records the B1 kinds, and only deterministically", ctx do
    for kind <- @kinds do
      allowed = Agents.record_decision(rule_attrs(ctx, kind), actor: ctx.agent)

      assert match?({:ok, %{kind: ^kind, mode: :deterministic}}, allowed),
             "B1: the agent runtime cannot record a #{kind} Decision: #{short(allowed)}"

      for actor <- other_actors(ctx) do
        refused = Agents.record_decision(rule_attrs(ctx, kind), actor: actor)

        assert match?({:error, %Ash.Error.Forbidden{}}, refused),
               "B1: #{label(actor)} recorded a #{kind} Decision: #{short(refused)}"
      end

      llm =
        rule_attrs(ctx, kind, %{
          mode: :llm,
          rule_id: nil,
          rule_version: nil,
          model_invocation_id: ctx.invocation.id,
          output_pointer: "/qualified"
        })

      decided_by_model = Agents.record_decision(llm, actor: ctx.agent)

      assert match?({:error, %Ash.Error.Invalid{}}, decided_by_model),
             "B1: the model decided a #{kind} Decision: #{short(decided_by_model)}"
    end
  end
end
