defmodule SdrAgent.CalibrationConsoleWitnessTest do
  @moduledoc """
  R0-07f RED (contract PASS at `0ee216e`,
  `docs/product/r0/r0-07f-console-witness.md`): the calibration console's
  own witness store root and result wait.

    * `current/1` reads `SDR_WITNESS_STORE_ROOT`; `plan/1` carries it, with
      the fixed `ResultGate` budget, and refuses an explicitly invalid root
      for every command without creating or repairing anything (OQ-F1).
    * `require/2` refuses the capture-required commands when the root is
      absent and lets the others through.
    * `apply_capture!/1` (called by `apply!/2`) puts exactly that root and
      budget into this VM, keeping the empty shipped allowlist.
    * The task parses argv, plans and requires before any effectful step.
    * Ordinary test VMs never read the variable.

  Nothing here starts the console, touches `sdr_agent_calibration` or makes
  a model call. Every test restores the `Witness`, `ResultGate` and
  `SDR_WITNESS_STORE_ROOT` environment it changes.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.CalibrationConsole
  alias SdrAgent.Test.WitnessRoot

  @variable "SDR_WITNESS_STORE_ROOT"
  @task_source Path.expand("../../lib/mix/tasks/sdr.calibration.console.ex", __DIR__)
  @secrets %{
    secret_key_base: Base.encode64(:binary.copy(<<1>>, 64)),
    token_signing_secret: Base.encode64(:binary.copy(<<2>>, 64))
  }

  setup do
    witness = Application.get_env(:sdr_agent, Witness)
    gate = Application.get_env(:sdr_agent, ResultGate)
    variable = System.get_env(@variable)
    System.delete_env(@variable)

    on_exit(fn ->
      restore(Witness, witness)
      restore(ResultGate, gate)
      if variable, do: System.put_env(@variable, variable), else: System.delete_env(@variable)
    end)

    root = WitnessRoot.mkdir!("r007f")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp restore(key, nil), do: Application.delete_env(:sdr_agent, key)
  defp restore(key, value), do: Application.put_env(:sdr_agent, key, value)

  # The real current configuration of this test build, with in-memory
  # secrets (the console's secrets file is never read here).
  defp plan(env \\ nil) do
    if env, do: System.put_env(@variable, env), else: System.delete_env(@variable)

    :test
    |> CalibrationConsole.current()
    |> Map.put(:secrets, @secrets)
    |> CalibrationConsole.plan()
  end

  defp refused!(value) do
    result = plan(value)
    assert match?({:error, _}, result), "accepted #{inspect(value)}: #{inspect(result)}"
    {:error, reason} = result
    reason
  end

  defp api!(fun, arity) do
    Code.ensure_loaded!(CalibrationConsole)

    assert function_exported?(CalibrationConsole, fun, arity),
           "R0-07f: CalibrationConsole.#{fun}/#{arity} is not implemented"
  end

  describe "current/1 and plan/1 carry the root and the budget" do
    test "a trusted root is read from the environment into the plan", %{root: root} do
      assert CalibrationConsole.current(:test)[:witness_store_root] == nil
      System.put_env(@variable, root)
      assert CalibrationConsole.current(:test)[:witness_store_root] == root

      assert {:ok, plan} = plan(root)
      assert plan[:witness] == %{store_root: root}
      assert plan[:result_gate] == [wait_ms: 120_000, poll_ms: 1_000]
    end

    test "an absent root plans with nil", _ctx do
      assert {:ok, plan} = plan()
      assert plan[:witness] == %{store_root: nil}
      assert plan[:result_gate] == [wait_ms: 120_000, poll_ms: 1_000]
    end
  end

  describe "plan/1 refuses an explicitly invalid root, without repair" do
    test "relative, URI, empty-segment and missing paths", %{root: root} do
      missing = Path.join(root, "not-there")

      for bad <- ["tmp/witness", "file://#{root}", root <> "//x", missing, ""] do
        assert refused!(bad) =~ @variable
      end

      refute File.exists?(missing), "the missing root was created"
    end

    test "control characters, though spaces are allowed", _ctx do
      spaced = WitnessRoot.mkdir!("r007f with space")
      on_exit(fn -> File.rm_rf!(spaced) end)
      assert {:ok, %{witness: %{store_root: ^spaced}}} = plan(spaced)

      for bad <- [spaced <> "\nSDR_CALIBRATION_CONSOLE x", spaced <> "\t", spaced <> "\e[0m"] do
        assert refused!(bad) =~ @variable
      end
    end

    test "a symlinked root or ancestor", %{root: root} do
      target = Path.join(root, "target")
      File.mkdir!(target)
      File.chmod!(target, 0o700)
      link = Path.join(root, "link")
      File.ln_s!(target, link)
      inner = Path.join(target, "inner")
      File.mkdir!(inner)
      File.chmod!(inner, 0o700)

      for bad <- [link, Path.join(link, "inner")] do
        assert refused!(bad) =~ @variable
      end
    end

    test "a group- or world-writable root, whose mode is left unchanged", %{root: root} do
      for mode <- [0o770, 0o707] do
        File.chmod!(root, mode)
        assert refused!(root) =~ @variable
        assert Bitwise.band(File.stat!(root).mode, 0o777) == mode
      end

      File.chmod!(root, 0o700)
    end
  end

  describe "require/2: the capture-required commands" do
    test "refuse an absent root; the others pass", %{root: root} do
      assert {:ok, absent} = plan()
      api!(:require, 2)

      for command <- [{:calibrate, :claude_cli_opus}, {:calibrate, :claude_cli_sonnet}] do
        assert {:error, reason} = CalibrationConsole.require(absent, command)
        assert reason =~ @variable
      end

      assert {:error, _} = CalibrationConsole.require(absent, {:recover, Ash.UUIDv7.generate()})

      for command <- [:check, :serve, :bootstrap_admin, {:recover, nil}] do
        assert :ok = CalibrationConsole.require(absent, command), inspect(command)
      end

      assert {:ok, present} = plan(root)
      assert :ok = CalibrationConsole.require(present, {:calibrate, :claude_cli_opus})
      assert :ok = CalibrationConsole.require(present, {:recover, Ash.UUIDv7.generate()})
    end
  end

  describe "apply_capture!/1" do
    test "puts the plan's root and budget into this VM, keeping the empty allowlist", %{
      root: root
    } do
      assert Witness.store_root() == nil
      assert ResultGate.wait_ms() == 1_000
      assert {:ok, plan} = plan(root)
      api!(:apply_capture!, 1)

      assert :ok = CalibrationConsole.apply_capture!(plan)
      assert Witness.store_root() == root
      assert Witness.reconciled_methods() == []
      assert Application.get_env(:sdr_agent, Witness)[:allow_method_override] == true
      assert ResultGate.wait_ms() == 120_000
      assert Application.get_env(:sdr_agent, ResultGate)[:poll_ms] == 1_000
      assert {:ok, ^root} = Store.validate_root(Witness.store_root())
    end

    test "an absent root applies nil and the budget", _ctx do
      assert {:ok, plan} = plan()
      api!(:apply_capture!, 1)

      assert :ok = CalibrationConsole.apply_capture!(plan)
      assert Witness.store_root() == nil
      assert ResultGate.wait_ms() == 120_000
    end

    test "apply!/2 applies the capture configuration through it" do
      source = File.read!(Path.expand("../../lib/sdr_agent/calibration_console.ex", __DIR__))
      {:ok, ast} = Code.string_to_quoted(source)

      body =
        find_def(ast, :apply!, 2) || flunk("CalibrationConsole.apply!/2 not found")

      assert calls?(body, :apply_capture!), "R0-07f: apply!/2 does not call apply_capture!/1"
    end
  end

  describe "the task: parse, plan and require before any effect" do
    test "calibrate and calibrate-recover require the root before effectful steps" do
      {:ok, ast} = @task_source |> File.read!() |> Code.string_to_quoted()

      for {command, effectful} <- [
            {"calibrate",
             [:prepare!, :apply!, :ensure_storage!, :ensure_storage, {:app_start}, {:run}]},
            {"calibrate-recover",
             [:prepare!, :apply!, :ensure_storage!, {:app_start}, {:recover}]}
          ] do
        order = run_clause(ast, command) |> steps()
        index = &Enum.find_index(order, fn step -> step == &1 end)

        assert index.(:require), "R0-07f: #{command} never calls CalibrationConsole.require/2"
        assert index.(:plan!) < index.(:require)
        assert index.(:parse) < index.(:require), "argv parsing must precede the prerequisite"

        for step <- effectful, at = index.(step), not is_nil(at) do
          assert index.(:require) < at, "#{inspect(step)} runs before require in #{command}"
        end
      end
    end
  end

  describe "ordinary test VMs never read the variable" do
    test "runtime.exs under :test leaves the store root unset", %{root: root} do
      System.put_env(@variable, root)
      config = Config.Reader.read!("config/runtime.exs", env: :test)
      refute get_in(config, [:sdr_agent, Witness, :store_root])
    end

    test "a clean test VM with the variable set keeps the root nil", %{root: root} do
      {out, 0} =
        System.cmd(
          "mix",
          ["run", "--no-start", "-e", "IO.inspect(SdrAgent.Agents.Witness.store_root())"],
          env: [{"MIX_ENV", "test"}, {@variable, root}],
          stderr_to_stdout: true
        )

      assert out |> String.split("\n", trim: true) |> List.last() == "nil"
    end
  end

  ## AST helpers

  defp find_def(ast, name, arity) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [{^name, _, args}, [do: body]]} = node, nil when length(args) == arity ->
          {node, body}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp calls?(body, name) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [_module, ^name]}, _, _} = node, _acc -> {node, true}
        {^name, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # The body of `def run([command | argv])`.
  defp run_clause(ast, command) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [{:run, _, [[{:|, _, [^command, _argv]}]]}, [do: body]]} = node, nil ->
          {node, body}

        node, acc ->
          {node, acc}
      end)

    found || flunk("no run([#{inspect(command)} | argv]) clause")
  end

  # The clause's steps, in source order.
  defp steps(body) do
    {_ast, acc} =
      Macro.prewalk(body, [], fn node, acc ->
        case step(node) do
          nil -> {node, acc}
          step -> {node, [step | acc]}
        end
      end)

    Enum.reverse(acc)
  end

  defp step({:plan!, _, []}), do: :plan!
  defp step({:prepare!, _, [_]}), do: :prepare!
  defp step({{:., _, [{:__aliases__, _, [:CalibrationConsole]}, name]}, _, _}), do: name

  defp step({{:., _, [{:__aliases__, _, [:Mix, :Task]}, :run]}, _, ["app.start" | _]}),
    do: {:app_start}

  defp step({:apply, _, [{:@, _, [{:calibrate, _, _}]}, fun, _args]})
       when fun in [:command, :recover_command],
       do: :parse

  defp step({:apply, _, [{:@, _, [{:calibrate, _, _}]}, :run, _args]}), do: {:run}
  defp step({:apply, _, [{:@, _, [{:calibrate, _, _}]}, :recover, _args]}), do: {:recover}
  defp step(_node), do: nil
end
