defmodule SdrAgent.Prototype.ImportTaskTest do
  @moduledoc """
  Shared-VM entry refusal of the real D-237 import task's launch route.

  The task must exist and export run/1. In ExUnit the terminal-only launch
  prelude deliberately refuses at entry, before argv parsing, Session or
  any protected reader. Each invocation therefore expects the exact fixed
  task_aborted entry line and status70, including argv with synthetic
  sentinels. These are not invalid-argv status2 or import behavior tests.

  True malformed-argv status2 and import success/replay/partial-effect
  evidence remain HELD for reviewed, bounded fresh-terminal invocations of
  the real Mix task. This file does not fake guard success, relax launch
  eligibility, read a dossier, create fixtures, query a database, or call a
  model. An absent task is structural RED only, never reached entry RED.

  Tests are serialized because SafeLog and ERL_CRASH_DUMP_BYTES are
  VM-global. Cleanup restores the variable and detaches the filter.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias SdrAgent.Prototype.SafeLog

  @task Mix.Tasks.Sdr.Prototype.Import
  @dump_var "ERL_CRASH_DUMP_BYTES"
  @aborted "prototype: task_aborted task=import stage=entry\n"

  setup do
    # Deliberately outside the capture/catch: an absent task must remain
    # an assertion, not be swallowed into an expected exit70 summary.
    assert Code.ensure_loaded?(@task), "structural prerequisite: import task is absent"

    previous = System.get_env(@dump_var)

    on_exit(fn ->
      SafeLog.detach()

      if previous,
        do: System.put_env(@dump_var, previous),
        else: System.delete_env(@dump_var)
    end)

    {:ok, sentinel: "S3-T4-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
  end

  test "the real import task exports run/1" do
    assert function_exported?(@task, :run, 1), "structural prerequisite: run/1 is absent"
  end

  test "empty argv refuses at launch entry before parsing" do
    assert_entry_refused([], nil)
  end

  test "entry refusal never echoes an unknown option value", %{sentinel: sentinel} do
    assert_entry_refused(["--unknown-t4-option", sentinel], sentinel)
  end

  test "entry refusal never echoes a positional value", %{sentinel: sentinel} do
    assert_entry_refused([sentinel], sentinel)
  end

  test "a valueless flag refuses at launch entry before parsing" do
    assert_entry_refused(["--agent"], nil)
  end

  defp assert_entry_refused(argv, sentinel) do
    assert function_exported?(@task, :run, 1), "structural prerequisite: run/1 is absent"

    if is_binary(sentinel) do
      present? = sentinel in argv
      assert present?, "sentinel control: the argv must contain the synthetic marker"
    end

    {{{result, stdout}, stderr}, log} = with_log(fn -> capture_task_io(argv) end)

    assert result == {:exited, {:shutdown, 70}}
    same_stdout? = stdout == @aborted
    empty_stderr? = stderr == ""
    assert same_stdout?, "stdout differs from the exact closed refusal line"
    assert empty_stderr?, "stderr is not empty"

    if is_binary(sentinel) do
      leaked? = Enum.any?([stdout, stderr, log], &String.contains?(&1, sentinel))
      refute leaked?, "a synthetic argv sentinel reached a captured output channel"
    end
  end

  defp capture_task_io(argv) do
    with_io(:stderr, fn -> with_io(fn -> invoke(argv) end) end)
  end

  # Dynamic call prevents a missing task from becoming a compiler/setup
  # crash. Never inspect, format or return a caught error/exit value.
  defp invoke(argv) do
    case Function.capture(@task, :run, 1).(argv) do
      :ok -> {:returned, :ok}
      _other -> {:returned, :other}
    end
  catch
    :exit, {:shutdown, status} when is_integer(status) -> {:exited, {:shutdown, status}}
    :exit, _reason -> {:exited, :other}
    kind, _reason -> {:raised, kind}
  end
end
