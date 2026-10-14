defmodule SdrAgent.Agents.GrantUsageTest do
  @moduledoc """
  C9-05: the attempts consumed per grant and allocation, derived from the
  ModelInvocations charged at reservation (never stored, never refunded),
  read as an admin or auditor; a reviewer reads no grant and so no usage.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Clock

  @now ~U[2026-10-20 12:00:00.000000Z]

  setup do
    # R0-07 slice B: real calls are admitted only with a promoted tuple and
    # a trusted store (`SdrAgent.AdmissionFixtures`).
    SdrAgent.AdmissionFixtures.admit_tuples!()
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    %{tenant: tenant, admin: human(:admin, tenant)}
  end

  defp reserve!(run, key) do
    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))

    {:ok, invocation} = Agents.reserve_model_invocation(run.run, attrs, actor: run.agent)
    invocation
  end

  test "counts charged invocations per grant, per allocation and today (UTC)", ctx do
    opus =
      AgentsFixtures.grant!(
        ctx.tenant,
        %{
          name: "G-OPUS",
          profile_ids: [:claude_cli_opus],
          allocations: [
            %{key: :b1, applies_to: [:b1], attempts: 5},
            %{key: :b5, applies_to: [:b5], attempts: 5}
          ]
        },
        ctx.admin
      )

    sonnet =
      AgentsFixtures.grant!(
        ctx.tenant,
        %{name: "G-SONNET", profile_ids: [:claude_cli_sonnet]},
        ctx.admin
      )

    run = AgentsFixtures.running_run(ctx.tenant)
    reserve!(run, "u-1")
    reserve!(run, "u-2")

    b1 = Enum.find(opus.allocations, &(&1.key == :b1))
    b5 = Enum.find(opus.allocations, &(&1.key == :b5))
    [daily] = sonnet.allocations

    for actor <- [ctx.admin, human(:auditor, ctx.tenant)] do
      assert {:ok, usage} = Agents.grant_usage([opus.id, sonnet.id], actor: actor)

      assert usage[opus.id] == %{consumed: 2, today: 2, allocations: %{b1.id => 2, b5.id => 0}}
      assert usage[sonnet.id] == %{consumed: 0, today: 0, allocations: %{daily.id => 0}}
    end

    Clock.freeze(DateTime.add(@now, 1, :day))
    assert {:ok, usage} = Agents.grant_usage([opus.id], actor: ctx.admin)
    assert %{consumed: 2, today: 0} = usage[opus.id]
  end

  test "a reviewer reads no usage; unknown ids are absent", ctx do
    grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)

    assert {:ok, usage} = Agents.grant_usage([grant.id], actor: human(:reviewer, ctx.tenant))
    assert usage == %{}

    assert {:ok, %{}} = Agents.grant_usage([Ash.UUIDv7.generate()], actor: ctx.admin)
    assert {:ok, %{}} = Agents.grant_usage([], actor: ctx.admin)
  end
end
