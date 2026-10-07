defmodule SdrAgent.SDR.GatesTest do
  @moduledoc """
  Spec §8: deterministic rules are decided by the application, never by the
  model — campaign state, suppression, and the run/daily budgets each stop
  the agent with a recorded deterministic Decision and without a model call;
  claims without evidence are rejected deterministically; ungrounded quotes
  never become evidence; invalid model output fails the run (operator
  attention) and writes no Qualification.
  """
  use SdrAgent.SDRCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Operations
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.FakeBrain
  alias SdrAgent.SDR.Runner
  alias SdrAgent.SDR.Signals

  defp decision(ctx, run, kind) do
    ctx |> decisions!(run) |> Enum.filter(&(&1.kind == kind))
  end

  defp with_env(key, value) do
    previous = Application.get_env(:sdr_agent, key)
    Application.put_env(:sdr_agent, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, key, previous),
        else: Application.delete_env(:sdr_agent, key)
    end)
  end

  defp lead_status(ctx, lead) do
    {:ok, lead} = Sales.fetch(Sales.Lead, lead.id, actor: ctx.admin)
    lead.status
  end

  describe "campaign state" do
    test "a paused campaign stops the assignment before any model call", ctx do
      {:ok, campaign} = Sales.fetch(Sales.Campaign, ctx.campaign_id, actor: ctx.admin)
      {:ok, paused} = SDR.pause_campaign(campaign, actor: ctx.admin)
      assert paused.status == :paused
      assert [event] = events_of_type(ctx.tenant, "sdr.campaign.paused")
      assert event.category == :signal
      assert event.subject_id == campaign.id

      %{run: run, lead: lead} = assign!(ctx, "01")
      assert %{success: 1} = drain!()

      run = run!(ctx, run)
      assert run.status == :succeeded
      assert run.phase == :stop
      assert invocations!(ctx, run) == []
      assert [check] = decision(ctx, run, :campaign_state_check)
      assert check.mode == :deterministic
      assert check.outcome == "not_active"
      assert lead_status(ctx, lead) == :assigned
    end

    test "sdr.campaign.paused stops a running assignment deterministically", ctx do
      %{run: run} = assign!(ctx, "01")
      {:ok, run} = Agents.start_run(run, actor: ctx.agent)
      {:ok, signal} = Signals.build("sdr.campaign.paused", %{campaign_id: ctx.campaign_id})

      assert {:ok, agent} = Runner.run(run, signal, [])
      assert agent.state.phase == :stop
      assert [halt] = decision(ctx, run, :campaign_state_check)
      assert halt.outcome == "paused"
      assert invocations!(ctx, run) == []
    end
  end

  describe "suppression" do
    defmodule SuppressEveryone do
      @moduledoc false
      @behaviour SdrAgent.SDR.SuppressionCheck
      def check(_email, _context), do: {:ok, :suppressed, %{store: "test", scope: "email"}}
    end

    test "a suppressed recipient stops the assignment before any model call", ctx do
      with_env(:suppression_check, SuppressEveryone)
      %{run: run} = assign!(ctx, "01")
      assert %{success: 1} = drain!()

      run = run!(ctx, run)
      assert run.phase == :stop
      assert invocations!(ctx, run) == []
      assert [check] = decision(ctx, run, :suppression_check)
      assert check.mode == :deterministic
      assert check.outcome == "suppressed"
    end

    test "the S7 default suppression check records that no store exists yet", ctx do
      %{run: run} = assign!(ctx, "01")
      assert %{success: 1} = drain!()
      assert [check | _] = decision(ctx, run!(ctx, run), :suppression_check)
      assert check.outcome == "not_suppressed"
      assert check.rule_id == "sdr.suppression_check"
    end

    test "sdr.lead.suppressed stops a running assignment", ctx do
      %{run: run, lead: lead} = assign!(ctx, "01")
      {:ok, run} = Agents.start_run(run, actor: ctx.agent)
      {:ok, signal} = Signals.build("sdr.lead.suppressed", %{lead_id: lead.id})

      assert {:ok, agent} = Runner.run(run, signal, [])
      assert agent.state.phase == :stop
      assert [halt] = decision(ctx, run, :suppression_check)
      assert halt.outcome == "suppressed"
    end
  end

  describe "budgets" do
    test "the run budget stops the agent before the call that would exceed it", ctx do
      %{run: run} = assign!(ctx, "01", max_model_calls: 1)
      assert %{success: 1} = drain!()

      run = run!(ctx, run)
      assert run.status == :budget_exhausted
      assert run.status_reason == :run_budget_calls
      assert [_extraction] = invocations!(ctx, run)

      assert Enum.any?(
               decision(ctx, run, :budget_reservation),
               &(&1.outcome == "run_budget_exhausted" and &1.mode == :deterministic)
             )

      {:ok, attention} = Operations.list_attention(actor: ctx.admin)

      assert Enum.any?(
               attention,
               &(&1.id == run.attention_failure_id and &1.class == :budget_exhausted)
             )
    end

    test "the persisted daily budget stops the agent", ctx do
      with_env(:daily_model_call_limit, 1)
      %{run: run} = assign!(ctx, "01")
      assert %{success: 1} = drain!()

      run = run!(ctx, run)
      assert run.status == :budget_exhausted
      assert run.status_reason == :daily_budget
      assert length(invocations!(ctx, run)) == 1

      assert Enum.any?(
               decision(ctx, run, :budget_reservation),
               &(&1.outcome == "daily_budget_exhausted")
             )
    end
  end

  describe "evidence" do
    defmodule HallucinatingExtractor do
      @moduledoc false
      def respond("sdr.evidence_extraction" = op, input) do
        %{claims: claims} = FakeBrain.respond(op, input)

        fake = %{
          source: 0,
          claim: "The company raised a billion dollars.",
          quote: "raised a billion dollars",
          confidence: 0.99,
          quality: "accepted",
          reason: "invented"
        }

        %{claims: [fake | claims]}
      end

      def respond(op, input), do: FakeBrain.respond(op, input)
    end

    test "an ungrounded quote is recorded as a rejection and never persisted", ctx do
      %{run: run, lead: lead} =
        assign!(ctx, "01", model: [provider_options: [responder: HallucinatingExtractor]])

      assert %{success: 1} = drain!()
      assert run!(ctx, run).status == :succeeded

      {:ok, claims} =
        Research.list_records(Research.EvidenceClaim,
          filter: [lead_id: lead.id],
          actor: ctx.admin
        )

      refute Enum.any?(claims, &(&1.quote =~ "billion"))

      assert [ungrounded] =
               Enum.filter(decision(ctx, run, :evidence_quality), &(&1.outcome == "ungrounded"))

      assert ungrounded.mode == :llm
      assert ungrounded.output_pointer == "/claims/0"
    end

    defmodule UnsupportedClaims do
      @moduledoc false
      def respond("sdr.outreach_proposal" = op, input) do
        proposal = FakeBrain.respond(op, input)
        [claim | rest] = proposal.claims
        %{proposal | claims: [%{claim | evidence_id: Ecto.UUID.generate()} | rest]}
      end

      def respond(op, input), do: FakeBrain.respond(op, input)
    end

    test "ValidateClaims rejects a claim without evidence; nothing is handed to S8", ctx do
      %{run: run, lead: lead} =
        assign!(ctx, "01", model: [provider_options: [responder: UnsupportedClaims]])

      assert %{success: 1} = drain!()

      run = run!(ctx, run)
      assert run.status == :failed
      assert run.status_reason == :invalid_model_output
      assert [validation] = decision(ctx, run, :claims_validation)
      assert validation.mode == :deterministic
      assert validation.outcome == "rejected"
      refute "sdr.draft.completed" in signal_types(ctx.tenant, run)
      assert {:error, :no_proposal} = SDR.proposal(run.id, actor: ctx.agent)
      assert lead_status(ctx, lead) == :qualified

      {:ok, attention} = Operations.list_attention(actor: ctx.admin)
      assert Enum.any?(attention, &(&1.id == run.attention_failure_id))
    end
  end

  describe "invalid model output" do
    defmodule InvalidQualification do
      @moduledoc false
      def respond("sdr.qualification" = op, input) do
        %{FakeBrain.respond(op, input) | score: "high"}
      end

      def respond(op, input), do: FakeBrain.respond(op, input)
    end

    test "fails the run, opens a Failure and writes no Qualification", ctx do
      %{run: run, lead: lead} =
        assign!(ctx, "01", model: [provider_options: [responder: InvalidQualification]])

      assert %{success: 1} = drain!()

      run = run!(ctx, run)
      assert run.status == :failed
      assert run.status_reason == :invalid_model_output
      assert {:ok, nil} = Research.current_qualification(lead.id, actor: ctx.admin)
      assert lead_status(ctx, lead) == :qualifying
      assert decision(ctx, run, :qualification) == []

      {:ok, attention} = Operations.list_attention(actor: ctx.admin)
      assert Enum.any?(attention, &(&1.id == run.attention_failure_id))
    end
  end
end
