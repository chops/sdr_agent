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
  alias SdrAgent.Audit
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.FakeBrain
  alias SdrAgent.SDR.SuppressionCheck

  # F2 (plan r3 §5): a responder for "sdr.outreach_proposal" applies one
  # configuration change — after the accept gate ran with `Store`, before
  # the hand-off runs — then delegates to `FakeBrain`. Each test registers
  # the exact restoration of the key before the run starts.
  defmodule RemoveSuppressionCheck do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      Application.delete_env(:sdr_agent, :suppression_check)
      FakeBrain.respond(op, input)
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule BehaviourlessNotSuppressed do
    @moduledoc false
    def check(_email, _context), do: {:ok, :not_suppressed, %{"store" => "behaviourless"}}
  end

  defmodule ConfigureBehaviourless do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      Application.put_env(:sdr_agent, :suppression_check, BehaviourlessNotSuppressed)
      FakeBrain.respond(op, input)
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defmodule ErroringStub do
    @moduledoc false
    @behaviour SdrAgent.SDR.SuppressionCheck

    @impl true
    def check(_email, _context), do: {:error, :stub_failed}
  end

  defmodule ConfigureErroringStub do
    @moduledoc false
    def respond("sdr.outreach_proposal" = op, input) do
      Application.put_env(:sdr_agent, :suppression_check, ErroringStub)
      FakeBrain.respond(op, input)
    end

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

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

  # Suppression safety fix, defect B (plan r3 §4 "Hand-off", §6 G5–G7): a
  # suppression check that is missing, invalid or erroring at the enroll
  # point rolls the whole hand-off back — `assert_no_handoff/3` covers the
  # enrollment, lead status, signal, enrollment Decision and proposal; the
  # Draft row and the exact gate Decision counts are checked separately.

  # Registers the exact restoration of `key` (its `fetch_env` value or
  # absence) and returns that previous state.
  defp register_restore!(key) do
    previous = Application.fetch_env(:sdr_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, key, value)
        :error -> Application.delete_env(:sdr_agent, key)
      end
    end)

    previous
  end

  defp drafts(ctx, lead) do
    {:ok, drafts} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    drafts
  end

  defp inputs!(ctx, decision) do
    {:ok, json} = Audit.read_content(decision.inputs_sha256, actor: ctx.admin)
    Jason.decode!(json)
  end

  # Exactly the accept gate Decisions remain: one `campaign_state_check` and
  # one `suppression_check`, the latter at the accept point and made by
  # `Store`; the enroll-point ones rolled back with the hand-off.
  defp assert_only_accept_gates(ctx, run) do
    decisions = decisions!(ctx, run)
    assert Enum.count(decisions, &(&1.kind == :campaign_state_check)) == 1
    suppression_checks = Enum.filter(decisions, &(&1.kind == :suppression_check))
    assert length(suppression_checks) == 1
    [check] = suppression_checks
    assert check.idempotency_key == "run:#{run.id}:suppression_check:accept"
    assert inputs!(ctx, check)["checker"] == inspect(SuppressionCheck.Store)
  end

  # Runs the assignment with `responder` (F2); the accept gate runs with the
  # configured `Store`, the hand-off with whatever the responder configured.
  defp handoff_with(ctx, responder) do
    assert register_restore!(:suppression_check) == {:ok, SuppressionCheck.Store}

    %{run: run, lead: lead} =
      assign!(ctx, "01", model: [provider_options: [responder: responder]])

    assert %{success: 1} = drain!()
    {run!(ctx, run), lead}
  end

  test "G5: the suppression_check key removed before the hand-off: no hand-off, no Draft, only the accept gate Decisions; the run fails with the :missing tag",
       ctx do
    {run, lead} = handoff_with(ctx, RemoveSuppressionCheck)
    assert Application.fetch_env(:sdr_agent, :suppression_check) == :error

    assert_no_handoff(ctx, run, lead)
    assert drafts(ctx, lead) == []
    assert_only_accept_gates(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :crash}
    assert run.failure_reason == inspect({:suppression_check, :missing})
  end

  test "G6: a behaviour-less module answering not_suppressed configured before the hand-off: no hand-off, no Draft, only the accept gate Decisions; the run fails with the :invalid tag",
       ctx do
    {run, lead} = handoff_with(ctx, ConfigureBehaviourless)

    assert Application.fetch_env(:sdr_agent, :suppression_check) ==
             {:ok, BehaviourlessNotSuppressed}

    assert_no_handoff(ctx, run, lead)
    assert drafts(ctx, lead) == []
    assert_only_accept_gates(ctx, run)
    assert {run.status, run.status_reason} == {:failed, :crash}
    assert run.failure_reason == inspect({:suppression_check, :invalid})
  end

  # Control: the hand-off's rollback of a checker error exists today.
  test "G7: an erroring behaviour stub configured before the hand-off: no hand-off, no Draft, only the accept gate Decisions; the run fails",
       ctx do
    {run, lead} = handoff_with(ctx, ConfigureErroringStub)
    assert Application.fetch_env(:sdr_agent, :suppression_check) == {:ok, ErroringStub}

    assert_no_handoff(ctx, run, lead)
    assert drafts(ctx, lead) == []
    assert_only_accept_gates(ctx, run)
    assert run.status == :failed
  end
end
