defmodule SdrAgent.Agents.RunSettingsLimitsTest do
  @moduledoc """
  C4-01a (`docs/product/c4/readiness.md`, section 5 tests 21 and 22;
  C4-R6, C4-R9, C4-R10, C4-R13; obligations 6 and 7): live checks at use.

  A run's budget is frozen from its snapshot at `:create` (the lower of the
  caller's argument and the snapshot's `run_*` value); later raises or
  lowers never change it; the guarded counters (`:reserve_model_call`,
  `:record_tool_call`, and the token check moved into the counter) refuse
  at the frozen budget, for direct domain calls and retries; a raised
  per-run setting still yields to grant allocations and the tenant-day
  limit. The booking link is re-checked against the real-data guard at
  every use: a link failing it is withheld, with no substitution and no
  URL in the model input. Test 21a (questions-first first touch) is a
  consumer test that lands with B1-05 and B5-03.

  RED: calls are presence-guarded (`SdrAgent.SettingsFixtures`).
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [put_env!: 2]
  import SdrAgent.SettingsFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.SDR
  alias SdrAgent.SDR.FakeBrain
  alias SdrAgent.SettingsFixtures.RecordingBrain

  @moduletag :c4_01a

  defmodule InvalidQualification do
    @moduledoc "Test responder: an invalid qualification score fails the run."
    def respond("sdr.qualification" = op, input),
      do: %{FakeBrain.respond(op, input) | score: "high"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  defp lowered,
    do:
      Map.merge(limit_defaults(), %{
        run_max_model_calls: 3,
        run_max_tool_calls: 4,
        run_max_tokens: 1_000,
        research_max_sources: 5
      })

  defp save_limits!(ctx, limits, previous) do
    save!(:operational_limits, limits, ctx.admin, confirm_raised: raised(limits, previous))
  end

  defp running!(ctx, opts \\ []) do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, opts)
    {run, agent}
  end

  defp reserve(run, agent), do: Agents.reserve_model_call(reload(run, agent), actor: agent)

  defp record_tool(run, agent) do
    run
    |> reload(agent)
    |> Ash.Changeset.for_update(:record_tool_call, %{}, actor: agent)
    |> Ash.update()
  end

  defp settle(run, agent, tokens) do
    run
    |> reload(agent)
    |> Ash.Changeset.for_update(:settle_model_call, %{calls: 0, tokens: tokens}, actor: agent)
    |> Ash.update()
  end

  defp reload(run, agent) do
    {:ok, run} = Agents.get_run(run.id, actor: agent)
    run
  end

  defp successes(fun, limit) do
    Enum.reduce_while(1..(limit + 5), 0, fn _, n ->
      if match?({:ok, _}, fun.()), do: {:cont, n + 1}, else: {:halt, n}
    end)
  end

  ## Test 21

  describe "test 21: frozen budget and allowances" do
    test "a later raise or lower leaves the snapshot, the frozen budget and allowances", ctx do
      save_offering!(ctx.admin)
      save_limits!(ctx, lowered(), limit_defaults())
      {run, agent} = running!(ctx, max_model_calls: 20, max_tool_calls: 10)

      assert {run.budget.max_model_calls, run.budget.max_tool_calls, run.budget.max_tokens} ==
               {3, 4, 1_000},
             "C4-01a: the budget is not frozen from the snapshot"

      snapshot = snapshot_of!(run, agent)

      raised =
        Map.merge(lowered(), %{
          run_max_model_calls: 30,
          run_max_tool_calls: 90,
          run_max_tokens: 500_000,
          research_max_sources: 9
        })

      save_limits!(ctx, raised, lowered())

      lowest =
        Map.merge(raised, %{
          run_max_model_calls: 1,
          research_max_model_calls: 1,
          run_max_tool_calls: 1,
          run_max_tokens: 10,
          research_max_sources: 1
        })

      save_limits!(ctx, lowest, raised)

      run = reload(run, agent)

      assert {run.budget.max_model_calls, run.budget.max_tool_calls, run.budget.max_tokens} ==
               {3, 4, 1_000}

      assert snapshot_of!(run, agent) == snapshot

      for {field, value} <- [
            run_max_model_calls: 3,
            run_max_tool_calls: 4,
            run_max_tokens: 1_000,
            research_max_sources: 5,
            research_max_model_calls: 2
          ] do
        assert allowance(run, field) == {:ok, value}, "allowance #{field}"
      end
    end

    test ":reserve_model_call and :record_tool_call refuse at the frozen budget after a raise",
         ctx do
      save_offering!(ctx.admin)
      save_limits!(ctx, lowered(), limit_defaults())
      {run, agent} = running!(ctx, max_model_calls: 20, max_tool_calls: 10)

      save_limits!(
        ctx,
        Map.merge(lowered(), %{run_max_model_calls: 30, run_max_tool_calls: 90}),
        lowered()
      )

      assert successes(fn -> reserve(run, agent) end, 30) == 3,
             "C4-01a: model-call reservations not refused at the frozen budget of 3"

      assert successes(fn -> record_tool(run, agent) end, 90) == 4,
             "C4-01a: tool calls not refused at the frozen budget of 4"
    end

    test "the token check refuses the next reservation; one call may overshoot", ctx do
      save_offering!(ctx.admin)
      save_limits!(ctx, lowered(), limit_defaults())
      {run, agent} = running!(ctx)
      assert run.budget.max_tokens == 1_000, "C4-01a: max_tokens not frozen from the snapshot"

      assert {:ok, _} = reserve(run, agent)
      assert {:ok, settled} = settle(run, agent, 1_500)
      assert settled.budget.tokens_used == 1_500

      result = reserve(run, agent)

      assert match?({:error, %Ash.Error.Invalid{}}, result),
             "C4-01a: a reservation after the token budget was used: #{short(result)}"
    end

    test "a retry keeps the frozen budget and is refused at it", ctx do
      save_offering!(ctx.admin)
      limits = Map.put(lowered(), :run_max_model_calls, 5)
      save_limits!(ctx, limits, limit_defaults())

      %{run: run} =
        assign!(ctx, "01", model: [provider_options: [responder: InvalidQualification]])

      assert %{success: 1} = drain!()
      failed = run!(ctx, run)
      assert failed.status == :failed
      assert failed.budget.max_model_calls == 5, "C4-01a: the assignment budget is not frozen"

      save_limits!(ctx, Map.put(limits, :run_max_model_calls, 50), limits)
      assert {:ok, %{run: retry}} = SDR.retry_run(failed.id, actor: ctx.admin)
      assert retry.budget.max_model_calls == 5
      assert retry.settings_snapshot_id == failed.settings_snapshot_id
      assert allowance(retry, :run_max_model_calls) == {:ok, 5}

      {:ok, retry} = Agents.start_run(retry, actor: ctx.agent)
      assert successes(fn -> reserve(retry, ctx.agent) end, 50) == 5
    end

    test "a raised run_max_model_calls still yields to an exhausted grant allocation", ctx do
      SdrAgent.AdmissionFixtures.admit_tuples!()
      save_offering!(ctx.admin)
      raised = Map.put(limit_defaults(), :run_max_model_calls, 1_000)
      save_limits!(ctx, raised, limit_defaults())

      AgentsFixtures.grant!(ctx.tenant, %{
        total_attempts: 10,
        allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]
      })

      {run, agent} = running!(ctx, max_model_calls: 1_000)
      assert snapshot_of!(run, agent).limits.run_max_model_calls == 1_000

      assert run.budget.max_model_calls == 1_000,
             "C4-01a: the raised snapshot value is not frozen"

      reserve_claude = fn key ->
        Agents.reserve_model_invocation(reload(run, agent), AgentsFixtures.claude_attrs(key),
          actor: agent
        )
      end

      assert {:ok, _} = reserve_claude.("grant-1")
      result = reserve_claude.("grant-2")

      assert match?({:error, %Refused{reason: {:budget_exhausted, :allocation}}}, result),
             short(result)
    end

    test "a raised run_max_model_calls still yields to the tenant-day limit", ctx do
      save_offering!(ctx.admin)
      raised = Map.put(limit_defaults(), :run_max_model_calls, 1_000)
      save_limits!(ctx, raised, limit_defaults())
      {run, agent} = running!(ctx, max_model_calls: 1_000)
      assert snapshot_of!(run, agent).limits.run_max_model_calls == 1_000

      assert run.budget.max_model_calls == 1_000,
             "C4-01a: the raised snapshot value is not frozen"

      put_env!(:daily_model_call_limit, Agents.daily_model_calls(ctx.tenant.id) + 1)

      reserve_fake = fn key ->
        Agents.reserve_model_invocation(reload(run, agent), AgentsFixtures.model_attrs(key),
          actor: agent
        )
      end

      assert {:ok, _} = reserve_fake.("daily-1")
      assert reserve_fake.("daily-2") == {:error, {:budget_exhausted, :daily}}
    end
  end

  ## Test 22

  describe "test 22: booking link at use" do
    test "a guard failing now withholds the link from new, queued and retried runs", ctx do
      url = "https://book.example.test/demo/intro"
      save_offering!(ctx.admin)
      booking = save!(:booking_link, %{url: url}, ctx.admin)

      %{run: run} =
        assign!(ctx, "02", model: [provider_options: [responder: InvalidQualification]])

      assert %{success: 1} = drain!()
      failed = run!(ctx, run)
      %{run: queued} = assign!(ctx, "01")
      assert booking_link_for_use(queued) == {:ok, url}, "positive control: the guard passes"

      put_env!(:booking_link_guard, {SdrAgent.SettingsFixtures, :deny_every_host})
      put_env!(RecordingBrain, self())

      %{run: fresh} =
        assign!(ctx, "03", model: [provider_options: [responder: RecordingBrain]])

      assert {:ok, %{run: retry}} = SDR.retry_run(failed.id, actor: ctx.admin)

      for {label, run} <- [new: fresh, queued: queued, retry: retry] do
        assert booking_link_for_use(run) == {:error, :booking_link_withheld}, "#{label} run"
      end

      drain!()
      inputs = collect_inputs([])
      assert inputs != [], "the recording responder saw no model input"
      refute Enum.any?(inputs, &(inspect(&1, limit: :infinity) =~ "book.example.test"))

      assert revision_numbers(ctx.tenant.id, :booking_link) == [1]
      assert latest_number(ctx.tenant.id, :booking_link) == booking.number
    end

    test "no newer or older revision is substituted for a withheld link", ctx do
      save_offering!(ctx.admin)
      save!(:booking_link, %{url: "https://book.example.test/demo/intro"}, ctx.admin)
      save!(:booking_link, %{url: "https://book2.example.test/demo/intro"}, ctx.admin)
      put_env!(:booking_link_guard, {SdrAgent.SettingsFixtures, :deny_book2})

      %{run: run} = assign!(ctx, "01")
      assert booking_link_for_use(run) == {:error, :booking_link_withheld}
    end

    test "a run with no saved booking link gets :booking_link_absent", ctx do
      save_offering!(ctx.admin)
      %{run: run} = assign!(ctx, "01")
      assert booking_link_for_use(run) == {:error, :booking_link_absent}

      # A link saved later is for later runs only.
      save!(:booking_link, %{url: "https://book.example.test/demo/intro"}, ctx.admin)

      assert booking_link_for_use(run!(ctx, run)) == {:error, :booking_link_absent},
             "C4-01a: the bound run fell back to the current booking link"

      %{run: later} = assign!(ctx, "02")
      assert booking_link_for_use(later) == {:ok, "https://book.example.test/demo/intro"}
    end
  end

  defp collect_inputs(acc) do
    receive do
      {:fake_model_input, operation, input} -> collect_inputs([{operation, input} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
