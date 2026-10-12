defmodule SdrAgent.Agents.UsageOriginTest do
  @moduledoc """
  C9 (R0 readiness packet): every new AgentRun carries the `usage_origin`
  its entry point sets at `:create` (closed set, required, immutable,
  copied by `:retry` — see `SdrAgent.SDR.RetryRunTest`), and the trusted
  usage bucket of a model call is `(usage_origin, purpose)` under the
  owner-approved mapping (D-104). Callers never supply a bucket.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.UsageBucket
  alias SdrAgent.AgentsFixtures

  setup do
    %{tenant: bootstrap!()}
  end

  defp reload(run, agent) do
    {:ok, run} = Agents.get_run(run.id, actor: agent)
    run
  end

  describe "run usage origin" do
    test "is required and closed at create, and no later action changes it", ctx do
      %{agent: agent, definition: definition, run: run} =
        AgentsFixtures.running_run(ctx.tenant, usage_origin: :reply)

      assert run.usage_origin == :reply
      attrs = AgentsFixtures.run_attrs(definition)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.create_run(Map.delete(attrs, :usage_origin), actor: agent)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.create_run(%{attrs | usage_origin: :anything}, actor: agent)

      assert {:error, %Ash.Error.Invalid{}} =
               run
               |> Ash.Changeset.for_update(:set_phase, %{phase: :plan, usage_origin: :proof},
                 actor: agent
               )
               |> Ash.update()

      assert reload(run, agent).usage_origin == :reply
    end
  end

  describe "usage bucket (trusted mapping, D-104)" do
    test "maps every origin and purpose to the owner-approved bucket" do
      purposes = [:qualification, :outreach_proposal, :evidence_extraction, :reply_classification]

      expected = %{
        assignment: %{default: :b1},
        referral: %{default: :b1, outreach_proposal: :b5},
        reply: %{default: :b5},
        followup: %{default: :b4},
        discovery: %{default: :b2},
        channel: %{default: :b3},
        proof: %{default: :proof}
      }

      assert UsageBucket.origins() |> Enum.sort() == expected |> Map.keys() |> Enum.sort()

      for {origin, buckets} <- expected, purpose <- purposes do
        assert UsageBucket.bucket(origin, purpose) == Map.get(buckets, purpose, buckets.default),
               "#{origin} / #{purpose}"
      end
    end

    test "has no bucket without an origin" do
      assert UsageBucket.bucket(nil, :qualification) == nil
    end
  end
end
