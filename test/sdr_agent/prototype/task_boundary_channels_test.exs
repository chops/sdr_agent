defmodule SdrAgent.Prototype.TaskBoundaryChannelsTest do
  @moduledoc """
  Class C of the D-237 task boundary real-process proof (S1b proposal r4
  section 4): the pure channel checker's sensitivity, on synthetic
  observations only. A run that meets its expectation exactly reports no
  violation; each single defect reports its closed violation; the framing
  defects (missing newline, partial line, extra blank line, invalid byte)
  report exactly their closed violations. No process, file, database or
  environment is touched.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.D237BoundaryCases, as: Cases
  alias SdrAgent.D237BoundaryChannels, as: Channels

  @s "S1B-P2-C-0123456789abcdef"
  @abort "prototype: task_aborted task=import stage=body"
  @logger_line "13:32:18.204 [error] prototype: log content withheld"
  @files ["err", "out", "pid", "ran"]

  defp clean_bounded_abort,
    do: %{status: 70, stdout: @abort <> "\n", stderr: "", files: @files, orphans: 0, launcher: ""}

  defp v(expected, observed), do: Channels.violations(expected, observed, @s)
  defp bounded_raise, do: Cases.expected(:bounded, "raise")

  test "an exact bounded abort, refusal, completion and logged completion report nothing" do
    assert v(bounded_raise(), clean_bounded_abort()) == []

    refused = %{clean_bounded_abort() | status: 2, stdout: Cases.refusal_line() <> "\n"}
    assert v(Cases.expected(:bounded, "refused"), refused) == []

    assert v(Cases.expected(:bounded, "ok"), %{clean_bounded_abort() | status: 0, stdout: ""}) ==
             []

    logged = %{clean_bounded_abort() | status: 0, stdout: @logger_line <> "\n"}
    assert v(Cases.expected(:bounded, "logger"), logged) == []

    crash = %{clean_bounded_abort() | stdout: @logger_line <> "\n" <> @abort <> "\n"}
    assert v(Cases.expected(:bounded, "task_await"), crash) == []
  end

  test "exact raw controls report nothing" do
    leak = %{
      clean_bounded_abort()
      | status: 1,
        stdout: "",
        stderr: "** (RuntimeError) synthetic #{@s}\n    (app) lib/x.ex:1: f/0\n"
    }

    assert v(Cases.expected(:raw, "raise"), leak) == []

    killed = %{leak | stderr: "** (EXIT from #PID<0.94.0>) killed\n"}
    assert v(Cases.expected(:raw, "self_kill"), killed) == []

    assert v(Cases.expected(:raw, "exit_normal"), %{leak | status: 0, stderr: ""}) == []
  end

  test "each single defect is reported" do
    o = clean_bounded_abort()

    for {defect, observed} <- [
          sentinel_stdout: %{o | stdout: @abort <> "\n" <> "prototype: x note=" <> @s <> "\n"},
          sentinel_stderr: %{o | stderr: "** (RuntimeError) " <> @s <> "\n"},
          stderr_not_empty: %{o | stderr: "anything\n"},
          unknown_line: %{o | stdout: @abort <> "\nhello\n"},
          missing_line: %{o | stdout: ""},
          extra_line: %{o | stdout: @abort <> "\n" <> @abort <> "\n"},
          logger_count: %{o | stdout: @logger_line <> "\n" <> @abort <> "\n"},
          banner_stdout: %{o | stdout: @abort <> "\n** (RuntimeError) x\n"},
          status: %{o | status: 0},
          files: %{o | files: @files ++ ["erl_crash.dump"]},
          orphans: %{o | orphans: 1},
          launcher_output: %{o | launcher: "timeout: failed to run command\n"}
        ] do
      found = v(bounded_raise(), observed)
      assert defect in found, "#{defect} was not reported"
    end
  end

  test "the abort line without its terminating newline is a partial line, not a match" do
    assert v(bounded_raise(), %{clean_bounded_abort() | stdout: @abort}) ==
             [:missing_line, :partial_line]
  end

  test "a truncated final line after a complete one is a partial line" do
    partial = %{clean_bounded_abort() | stdout: @abort <> "\nprototype: task_ab"}
    assert v(bounded_raise(), partial) == [:partial_line]
  end

  test "an extra blank line is reported, never trimmed" do
    blank = %{clean_bounded_abort() | stdout: @abort <> "\n\n"}
    assert v(bounded_raise(), blank) == [:blank_line]
  end

  test "an invalid byte, including a carriage return, is reported, never normalized" do
    invalid = %{clean_bounded_abort() | stdout: @abort <> "\n" <> <<0xFF>> <> "x\n"}
    assert v(bounded_raise(), invalid) == [:invalid_byte]

    crlf = %{clean_bounded_abort() | stdout: @abort <> "\r\n"}
    assert v(bounded_raise(), crlf) == [:invalid_byte, :missing_line]
  end

  test "an unreadable capture or file listing is unknown, never empty" do
    o = clean_bounded_abort()

    assert :capture_unknown in v(bounded_raise(), %{o | stdout: {:unreadable, :enoent}})
    assert :capture_unknown in v(bounded_raise(), %{o | stderr: {:unreadable, :eacces}})

    found = v(bounded_raise(), %{o | files: {:unreadable, :enoent}})
    assert :capture_unknown in found
    assert :files in found
  end

  test "a raw control without its leak, or a kill banner holding the sentinel, is reported" do
    no_leak = %{clean_bounded_abort() | status: 1, stdout: "", stderr: ""}
    assert :stderr_missing_leak in v(Cases.expected(:raw, "raise"), no_leak)

    leaky_kill = %{no_leak | stderr: "** (EXIT from #PID<0.1.0>) " <> @s <> "\n"}
    found = v(Cases.expected(:raw, "self_kill"), leaky_kill)
    assert :stderr_shape in found
    assert :sentinel_stderr in found
  end

  test "every case has a bounded and a raw expectation over the same four files" do
    for name <- Cases.cases(), class <- [:bounded, :raw] do
      assert %{files: @files} = Cases.expected(class, name)
    end
  end

  test "every bounded expectation requires zero stderr bytes" do
    for name <- Cases.cases() do
      assert %{stderr: :empty} = Cases.expected(:bounded, name)
    end
  end
end
