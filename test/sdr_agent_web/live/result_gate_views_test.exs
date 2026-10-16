defmodule SdrAgentWeb.ResultGateViewsTest do
  @moduledoc """
  R0-07 slice A round 5, PASS clarification 5 (masked consumers): the
  operator views that list a generation-2 ClaudeCLI invocation — the run
  view and the audit timeline filtered by that run — render without
  crashing and never show an unreleased output or its diagnostics.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures

  setup ctx do
    # R0-07 slice B: real calls are admitted only with a promoted tuple and
    # a trusted store (`SdrAgent.AdmissionFixtures`).
    SdrAgent.AdmissionFixtures.admit_tuples!()
    AgentsFixtures.grant!(ctx.tenant, %{}, user!(ctx, :admin))
    # A run of a seeded lead, so the run view resolves its contact.
    agent = ctx.agent
    lead = fixture_lead!(ctx, "01")
    definition = AgentsFixtures.definition!(ctx.tenant)
    attrs = definition |> AgentsFixtures.run_attrs() |> Map.put(:lead_id, lead.id)
    # C4-R8: an assignment-origin run needs a saved offering profile.
    AgentsFixtures.ensure_offering!(ctx.tenant)
    {:ok, run} = Agents.create_run(attrs, actor: agent)
    {:ok, run} = Agents.start_run(run, actor: agent)
    canary = "canary-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    completion =
      AgentsFixtures.completion()
      |> Map.merge(%{
        response: ~s({"result":"raw"}),
        parsed_output: %{"note" => canary},
        validation_status: :invalid,
        validation_errors: [%{"message" => "bad #{canary}"}],
        refusal: "refused #{canary}"
      })

    {:ok, reserved} =
      Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("view-1"), actor: agent)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    {:ok, _done} = Agents.complete_model_invocation(sent, completion, actor: agent)
    %{run: run, canary: canary}
  end

  test "the run view lists the invocation without its output", %{conn: conn} = ctx do
    {:ok, _view, html} = conn |> sign_in(:admin) |> live(~p"/runs/#{ctx.run.id}")
    assert html =~ "claude-opus-5-5"
    refute html =~ ctx.canary
  end

  test "the audit timeline of the run shows no output", %{conn: conn} = ctx do
    {:ok, _view, html} = conn |> sign_in(:auditor) |> live(~p"/audit?run=#{ctx.run.id}")
    assert html =~ "model.invocation.completed"
    refute html =~ ctx.canary
  end
end
