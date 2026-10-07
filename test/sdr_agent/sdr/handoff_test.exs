defmodule SdrAgent.SDR.HandoffTest do
  @moduledoc """
  S7b review (Codex, PR #12) must-fix 2: the OutreachProposal hand-off —
  enrollment, Lead qualified → in_outreach and the durable
  `sdr.draft.completed` record — is one transaction, and `SDR.proposal/2`
  reconstructs the proposal only from that committed hand-off, bound to the
  exact Decisions, invocation, enrollment and step it names. A refused
  transition or a failed hand-off append leaves none of them behind.
  """
  use SdrAgent.SDRCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Sales
  alias SdrAgent.SDR

  # A temporary trigger in this test's sandbox transaction (rolled back with it).
  defp reject!(table, condition) do
    Repo.query!("""
    CREATE FUNCTION pg_temp.s7_reject() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN RAISE EXCEPTION 's7 test: rejected write'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER s7_reject BEFORE #{table} FOR EACH ROW
    WHEN (#{condition}) EXECUTE FUNCTION pg_temp.s7_reject()
    """)
  end

  defp enrollments(ctx, lead) do
    {:ok, rows} =
      Sales.list_records(Sales.CampaignEnrollment, filter: [lead_id: lead.id], actor: ctx.admin)

    rows
  end

  defp assert_no_handoff(ctx, run, lead) do
    assert enrollments(ctx, lead) == []
    {:ok, lead} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    assert lead.status == :qualified
    refute "sdr.draft.completed" in signal_types(ctx.tenant, run)
    refute Enum.any?(decisions!(ctx, run), &(&1.kind == :enrollment))
    assert {:error, :no_proposal} = SDR.proposal(run.id, actor: ctx.agent)
  end

  test "a refused lead transition rolls the whole hand-off back", ctx do
    reject!("UPDATE ON leads", "NEW.status = 'in_outreach'")
    %{run: run, lead: lead} = assign!(ctx, "01")
    assert %{success: 1} = drain!()

    assert run!(ctx, run).status == :failed
    assert_no_handoff(ctx, run, lead)
  end

  test "a failed hand-off append rolls the enrollment and the transition back", ctx do
    reject!("INSERT ON audit_events", "NEW.event_type = 'sdr.draft.completed'")
    %{run: run, lead: lead} = assign!(ctx, "01")
    assert %{success: 1} = drain!()

    assert run!(ctx, run).status == :failed
    assert_no_handoff(ctx, run, lead)
  end

  test "proposal/2 is bound to the committed hand-off's ids", ctx do
    %{run: run, lead: lead} = assign!(ctx, "01")
    assert %{success: 1} = drain!()

    [event] =
      ctx.tenant
      |> events_of_type("sdr.draft.completed")
      |> Enum.filter(&(&1.agent_run_id == run.id))

    data = event.payload["data"]
    {:ok, proposal} = SDR.proposal(run.id, actor: ctx.agent)
    assert proposal.decision_id == data["proposal_decision_id"]
    assert proposal.model_invocation_id == data["model_invocation_id"]
    assert proposal.enrollment_id == data["enrollment_id"]
    assert proposal.sequence_step_id == data["sequence_step_id"]
    assert [%{id: enrollment_id}] = enrollments(ctx, lead)
    assert enrollment_id == proposal.enrollment_id

    for key <- ~w(claims_validation_decision_id personalization_validation_decision_id
                  enrollment_decision_id) do
      {:ok, decisions} = Agents.list_decisions(run.id, actor: ctx.agent)
      assert Enum.any?(decisions, &(&1.id == data[key])), key
    end

    assert {:error, :no_proposal} = SDR.proposal(Ecto.UUID.generate(), actor: ctx.agent)
  end
end
