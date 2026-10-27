defmodule SdrAgent.AgentEnv.OperationSnapshotTest do
  @moduledoc """
  C2* S1 PR-A RED-1 (plan `claude-c2star-s1-environment-plan-r2.md`
  sections 4.1-4.3 and 7.1 rows T-U4, T-U4/R4, T-B1; ADR-0005 C2* amendment
  item 2, the owner-or-inherit rule; Codex r2 review: PR-A plan/entity PASS,
  ModeRefused in GREEN-1). The operation snapshot core:

    * **Constants and mode** (section 4.1): `agentenv-1`, its database,
      port and exclusive end; `mode/0` and `configured?/0` follow the
      `SdrAgent.AgentEnv` configuration, `:none` when there is none (so PR-A
      is inert in dev and prod).
    * **Lifetime** (section 4.3 `enter/2`): a top-level entry with no
      transaction open owns (observes, registers before its body, and only
      its own return or raise invalidates); a nested entry inherits the same
      reference and never replaces or invalidates it; with no snapshot and a
      transaction open it refuses (the body runs, nothing is observed or
      registered). One snapshot per process; generations are strictly
      increasing; unconfigured it is inert; `entries/0` is closed; in the
      non-run modes every entry raises `SdrAgent.AgentEnv.ModeRefused`
      before its body.
    * **verify/1** (R3): only this process's active registration verifies.
    * **Observation** (sections 4.2, 4.3): the three views, validity (lease
      nonce, mode and target; environment database), the two authorization
      digests kept distinct (R3 (a)); observation never raises;
      `State.read/2`'s canonical, closed-key views.
    * **Entry wiring** (T-U4): every inventoried entry (section 5.2 rows
      1-6 and 8-20) called at the top level with the smallest input that
      reaches its first line observes exactly once with its own tag, outside
      any transaction, and nested entries inherit; inside `Repo.transaction/1`
      it refuses; in bootstrap mode it raises ModeRefused. The DecisionRules
      check always runs in the Decision create's own transaction, so at the
      top level it refuses (it inherits under an owner: see
      `SdrAgent.AgentEnv.SnapshotNestingTest`). The worker owners
      (`:agent_finish`, `:stale_run_recover`, D-227) are covered there.
    * **Identity under the head** (R4): `live_database_identity/0` is a
      plain read inside a transaction holding the chain head: no lock
      clause, no snapshot observation, no file call.
    * **Identity independence** (T-B1, S1 half).

  Telemetry read by these tests (section 4.3; metadata only): the
  `[:sdr_agent, :agent_env, :snapshot, :observe]` span (start `%{entry,
  in_transaction?}`, stop `%{entry, generation}`) and the `:inherit`,
  `:refuse` and `:invalidate` events. The tests read `entry` on all three
  and `generation` on `:inherit` and `:invalidate`, which is how "inherits
  its generation" (section 7.1) is observed.

  RED: `SdrAgent.AgentEnv`, `SdrAgent.AgentEnv.OperationSnapshot`,
  `SdrAgent.AgentEnv.State` and `SdrAgent.AgentEnv.ModeRefused` do not exist
  (structural, guarded after the fixtures), and no entry emits a snapshot
  event (behavioural). The unconfigured wiring row is a control.

  Hermetic: SQL sandbox, physical roots under `tmp/agent-env-roots`, no
  port, process, real Mix or CLI.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ReleasedOutput
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.Outreach.Delivery.CaptureAdapter
  alias SdrAgent.Outreach.InboxCommands
  alias SdrAgent.SDR
  alias SdrAgent.SDR.Action
  alias SdrAgent.SDR.Actions
  alias SdrAgent.SDR.Context
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @agent_env SdrAgent.AgentEnv
  @snapshot SdrAgent.AgentEnv.OperationSnapshot
  @state SdrAgent.AgentEnv.State
  @mode_refused SdrAgent.AgentEnv.ModeRefused

  @snapshot_api [
    entries: 0,
    enter: 2,
    current: 0,
    verify: 1,
    valid?: 1,
    check_lease: 1,
    environment: 1,
    authorization: 1
  ]

  # Section 4.3: 23 atoms; the reserved receipt atom is dropped (S1-b).
  @entries [
    :sdr_action,
    :perform_score_lead,
    :perform_build_evidence_bundle,
    :perform_draft_email,
    :perform_classify_reply,
    :perform_hand_off_proposal,
    :model_provider_complete,
    :reserve_model_invocation,
    :admit_launch,
    :result_gate,
    :result_gate_recovery,
    :released_output,
    :released_output_fetch,
    :decision_rules,
    :sdr_proposal,
    :edit_draft,
    :approve,
    :inbox_command,
    :delivery_attempt,
    :capture_deliver,
    :record_receipt,
    :agent_finish,
    :stale_run_recover
  ]

  # Private bodies reached only through AgentWorker.run/2 and
  # StaleRunSweeper.sweep/1: SnapshotNestingTest covers them.
  @worker_owners [:agent_finish, :stale_run_recover]

  # Section 5.2 rows 1-6 and 8-20: {entry, call site}. Row 18 has two
  # sites with the one tag (Codex OQ6).
  @wiring [
    {:sdr_action, "SDR.Action.execute/3"},
    {:perform_score_lead, "ScoreLead.perform/2"},
    {:perform_build_evidence_bundle, "BuildEvidenceBundle.perform/2"},
    {:perform_draft_email, "DraftEmail.perform/2"},
    {:perform_classify_reply, "ClassifyReply.perform/2"},
    {:perform_hand_off_proposal, "HandOffProposal.perform/2"},
    {:model_provider_complete, "ModelProvider.complete/2"},
    {:reserve_model_invocation, "Agents.reserve_model_invocation/3"},
    {:admit_launch, "Agents.admit_launch/3"},
    {:result_gate, "ResultGate.gate/3"},
    {:result_gate_recovery, "ResultGate.Recovery.run/3"},
    {:released_output, "Agents.released_output/2"},
    {:released_output_fetch, "ReleasedOutput.fetch/2"},
    {:decision_rules, "the DecisionRules invocation check"},
    {:sdr_proposal, "SDR.proposal/2"},
    {:edit_draft, "Outreach.edit_draft/3"},
    {:approve, "Outreach.approve/3"},
    {:inbox_command, "Outreach.inbox_command/2"},
    {:inbox_command, "InboxCommands.execute/2"},
    {:delivery_attempt, "Delivery.attempt/2"},
    {:capture_deliver, "CaptureAdapter.deliver/3"},
    {:record_receipt, "Outreach.record_receipt/2"}
  ]

  # The DecisionRules check is a before_action hook: always inside the
  # Decision create's transaction, so a top-level create refuses there.
  @in_create_transaction [:decision_rules]

  # Not asserted to raise in bootstrap mode, because the enclosing code
  # rescues by design: the DecisionRules hook runs inside Ash's action, and
  # InboxCommands.execute/2 rescues into its fixed producer_error. Both still
  # run no command body (the facade row raises before the delegate).
  @raise_exempt ["the DecisionRules invocation check", "InboxCommands.execute/2"]

  setup do
    tenant = bootstrap!()
    root = Fx.root!("snapshot")
    Fx.unconfigure!()

    %{
      tenant: tenant,
      root: root,
      agent: system_actor(:agent_runtime, tenant),
      admin: human(:admin, tenant)
    }
  end

  ## Helpers

  defp require!(module, functions) do
    assert Code.ensure_loaded?(module), "C2* S1 RED-1: #{inspect(module)} is not available"

    for {function, arity} <- functions do
      assert function_exported?(module, function, arity),
             "C2* S1 RED-1: #{inspect(module)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp require_snapshot!, do: require!(@snapshot, @snapshot_api)

  defp snap(function, args), do: apply(@snapshot, function, args)
  defp env(function, args), do: apply(@agent_env, function, args)
  defp state(function, args), do: apply(@state, function, args)

  defp run_env!(ctx) do
    bound = Fx.bound!(ctx.root, lease: :run)
    Fx.configure!(ctx.root, mode: :run, nonce: bound.nonce, step: :run)
    bound
  end

  # One top-level owner's snapshot (`:approve` is any wrapped entry).
  defp sample! do
    case snap(:enter, [:approve, fn -> snap(:current, []) end]) do
      {:ok, snapshot} -> snapshot
      other -> flunk("C2* S1: a top-level owner sampled no snapshot: #{inspect(other)}")
    end
  end

  defp attempt(fun) do
    {:returned, fun.()}
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp in_transaction(call),
    do: Repo.transaction(fn -> Repo.rollback({:attempted, attempt(call)}) end)

  defp uuid, do: Ecto.UUID.generate()

  defp mine(events), do: Enum.filter(events, &(&1.pid == self()))
  defp of_kind(events, kind), do: Enum.filter(events, &(&1.kind == kind))
  defp tags(events), do: Enum.map(events, &{&1.kind, entry_of(&1)})
  defp entry_of(event), do: event |> Map.get(:metadata, %{}) |> Map.get(:entry)

  defp sha256_file(path),
    do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

  defp lock_query?(sql) when is_binary(sql),
    do: sql =~ ~r/\bFOR (UPDATE|SHARE|NO KEY UPDATE|KEY SHARE)\b/

  defp lock_query?(_sql), do: false

  # The owner rule's evidence for one top-level call in this process:
  # exactly one observation, with this tag, outside any transaction; every
  # nested entry inherits its generation; it alone invalidates, last.
  defp assert_owner(events, entry) do
    own = events |> mine() |> Enum.reject(&(&1.kind == :query))
    starts = of_kind(own, :observe_start)

    assert Enum.map(starts, & &1.metadata[:entry]) == [entry],
           "C2* item 2 (own): a top-level #{inspect(entry)} must observe exactly once as its " <>
             "own owner; snapshot events in this process: #{inspect(tags(own))}"

    [start] = starts
    assert start.metadata[:in_transaction?] == false
    assert start.in_transaction? == false, "C2* item 2: observed under an open transaction"
    assert [stop] = of_kind(own, :observe_stop)
    generation = stop.metadata[:generation]
    assert stop.metadata[:entry] == entry
    assert is_integer(generation) and generation > 0
    assert of_kind(own, :observe_exception) == []
    assert of_kind(own, :refuse) == []

    for inherit <- of_kind(own, :inherit) do
      assert inherit.metadata[:generation] == generation,
             "C2* item 2 (inherit): nested #{inspect(inherit.metadata[:entry])} did not " <>
               "inherit the owner's generation"
    end

    assert Enum.map(of_kind(own, :invalidate), &{&1.metadata[:entry], &1.metadata[:generation]}) ==
             [{entry, generation}],
           "C2* item 2: only the owner's own completion invalidates, once"

    assert List.last(own).kind == :invalidate
    generation
  end

  # Rule 3: no snapshot and a transaction open — refused first at `entry`,
  # nothing observed, inherited or invalidated.
  defp assert_refused(events, entry) do
    own = events |> mine() |> Enum.reject(&(&1.kind == :query))

    assert match?([%{kind: :refuse} | _], own) and hd(own).metadata[:entry] == entry,
           "C2* item 2 (refuse): #{inspect(entry)} inside an open transaction with no " <>
             "snapshot must refuse first; snapshot events: #{inspect(tags(own))}"

    assert Enum.all?(own, &(&1.kind == :refuse)), "refused, yet: #{inspect(tags(own))}"
  end

  defp assert_top_level(events, entry) when entry in @in_create_transaction,
    do: assert_refused(events, entry)

  defp assert_top_level(events, entry), do: assert_owner(events, entry)

  ## The wiring table's calls: the smallest input reaching each first line.

  defp sdr(c) do
    %Context{
      actor: c.agent,
      tenant_id: c.tenant.id,
      run_id: uuid(),
      correlation_id: uuid(),
      signal_id: "sig-c2star-s1-wiring",
      agent_state: %{phase: :validate, campaign_id: nil, evidence_ids: []}
    }
  end

  defp invocation(c), do: %{id: uuid(), tenant_id: c.tenant.id}
  defp gate, do: %{run_id: uuid(), operation_id: uuid()}
  defp dlv(c), do: Actor.system(:delivery_worker, c.tenant.id)

  defp llm_decision do
    %{
      kind: :draft_proposal,
      mode: :llm,
      subject_id: uuid(),
      model_invocation_id: uuid(),
      output_pointer: "",
      inputs: %{"evidence_ids" => []},
      outcome: "proposed",
      rationale: "C2* S1 wiring"
    }
  end

  defp wiring_call("SDR.Action.execute/3", c),
    do: fn -> Action.execute(Actions.ValidateClaims, %{}, %{sdr: sdr(c)}) end

  defp wiring_call("ScoreLead.perform/2", c),
    do: fn -> Actions.ScoreLead.perform(%{lead_id: uuid()}, sdr(c)) end

  defp wiring_call("BuildEvidenceBundle.perform/2", c) do
    params = %{
      lead_id: uuid(),
      crm: %{artifacts: []},
      company: %{artifacts: []},
      search: %{artifacts: []},
      pages: []
    }

    fn -> Actions.BuildEvidenceBundle.perform(params, sdr(c)) end
  end

  defp wiring_call("DraftEmail.perform/2", c) do
    params = %{lead_id: uuid(), claims: [], triggers: [], plan: %{}}
    fn -> Actions.DraftEmail.perform(params, sdr(c)) end
  end

  defp wiring_call("ClassifyReply.perform/2", c),
    do: fn -> Actions.ClassifyReply.perform(%{reply_id: uuid()}, sdr(c)) end

  defp wiring_call("HandOffProposal.perform/2", c),
    do: fn -> Actions.HandOffProposal.perform(%{}, sdr(c)) end

  defp wiring_call("ModelProvider.complete/2", _c) do
    opts = [provider: ClaudeCLI, provider_options: [server: :c2star_s1_wiring_no_server]]
    fn -> ModelProvider.complete(%{}, opts) end
  end

  defp wiring_call("Agents.reserve_model_invocation/3", c),
    do: fn -> Agents.reserve_model_invocation(c.run, %{}, actor: c.agent) end

  defp wiring_call("Agents.admit_launch/3", c),
    do: fn -> Agents.admit_launch(uuid(), :claude_cli_opus, actor: c.agent) end

  defp wiring_call("ResultGate.gate/3", c),
    do: fn -> ResultGate.gate(invocation(c), gate()) end

  defp wiring_call("ResultGate.Recovery.run/3", c),
    do: fn -> Recovery.run(invocation(c), gate()) end

  defp wiring_call("Agents.released_output/2", c),
    do: fn -> Agents.released_output(uuid(), actor: c.agent) end

  defp wiring_call("ReleasedOutput.fetch/2", c),
    do: fn -> ReleasedOutput.fetch(uuid(), c.agent) end

  defp wiring_call("the DecisionRules invocation check", c),
    do: fn -> Context.decide(%{sdr(c) | run_id: c.run.id}, llm_decision(), "c2star-s1") end

  defp wiring_call("SDR.proposal/2", c),
    do: fn -> SDR.proposal(uuid(), actor: c.agent) end

  defp wiring_call("Outreach.edit_draft/3", c),
    do: fn ->
      Outreach.edit_draft(%{id: uuid()}, %{subject: "s", body_text: "b"}, actor: c.admin)
    end

  defp wiring_call("Outreach.approve/3", c),
    do: fn -> Outreach.approve(%{id: uuid()}, %{}, actor: c.admin) end

  defp wiring_call("Outreach.inbox_command/2", _c),
    do: fn -> Outreach.inbox_command("c2star-s1-no-session", %{}) end

  defp wiring_call("InboxCommands.execute/2", _c),
    do: fn -> InboxCommands.execute("c2star-s1-no-session", %{}) end

  defp wiring_call("Delivery.attempt/2", c),
    do: fn -> Delivery.attempt(uuid(), c.tenant.id) end

  defp wiring_call("CaptureAdapter.deliver/3", c) do
    operation = %{id: uuid(), rendered_sha256: :crypto.hash(:sha256, "other bytes")}
    fn -> CaptureAdapter.deliver(operation, "rendered bytes", actor: dlv(c)) end
  end

  defp wiring_call("Outreach.record_receipt/2", c),
    do: fn -> Outreach.record_receipt(%{}, actor: dlv(c)) end

  ## Tests

  describe "constants and mode (section 4.1)" do
    test "the agentenv-1 constants", _ctx do
      require!(@agent_env, environment_id: 0, database: 0, http_port: 0, environment_end: 0)

      assert env(:environment_id, []) == "agentenv-1"
      assert env(:database, []) == "sdr_agent_agentenv"
      assert env(:http_port, []) == 4130
      assert DateTime.compare(env(:environment_end, []), ~U[2026-11-01 06:00:00.000000Z]) == :eq
    end

    test "mode/0 and configured?/0 follow the configuration; unconfigured is :none", ctx do
      require!(@agent_env, mode: 0, configured?: 0)
      require!(@state, root: 0)

      assert env(:mode, []) == :none
      refute env(:configured?, [])
      assert state(:root, []) == {:error, :agent_env_not_configured}

      for mode <- [:check, :bootstrap, :provisioning, :run] do
        Fx.configure!(ctx.root, mode: mode, nonce: Fx.nonce())
        assert env(:mode, []) == mode
        assert env(:configured?, [])
        assert state(:root, []) == {:ok, ctx.root}
      end
    end
  end

  describe "lifetime (T-U4)" do
    test "a top-level entry owns: it observes, registers before its body, invalidates on return",
         ctx do
      run_env!(ctx)
      require_snapshot!()
      me = self()

      {result, events} =
        Fx.trace_snapshots(fn ->
          snap(:enter, [:approve, fn -> {:inside, snap(:current, [])} end])
        end)

      assert {:inside, {:ok, snapshot}} = result
      assert snapshot.owner == me
      assert is_reference(snapshot.ref)
      assert %DateTime{} = snapshot.observed_at
      assert snap(:valid?, [snapshot])
      assert assert_owner(events, :approve) == snapshot.generation
      assert snap(:current, []) == {:error, :snapshot_not_in_use}
    end

    test "a nested entry inherits the same reference, observes nothing and never invalidates",
         ctx do
      run_env!(ctx)
      require_snapshot!()

      {result, events} =
        Fx.trace_snapshots(fn ->
          snap(:enter, [
            :sdr_proposal,
            fn ->
              outer = snap(:current, [])
              inner = snap(:enter, [:released_output, fn -> snap(:current, []) end])
              {outer, inner, snap(:current, [])}
            end
          ])
        end)

      assert {{:ok, outer}, {:ok, inner}, {:ok, after_inner}} = result
      assert inner == outer
      assert after_inner == outer, "a nested return must leave the parent's snapshot active"
      generation = assert_owner(events, :sdr_proposal)
      assert generation == outer.generation

      assert [%{metadata: %{entry: :released_output, generation: ^generation}}] =
               of_kind(events, :inherit)
    end

    test "with no snapshot inside an open transaction it refuses: the body runs, nothing registers",
         ctx do
      run_env!(ctx)
      require_snapshot!()

      for {label, transaction} <- [repo: &Repo.transaction/1, audit: &Audit.transaction/1] do
        {result, events} =
          Fx.trace_snapshots(fn ->
            transaction.(fn -> snap(:enter, [:approve, fn -> {:ran, snap(:current, [])} end]) end)
          end)

        assert result == {:ok, {:ran, {:error, :snapshot_not_in_use}}}, "#{label}"
        assert tags(events) == [{:refuse, :approve}], "#{label}: #{inspect(tags(events))}"
      end
    end

    test "an owner registered before its transaction stays active inside it; nested entries inherit",
         ctx do
      run_env!(ctx)
      require_snapshot!()

      {result, events} =
        Fx.trace_snapshots(fn ->
          snap(:enter, [
            :delivery_attempt,
            fn ->
              Repo.transaction(fn ->
                snap(:enter, [:capture_deliver, fn -> snap(:current, []) end])
              end)
            end
          ])
        end)

      assert {:ok, {:ok, snapshot}} = result
      assert assert_owner(events, :delivery_attempt) == snapshot.generation
      assert [inherit] = of_kind(events, :inherit)
      assert inherit.metadata[:entry] == :capture_deliver
      assert inherit.in_transaction? == true
    end

    test "a snapshot belongs to one process: a Task sees none and owns its own", ctx do
      run_env!(ctx)
      require_snapshot!()

      {result, events} =
        Fx.trace_snapshots(fn ->
          snap(:enter, [
            :sdr_proposal,
            fn ->
              task =
                Task.async(fn ->
                  {snap(:current, []),
                   snap(:enter, [:admit_launch, fn -> snap(:current, []) end])}
                end)

              {snap(:current, []), Task.await(task, 30_000)}
            end
          ])
        end)

      assert {{:ok, mine}, {{:error, :snapshot_not_in_use}, {:ok, theirs}}} = result
      assert theirs.owner != mine.owner
      assert theirs.ref != mine.ref
      assert theirs.generation != mine.generation
      assert length(of_kind(events, :observe_start)) == 2
      assert assert_owner(events, :sdr_proposal) == mine.generation
    end

    test "each top-level owner observes anew with a strictly greater generation", ctx do
      run_env!(ctx)
      require_snapshot!()

      samples =
        for entry <- [:approve, :edit_draft, :approve],
            do: snap(:enter, [entry, fn -> snap(:current, []) end])

      assert Enum.all?(samples, &match?({:ok, _}, &1)), inspect(samples)
      snapshots = Enum.map(samples, &elem(&1, 1))
      generations = Enum.map(snapshots, & &1.generation)
      assert generations == Enum.sort(generations)
      assert length(Enum.uniq(generations)) == 3
      assert length(Enum.uniq_by(snapshots, & &1.ref)) == 3
    end

    test "only the owner's own completion or raise invalidates; a nested raise leaves it active",
         ctx do
      run_env!(ctx)
      require_snapshot!()
      me = self()

      {result, events} =
        Fx.trace_snapshots(fn ->
          attempt(fn ->
            snap(:enter, [
              :approve,
              fn ->
                nested =
                  attempt(fn ->
                    snap(:enter, [:edit_draft, fn -> raise ArgumentError, "nested raise" end])
                  end)

                send(me, {:after_nested, nested, snap(:current, [])})
                raise RuntimeError, "owner raise"
              end
            ])
          end)
        end)

      assert {:raised, %RuntimeError{message: "owner raise"}} = result
      assert_received {:after_nested, {:raised, %ArgumentError{}}, {:ok, parent}}
      assert assert_owner(events, :approve) == parent.generation
      assert snap(:current, []) == {:error, :snapshot_not_in_use}
      assert snap(:verify, [parent]) == {:error, :snapshot_not_in_use}

      # The next top-level operation observes anew.
      assert {:ok, next} = snap(:enter, [:approve, fn -> snap(:current, []) end])
      assert next.generation > parent.generation
    end

    test "inert when unconfigured: the body runs, current/0 is :inert, nothing is emitted",
         _ctx do
      require_snapshot!()

      {result, events} =
        Fx.trace_snapshots(fn ->
          snap(:enter, [:approve, fn -> {:ran, snap(:current, [])} end])
        end)

      assert result == {:ran, :inert}
      assert events == []
      assert snap(:current, []) == :inert
    end

    test "entries/0 is the closed set of 23 atoms; :delivery_receipt_capture is not one (S1-b)",
         ctx do
      run_env!(ctx)
      require_snapshot!()
      me = self()

      assert Enum.sort(snap(:entries, [])) == Enum.sort(@entries)

      assert_raise ArgumentError, fn ->
        snap(:enter, [:delivery_receipt_capture, fn -> send(me, :body_ran) end])
      end

      refute_received :body_ran
    end

    for mode <- [:check, :bootstrap, :provisioning] do
      @mode mode

      test "#{mode} mode: an entry raises ModeRefused before its body runs", ctx do
        Fx.configure!(ctx.root, mode: @mode, nonce: Fx.nonce())
        require!(@mode_refused, exception: 1)
        require_snapshot!()
        me = self()

        {result, events} =
          Fx.trace_snapshots(fn ->
            attempt(fn -> snap(:enter, [:approve, fn -> send(me, :body_ran) end]) end)
          end)

        assert match?({:raised, %{__struct__: @mode_refused}}, result),
               "C2* L6: an entry in #{@mode} mode must raise ModeRefused: #{inspect(result)}"

        refute_received :body_ran
        assert of_kind(events, :observe_start) == []
      end
    end
  end

  describe "verify/1 (R3)" do
    test "only this process's active registration verifies; a caller-built one never does", ctx do
      run_env!(ctx)
      require_snapshot!()

      result =
        snap(:enter, [
          :approve,
          fn ->
            {:ok, snapshot} = snap(:current, [])

            forged = [
              other_ref: %{snapshot | ref: make_ref()},
              other_generation: %{snapshot | generation: snapshot.generation + 1},
              other_lease: %{snapshot | lease: :absent},
              plain_map: Map.from_struct(snapshot),
              not_a_snapshot: :snapshot
            ]

            %{
              snapshot: snapshot,
              active: snap(:verify, [snapshot]),
              nested: snap(:enter, [:edit_draft, fn -> snap(:verify, [snapshot]) end]),
              task: Task.await(Task.async(fn -> snap(:verify, [snapshot]) end), 30_000),
              forged: Enum.map(forged, fn {label, term} -> {label, snap(:verify, [term])} end)
            }
          end
        ])

      snapshot = result.snapshot
      assert result.active == {:ok, snapshot}
      assert result.nested == {:ok, snapshot}
      assert result.task == {:error, :snapshot_not_in_use}

      for {label, verdict} <- result.forged do
        assert verdict == {:error, :snapshot_not_in_use}, "a #{label} snapshot verified"
      end

      assert snap(:verify, [snapshot]) == {:error, :snapshot_not_in_use},
             "a completed owner's snapshot verified"
    end
  end

  describe "observation (sections 4.2, 4.3)" do
    test "a bound run environment: valid; its lease and environment views; no authorization",
         ctx do
      bound = run_env!(ctx)
      require_snapshot!()
      snapshot = sample!()

      assert snap(:valid?, [snapshot])
      assert snap(:check_lease, [snapshot]) == :ok
      lease_sha256 = sha256_file(Fx.path(ctx.root, :lease))
      assert {:valid, ^lease_sha256, _lease} = snapshot.lease
      binding = bound.binding_sha256
      assert {:valid, ^binding, _environment} = snapshot.environment
      assert snapshot.authorization == :absent

      assert snap(:environment, [snapshot]) ==
               {:ok,
                %{
                  binding_sha256: binding,
                  database: bound.database,
                  database_oid: bound.database_oid,
                  tenant_id: bound.tenant_id,
                  nonce: bound.bootstrap_nonce,
                  created_at: bound.environment["created_at"]
                }}

      assert snap(:authorization, [snapshot]) == {:error, :authorization_absent}
    end

    test "authorization.json: its file digest and the registry-entry digest it records stay distinct",
         ctx do
      run_env!(ctx)
      authorized = Fx.authorized!(ctx.root)
      require_snapshot!()
      snapshot = sample!()
      data = authorized.data
      file_sha256 = authorized.sha256

      assert {:valid, ^file_sha256, _authorization} = snapshot.authorization
      refute file_sha256 == data["authorization_sha256"]

      assert snap(:authorization, [snapshot]) ==
               {:ok,
                %{
                  sha256: file_sha256,
                  authorization_sha256: data["authorization_sha256"],
                  authorization_id: data["authorization_id"],
                  binding_sha256: data["binding_sha256"],
                  grant_id: data["grant_id"],
                  revision: 1,
                  event_id: data["event_id"],
                  nonce: data["nonce"]
                }}
    end

    test "an authorization bound to another environment is invalid (not part of valid?/1)", ctx do
      run_env!(ctx)
      Fx.authorized!(ctx.root, %{"binding_sha256" => Fx.hex(32)})
      require_snapshot!()
      snapshot = sample!()

      assert snap(:authorization, [snapshot]) == {:error, :authorization_invalid}
      assert snap(:valid?, [snapshot])
    end

    test "a lease whose nonce, mode or target differs from the boot config is not valid", ctx do
      bound = Fx.bound!(ctx.root, lease: :run)
      require_snapshot!()

      cases = [
        other_nonce: fn -> Fx.configure!(ctx.root, mode: :run, nonce: Fx.nonce()) end,
        provisioning_lease: fn ->
          nonce = Fx.write_lease!(ctx.root, :provisioning, bound.binding_sha256)
          Fx.configure!(ctx.root, mode: :run, nonce: nonce)
        end,
        other_target: fn ->
          nonce = Fx.write_lease!(ctx.root, :run, Fx.hex(32))
          Fx.configure!(ctx.root, mode: :run, nonce: nonce)
        end,
        no_lease: fn ->
          File.rm!(Fx.path(ctx.root, :lease))
          Fx.configure!(ctx.root, mode: :run, nonce: bound.nonce)
        end
      ]

      for {label, arrange} <- cases do
        arrange.()
        snapshot = sample!()
        refute snap(:valid?, [snapshot]), "#{label}: valid"

        assert snap(:check_lease, [snapshot]) == {:error, :agent_env_lease_mismatch},
               "#{label}: the lease check passed"
      end
    end

    test "an environment of another configured database is unattested", ctx do
      bound = Fx.bound!(ctx.root, lease: :run)
      Fx.configure!(ctx.root, mode: :run, nonce: bound.nonce, database: "c2star_s1_other")
      require_snapshot!()
      snapshot = sample!()

      refute snap(:valid?, [snapshot])
      assert snap(:environment, [snapshot]) == {:error, :environment_unattested}
    end

    test "observation never raises: an unreadable environment file is an invalid view", ctx do
      run_env!(ctx)
      Fx.write_state!(ctx.root, :environment, "not canonical json\n")
      require_snapshot!()
      snapshot = sample!()

      assert {:invalid, reason} = snapshot.environment
      assert is_atom(reason)
      refute snap(:valid?, [snapshot])
      assert snap(:environment, [snapshot]) == {:error, :environment_unattested}
    end

    test "State.read/2: canonical closed-key bytes are valid; anything else is invalid or absent",
         ctx do
      bound = run_env!(ctx)
      require!(@state, read: 2)
      binding = bound.binding_sha256
      environment = bound.environment

      assert {:valid, ^binding, _data} = state(:read, [ctx.root, :environment])
      assert state(:read, [ctx.root, :authorization]) == :absent

      canonical = Canonical.encode!(environment)
      pretty = Jason.encode!(environment, pretty: true)

      invalid = [
        trailing_newline: canonical <> "\n",
        not_canonical: pretty,
        unknown_key: Canonical.encode!(Map.put(environment, "extra", 1)),
        missing_key: Canonical.encode!(Map.delete(environment, "tenant_id"))
      ]

      for {label, bytes} <- invalid do
        Fx.write_state!(ctx.root, :environment, bytes)
        assert {:invalid, reason} = state(:read, [ctx.root, :environment]), "#{label}"
        assert is_atom(reason)
      end
    end
  end

  describe "entry wiring (T-U4; section 5.2 rows 1-6, 8-20)" do
    setup ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)
      %{run: run}
    end

    test "the table covers entries/0 exactly, with the two worker owners", _ctx do
      require_snapshot!()
      wired = @wiring |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert Enum.sort(wired ++ @worker_owners) == Enum.sort(snap(:entries, []))
    end

    test "control: with the selector unset no entry emits a snapshot event", ctx do
      for {_entry, label} <- @wiring do
        {_result, events} = Fx.trace_snapshots(fn -> attempt(wiring_call(label, ctx)) end)
        assert events == [], "#{label} emitted #{inspect(tags(events))} while inert"

        {_result, events} = Fx.trace_snapshots(fn -> in_transaction(wiring_call(label, ctx)) end)
        assert events == [], "#{label} emitted #{inspect(tags(events))} while inert"
      end
    end

    for {entry, label} <- @wiring do
      @entry entry
      @label label

      test "#{label}: called at the top level it applies the rule as #{inspect(entry)}", ctx do
        run_env!(ctx)
        {_result, events} = Fx.trace_snapshots(fn -> attempt(wiring_call(@label, ctx)) end)
        assert_top_level(events, @entry)
      end

      test "#{label}: inside an open transaction with no snapshot it refuses", ctx do
        run_env!(ctx)
        {_result, events} = Fx.trace_snapshots(fn -> in_transaction(wiring_call(@label, ctx)) end)
        assert_refused(events, @entry)
      end

      unless label in @raise_exempt do
        test "#{label}: in bootstrap mode it raises ModeRefused before its body", ctx do
          Fx.configure!(ctx.root, mode: :bootstrap, nonce: Fx.nonce(), step: :seed)
          {result, events} = Fx.trace_snapshots(fn -> attempt(wiring_call(@label, ctx)) end)

          assert match?({:raised, %{__struct__: @mode_refused}}, result),
                 "C2* L6: #{@label} in bootstrap mode must raise ModeRefused at its first " <>
                   "line; got #{inspect(result, limit: 6)}"

          assert of_kind(events, :observe_start) == []
        end
      end
    end
  end

  describe "identity under the head (T-U4, R4)" do
    test "live_database_identity/0 is a plain read under the chain head: no lock, no observe, no file",
         ctx do
      run_env!(ctx)
      require!(@agent_env, live_database_identity: 0)
      {name, oid} = Fx.live_identity!()
      expected = {:ok, %{database: name, database_oid: oid}}
      assert env(:live_database_identity, []) == expected

      {:ok, observed} =
        Audit.transaction(fn ->
          {:ok, _head} = Kernel.lock_head(ctx.tenant.id)

          {identity, events} =
            Fx.trace_snapshots(fn -> env(:live_database_identity, []) end,
              queries: fn _metadata -> true end
            )

          {again, files} = Fx.trace_file_calls(fn -> env(:live_database_identity, []) end)
          %{identity: identity, again: again, events: events, files: files}
        end)

      assert observed.identity == expected
      assert observed.again == expected
      queries = of_kind(observed.events, :query)
      assert queries != [], "the identity read no database row"
      assert Enum.all?(queries, & &1.in_transaction?)
      refute Enum.any?(queries, &lock_query?(&1.query)), "the identity read takes a row lock"
      assert Enum.reject(observed.events, &(&1.kind == :query)) == []
      assert observed.files == [], "the identity read did file I/O: #{inspect(observed.files)}"
    end

    test "check_live_binding/2 refuses a name and an oid mismatch apart; check_tenant/2 a tenant",
         ctx do
      bound = run_env!(ctx)
      require!(@agent_env, check_live_binding: 2, check_tenant: 2)

      environment = %{
        binding_sha256: bound.binding_sha256,
        database: bound.database,
        database_oid: bound.database_oid,
        tenant_id: bound.tenant_id,
        nonce: bound.bootstrap_nonce,
        created_at: bound.environment["created_at"]
      }

      identity = %{database: bound.database, database_oid: bound.database_oid}

      assert env(:check_live_binding, [environment, identity]) == :ok

      assert env(:check_live_binding, [environment, %{identity | database: "c2star_s1_other"}]) ==
               {:error, :database_name_mismatch}

      assert env(:check_live_binding, [
               environment,
               %{identity | database_oid: bound.database_oid + 1}
             ]) ==
               {:error, :database_oid_mismatch}

      assert env(:check_tenant, [environment, bound.tenant_id]) == :ok
      assert env(:check_tenant, [environment, uuid()]) == {:error, :tenant_mismatch}
    end
  end

  describe "identity independence (T-B1, S1 half)" do
    test "the same state bytes under other build, deps and cwd inputs give the same identity",
         ctx do
      bound = run_env!(ctx)
      elsewhere = Fx.root!("independence")
      require!(@state, root: 0, read: 2)
      require!(@agent_env, database: 0)
      require_snapshot!()

      first = identity_view(ctx.root)

      second =
        with_system_env(
          %{
            "MIX_BUILD_ROOT" => Path.join(elsewhere, "_build"),
            "MIX_DEPS_PATH" => Path.join(elsewhere, "deps")
          },
          fn -> File.cd!(elsewhere, fn -> identity_view(ctx.root) end) end
        )

      assert second == first
      binding = bound.binding_sha256
      root = ctx.root

      assert {{:ok, ^root}, "sdr_agent_agentenv", {:valid, ^binding, _data},
              {:ok, %{binding_sha256: ^binding}}} = first

      assert binding == sha256_file(Fx.path(ctx.root, :environment))
    end
  end

  defp identity_view(root) do
    environment =
      snap(:enter, [
        :sdr_proposal,
        fn ->
          case snap(:current, []) do
            {:ok, snapshot} -> snap(:environment, [snapshot])
            other -> other
          end
        end
      ])

    {state(:root, []), env(:database, []), state(:read, [root, :environment]), environment}
  end

  defp with_system_env(vars, fun) do
    previous = Map.new(vars, fn {key, _value} -> {key, System.get_env(key)} end)
    System.put_env(vars)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
