defmodule SdrAgent.CalibrationConsoleCaptureTest do
  @moduledoc """
  R0-07f RED (contract PASS at `0ee216e`, test 5 and 6): the console's
  applied plan, not a fixture, decides where and how long a calibration's
  observation waits.

  The root comes from `SDR_WITNESS_STORE_ROOT` through `current/1 →
  plan/1 → apply_capture!/1`; no `AdmissionFixtures.admit_tuples!/0` and no
  manual Witness `put_env`. A capture published about 1.5 s after the call
  is observed within the console's 120 s budget, while the unit-test budget
  (1 s) times out on the same capture, and the observation adds no
  reservation or launch. Calibration's own observation and sent recovery
  both read the applied root and budget: neither passes a root or a wait of
  its own. The fake CLI and a stand-in store; no model call.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.CalibrationConsole
  alias SdrAgent.GateFixtures

  @variable "SDR_WITNESS_STORE_ROOT"
  @calibrate_source Path.expand(
                      "../../lib/sdr_agent/calibration_console/calibrate.ex",
                      __DIR__
                    )
  @secrets %{
    secret_key_base: Base.encode64(:binary.copy(<<1>>, 64)),
    token_signing_secret: Base.encode64(:binary.copy(<<2>>, 64))
  }

  setup do
    witness = Application.get_env(:sdr_agent, Witness)
    gate = Application.get_env(:sdr_agent, ResultGate)
    variable = System.get_env(@variable)

    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent, operation: operation} = AgentsFixtures.operated_run(tenant)
    root = GateFixtures.root!()

    on_exit(fn ->
      File.rm_rf!(root)
      restore(Witness, witness)
      restore(ResultGate, gate)
      if variable, do: System.put_env(@variable, variable), else: System.delete_env(@variable)
    end)

    %{
      tenant: tenant,
      run: run,
      agent: agent,
      root: root,
      gate: %{run_id: run.id, operation_id: operation.id}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:sdr_agent, key)
  defp restore(key, value), do: Application.put_env(:sdr_agent, key, value)

  defp applied!(root) do
    System.put_env(@variable, root)

    {:ok, plan} =
      :test
      |> CalibrationConsole.current()
      |> Map.put(:secrets, @secrets)
      |> CalibrationConsole.plan()

    Code.ensure_loaded!(CalibrationConsole)

    assert function_exported?(CalibrationConsole, :apply_capture!, 1),
           "R0-07f: CalibrationConsole.apply_capture!/1 is not implemented"

    :ok = CalibrationConsole.apply_capture!(plan)
    plan
  end

  # A capture published `delay` ms after the call: its records are held
  # aside, then restored.
  defp delayed!(ctx, delay) do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
    records = Path.join([ctx.root, "witnesses", invocation.id])
    held = Path.join(ctx.root, "held-" <> invocation.id)
    File.rename!(records, held)

    Task.start(fn ->
      Process.sleep(delay)
      File.rename!(held, records)
    end)

    invocation
  end

  defp invocations(ctx) do
    ModelInvocation
    |> Ash.Query.filter(agent_run_id == ^ctx.run.id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  test "the applied console budget observes a capture that arrives after 1 s", ctx do
    plan = applied!(ctx.root)
    assert plan.witness.store_root == ctx.root
    assert Witness.store_root() == ctx.root
    assert Witness.reconciled_methods() == []

    invocation = delayed!(ctx, 1_500)
    calls = invocations(ctx)
    started = System.monotonic_time(:millisecond)

    # No root and no wait of the caller's own: the applied plan decides.
    assert {:ok, %{status: :mismatch}} = ResultGate.await(invocation, ctx.gate)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 1_000 and elapsed < 10_000, inspect(elapsed)
    assert invocations(ctx) == calls, "the observation reserved or launched again"
  end

  test "under the unit-test budget the same capture times out", ctx do
    Application.put_env(
      :sdr_agent,
      Witness,
      Keyword.put(Application.get_env(:sdr_agent, Witness, []), :store_root, ctx.root)
    )

    Application.put_env(:sdr_agent, ResultGate, wait_ms: 1_000, poll_ms: 25)
    invocation = delayed!(ctx, 1_500)

    assert {:timeout, _receipt} = ResultGate.await(invocation, ctx.gate)
  end

  test "calibration's observation and sent recovery pass no root or wait of their own" do
    {:ok, ast} = @calibrate_source |> File.read!() |> Code.string_to_quoted()

    {_ast, awaits} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:ResultGate]}, :await]}, _, args} = node, acc ->
          {node, [args | acc]}

        node, acc ->
          {node, acc}
      end)

    assert length(awaits) == 2, "expected the observation and the recovery awaits"

    for args <- awaits do
      opts = if length(args) == 3, do: List.last(args), else: []
      keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []
      refute :store_root in keys
      refute :wait_ms in keys
    end

    # The console applies the root and budget before the app starts.
    assert {:ok, %{witness: _, result_gate: _}} =
             :test
             |> CalibrationConsole.current()
             |> Map.put(:secrets, @secrets)
             |> CalibrationConsole.plan()
  end
end
