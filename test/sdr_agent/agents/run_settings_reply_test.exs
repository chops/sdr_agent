defmodule SdrAgent.Agents.RunSettingsReplyTest do
  @moduledoc """
  C4-01a (`docs/product/c4/readiness.md`, section 5 tests 14 and 15;
  C4-R8; obligation 6): reply intake binds a snapshot without requiring
  business settings, its unsubscribe handling never waits on them, and
  reply runs still meet every model-call, grant and tenant-day limit. The
  completeness table names every usage origin; business origins without a
  saved offering are refused at `AgentRun :create` before anything is
  written; `:reply` and `:proof` bind a snapshot; an unknown or missing
  origin is refused as today.

  RED: calls are presence-guarded (`SdrAgent.SettingsFixtures`).
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.SettingsFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.UsageBucket
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.SDR.ReplyIntake

  @moduletag :c4_01a

  @business [:assignment, :referral, :followup, :discovery, :channel]
  @exempt [:reply, :proof]

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  # Reply intake as the matched reply's transaction runs it (no delivery
  # needed): returns the reply run.
  defp reply_run!(ctx) do
    lead = fixture_lead!(ctx, "01")

    reply = %{
      id: Ecto.UUID.generate(),
      tenant_id: ctx.tenant.id,
      webhook_event_id: Ecto.UUID.generate()
    }

    match = %{lead_id: lead.id, campaign_id: ctx.campaign_id, enrollment_id: Ecto.UUID.generate()}
    ingestor = system_actor(:webhook_ingestor, ctx.tenant)

    result =
      SdrAgent.Audit.transaction(fn ->
        case ReplyIntake.received(reply, match, ingestor) do
          :ok -> :ok
          {:error, error} -> SdrAgent.Repo.rollback(error)
        end
      end)

    assert result == {:ok, :ok}, "C4-01a: reply intake failed: #{short(result)}"
    {:ok, runs} = Agents.list_runs(actor: ctx.admin)
    assert [run] = Enum.filter(runs, &(&1.trigger_signal_type == "sdr.reply.received"))
    run
  end

  defp started!(ctx, run) do
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)
    run
  end

  defp reload(ctx, run) do
    {:ok, run} = Agents.get_run(run.id, actor: ctx.agent)
    run
  end

  ## Test 14

  describe "test 14: reply intake" do
    test "with no saved settings, reply intake creates its run and snapshot", ctx do
      assert not table_exists?("settings_revisions") or
               latest_number(ctx.tenant.id, :offering_profile) == 0,
             "precondition: no offering"

      run = reply_run!(ctx)
      snapshot = snapshot_of!(run, ctx.agent)

      assert {snapshot.offering_profile_source, snapshot.booking_link_source} ==
               {:absent, :absent}

      for kind <- [:writing_guide, :research_brief, :operational_limits] do
        assert Map.get(snapshot, :"#{kind}_source") == :code_default
      end

      assert {run.budget.max_model_calls, run.budget.max_tool_calls} == {2, 5}
      assert {:ok, settings} = run_settings(run, ctx.agent)
      assert slot_value(settings, :offering_profile, :source) == :absent
    end

    test "the reply code budget is lowered further by a smaller snapshot value", ctx do
      limits = Map.merge(limit_defaults(), %{run_max_model_calls: 1, research_max_model_calls: 1})
      save!(:operational_limits, limits, ctx.admin)
      run = reply_run!(ctx)
      assert run.budget.max_model_calls == 1, "C4-01a: reply budget not lowered by the snapshot"
      assert run.budget.max_tool_calls == 5
    end

    test "an unsubscribe reply is classified and suppressed; its run binds a snapshot", ctx do
      save_offering!(ctx.admin)
      %{delivery: delivery, lead: lead} = approved!(ctx)
      assert %{success: 1} = deliver!()
      delivery = outreach!(ctx, delivery)

      body = reply_body(delivery, "Please remove me from your list.\n\nUnsubscribe.")
      assert {:ok, %{status: :accepted}} = ingest!("reply", body)
      assert %{success: 1} = process!()

      assert [reply] = replies!(ctx)
      assert [rule] = decisions_about!(ctx, reply.id, :unsubscribe_rule)
      assert {rule.mode, rule.outcome} == {:deterministic, "unsubscribe"}
      assert [_] = Enum.filter(suppressions!(ctx), &(&1.reason == :unsubscribe_reply))
      assert reload!(ctx, lead).status == :stopped

      {:ok, runs} = Agents.list_runs(actor: ctx.admin)

      for run <- Enum.filter(runs, &(&1.trigger_signal_type == "sdr.reply.received")) do
        assert is_binary(snapshot_of!(run, ctx.agent).id)
      end
    end

    test "a reply run is refused at its model-call budget", ctx do
      run = reply_run!(ctx)
      _snapshot = snapshot_of!(run, ctx.agent)
      run = started!(ctx, run)
      assert {:ok, _} = Agents.reserve_model_call(reload(ctx, run), actor: ctx.agent)
      assert {:ok, _} = Agents.reserve_model_call(reload(ctx, run), actor: ctx.agent)

      assert match?(
               {:error, %Ash.Error.Invalid{}},
               Agents.reserve_model_call(reload(ctx, run), actor: ctx.agent)
             )
    end

    test "a reply run is refused by an exhausted grant allocation", ctx do
      SdrAgent.AdmissionFixtures.admit_tuples!()

      AgentsFixtures.grant!(ctx.tenant, %{
        total_attempts: 1,
        allocations: [%{key: :b5, applies_to: [:b5], attempts: 1}]
      })

      run = reply_run!(ctx)
      _snapshot = snapshot_of!(run, ctx.agent)
      run = started!(ctx, run)

      reserve = fn key ->
        Agents.reserve_model_invocation(reload(ctx, run), AgentsFixtures.claude_attrs(key),
          actor: ctx.agent
        )
      end

      assert {:ok, _} = reserve.("reply-grant-1")
      result = reserve.("reply-grant-2")

      assert match?({:error, %Refused{reason: {:budget_exhausted, :allocation}}}, result),
             short(result)
    end

    test "a reply run is refused by the tenant-day limit", ctx do
      run = reply_run!(ctx)
      _snapshot = snapshot_of!(run, ctx.agent)
      run = started!(ctx, run)
      put_env!(:daily_model_call_limit, Agents.daily_model_calls(ctx.tenant.id) + 1)

      reserve = fn key ->
        Agents.reserve_model_invocation(reload(ctx, run), AgentsFixtures.model_attrs(key),
          actor: ctx.agent
        )
      end

      assert {:ok, _} = reserve.("reply-daily-1")
      assert reserve.("reply-daily-2") == {:error, {:budget_exhausted, :daily}}
    end
  end

  ## Test 15

  describe "test 15: completeness by origin" do
    test "every usage origin has a row in the completeness table", _ctx do
      table = call(run_settings_module(), :completeness, [])

      assert Enum.sort(Map.keys(table)) == Enum.sort(UsageBucket.origins()),
             "a usage origin was added without a completeness row"

      for origin <- @business, do: assert(Map.fetch!(table, origin) == [:offering_profile])
      for origin <- @exempt, do: assert(Map.fetch!(table, origin) == [])
    end

    test "business origins need an offering; reply and proof bind a snapshot", ctx do
      definition = AgentsFixtures.definition!(ctx.tenant)
      require_table!("run_settings_snapshots")
      before = {count_rows("agent_runs"), count_rows("run_settings_snapshots")}

      for origin <- @business do
        attrs = AgentsFixtures.run_attrs(definition, usage_origin: origin)
        result = observe(fn -> Agents.create_run(attrs, actor: ctx.agent) end)

        assert settings_incomplete?(result, [:offering_profile]),
               "C4-01a: #{origin} without an offering: #{short(result)}"
      end

      assert {count_rows("agent_runs"), count_rows("run_settings_snapshots")} == before

      for origin <- @exempt do
        attrs = AgentsFixtures.run_attrs(definition, usage_origin: origin)
        assert {:ok, run} = Agents.create_run(attrs, actor: ctx.agent)
        assert is_binary(snapshot_of!(run, ctx.agent).id)
      end

      save_offering!(ctx.admin)

      for origin <- @business do
        attrs = AgentsFixtures.run_attrs(definition, usage_origin: origin)
        assert {:ok, run} = Agents.create_run(attrs, actor: ctx.agent)
        assert snapshot_of!(run, ctx.agent).offering_profile_source == :revision
      end
    end

    test "an unknown or missing origin is refused", ctx do
      _table = call(run_settings_module(), :completeness, [])
      definition = AgentsFixtures.definition!(ctx.tenant)
      before = count_rows("agent_runs")

      for origin <- [:unknown_origin, nil] do
        attrs = AgentsFixtures.run_attrs(definition, usage_origin: origin)
        result = observe(fn -> Agents.create_run(attrs, actor: ctx.agent) end)
        refute match?({:ok, _}, result), "origin #{inspect(origin)} accepted"
      end

      assert count_rows("agent_runs") == before
    end
  end
end
