defmodule SdrAgent.Prototype.ImportTaskTest do
  @moduledoc """
  T4-R1 of the D-237 import task: real task presence and four malformed
  argv cases, with closed terminal summaries and synthetic sentinels.

  This is NOT full T4. Success, replay, domain authorization, partial row
  commit, guard refusal and Session/K0/guard adoption remain HELD in the
  external source packet. An absent task is structural RED only: it does
  not prove any of these runtime assertions were reached. No skipped tag,
  fabricated task, substituted guard, synthetic success or new test seam.

  Only the two argv cases actually containing a sentinel claim a sentinel
  leak check. Empty/valueless argv cases assert exact closed output only.

  No database fixture, dossier read, network or model call. A future real
  task owns its existing app.config/opentelemetry body prologue; this is
  not a fresh-VM startup proof. All cases are serialized because SafeLog
  and ERL_CRASH_DUMP_BYTES are VM-global. Cleanup restores the variable
  and detaches the filter, following the accepted boundary test pattern.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias SdrAgent.Prototype.SafeLog

  @task Mix.Tasks.Sdr.Prototype.Import
  @dump_var "ERL_CRASH_DUMP_BYTES"
  @invalid "prototype: import_refused reason=invalid_arguments\n"

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

  test "empty argv is one input refusal and status2" do
    assert_invalid([], nil)
  end

  test "an unknown option is refused without echoing its value", %{sentinel: sentinel} do
    assert_invalid(["--unknown-t4-option", sentinel], sentinel)
  end

  test "a positional argument is refused without echoing it", %{sentinel: sentinel} do
    assert_invalid([sentinel], sentinel)
  end

  test "a flag without its value is one input refusal and status2" do
    assert_invalid(["--agent"], nil)
  end

  defp assert_invalid(argv, sentinel) do
    assert function_exported?(@task, :run, 1), "structural prerequisite: run/1 is absent"

    if is_binary(sentinel) do
      present? = sentinel in argv
      assert present?, "sentinel control: the argv must contain the synthetic marker"
    end

    {{{result, stdout}, stderr}, log} =
      with_log(fn ->
        with_io(:stderr, fn -> with_io(fn -> invoke(argv) end) end)
      end)

    assert result == {:exited, {:shutdown, 2}}
    same_stdout? = stdout == @invalid
    empty_stderr? = stderr == ""
    assert same_stdout?, "stdout differs from the exact closed refusal line"
    assert empty_stderr?, "stderr is not empty"

    if is_binary(sentinel) do
      leaked? = Enum.any?([stdout, stderr, log], &String.contains?(&1, sentinel))
      refute leaked?, "a synthetic argv sentinel reached a captured output channel"
    end
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
