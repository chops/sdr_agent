defmodule SdrAgent.AgentEnv.SnapshotNestingTest do
  @moduledoc """
  C2* S1 PR-A RED-1 (plan `claude-c2star-s1-environment-plan-r2.md` section
  7.1 rows T-U5 (S1 half) and S1-a; ADR-0005 C2* amendment item 2 and its
  addendum 1, accepted as D-227; Codex r2 rulings F2 and OQ5): the
  owner-or-inherit rule along real nested call paths.

    * **Direct hand-off owner (F2).** `handoff_ready!/2` builds a real run up
      to B1's `"proposal"` boundary (framework execution for setup only); the
      trace starts after it. A direct `HandOffProposal.perform/2` then owns:
      one observation, outside any transaction and before its first row
      lock; under every lock `current/0` is its snapshot; `SDR.proposal/2`,
      `Agents.released_output/2` and `ReleasedOutput.fetch/2` inherit its
      generation; the draft is proposed.
    * **Direct hand-off in a transaction (F2).** The same call inside
      `Audit.transaction/1` with no snapshot refuses at every entry, observes
      nothing, and `current/0` under its locks is `{:error,
      :snapshot_not_in_use}`. The S1 outcome is unchanged (S4 adds the
      business refusal).
    * **:llm decision.** `BuildEvidenceBundle` directly and through `run/2`:
      the DecisionRules invocation check inherits (with the model provider
      and reservation entries).
    * **Capture.** `Delivery.attempt/2` owns; `CaptureAdapter.deliver/3` and
      `Outreach.record_receipt/2` inherit.
    * **Framework.** `SDR.Action.execute/3` owns; the perform and its nested
      entries inherit.
    * **Invalidation and resampling.** A file change after the sample is
      seen by the next top-level owner, not by this one.
    * **Launch admission.** `admit_launch/3` in a spawned process owns its
      own snapshot; the caller's stays active.
    * **Worker finish (S1-a, D-227).** `AgentWorker.run/2` owns
      `:agent_finish` after the last action's invalidation, outside any
      transaction; the unreleased-invocations query in its terminal
      transaction sees that snapshot.
    * **Sweeper recovery (S1-a, D-227).** `StaleRunSweeper.sweep/1` owns one
      `:stale_run_recover` per run; the unlocked prefilter, the locked
      re-check and the Recovery it runs share that generation.

  The repo-query probes run in the querying process (telemetry handlers
  are synchronous), so `current/0` is read exactly where a consumer would
  read it. Telemetry fields read: see `SdrAgent.AgentEnv.OperationSnapshotTest`.

  RED: no entry is wrapped, so no snapshot event is emitted (behavioural:
  the first owner/refusal assertion fails on an empty trace); the
  resampling and launch-admission cases call `OperationSnapshot` directly
  (structural, guarded after the fixtures). The fixture and inert cases are
  controls and pass at RED.

  Hermetic: SQL sandbox, the Fake provider, physical roots under
  `tmp/agent-env-roots`; no port, CLI, real Mix or VM.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [approved!: 1, outreach!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.GateFixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.SDR
  alias SdrAgent.SDR.Actions.BuildEvidenceBundle
  alias SdrAgent.SDR.Actions.HandOffProposal
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.StaleRunSweeper
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @snapshot SdrAgent.AgentEnv.OperationSnapshot
  @snapshot_api [enter: 2, current: 0, verify: 1, valid?: 1, check_lease: 1]

  # B1's HandOffProposal v2 params at this base (prepare_outreach_flow.ex
  # "proposal" step), pinned (Codex OQ5).
  @handoff_params [:claims_check, :draft, :lead_id, :personalization_check, :plan, :shape_check]
  @handoff_nested [:sdr_proposal, :released_output, :released_output_fetch]

  setup do
    Fx.unconfigure!()
    %{root: Fx.root!("nesting")}
  end

  ## Helpers

  defp run_env!(ctx) do
    bound = Fx.bound!(ctx.root, lease: :run)
    Fx.configure!(ctx.root, mode: :run, nonce: bound.nonce, step: :run)
    bound
  end

  defp require_snapshot! do
    assert Code.ensure_loaded?(@snapshot), "C2* S1 RED-1: #{inspect(@snapshot)} is not available"

    for {function, arity} <- @snapshot_api do
      assert function_exported?(@snapshot, function, arity),
             "C2* S1 RED-1: #{inspect(@snapshot)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp snap(function, args), do: apply(@snapshot, function, args)

  defp attempt(fun) do
    {:returned, fun.()}
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp mine(events), do: Enum.filter(events, &(&1.pid == self()))
  defp of_kind(events, kind), do: Enum.filter(events, &(&1.kind == kind))
  defp snapshot_events(events), do: Enum.reject(events, &(&1.kind == :query))
  defp tags(events), do: Enum.map(events, &{&1.kind, entry_of(&1)})
  defp entry_of(event), do: event |> Map.get(:metadata, %{}) |> Map.get(:entry)

  defp owners_of(events, entry),
    do: Enum.filter(events, &(&1.kind == :observe_start and entry_of(&1) == entry))

  defp inherited_by(events, generation) do
    events
    |> Enum.filter(&(&1.kind == :inherit and &1.metadata[:generation] == generation))
    |> Enum.map(&entry_of/1)
  end

  defp lock_query?(%{query: sql}) when is_binary(sql),
    do: sql =~ ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/

  defp lock_query?(_metadata), do: false

  # ResultGate.unreleased_invocations/1 (result_gate.ex): model_invocations
  # filtered on ledger_generation with a NOT EXISTS over :released releases.
  defp unreleased_query?(%{query: sql}) when is_binary(sql) do
    Enum.all?(
      [
        ~s("model_invocations"),
        ~s("model_result_releases"),
        ~s("ledger_generation"),
        ~s("disposition")
      ],
      &String.contains?(sql, &1)
    )
  end

  defp unreleased_query?(_metadata), do: false

  # The owner rule for one owner in this process (see OperationSnapshotTest).
  defp assert_owner(events, entry) do
    own = events |> mine() |> snapshot_events()
    starts = of_kind(own, :observe_start)

    assert Enum.map(starts, &entry_of/1) == [entry],
           "C2* item 2 (own): #{inspect(entry)} must observe exactly once as the owner; " <>
             "snapshot events in this process: #{inspect(tags(own))}"

    [start] = starts
    assert start.metadata[:in_transaction?] == false
    assert start.in_transaction? == false, "C2* item 2: observed under an open transaction"
    assert [stop] = of_kind(own, :observe_stop)
    generation = stop.metadata[:generation]
    assert is_integer(generation) and generation > 0
    assert of_kind(own, :refuse) == []

    for inherit <- of_kind(own, :inherit) do
      assert inherit.metadata[:generation] == generation,
             "C2* item 2 (inherit): #{inspect(entry_of(inherit))} did not inherit the owner"
    end

    assert Enum.map(of_kind(own, :invalidate), &{entry_of(&1), &1.metadata[:generation]}) ==
             [{entry, generation}],
           "C2* item 2: only the owner's own completion invalidates, once"

    generation
  end

  defp assert_refused(events, entry) do
    own = events |> mine() |> snapshot_events()

    assert match?([%{kind: :refuse} | _], own) and entry_of(hd(own)) == entry,
           "C2* item 2 (refuse): #{inspect(entry)} inside an open transaction with no " <>
             "snapshot must refuse first; snapshot events: #{inspect(tags(own))}"

    assert Enum.all?(own, &(&1.kind == :refuse)), "refused, yet: #{inspect(tags(own))}"
  end

  # The generation of owner `start`, and the events between its observation
  # and its own invalidation.
  defp window(events, start) do
    stop =
      Enum.find(
        events,
        &(&1.kind == :observe_stop and &1.pid == start.pid and &1.seq > start.seq)
      )

    assert stop, "C2* item 2: the #{inspect(entry_of(start))} observation never completed"
    generation = stop.metadata[:generation]

    finish =
      Enum.find(
        events,
        &(&1.kind == :invalidate and &1.pid == start.pid and
            &1.metadata[:generation] == generation)
      )

    assert finish, "C2* item 2: the #{inspect(entry_of(start))} owner was never invalidated"
    {generation, Enum.filter(events, &(&1.seq > start.seq and &1.seq < finish.seq))}
  end

  defp assert_proposed!(ctx, key) do
    lead = fixture_lead!(ctx, key)

    {:ok, drafts} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: lead.id], actor: ctx.admin)

    assert [_draft] = drafts, "the hand-off proposed #{length(drafts)} drafts"
  end

  defp framework_context(sdr), do: %{sdr: %{sdr | agent_state: nil}, agent_state: sdr.agent_state}

  defp abandoned_run!(ctx) do
    missing_job_id = 2_000_000_000 + System.unique_integer([:positive])
    %{run: run} = AgentsFixtures.operated_run(ctx.tenant, oban_job_id: missing_job_id)
    run
  end

  defp past_stale!(ctx, runs) do
    latest = runs |> Enum.map(&run!(ctx, &1).started_at) |> Enum.max(DateTime)
    Clock.freeze(DateTime.add(latest, StaleRunSweeper.stale_after_seconds() + 1, :second))
  end

  ## Tests

  describe "the direct hand-off fixture (controls)" do
    test "handoff_ready!/2 stops at B1's hand-off boundary with its six current params", ctx do
      {params, sdr} = Fx.handoff_ready!(ctx, "01")

      assert HandOffProposal.sdr_action_version() == "3"
      assert params |> Map.keys() |> Enum.sort() == @handoff_params
      assert %{passed: true} = params.claims_check
      assert %{passed: true} = params.personalization_check
      assert %{passed: true, decision_id: shape_id} = params.shape_check
      assert is_binary(shape_id)
      assert %{decision_id: draft_id, model_invocation_id: invocation_id} = params.draft
      assert is_binary(draft_id) and is_binary(invocation_id)

      lead = fixture_lead!(ctx, "01")
      assert params.lead_id == lead.id
      assert lead.status == :qualified
      assert sdr.signal_type == "sdr.draft.requested"
      assert sdr.tool_invocation == nil
      run = run!(ctx, %{id: sdr.run_id})
      assert run.status == :running
      assert {:error, :no_proposal} = SDR.proposal(sdr.run_id, actor: ctx.agent)
      refute "sdr.draft.completed" in signal_types(ctx.tenant, run)
    end

    test "with the selector unset the direct hand-off emits nothing and proposes the draft",
         ctx do
      {params, sdr} = Fx.handoff_ready!(ctx, "01")

      {result, events} = Fx.trace_snapshots(fn -> HandOffProposal.perform(params, sdr) end)

      assert {:ok, %{phase: :review}} = result
      assert events == []
      assert_proposed!(ctx, "01")
    end
  end

  describe "direct hand-off owner (F2)" do
    test "HandOffProposal.perform/2 owns before its first lock; nested entries inherit under it",
         ctx do
      {params, sdr} = Fx.handoff_ready!(ctx, "01")
      run_env!(ctx)

      # The trace starts here: the framework ran only the setup (Codex OQ5).
      {result, events} =
        Fx.trace_snapshots(fn -> HandOffProposal.perform(params, sdr) end,
          queries: &lock_query?/1
        )

      generation = assert_owner(events, :perform_hand_off_proposal)
      assert length(of_kind(events, :observe_start)) == 1
      [start] = owners_of(mine(events), :perform_hand_off_proposal)
      locks = events |> mine() |> of_kind(:query)
      assert locks != [], "the hand-off took no row lock"
      assert start.seq < hd(locks).seq, "C2* item 2: the owner observed after its first lock"

      for lock <- locks do
        assert match?({:ok, %{generation: ^generation}}, lock.current),
               "under a row lock current/0 was #{inspect(lock.current)}, not the owner's"
      end

      inherited = inherited_by(mine(events), generation)

      for entry <- @handoff_nested do
        assert entry in inherited,
               "C2* item 2: nested #{inspect(entry)} did not inherit (#{inspect(inherited)})"
      end

      assert {:ok, %{phase: :review}} = result
      assert_proposed!(ctx, "01")
    end
  end

  describe "direct hand-off in a transaction (F2)" do
    test "inside Audit.transaction/1 with no snapshot every entry refuses; the S1 outcome holds",
         ctx do
      {params, sdr} = Fx.handoff_ready!(ctx, "01")
      run_env!(ctx)

      {result, events} =
        Fx.trace_snapshots(
          fn -> Audit.transaction(fn -> HandOffProposal.perform(params, sdr) end) end,
          queries: &lock_query?/1
        )

      assert_refused(events, :perform_hand_off_proposal)
      assert of_kind(events, :observe_start) == []
      refused = events |> mine() |> of_kind(:refuse) |> Enum.map(&entry_of/1)

      for entry <- @handoff_nested do
        assert entry in refused, "nested #{inspect(entry)} did not refuse (#{inspect(refused)})"
      end

      locks = events |> mine() |> of_kind(:query)
      assert locks != []

      for lock <- locks do
        assert lock.current == {:error, :snapshot_not_in_use},
               "under a row lock current/0 was #{inspect(lock.current)}"
      end

      assert {:ok, {:ok, %{phase: :review}}} = result
      assert_proposed!(ctx, "01")
    end
  end

  describe ":llm decision (T-U5)" do
    test "a direct BuildEvidenceBundle.perform/2 owns; the DecisionRules check inherits", ctx do
      {params, sdr} = Fx.evidence_ready!(ctx, "01")
      run_env!(ctx)

      {result, events} = Fx.trace_snapshots(fn -> BuildEvidenceBundle.perform(params, sdr) end)

      generation = assert_owner(events, :perform_build_evidence_bundle)
      inherited = inherited_by(mine(events), generation)

      for entry <- [:model_provider_complete, :reserve_model_invocation, :decision_rules] do
        assert entry in inherited, "#{inspect(entry)} did not inherit (#{inspect(inherited)})"
      end

      assert elem(result, 0) == :ok
    end

    test "through run/2 execute/3 owns; the perform and the DecisionRules check inherit", ctx do
      {params, sdr} = Fx.evidence_ready!(ctx, "02")
      run_env!(ctx)

      {result, events} =
        Fx.trace_snapshots(fn -> BuildEvidenceBundle.run(params, framework_context(sdr)) end)

      generation = assert_owner(events, :sdr_action)
      inherited = inherited_by(mine(events), generation)

      for entry <- [:perform_build_evidence_bundle, :decision_rules] do
        assert entry in inherited, "#{inspect(entry)} did not inherit (#{inspect(inherited)})"
      end

      assert elem(result, 0) == :ok
    end
  end

  describe "capture (T-U5)" do
    test "Delivery.attempt/2 owns; CaptureAdapter.deliver/3 and record_receipt/2 inherit", ctx do
      %{delivery: operation} = approved!(ctx)
      run_env!(ctx)

      {_result, events} =
        Fx.trace_snapshots(fn -> Delivery.attempt(operation.id, ctx.tenant.id) end)

      generation = assert_owner(events, :delivery_attempt)
      inherited = inherited_by(mine(events), generation)

      for entry <- [:capture_deliver, :record_receipt] do
        assert entry in inherited, "#{inspect(entry)} did not inherit (#{inspect(inherited)})"
      end

      assert outreach!(ctx, operation).state == :accepted
    end
  end

  describe "framework (T-U5)" do
    test "SDR.Action.execute/3 owns the hand-off; perform/2 and its nested entries inherit",
         ctx do
      {params, sdr} = Fx.handoff_ready!(ctx, "01")
      run_env!(ctx)

      {result, events} =
        Fx.trace_snapshots(fn -> HandOffProposal.run(params, framework_context(sdr)) end)

      generation = assert_owner(events, :sdr_action)
      inherited = inherited_by(mine(events), generation)

      for entry <- [:perform_hand_off_proposal | @handoff_nested] do
        assert entry in inherited, "#{inspect(entry)} did not inherit (#{inspect(inherited)})"
      end

      assert {:ok, %{phase: :review}} = result
      assert_proposed!(ctx, "01")
    end
  end

  describe "invalidation and resampling (T-U5)" do
    test "a file change after the sample is seen by the next top-level owner, not by this one",
         ctx do
      run_env!(ctx)
      require_snapshot!()

      first =
        snap(:enter, [
          :sdr_proposal,
          fn ->
            sampled = snap(:current, [])
            Fx.tamper!(ctx.root, :lease)
            {sampled, snap(:enter, [:released_output, fn -> snap(:current, []) end])}
          end
        ])

      assert {{:ok, sampled}, {:ok, nested}} = first
      assert nested == sampled, "the nested entry re-observed instead of inheriting"
      assert snap(:valid?, [sampled])
      assert snap(:verify, [sampled]) == {:error, :snapshot_not_in_use}

      assert {:ok, next} = snap(:enter, [:sdr_proposal, fn -> snap(:current, []) end])
      assert next.generation > sampled.generation
      refute snap(:valid?, [next]), "the next owner did not see the changed lease"
      assert snap(:check_lease, [next]) == {:error, :agent_env_lease_mismatch}
    end
  end

  describe "launch admission (T-U5)" do
    test "admit_launch/3 in a spawned process owns its own snapshot; the caller's is untouched",
         ctx do
      run_env!(ctx)
      require_snapshot!()

      {result, events} =
        Fx.trace_snapshots(fn ->
          snap(:enter, [
            :sdr_proposal,
            fn ->
              before = snap(:current, [])

              task =
                Task.async(fn ->
                  launch =
                    attempt(fn ->
                      Agents.admit_launch(Ecto.UUID.generate(), :claude_cli_opus,
                        actor: ctx.agent
                      )
                    end)

                  {self(), launch, snap(:current, [])}
                end)

              {before, Task.await(task, 30_000), snap(:current, [])}
            end
          ])
        end)

      assert {{:ok, caller}, {task_pid, _launch, after_in_task}, {:ok, still}} = result
      assert still == caller, "the caller's snapshot changed across the spawned launch"
      assert after_in_task == {:error, :snapshot_not_in_use}

      assert [launch] = owners_of(events, :admit_launch)
      assert launch.pid == task_pid
      assert launch.in_transaction? == false
      {launch_generation, _window} = window(events, launch)
      refute launch_generation == caller.generation
      assert assert_owner(events, :sdr_proposal) == caller.generation
    end
  end

  describe "worker finish (S1-a; ADR-0005 addendum 1, D-227)" do
    test "AgentWorker.run/2 owns :agent_finish after the actions; its unreleased check sees it",
         ctx do
      %{run: run, job: job} = assign!(ctx, "01")
      run_env!(ctx)

      {result, events} =
        Fx.trace_snapshots(fn -> AgentWorker.run(job, []) end, queries: &unreleased_query?/1)

      assert result == :ok
      finish = owners_of(events, :agent_finish)

      assert match?([_one], finish),
             "C2* addendum 1: AgentWorker.run/2 must own :agent_finish exactly once; owners: " <>
               inspect(Enum.map(of_kind(events, :observe_start), &entry_of/1))

      [start] = finish
      assert start.pid == self()
      assert start.in_transaction? == false
      assert start.metadata[:in_transaction?] == false
      {generation, window} = window(events, start)

      actions = Enum.filter(of_kind(events, :invalidate), &(entry_of(&1) == :sdr_action))
      assert actions != [], "no action owned its execute/3"
      assert List.last(actions).seq < start.seq, "finish observed before the last action ended"

      others = of_kind(events, :observe_start) -- finish
      assert Enum.all?(others, &(entry_of(&1) == :sdr_action)), inspect(tags(others))

      assert [query] = of_kind(window, :query)
      assert query.pid == self()
      assert query.in_transaction? == true
      assert match?({:ok, %{generation: ^generation}}, query.current), inspect(query.current)
      assert run!(ctx, run).status == :succeeded
    end
  end

  describe "sweeper recovery (S1-a; ADR-0005 addendum 1, D-227)" do
    test "crash path: one owner per run; the prefilter and the locked re-check share it", ctx do
      runs = [abandoned_run!(ctx), abandoned_run!(ctx)]
      past_stale!(ctx, runs)
      run_env!(ctx)

      {result, events} =
        Fx.trace_snapshots(fn -> StaleRunSweeper.sweep(ctx.tenant.id) end,
          queries: &unreleased_query?/1
        )

      assert result == :ok
      owners = owners_of(events, :stale_run_recover)

      assert length(owners) == 2,
             "C2* addendum 1: one :stale_run_recover owner per run; owners: " <>
               inspect(Enum.map(of_kind(events, :observe_start), &entry_of/1))

      generations =
        for owner <- owners do
          assert owner.pid == self()
          assert owner.in_transaction? == false
          {generation, window} = window(events, owner)
          assert [prefilter, locked] = of_kind(window, :query)
          assert prefilter.in_transaction? == false
          assert locked.in_transaction? == true

          for query <- [prefilter, locked] do
            assert match?({:ok, %{generation: ^generation}}, query.current),
                   inspect(query.current)
          end

          generation
        end

      assert length(Enum.uniq(generations)) == 2

      for run <- runs do
        recovered = run!(ctx, run)
        assert {recovered.status, recovered.status_reason} == {:failed, :crash}
      end
    end

    test "gate path: the per-run owner's prefilter and the Recovery it runs share it", ctx do
      AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      run = abandoned_run!(ctx)
      invocation = AgentsFixtures.claude_completed!(run, ctx.agent, "c2star-s1-sweep-gate")
      _cause = GateFixtures.cause!(invocation, operation_id: run.operation_id)
      past_stale!(ctx, [run])
      run_env!(ctx)

      {result, events} =
        Fx.trace_snapshots(fn -> StaleRunSweeper.sweep(ctx.tenant.id) end,
          queries: &unreleased_query?/1
        )

      assert result == :ok
      owners = owners_of(events, :stale_run_recover)

      assert match?([_one], owners),
             "C2* addendum 1: one :stale_run_recover owner for the run; owners: " <>
               inspect(Enum.map(of_kind(events, :observe_start), &entry_of/1))

      [owner] = owners
      {generation, window} = window(events, owner)
      assert [prefilter] = of_kind(window, :query)
      assert prefilter.in_transaction? == false
      assert match?({:ok, %{generation: ^generation}}, prefilter.current)

      recoveries =
        Enum.filter(of_kind(window, :inherit), &(entry_of(&1) == :result_gate_recovery))

      assert recoveries != [], "the Recovery run by the sweeper did not inherit its owner"
      assert Enum.all?(recoveries, &(&1.metadata[:generation] == generation))
      assert owners_of(events, :result_gate_recovery) == []
      assert run!(ctx, run).status == :failed
    end
  end
end
