defmodule SdrAgent.Prototype.RecoveryPartitionTest do
  @moduledoc """
  TF-1 RED (plan r2, `claude-d237-s2-tf1-recovery-plan-r2-20261028.md`;
  Codex eff38bd0, cc688175), D-237 slice S2: in prototype runtime a failed
  finalize is never followed by an ordinary Recovery decision.

  - **(a) The facade** (`ResultGate.gate/3`) and **the sweeper**
    (`StaleRunSweeper.sweep/1`) return the ORIGINAL technical
    `{:error, e}` from finalize unchanged: no release row, no `model.result.*`
    event, no new Failure, no run stop or Operation failure, the run still
    `:running`, the charge kept. `recheck_failed` is returned unchanged by
    the facade and is a retry-next-pass skip in the sweeper (prototype
    runtime only). A raise or a throw propagates unchanged.
  - **(b) With no release, the sweeper finalizes through the prototype gate**
    (reconcile first, then `{:interrupted, receipt}`), also when evidence
    persisted: one `before_head` attempt, a closed withheld
    `gate_interrupted` decision.
  - **Direct `Recovery.run/3` with no release** returns the finite internal
    `{:error, :no_prototype_decision}` and writes nothing.
  - **(c) An existing release is authoritative:** a stopped run's withheld
    is returned as it is; a `released_unverified` is returned only through
    the verified fetch (b2c prerequisite).

  Technical errors are injected through `Prototype.Release`'s test-seam-only
  `finalize_result` hook (a deny/no-positive declaration: `{:error, _}` or
  `:passthrough` only). The sweeper's routing-read and reconcile hooks
  (plan r2 SW-6) are not signed yet: their cases stop at the seam
  prerequisite. Sweeper runs are built through real APIs only
  (`PrototypeGateFixtures.assigned!/1`, `abandon!/1`). The injected Unknown
  has a binary `UnknownError` leaf (no Postgrex struct). Messages are
  value-free (`G.summary/1`).
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias Ash.Error.Unknown
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Prototype.Release
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.SDR.StaleRunSweeper

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

  ## Helpers

  defp unknown,
    do: Unknown.exception(errors: [UnknownError.exception(error: "d237-s2 tf1 synthetic")])

  defp technical(:unknown), do: unknown()
  defp technical(:forbidden), do: Ash.Error.Forbidden.exception([])
  defp technical(:other), do: :d237_tf1_synthetic_technical

  # The finalize seam for `target` (an invocation id, or :all); every other
  # invocation runs the real attempts.
  defp inject!(target, result) do
    Application.put_env(:sdr_agent, Release,
      finalize_result: fn invocation ->
        if target == :all or invocation.id == target do
          Process.put(:tf1_injected, Process.get(:tf1_injected, 0) + 1)
          result
        else
          :passthrough
        end
      end
    )
  end

  defp injected!,
    do:
      assert(
        Process.get(:tf1_injected, 0) > 0,
        "prerequisite: the finalize seam was not consulted"
      )

  # The prototype gate's own attempts, counted by the existing hook.
  defp count_attempts! do
    Application.put_env(:sdr_agent, Release,
      before_head: fn _invocation ->
        Process.put(:tf1_attempts, Process.get(:tf1_attempts, 0) + 1)
      end
    )
  end

  defp attempts, do: Process.get(:tf1_attempts, 0)

  defp run(id), do: Ash.get!(AgentRun, id, authorize?: false)

  defp failures(invocation) do
    Failure
    |> Ash.Query.filter(subject_id == ^invocation.id and class == :reconciliation_required)
    |> Ash.read!(SdrAgent.Audit.Kernel.opts(invocation.tenant_id))
  end

  defp result_events(fx),
    do:
      Enum.filter(
        events(fx.tenant),
        &String.starts_with?(&1.event_type, "model.result.")
      )

  # Nothing was decided for `invocation`: no release, no result event, no new
  # cause, the run still running.
  defp undecided?(fx, invocation, failures_before) do
    G.release(invocation) == nil and result_events(fx) == [] and
      length(failures(invocation)) == failures_before and
      run(invocation.agent_run_id).status == :running
  end

  ## (a) The facade

  describe "the facade (ResultGate.gate/3)" do
    setup %{fx: fx} do
      run = G.run!(fx)
      %{run: run, invocation: G.completed!(fx, run)}
    end

    for kind <- [:unknown, :forbidden, :other] do
      test "F: a #{kind} technical error from finalize is returned unchanged; nothing decided",
           ctx do
        error = technical(unquote(kind))
        inject!(ctx.invocation.id, {:error, error})
        result = ResultGate.gate(ctx.invocation, G.gate(ctx.run))
        injected!()

        assert result == {:error, error}, "gate: #{inspect(G.summary(result))}"
        assert undecided?(ctx.fx, ctx.invocation, 0)
        assert G.charged(ctx.fx) == 1
      end
    end

    test "F5: a raise in the attempt propagates unchanged; nothing decided", ctx do
      Application.put_env(:sdr_agent, Release,
        before_head: fn _invocation -> raise RuntimeError, "d237-s2 tf1 synthetic raise" end
      )

      assert_raise RuntimeError, "d237-s2 tf1 synthetic raise", fn ->
        ResultGate.gate(ctx.invocation, G.gate(ctx.run))
      end

      assert undecided?(ctx.fx, ctx.invocation, 0)
    end

    test "F6: a throw in the attempt propagates unchanged; nothing decided", ctx do
      Application.put_env(:sdr_agent, Release,
        before_head: fn _invocation -> throw(:d237_s2_tf1_synthetic_throw) end
      )

      assert catch_throw(ResultGate.gate(ctx.invocation, G.gate(ctx.run))) ==
               :d237_s2_tf1_synthetic_throw

      assert undecided?(ctx.fx, ctx.invocation, 0)
    end

    test "F7: the seam refuses a non-error value with a fixed message (seam control)", ctx do
      Application.put_env(:sdr_agent, Release,
        finalize_result: fn _invocation -> {:ok, :released} end
      )

      assert_raise ArgumentError, "finalize_result injects {:error, _} only", fn ->
        ResultGate.gate(ctx.invocation, G.gate(ctx.run))
      end

      assert undecided?(ctx.fx, ctx.invocation, 0)
    end
  end

  ## Direct Recovery

  describe "direct Recovery.run/3" do
    setup %{fx: fx} do
      run = G.run!(fx)
      %{run: run, invocation: G.completed!(fx, run)}
    end

    test "R1: with no release it decides nothing: {:error, :no_prototype_decision}", ctx do
      result = Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert result == {:error, :no_prototype_decision}, "recovery: #{inspect(G.summary(result))}"
      assert undecided?(ctx.fx, ctx.invocation, 0)
    end

    test "R2: an existing withheld of a stopped run is returned as it is (control)", ctx do
      G.drift!()
      decided = G.finalize(ctx.invocation, ctx.run)

      assert match?({:withheld, _, _}, decided),
             "prerequisite: withheld: #{inspect(G.summary(decided))}"

      {:withheld, release, _stopped} = decided
      assert PrototypeFixtures.put_live_identity(%{}) == :ok
      events_before = length(result_events(ctx.fx))
      failures_before = length(failures(ctx.invocation))

      result = Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert match?({:withheld, %{id: id}, _} when id == release.id, result),
             "recovery: #{inspect(G.summary(result))}"

      assert length(result_events(ctx.fx)) == events_before
      assert length(failures(ctx.invocation)) == failures_before
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
  end

  ## The sweeper

  describe "the sweeper (StaleRunSweeper.sweep/1)" do
    setup %{fx: fx} do
      %{assigned: G.assigned!(fx)}
    end

    for kind <- [:unknown, :forbidden, :other] do
      test "S: a #{kind} technical error from finalize is the pass's original error; nothing decided",
           ctx do
        a = ctx.assigned
        error = technical(unquote(kind))
        G.abandon!(a)
        inject!(a.invocation.id, {:error, error})
        result = StaleRunSweeper.sweep(ctx.fx.tenant.id)
        injected!()

        assert result == {:error, error}, "sweep: #{inspect(G.summary(result))}"
        assert undecided?(ctx.fx, a.invocation, 0)
        assert G.charged(ctx.fx) == 1
      end
    end

    test "S4: evidence persisted (a live warning), no release: the prototype gate decides",
         ctx do
      a = ctx.assigned

      warning =
        GateFixtures.cause!(a.invocation, severity: :warning, operation_id: a.run.operation_id)

      G.abandon!(a)
      count_attempts!()
      result = StaleRunSweeper.sweep(ctx.fx.tenant.id)

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert attempts() == 1, "prototype gate attempts: #{attempts()}"
      release = G.release(a.invocation)
      assert release && {release.disposition, release.reason} == {:withheld, :gate_interrupted}
      [event] = G.release_events(ctx.fx, "model.result.withheld", release)
      assert event.payload["arguments"]["gate_cause_id"] == warning.id
      assert run(a.run.id).status_reason == :witness_unreconciled
    end

    test "S5: evidence persisted (a live critical, no mismatch link): the prototype gate decides",
         ctx do
      a = ctx.assigned
      GateFixtures.cause!(a.invocation, severity: :critical, operation_id: a.run.operation_id)
      G.abandon!(a)
      count_attempts!()
      result = StaleRunSweeper.sweep(ctx.fx.tenant.id)

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert attempts() == 1, "prototype gate attempts: #{attempts()}"
      release = G.release(a.invocation)
      assert release && release.disposition == :withheld
    end

    test "S6: a terminal run with evidence persisted gets the release only, from the prototype gate",
         ctx do
      a = ctx.assigned
      GateFixtures.cause!(a.invocation, severity: :warning, operation_id: a.run.operation_id)
      {:ok, cancelled} = SdrAgent.Agents.cancel_run(a.run, actor: ctx.fx.agent)
      G.abandon!(a)
      count_attempts!()
      result = StaleRunSweeper.sweep(ctx.fx.tenant.id)

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert attempts() == 1, "prototype gate attempts: #{attempts()}"
      assert G.release(a.invocation).disposition == :withheld
      assert run(a.run.id).status == cancelled.status
    end

    test "O1: a recheck_failed run is skipped and the next eligible run is examined", ctx do
      a = ctx.assigned
      b = G.assigned!(ctx.fx)
      # b started later: abandoning it last puts both past the grace.
      G.abandon!(a)
      G.abandon!(b)
      inject!(a.invocation.id, {:error, :recheck_failed})
      result = StaleRunSweeper.sweep(ctx.fx.tenant.id)
      injected!()

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      assert G.release(a.invocation) == nil
      assert run(a.run.id).status == :running
      assert G.release(b.invocation) != nil
    end

    test "O2: a technical error halts the pass with that error; its run is undecided", ctx do
      a = ctx.assigned
      b = G.assigned!(ctx.fx)
      G.abandon!(a)
      G.abandon!(b)
      error = unknown()
      inject!(a.invocation.id, {:error, error})
      result = StaleRunSweeper.sweep(ctx.fx.tenant.id)
      injected!()

      assert result == {:error, error}, "sweep: #{inspect(G.summary(result))}"
      assert G.release(a.invocation) == nil
      assert run(a.run.id).status == :running
    end

    # Plan r2 SW-6 (not signed): the routing read and the gated reconcile
    # hooks. Without them these cases stop at the seam prerequisite.
    for {label, {key, value}} <- [
          routing_read_raises: {:released_read, :raise},
          race_released_read_false: {:released_read, false},
          reconcile_error: {:reconcile_result, :error}
        ] do
      test "S-SW6: #{label}", ctx do
        a = ctx.assigned
        G.abandon!(a)

        Application.put_env(:sdr_agent, StaleRunSweeper, [
          {unquote(key),
           fn _invocation ->
             Process.put(:tf1_sw6, true)

             case unquote(value) do
               :raise -> raise RuntimeError, "d237-s2 tf1 routing read"
               :error -> {:error, unknown()}
               other -> other
             end
           end}
        ])

        result =
          try do
            StaleRunSweeper.sweep(ctx.fx.tenant.id)
          rescue
            _error in RuntimeError -> :raised
          end

        assert Process.get(:tf1_sw6, false), "prerequisite: the SW-6 seam was not consulted"
        assert result != :ok, "sweep: #{inspect(G.summary(result))}"
        assert G.release(a.invocation) == nil
      end
    end
  end
end
