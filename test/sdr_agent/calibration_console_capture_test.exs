defmodule SdrAgent.CalibrationConsoleCaptureTest do
  @moduledoc """
  R0-07f RED (contract PASS at `0ee216e`, tests 5 and 6), the **legacy
  contrast** and the structural half. The calibrated positive proof (the
  real calibration path, the console-applied root and budget, an empty
  shipped allowlist throughout) is in
  `SdrAgent.CalibrationConsole.CalibrateTest`, "R0-07f".

    * Under the unit-test budget (1 s) a capture published about 1.5 s
      after an ordinary gated call times out. This uses the generic gate
      fixture (which admits its call through `AdmissionFixtures`); it is a
      contrast only, never the calibrated proof.
    * Calibration's own observation and sent recovery pass no root or wait
      of their own, so the applied configuration decides both.

  The delayed publisher is a tracked task, joined before the store is
  removed. The fake CLI and a stand-in store; no model call.
  """
  use SdrAgent.AuditCase, async: false

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

  # A capture published `delay` ms after the call: its records are held
  # aside, then restored.
  defp delayed!(ctx, delay) do
    invocation = GateFixtures.call_model!(ctx, "cli_shape_v3_mismatch")
    records = Path.join([ctx.root, "witnesses", invocation.id])
    held = Path.join(ctx.root, "held-" <> invocation.id)
    File.rename!(records, held)

    publisher =
      Task.async(fn ->
        Process.sleep(delay)
        File.rename!(held, records)
      end)

    {invocation, publisher}
  end

  test "legacy contrast: under the unit-test budget a capture after 1.5 s times out", ctx do
    Application.put_env(
      :sdr_agent,
      Witness,
      Keyword.put(Application.get_env(:sdr_agent, Witness, []), :store_root, ctx.root)
    )

    Application.put_env(:sdr_agent, ResultGate, wait_ms: 1_000, poll_ms: 25)
    {invocation, publisher} = delayed!(ctx, 1_500)

    try do
      assert {:timeout, _receipt} = ResultGate.await(invocation, ctx.gate)
    after
      # Joined before setup's on_exit removes the store.
      Task.await(publisher, 5_000)
    end
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
