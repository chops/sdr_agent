defmodule SdrAgent.Prototype.TaskBoundaryEntryTest do
  @moduledoc """
  The entry guards of the D-237 task presentation boundary (contract r6
  steps 4a and 4b; S1b plan r4, I2 r2), with synthetic sentinels only.

  - The pure decision `TaskBoundary.entry_decision/2` over every observed
    RepoState and OperationSnapshot result class. The observed results
    are passed in: there is no seam, stub or substituted guard.
  - Two real cases in the sandbox: a caller inside an open
    `Repo.transaction` is refused at stage `entry` and the body never
    runs; a caller with no open transaction runs the body. Both need S1's
    reviewed RepoState GREEN in the measured build (the I3 composite). At
    the base, RepoState is absent and `run/3` is deny-only.

  A real OperationSnapshot registration cannot be made here:
  `AgentEnv.mode/0` is `:none` in the test environment, so `current/0` is
  `:inert`. Step 4b's refusal is covered by the pure decision only.

  The entry checks are bounded, non-linearizable observations (contract
  r6), not transaction or capability erasure. Assertions compare closed
  summaries and booleans; a failure never renders a caught value or
  captured text.
  """
  use SdrAgent.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias SdrAgent.Prototype.SafeLog
  alias SdrAgent.Prototype.TaskBoundary

  @dump_var "ERL_CRASH_DUMP_BYTES"

  @clear_repo [{:returned, :not_started}, {:returned, {:started, false}}]
  @clear_snapshot [{:returned, :inert}, {:returned, {:error, :snapshot_not_in_use}}]

  @refuse_repo [
    {:returned, {:started, true}},
    {:returned, :unavailable},
    {:returned, {:error, :not_implemented}},
    {:returned, :observe_transaction},
    {:returned, {:started, :unknown}},
    {:returned, nil},
    {:raised, :error},
    {:raised, :exit},
    {:raised, :throw}
  ]

  @refuse_snapshot [
    {:returned, {:ok, :synthetic_snapshot}},
    {:returned, {:error, :other}},
    {:returned, nil},
    {:raised, :error},
    {:raised, :exit},
    {:raised, :throw}
  ]

  @malformed [:not_started, :inert, {:raised, :other}, {:returned}, {:returned, 1, 2}, "x", nil]

  describe "the pure entry decision (steps 4a and 4b)" do
    test "clear only for a clear repo state and a clear snapshot" do
      for repo <- @clear_repo, snapshot <- @clear_snapshot do
        assert TaskBoundary.entry_decision(repo, snapshot) == :clear
      end
    end

    test "every other repo state refuses, whatever the snapshot" do
      for repo <- @refuse_repo, snapshot <- @clear_snapshot ++ @refuse_snapshot do
        assert TaskBoundary.entry_decision(repo, snapshot) == :refuse
      end
    end

    test "every other snapshot refuses, whatever the repo state" do
      for repo <- @clear_repo ++ @refuse_repo, snapshot <- @refuse_snapshot do
        assert TaskBoundary.entry_decision(repo, snapshot) == :refuse
      end
    end

    test "a malformed observation refuses" do
      for bad <- @malformed do
        assert TaskBoundary.entry_decision(bad, {:returned, :inert}) == :refuse
        assert TaskBoundary.entry_decision({:returned, :not_started}, bad) == :refuse
      end
    end
  end

  describe "real caller state (sandbox; needs RepoState GREEN in the measured build)" do
    setup do
      previous = System.get_env(@dump_var)
      :ok = SafeLog.attach(file: nil)

      on_exit(fn ->
        SafeLog.detach()

        if previous,
          do: System.put_env(@dump_var, previous),
          else: System.delete_env(@dump_var)
      end)

      {:ok, sentinel: "S1B-I2-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
    end

    test "a caller inside an open Repo.transaction is refused at stage entry", %{sentinel: s} do
      test_pid = self()

      transaction =
        SdrAgent.Repo.transaction(fn ->
          boundary(:import, :ok, body(test_pid, fn -> :ok end))
        end)

      assert match?({:ok, {_result, _out, _log}}, transaction)
      {:ok, {result, out, log}} = transaction

      assert result == {:exited, {:shutdown, 70}}
      assert_stdout(out, "prototype: task_aborted task=import stage=entry\n", s)
      refute_leak(log, s)
      refute_received {:body_ran, _pid, _callers}
    end

    test "a caller with no open transaction runs the body", %{sentinel: s} do
      test_pid = self()

      {result, out, log} = boundary(:import, :ok, body(test_pid, fn -> :ok end))

      assert result == {:returned, :ok}
      assert_stdout(out, "", s)
      refute_leak(log, s)
      assert_received {:body_ran, body_pid, _callers}
      refute body_pid == test_pid
    end
  end

  # The P1 helpers (task_boundary_test.exs), repeated so this file stands
  # alone: the boundary in the test process, stdout and the log captured,
  # the result reduced to a closed summary.
  defp boundary(task, attached, body) do
    {{result, out}, log} = with_log(fn -> with_io(fn -> outcome(task, attached, body) end) end)
    {summary(result), out, log}
  end

  defp outcome(task, attached, body) do
    {:returned, TaskBoundary.run(task, attached, body)}
  catch
    :exit, reason -> {:exited, reason}
    kind, _reason -> {:raised, kind}
  end

  defp summary({:returned, :ok}), do: {:returned, :ok}
  defp summary({:returned, _other}), do: {:returned, :other}
  defp summary({:exited, {:shutdown, n}}) when is_integer(n), do: {:exited, {:shutdown, n}}
  defp summary({:exited, _reason}), do: {:exited, :other}
  defp summary({:raised, kind}), do: {:raised, kind}

  defp body(test_pid, fun) do
    fn ->
      send(test_pid, {:body_ran, self(), Process.get(:"$callers")})
      if self() == test_pid, do: :ran_in_test_process, else: fun.()
    end
  end

  defp assert_stdout(out, expected, sentinel) do
    same? = out == expected
    leaked? = String.contains?(out, sentinel)
    refute leaked?, "the sentinel reached stdout"
    assert same?, "stdout is not exactly the expected closed lines"
  end

  defp refute_leak(log, sentinel) do
    leaked? = String.contains?(log, sentinel)
    refute leaked?, "the sentinel reached the log"
  end
end
