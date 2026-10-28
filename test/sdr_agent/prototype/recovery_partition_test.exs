defmodule SdrAgent.Prototype.RecoveryPartitionTest do
  @moduledoc """
  TF-1 RED r3 (plan r3, `claude-d237-s2-tf1-recovery-plan-r3-20261028.md`;
  Codex eff38bd0, cc688175, 5ec3911b), D-237 slice S2: in prototype runtime a
  failed finalize is never followed by an ordinary Recovery decision, and the
  ordinary runtime of the same build keeps today's paths.

  - **(a) A technical failure decides nothing.** The facade
    (`ResultGate.gate/3`) and the sweeper (`StaleRunSweeper.sweep/1`) return
    the ORIGINAL `{:error, e}` from finalize unchanged and write nothing: no
    release, cause, event, run stop or Operation transition; the run stays
    `:running` and the charge is kept. A raise or a throw propagates
    unchanged. The facade returns `recheck_failed`; the sweeper skips it to
    the next pass (prototype runtime only). A technical error halts the pass.
    The sweeper examines runs in `Agents.list_runs/1` order (newest first),
    so the order tests bind their runs to that real listing and record the
    visited invocations.
  - **(b) With no release, the sweeper finalizes through the prototype
    gate** (reconcile first, then `{:interrupted, receipt}`), also when
    evidence persisted. The gate's own selection applies (b1, unchanged):
    - A mismatch link binds the usable live critical. With none usable, the
      result is `mismatch_cause_unbound`, a skip.
    - Otherwise the decision is `gate_interrupted`, bound to the receipt's
      usable warning (the absent store has none), else the deduplicated gate
      cause, else a new one opened under the head.
    - A persisted warning or critical that is not that cause stays live and
      unbound.
    - A running run stops and its Operation fails by the worker's rule, once
      each. A terminal run gets the release only.
  - **Direct `Recovery.run/3` with no release** returns the finite internal
    `{:error, :no_prototype_decision}` and writes nothing.
  - **(c) An existing release is authoritative.**
    - A stopped run's withheld is returned as it is, and an already-terminal
      replay appends no event.
    - A `released_unverified` is returned only through the verified fetch
      (a b2c prerequisite).
    - A winner committed between the routing read and the locked finalize
      stands. The sweeper's own finalize is refused by its run guard, and
      the Operation fails once, by the existing heal step.
  - **The ordinary runtime of this build** (the `D` controls): the facade,
    direct Recovery and the sweeper keep the ordinary G5/G7 paths. A
    `recheck_failed` that reaches the pass there is the pass's error.

  Technical errors are injected through `Prototype.Release`'s test-seam-only
  `finalize_result` hook, which accepts only `{:error, _}` or `:passthrough`
  and records every consultation in order. The sweeper's routing-read and
  reconcile hooks (plan r3 SW-6) are not signed yet, so their cases stop at
  the seam prerequisite.

  Sweeper runs are built through real APIs only
  (`PrototypeGateFixtures.assigned!/1`, `abandon!/1`), and a mismatch link
  through `Agents.link_wire_witness/2` as REC. The injected Unknown has a
  binary `UnknownError` leaf, with no Postgrex struct. Messages are
  value-free: tags, modules, atoms, counts and positions only.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias Ash.Error.Unknown
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Prototype.Release
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.SDR.StaleRunSweeper

  @run_fields [:status, :status_reason, :attention_failure_id, :updated_at]
  @operation_fields [:status, :last_failure_id, :attempts, :updated_at]
  @release_body [
    :id,
    :model_invocation_id,
    :disposition,
    :reason,
    :wire_witness_link_id,
    :projection_version,
    :method,
    :evidence_sha256,
    :decided_at
  ]

  setup do
    previous =
      {Application.get_env(:sdr_agent, Release), Application.get_env(:sdr_agent, StaleRunSweeper)}

    on_exit(fn ->
      {release, sweeper} = previous
      restore(Release, release)
      restore(StaleRunSweeper, sweeper)
    end)

    %{fx: G.prototype!()}
  end

  defp restore(key, nil), do: Application.delete_env(:sdr_agent, key)
  defp restore(key, value), do: Application.put_env(:sdr_agent, key, value)

  ## Seams and hooks (merged into the module's Application env)

  defp put!(module, key, fun) do
    env = Application.get_env(:sdr_agent, module, [])
    Application.put_env(:sdr_agent, module, Keyword.put(env, key, fun))
  end

  defp unknown,
    do: Unknown.exception(errors: [UnknownError.exception(error: "d237-s2 tf1 synthetic")])

  defp technical(:unknown), do: unknown()
  defp technical(:forbidden), do: Ash.Error.Forbidden.exception([])
  defp technical(:other), do: :d237_tf1_synthetic_technical

  # The finalize seam: every consultation is recorded in order (the visited
  # invocations), then `choose` gives `{:error, _}` or `:passthrough`.
  defp seam!(choose) do
    put!(Release, :finalize_result, fn invocation ->
      Process.put(:tf1_visits, visits() ++ [invocation.id])
      choose.(invocation.id)
    end)
  end

  # `target` gets `result`; every other invocation runs the real attempts.
  defp inject!(target, result),
    do: seam!(fn id -> if id == target, do: result, else: :passthrough end)

  # Records the visits only; every invocation runs the real attempts.
  defp record!, do: seam!(fn _id -> :passthrough end)

  # As `inject!/2`, but the seam first returns this process to ordinary
  # runtime (S1's test seam): what follows the prototype finalize runs in
  # the ordinary runtime of this build.
  defp leave_then!(target, result) do
    seam!(fn id ->
      if id == target do
        :ok = PrototypeFixtures.leave_runtime()
        result
      else
        :passthrough
      end
    end)
  end

  defp visits, do: Process.get(:tf1_visits, [])

  defp injected!(target),
    do: assert(target in visits(), "prerequisite: the finalize seam was not consulted")

  defp positions(ids, labels), do: Enum.map(ids, &Map.get(labels, &1, :other))

  # The prototype gate's own attempts, counted by the existing hook.
  defp count_attempts!,
    do:
      put!(Release, :before_head, fn _invocation -> Process.put(:tf1_attempts, attempts() + 1) end)

  defp attempts, do: Process.get(:tf1_attempts, 0)

  # A plan r3 SW-6 sweeper hook; its consultation is recorded first.
  defp hook!(key, fun) do
    put!(StaleRunSweeper, key, fn invocation ->
      Process.put(:tf1_sw6, [key | Process.get(:tf1_sw6, [])])
      fun.(invocation)
    end)
  end

  defp consulted?(key), do: key in Process.get(:tf1_sw6, [])

  defp sw6!(key),
    do: assert(consulted?(key), "prerequisite: the SW-6 #{key} seam was not consulted")

  defp ordinary!,
    do: assert(SdrAgent.Prototype.runtime() == :ordinary, "prerequisite: ordinary runtime")

  defp sweep(fx), do: StaleRunSweeper.sweep(fx.tenant.id)

  # How a call ended, for exact identity checks.
  defp outcome(fun) do
    {:returned, fun.()}
  rescue
    exception -> {:raised, exception}
  catch
    :throw, value -> {:thrown, value}
  end

  defp shape({:returned, value}), do: {:returned, G.summary(value)}
  defp shape({:raised, %{__struct__: module}}), do: {:raised, module}
  defp shape({:thrown, _value}), do: :thrown

  ## State reads (kernel reads of the tenant's rows)

  defp kernel(tenant_id), do: SdrAgent.Audit.Kernel.opts(tenant_id)

  defp run(id), do: Ash.get!(AgentRun, id, authorize?: false)

  defp operation(s), do: Ash.get!(Operation, s.run.operation_id, kernel(s.invocation.tenant_id))

  defp failure(invocation, id), do: Ash.get!(Failure, id, kernel(invocation.tenant_id))

  defp failures(invocation) do
    Failure
    |> Ash.Query.filter(subject_id == ^invocation.id and class == :reconciliation_required)
    |> Ash.read!(kernel(invocation.tenant_id))
  end

  defp failure_ids(invocation), do: invocation |> failures() |> Enum.map(& &1.id) |> Enum.sort()

  defp result_events(fx),
    do: Enum.filter(events(fx.tenant), &String.starts_with?(&1.event_type, "model.result."))

  defp event_ids(fx), do: fx.tenant |> events() |> Enum.map(& &1.id)

  defp typed(fx, type, subject_id),
    do: fx.tenant |> events_of_type(type) |> Enum.count(&(&1.subject_id == subject_id))

  # The cause a release's one withheld event binds.
  defp bound_cause_id(fx, release) do
    withheld = G.release_events(fx, "model.result.withheld", release)
    assert length(withheld) == 1, "withheld events: #{length(withheld)}"
    [event] = withheld
    event.payload["arguments"]["gate_cause_id"]
  end

  # A subject `s` (`%{run:, invocation:}`): the run, its Operation, the
  # invocation's release and reconciliation Failures, and every event whose
  # subject is the run, its Operation or the invocation.
  defp state(fx, s) do
    ids = [s.run.id, s.run.operation_id, s.invocation.id]

    %{
      run: Map.take(run(s.run.id), @run_fields),
      operation: Map.take(operation(s), @operation_fields),
      release: G.release(s.invocation),
      failures: failure_ids(s.invocation),
      events: fx.tenant |> events() |> Enum.filter(&(&1.subject_id in ids)) |> Enum.map(& &1.id)
    }
  end

  # Nothing was decided or written for `s`: no release, cause, event, run
  # stop or Operation transition; the run still running.
  defp unchanged!(fx, s, before) do
    now = state(fx, s)
    assert now.release == nil, "a release was decided"
    assert now.failures == before.failures, "a cause was opened or changed"
    assert now.run == before.run, "the run changed: #{inspect(now.run.status)}"

    assert now.operation == before.operation,
           "the Operation changed: #{inspect(now.operation.status)}"

    assert now.events == before.events, "an event of the run, its Operation or the invocation"
    assert now.run.status == :running, "run: #{inspect(now.run.status)}"
  end

  # No event at all was appended to the tenant's chain since `before`.
  defp quiet!(fx, before) do
    appended =
      fx.tenant |> events() |> Enum.reject(&(&1.id in before)) |> Enum.map(& &1.event_type)

    assert appended == [], "events appended: #{inspect(appended)}"
  end

  defp nothing!(fx, s, {before, event_ids}) do
    unchanged!(fx, s, before)
    quiet!(fx, event_ids)
  end

  # The gate stop of a running run on `cause_id` and its Operation's failure
  # by the worker's rule, once each. One attempt, so the failure discards it.
  defp stopped!(fx, a, cause_id, reason) do
    assert {a.operation.attempts, a.operation.max_attempts} == {1, 1}, "prerequisite: one attempt"
    run = run(a.run.id)
    assert {run.status, run.status_reason} == {:failed, reason}, "run: #{inspect(run.status)}"
    assert run.attention_failure_id == cause_id, "the run's attention is not the bound cause"
    op = operation(a)
    assert op.status == :discarded, "Operation: #{inspect(op.status)}"
    assert op.last_failure_id == cause_id, "the Operation does not link the bound cause"
    assert typed(fx, "agents.run.failed", a.run.id) == 1, "run stop events"
    assert typed(fx, "operations.operation.failed", a.operation.id) == 1, "Operation failures"
    assert typed(fx, "operations.operation.discarded", a.operation.id) == 1, "Operation discards"
  end

  # The deduplicated gate cause a gate_interrupted decision binds when the
  # receipt has none: a live warning of the invocation and its run's
  # Operation, NOT the persisted cause `persisted_id`.
  defp dedup_cause!(fx, a, release, persisted_id) do
    id = bound_cause_id(fx, release)
    assert id != persisted_id, "bound to the persisted cause, not the deduplicated gate cause"
    cause = failure(a.invocation, id)

    assert {cause.class, cause.severity, cause.status} ==
             {:reconciliation_required, :warning, :open}

    assert cause.subject_id == a.invocation.id, "the gate cause's subject"
    assert cause.operation_id == a.run.operation_id, "the gate cause's Operation"
    id
  end

  defp interrupted!(release) do
    assert release != nil, "no release"
    assert {release.disposition, release.reason} == {:withheld, :gate_interrupted}
  end

  # The sweeper's own order: `Agents.list_runs/1` sorts newest first
  # (inserted_at desc, id desc). Bound from the real listing, never assumed.
  defp listed(fx, x, y) do
    {:ok, runs} = Agents.list_runs(actor: fx.agent)
    ids = runs |> Enum.map(& &1.id) |> Enum.filter(&(&1 in [x.run.id, y.run.id]))
    assert length(ids) == 2, "prerequisite: both runs are listed"
    if ids == [x.run.id, y.run.id], do: {x, y}, else: {y, x}
  end

  ## (a) The facade

  describe "the facade (ResultGate.gate/3)" do
    setup %{fx: fx} do
      run = G.run!(fx)
      %{run: run, invocation: G.completed!(fx, run)}
    end

    for kind <- [:unknown, :forbidden, :other] do
      test "F: a #{kind} technical error from finalize is returned unchanged; nothing is written",
           ctx do
        error = technical(unquote(kind))
        inject!(ctx.invocation.id, {:error, error})
        before = {state(ctx.fx, ctx), event_ids(ctx.fx)}
        result = ResultGate.gate(ctx.invocation, G.gate(ctx.run))
        injected!(ctx.invocation.id)

        assert result == {:error, error}, "gate: #{inspect(G.summary(result))}"
        nothing!(ctx.fx, ctx, before)
        assert G.charged(ctx.fx) == 1
      end
    end

    test "F5: a raise in the attempt propagates unchanged; nothing is written (control)", ctx do
      put!(Release, :before_head, fn _invocation ->
        raise RuntimeError, "d237-s2 tf1 synthetic raise"
      end)

      before = {state(ctx.fx, ctx), event_ids(ctx.fx)}

      assert_raise RuntimeError, "d237-s2 tf1 synthetic raise", fn ->
        ResultGate.gate(ctx.invocation, G.gate(ctx.run))
      end

      nothing!(ctx.fx, ctx, before)
    end

    test "F6: a throw in the attempt propagates unchanged; nothing is written (control)", ctx do
      put!(Release, :before_head, fn _invocation -> throw(:d237_s2_tf1_synthetic_throw) end)
      before = {state(ctx.fx, ctx), event_ids(ctx.fx)}

      assert catch_throw(ResultGate.gate(ctx.invocation, G.gate(ctx.run))) ==
               :d237_s2_tf1_synthetic_throw

      nothing!(ctx.fx, ctx, before)
    end

    test "F7: the seam refuses a non-error value with a fixed message (seam control)", ctx do
      put!(Release, :finalize_result, fn _invocation -> {:ok, :released} end)
      before = {state(ctx.fx, ctx), event_ids(ctx.fx)}

      assert_raise ArgumentError, "finalize_result injects {:error, _} only", fn ->
        ResultGate.gate(ctx.invocation, G.gate(ctx.run))
      end

      nothing!(ctx.fx, ctx, before)
    end

    test "D1: in ordinary runtime the facade keeps its one G7 Recovery attempt (control)", ctx do
      leave_then!(ctx.invocation.id, {:error, unknown()})
      count_attempts!()
      result = ResultGate.gate(ctx.invocation, G.gate(ctx.run))
      injected!(ctx.invocation.id)
      ordinary!()

      assert match?(
               {:withheld, %{disposition: :withheld, reason: :gate_interrupted},
                %{status: :failed, status_reason: :witness_unreconciled}},
               result
             ),
             "gate: #{inspect(G.summary(result))}"

      assert attempts() == 0, "prototype gate attempts: #{attempts()}"
      {:withheld, release, stopped} = result
      assert bound_cause_id(ctx.fx, release) == stopped.attention_failure_id
    end
  end

  ## Direct Recovery

  describe "direct Recovery.run/3" do
    setup %{fx: fx} do
      run = G.run!(fx)
      %{run: run, invocation: G.completed!(fx, run)}
    end

    test "R1: with no release it decides nothing: {:error, :no_prototype_decision}", ctx do
      before = {state(ctx.fx, ctx), event_ids(ctx.fx)}
      result = Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert result == {:error, :no_prototype_decision}, "recovery: #{inspect(G.summary(result))}"
      nothing!(ctx.fx, ctx, before)
    end

    test "R2: a STOPPED run's existing withheld is returned as it is; the replay appends nothing (control)",
         ctx do
      G.drift!()
      decided = G.finalize(ctx.invocation, ctx.run)

      assert match?({:withheld, _, %{status: :failed}}, decided),
             "prerequisite: a withheld stop: #{inspect(G.summary(decided))}"

      {:withheld, release, _stopped} = decided
      assert PrototypeFixtures.put_live_identity(%{}) == :ok
      before = state(ctx.fx, ctx)
      ids = event_ids(ctx.fx)

      result = Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert match?({:withheld, %{id: id}, _} when id == release.id, result),
             "recovery: #{inspect(G.summary(result))}"

      assert Map.take(G.release(ctx.invocation), @release_body) ==
               Map.take(release, @release_body)

      quiet!(ctx.fx, ids)
      now = state(ctx.fx, ctx)

      assert {now.run, now.operation, now.failures} ==
               {before.run, before.operation, before.failures}
    end

    test "R3: an existing released_unverified is returned through the verified fetch only",
         ctx do
      decided = G.finalize(ctx.invocation, ctx.run)

      assert match?({:released, %{disposition: :released_unverified}, _}, decided),
             "prerequisite: the release: #{inspect(G.summary(decided))}"

      {:released, release, output} = decided
      result = Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert match?({:released, %{id: id}, ^output} when id == release.id, result),
             "recovery: #{inspect(G.summary(result))}"
    end

    test "D2: in ordinary runtime direct Recovery keeps the G5 selection (control)", ctx do
      assert PrototypeFixtures.leave_runtime() == :ok
      ordinary!()
      result = Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert match?(
               {:withheld, %{reason: :gate_interrupted},
                %{status: :failed, status_reason: :witness_unreconciled}},
               result
             ),
             "recovery: #{inspect(G.summary(result))}"
    end
  end

  ## The sweeper

  describe "the sweeper (StaleRunSweeper.sweep/1)" do
    setup %{fx: fx} do
      %{assigned: G.assigned!(fx)}
    end

    for kind <- [:unknown, :forbidden, :other] do
      test "S: a #{kind} technical error from finalize is the pass's original error; nothing is written",
           ctx do
        a = ctx.assigned
        error = technical(unquote(kind))
        G.abandon!(a)
        inject!(a.invocation.id, {:error, error})
        before = {state(ctx.fx, a), event_ids(ctx.fx)}
        result = sweep(ctx.fx)
        injected!(a.invocation.id)

        assert result == {:error, error}, "sweep: #{inspect(G.summary(result))}"
        nothing!(ctx.fx, a, before)
        assert G.charged(ctx.fx) == 1
      end
    end

    test "SR: a raise in the sweeper's prototype finalize propagates unchanged; nothing is written (control)",
         ctx do
      a = ctx.assigned
      fault = RuntimeError.exception("d237-s2 tf1 synthetic sweeper raise")
      G.abandon!(a)
      put!(Release, :before_head, fn _invocation -> raise fault end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)

      assert result == {:raised, fault}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "ST: a throw in the sweeper's prototype finalize propagates unchanged; nothing is written (control)",
         ctx do
      a = ctx.assigned
      G.abandon!(a)
      put!(Release, :before_head, fn _invocation -> throw(:d237_s2_tf1_sweeper_throw) end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)

      assert result == {:thrown, :d237_s2_tf1_sweeper_throw}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "S4: a persisted live warning, no release: the prototype gate decides on the deduplicated gate cause",
         ctx do
      a = ctx.assigned

      warning =
        GateFixtures.cause!(a.invocation, severity: :warning, operation_id: a.run.operation_id)

      G.abandon!(a)
      record!()
      count_attempts!()
      result = sweep(ctx.fx)
      labels = %{a.invocation.id => :a}

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert visits() == [a.invocation.id], "visited: #{inspect(positions(visits(), labels))}"
      assert attempts() == 1, "prototype gate attempts: #{attempts()}"
      release = G.release(a.invocation)
      interrupted!(release)
      cause_id = dedup_cause!(ctx.fx, a, release, warning.id)
      assert failure(a.invocation, warning.id).status == :open, "the persisted warning changed"
      assert failure_ids(a.invocation) == Enum.sort([warning.id, cause_id])
      assert length(result_events(ctx.fx)) == 1
      stopped!(ctx.fx, a, cause_id, :witness_unreconciled)
    end

    test "S5: a persisted live critical, no mismatch link: gate_interrupted on the deduplicated gate cause",
         ctx do
      a = ctx.assigned

      critical =
        GateFixtures.cause!(a.invocation, severity: :critical, operation_id: a.run.operation_id)

      G.abandon!(a)
      record!()
      count_attempts!()
      result = sweep(ctx.fx)
      labels = %{a.invocation.id => :a}

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert visits() == [a.invocation.id], "visited: #{inspect(positions(visits(), labels))}"
      assert attempts() == 1, "prototype gate attempts: #{attempts()}"
      release = G.release(a.invocation)
      interrupted!(release)
      cause_id = dedup_cause!(ctx.fx, a, release, critical.id)
      assert failure(a.invocation, critical.id).status == :open, "the persisted critical changed"
      assert failure_ids(a.invocation) == Enum.sort([critical.id, cause_id])
      assert length(result_events(ctx.fx)) == 1
      stopped!(ctx.fx, a, cause_id, :witness_unreconciled)
    end

    test "S5m: a persisted mismatch link: witness_mismatch on the usable live critical", ctx do
      a = ctx.assigned
      rec = system_actor(:reconciler, ctx.fx.tenant)
      AgentsFixtures.reconciled_link!(a.invocation, rec, link_status: :mismatch)

      critical =
        GateFixtures.cause!(a.invocation, severity: :critical, operation_id: a.run.operation_id)

      G.abandon!(a)
      record!()
      count_attempts!()
      result = sweep(ctx.fx)
      labels = %{a.invocation.id => :a}

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert visits() == [a.invocation.id], "visited: #{inspect(positions(visits(), labels))}"
      assert attempts() == 1, "prototype gate attempts: #{attempts()}"
      release = G.release(a.invocation)
      assert release != nil, "no release"
      assert {release.disposition, release.reason} == {:withheld, :witness_mismatch}
      assert bound_cause_id(ctx.fx, release) == critical.id, "not bound to the usable critical"
      assert failure_ids(a.invocation) == [critical.id]
      stopped!(ctx.fx, a, critical.id, :witness_mismatch)
    end

    test "S5u: a persisted mismatch link without a usable critical stays attention: a skip; nothing is written",
         ctx do
      a = ctx.assigned
      rec = system_actor(:reconciler, ctx.fx.tenant)
      AgentsFixtures.reconciled_link!(a.invocation, rec, link_status: :mismatch)
      # No Operation: not gate-capable for a run that has one (row R7-2).
      _unusable = GateFixtures.cause!(a.invocation, severity: :critical)
      G.abandon!(a)
      record!()
      count_attempts!()
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = sweep(ctx.fx)
      labels = %{a.invocation.id => :a}

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert visits() == [a.invocation.id], "visited: #{inspect(positions(visits(), labels))}"
      assert attempts() == 0, "refused before the head: #{attempts()} attempts"
      nothing!(ctx.fx, a, before)
    end

    test "S6: a terminal run with a persisted warning gets the release only, from the prototype gate",
         ctx do
      a = ctx.assigned

      warning =
        GateFixtures.cause!(a.invocation, severity: :warning, operation_id: a.run.operation_id)

      {:ok, _cancelled} = Agents.cancel_run(a.run, actor: ctx.fx.agent)
      G.abandon!(a)
      record!()
      count_attempts!()
      before = state(ctx.fx, a)
      result = sweep(ctx.fx)
      labels = %{a.invocation.id => :a}

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert visits() == [a.invocation.id], "visited: #{inspect(positions(visits(), labels))}"
      assert attempts() == 1, "prototype gate attempts: #{attempts()}"
      release = G.release(a.invocation)
      interrupted!(release)
      cause_id = dedup_cause!(ctx.fx, a, release, warning.id)
      assert failure(a.invocation, warning.id).status == :open, "the persisted warning changed"
      assert failure_ids(a.invocation) == Enum.sort([warning.id, cause_id])
      now = state(ctx.fx, a)
      assert now.run == before.run, "the terminal run changed: #{inspect(now.run.status)}"
      assert now.operation == before.operation, "its Operation changed"
      assert now.events == before.events, "an event of the run, its Operation or the invocation"
    end

    test "O1: a recheck_failed run is skipped; the run listed after it is then examined and decided",
         ctx do
      b = G.assigned!(ctx.fx)
      {first, second} = listed(ctx.fx, ctx.assigned, b)
      # Creation order: the later start freezes the clock past both grace periods.
      G.abandon!(ctx.assigned)
      G.abandon!(b)
      inject!(first.invocation.id, {:error, :recheck_failed})
      before = state(ctx.fx, first)
      result = sweep(ctx.fx)
      injected!(first.invocation.id)
      labels = %{first.invocation.id => :first, second.invocation.id => :second}

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"

      assert visits() == [first.invocation.id, second.invocation.id],
             "visited: #{inspect(positions(visits(), labels))}"

      unchanged!(ctx.fx, first, before)
      release = G.release(second.invocation)
      interrupted!(release)
      stopped!(ctx.fx, second, bound_cause_id(ctx.fx, release), :witness_unreconciled)
    end

    test "O2: a technical error halts the pass with that error; no later run is visited; nothing is written",
         ctx do
      b = G.assigned!(ctx.fx)
      {first, second} = listed(ctx.fx, ctx.assigned, b)
      G.abandon!(ctx.assigned)
      G.abandon!(b)
      error = unknown()
      inject!(first.invocation.id, {:error, error})
      before = {state(ctx.fx, first), state(ctx.fx, second)}
      ids = event_ids(ctx.fx)
      result = sweep(ctx.fx)
      injected!(first.invocation.id)
      labels = %{first.invocation.id => :first, second.invocation.id => :second}

      assert result == {:error, error}, "sweep: #{inspect(G.summary(result))}"
      assert visits() == [first.invocation.id], "visited: #{inspect(positions(visits(), labels))}"
      unchanged!(ctx.fx, first, elem(before, 0))
      unchanged!(ctx.fx, second, elem(before, 1))
      quiet!(ctx.fx, ids)
      assert G.charged(ctx.fx) == 2
    end

    test "D3a: in ordinary runtime a persisted warning still goes to Recovery, bound to it (control)",
         ctx do
      a = ctx.assigned

      warning =
        GateFixtures.cause!(a.invocation, severity: :warning, operation_id: a.run.operation_id)

      G.abandon!(a)
      record!()
      count_attempts!()
      assert PrototypeFixtures.leave_runtime() == :ok
      ordinary!()
      result = sweep(ctx.fx)

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert {visits(), attempts()} == {[], 0}, "the prototype gate was consulted"
      release = G.release(a.invocation)
      interrupted!(release)
      assert bound_cause_id(ctx.fx, release) == warning.id, "not bound to the persisted warning"
      assert failure_ids(a.invocation) == [warning.id]
      stopped!(ctx.fx, a, warning.id, :witness_unreconciled)
    end

    test "D3b: in ordinary runtime a refused finalize still gets the one G7 Recovery attempt (control)",
         ctx do
      a = ctx.assigned
      G.abandon!(a)
      leave_then!(a.invocation.id, {:error, unknown()})
      result = sweep(ctx.fx)
      injected!(a.invocation.id)
      ordinary!()

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      release = G.release(a.invocation)
      interrupted!(release)
      stopped!(ctx.fx, a, bound_cause_id(ctx.fx, release), :witness_unreconciled)
    end
  end

  ## The sweeper's SW-6 hooks (plan r3; not signed: prerequisite until then)

  describe "the sweeper's routing read and reconcile (plan r3 SW-6)" do
    setup %{fx: fx} do
      a = G.assigned!(fx)
      G.abandon!(a)
      %{assigned: a}
    end

    test "S8: a winner committed after the routing read stands; the locked guard refuses the sweeper",
         ctx do
      a = ctx.assigned
      record!()

      hook!(:released_read, fn invocation ->
        # The race point: a concurrent prototype gate decision commits after
        # the routing read observed no release (a stale `false`).
        Process.put(
          :tf1_winner,
          G.finalize(invocation, a.run, {:interrupted, G.absent_receipt()})
        )

        false
      end)

      result = sweep(ctx.fx)
      sw6!(:released_read)
      winner = Process.get(:tf1_winner)

      assert match?({:withheld, %{reason: :gate_interrupted}, %{status: :failed}}, winner),
             "prerequisite: the winner: #{inspect(G.summary(winner))}"

      {:withheld, decided, stopped} = winner
      cause_id = stopped.attention_failure_id
      labels = %{a.invocation.id => :a}

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      # The winner's finalize, then the sweeper's own locked finalize.
      assert visits() == [a.invocation.id, a.invocation.id],
             "visited: #{inspect(positions(visits(), labels))}"

      release = G.release(a.invocation)
      assert release != nil, "no release"
      assert Map.take(release, @release_body) == Map.take(decided, @release_body), "replaced"
      assert bound_cause_id(ctx.fx, release) == cause_id, "the winner's cause was replaced"
      assert failure_ids(a.invocation) == [cause_id], "a second cause"
      assert length(result_events(ctx.fx)) == 1, "a second decision"

      assert Map.take(run(a.run.id), @run_fields) == Map.take(stopped, @run_fields),
             "run rewritten"

      # The historical-bound Operation failure (the existing heal step), once.
      stopped!(ctx.fx, a, cause_id, :witness_unreconciled)
    end

    test "S10: a raise of the routing read propagates as that exact exception; nothing is written",
         ctx do
      a = ctx.assigned
      fault = RuntimeError.exception("d237-s2 tf1 synthetic routing read fault")
      hook!(:released_read, fn _invocation -> raise fault end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:released_read)

      assert result == {:raised, fault}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "S10t: a throw of the routing read propagates as that exact value; nothing is written",
         ctx do
      a = ctx.assigned
      hook!(:released_read, fn _invocation -> throw(:d237_s2_tf1_routing_throw) end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:released_read)

      assert result == {:thrown, :d237_s2_tf1_routing_throw}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "S11: a reconcile error is the pass's exact error; nothing is written", ctx do
      a = ctx.assigned
      error = unknown()
      hook!(:reconcile_result, fn _invocation -> {:error, error} end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:reconcile_result)

      assert result == {:returned, {:error, error}}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "S11r: a raise in the reconcile propagates as that exact exception; nothing is written",
         ctx do
      a = ctx.assigned
      fault = RuntimeError.exception("d237-s2 tf1 synthetic reconcile fault")
      hook!(:reconcile_result, fn _invocation -> raise fault end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:reconcile_result)

      assert result == {:raised, fault}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "S11t: a throw in the reconcile propagates as that exact value; nothing is written",
         ctx do
      a = ctx.assigned
      hook!(:reconcile_result, fn _invocation -> throw(:d237_s2_tf1_reconcile_throw) end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:reconcile_result)

      assert result == {:thrown, :d237_s2_tf1_reconcile_throw}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "S12: a non-boolean routing read raises the fixed ArgumentError (seam control)", ctx do
      a = ctx.assigned
      hook!(:released_read, fn _invocation -> nil end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:released_read)

      assert match?(
               {:raised, %ArgumentError{message: "released_read returns a boolean only"}},
               result
             ),
             "sweep: #{inspect(shape(result))}"

      nothing!(ctx.fx, a, before)
    end

    test "S13: a non-error reconcile result raises the fixed ArgumentError (seam control)", ctx do
      a = ctx.assigned
      hook!(:reconcile_result, fn _invocation -> {:ok, %{receipt: G.absent_receipt()}} end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:reconcile_result)

      assert match?(
               {:raised, %ArgumentError{message: "reconcile_result injects {:error, _} only"}},
               result
             ),
             "sweep: #{inspect(shape(result))}"

      nothing!(ctx.fx, a, before)
    end

    test "D4: in ordinary runtime a recheck_failed reaching the pass is the pass's exact error (SW-4)",
         ctx do
      a = ctx.assigned

      hook!(:reconcile_result, fn _invocation ->
        :ok = PrototypeFixtures.leave_runtime()
        {:error, :recheck_failed}
      end)

      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:reconcile_result)
      ordinary!()

      assert result == {:returned, {:error, :recheck_failed}}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "D4p: in prototype runtime the same recheck_failed is a retry-next-pass skip (SW-4)",
         ctx do
      a = ctx.assigned
      hook!(:reconcile_result, fn _invocation -> {:error, :recheck_failed} end)
      before = {state(ctx.fx, a), event_ids(ctx.fx)}
      result = outcome(fn -> sweep(ctx.fx) end)
      sw6!(:reconcile_result)

      assert result == {:returned, :ok}, "sweep: #{inspect(shape(result))}"
      nothing!(ctx.fx, a, before)
    end

    test "D5: in ordinary runtime the SW-6 hooks are never consulted (control)", ctx do
      a = ctx.assigned
      hook!(:released_read, fn _invocation -> true end)
      hook!(:reconcile_result, fn _invocation -> {:error, :d237_s2_tf1_never} end)
      assert PrototypeFixtures.leave_runtime() == :ok
      ordinary!()
      result = sweep(ctx.fx)

      refute consulted?(:released_read), "the routing hook was consulted in ordinary runtime"
      refute consulted?(:reconcile_result), "the reconcile hook was consulted in ordinary runtime"
      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      release = G.release(a.invocation)
      interrupted!(release)
      stopped!(ctx.fx, a, bound_cause_id(ctx.fx, release), :witness_unreconciled)
    end
  end
end
