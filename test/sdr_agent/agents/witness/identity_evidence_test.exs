defmodule SdrAgent.Agents.Witness.IdentityEvidenceTest do
  @moduledoc """
  R0-07 slice A round 5, item 7 (ADR-0005 R0 amendment item 1; packet
  section 5.2, PASS clarification 3): a link of a gated parent (generation 2
  and `claude_cli`) carries `model_id` and `profile_id` evidence equal to
  the invocation's; `:released` rechecks that equality. A generation-1
  parent keeps the legacy shape: its links never carry `profile_id`, and
  nothing is backfilled.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      rec: system_actor(:reconciler, tenant),
      invocation: AgentsFixtures.claude_completed!(run, agent, "ie-1")
    }
  end

  defp link(invocation, evidence, rec) do
    attrs = AgentsFixtures.link_attrs(invocation)
    Agents.link_wire_witness(%{attrs | evidence: evidence}, actor: rec)
  end

  defp base(invocation),
    do: invocation |> AgentsFixtures.link_attrs() |> Map.fetch!(:evidence)

  test "the fixture evidence of a gated parent names its model and profile", ctx do
    evidence = base(ctx.invocation)
    assert evidence["model_id"] == ctx.invocation.model_id
    assert evidence["profile_id"] == Atom.to_string(ctx.invocation.profile_id)
    assert {:ok, _link} = link(ctx.invocation, evidence, ctx.rec)
  end

  test "a gated parent's link without, or with other, identity keys is refused", ctx do
    evidence = base(ctx.invocation)

    for {label, bad} <- [
          {"no model_id", Map.delete(evidence, "model_id")},
          {"no profile_id", Map.delete(evidence, "profile_id")},
          {"other model", %{evidence | "model_id" => "claude-sonnet-5-5"}},
          {"other profile", %{evidence | "profile_id" => "claude_cli_sonnet"}},
          {"not a real profile", %{evidence | "profile_id" => "fake"}}
        ] do
      assert {:error, %Ash.Error.Invalid{}} = link(ctx.invocation, bad, ctx.rec), label
    end

    assert {:ok, []} = Agents.list_wire_witness_links(ctx.invocation.id, actor: ctx.rec)
  end

  test "a generation-1 parent keeps the legacy shape: profile_id is refused", ctx do
    legacy = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "ie-legacy")

    tamper!(
      "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
        "allocation_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(legacy.id)]
    )

    legacy = %{legacy | ledger_generation: 1, profile_id: nil}
    evidence = base(legacy)
    refute Map.has_key?(evidence, "model_id")
    refute Map.has_key?(evidence, "profile_id")
    assert {:ok, _link} = link(legacy, evidence, ctx.rec)

    assert {:error, %Ash.Error.Invalid{}} =
             link(legacy, Map.put(evidence, "profile_id", "claude_cli_opus"), ctx.rec)
  end

  test ":released rechecks the identity keys against the invocation", ctx do
    link = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec)

    # Rewrite the immutable link's evidence behind the application's back.
    tamper!(
      ~s(UPDATE wire_witness_links SET evidence = evidence || '{"model_id":"claude-sonnet-5-5"}' ) <>
        "WHERE id = $1",
      [Ecto.UUID.dump!(link.id)]
    )

    attrs = %{
      model_invocation_id: ctx.invocation.id,
      disposition: :released,
      reason: :reconciled,
      wire_witness_link_id: link.id
    }

    assert {:error, %Ash.Error.Invalid{}} = Agents.decide_result_release(attrs, actor: ctx.agent)
  end
end
