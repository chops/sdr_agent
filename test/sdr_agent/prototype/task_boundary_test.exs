defmodule SdrAgent.Prototype.TaskBoundaryTest do
  @moduledoc """
  P1 of the D-237 task presentation boundary (S1b proposal r2 section 4):
  the in-process contract of `SdrAgent.Prototype.TaskBoundary.run/3`, with
  synthetic sentinels only.

  No database, model, network, subprocess or application start beyond the
  suite's own; no Repo checkout. This is not the real-process proof (P2),
  a real SafeLog sink proof or a startup proof.

  ExUnit host safety: every body that links, kills or exits first checks
  that it is not running in the test process, and otherwise returns a
  marker instead (which the assertions reject). The deny-only declaration
  never calls a body.

  Assertions compare closed summaries (`summary/1`) and booleans, so a
  failure never renders a caught value or captured text.

  The attached SafeLog filter and `ERL_CRASH_DUMP_BYTES` are VM-wide, so
  this module is `async: false`, detaches the filter and restores the
  variable after every test.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Ash.Error.Unknown
  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Prototype.SafeLog
  alias SdrAgent.Prototype.TaskBoundary

  @dump_var "ERL_CRASH_DUMP_BYTES"
  @withheld "prototype: log content withheld\n"

  defmodule SentinelError do
    @moduledoc "A synthetic exception whose field and message carry a sentinel (test only)."
    defexception [:value]

    @impl true
    def message(%{value: value}), do: "synthetic failure holding " <> value
  end

  setup do
    previous = System.get_env(@dump_var)
    :ok = SafeLog.attach(file: nil)

    on_exit(fn ->
      SafeLog.detach()

      if previous,
        do: System.put_env(@dump_var, previous),
        else: System.delete_env(@dump_var)
    end)

    {:ok, sentinel: "S1B-P1-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
  end

  # Runs the boundary in the test process with stdout and the log captured.
  # Returns {closed outcome summary, stdout, log}.
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

  # A body that reports where it ran, then runs `fun` only outside the test
  # process.
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

  defp aborted(task, stage), do: "prototype: task_aborted task=#{task} stage=#{stage}\n"

  describe "completion and refusal" do
    test ":ok returns :ok, prints nothing and runs the body in another process", %{sentinel: s} do
      test_pid = self()
      own_callers = Process.get(:"$callers") || []

      {result, out, log} = boundary(:import, :ok, body(test_pid, fn -> :ok end))

      assert result == {:returned, :ok}
      assert_stdout(out, "", s)
      refute_leak(log, s)
      assert_received {:body_ran, body_pid, callers}
      refute body_pid == test_pid
      assert callers == [test_pid | own_callers]
    end

    test "the body's process has ended and no monitor message is left behind", %{sentinel: s} do
      test_pid = self()

      {result, out, _log} = boundary(:op, :ok, body(test_pid, fn -> :ok end))

      assert result == {:returned, :ok}
      assert_stdout(out, "", s)
      assert_received {:body_ran, body_pid, _callers}
      ref = Process.monitor(body_pid)
      assert_receive {:DOWN, ^ref, :process, ^body_pid, _reason}, 1_000
      refute_received {:DOWN, _other_ref, :process, _pid, _reason}
    end

    test ":refused exits {:shutdown, 2} with only the body's own closed line", %{sentinel: s} do
      test_pid = self()
      id = Ecto.UUID.generate()

      refuse = fn ->
        SafeLog.say(:op_result, command: :status, id: id, result: :refused, reason: :forbidden)
        :refused
      end

      {result, out, log} = boundary(:op, :ok, body(test_pid, refuse))

      assert result == {:exited, {:shutdown, 2}}

      assert_stdout(
        out,
        "prototype: op_result command=status id=#{id} result=refused reason=forbidden\n",
        s
      )

      refute_leak(log, s)
      assert_received {:body_ran, _pid, _callers}
    end
  end

  describe "aborts in the body: one fixed line and {:shutdown, 70}" do
    for {name, fun} <- [
          raise: quote(do: fn s -> raise "synthetic " <> s end),
          exception_field: quote(do: fn s -> raise SentinelError, value: s end),
          ash_unknown:
            quote(
              do: fn s -> raise Unknown.exception(errors: [UnknownError.exception(error: s)]) end
            ),
          throw: quote(do: fn s -> throw({:thrown, s}) end),
          exit_reason: quote(do: fn s -> exit({:custom, s}) end),
          exit_normal: quote(do: fn _s -> exit(:normal) end),
          exit_shutdown_0: quote(do: fn _s -> exit({:shutdown, 0}) end),
          exit_shutdown_term: quote(do: fn s -> exit({:shutdown, {:term, s}}) end),
          mix_raise: quote(do: fn s -> Mix.raise("synthetic " <> s) end),
          bad_return_error: quote(do: fn s -> {:error, s} end),
          bad_return_ok_tuple: quote(do: fn s -> {:ok, s} end),
          bad_return_nil: quote(do: fn _s -> nil end)
        ] do
      test "#{name}", %{sentinel: s} do
        test_pid = self()
        fun = unquote(fun)

        {result, out, log} = boundary(:import, :ok, body(test_pid, fn -> fun.(s) end))

        assert result == {:exited, {:shutdown, 70}}
        assert_stdout(out, aborted(:import, :body), s)
        refute_leak(log, s)
        assert_received {:body_ran, body_pid, _callers}
        refute body_pid == test_pid
      end
    end

    test "a linked process crashing", %{sentinel: s} do
      test_pid = self()

      linked = fn ->
        spawn_link(fn -> raise "synthetic linked " <> s end)

        receive do
        after
          5_000 -> :ok
        end
      end

      {result, out, log} = boundary(:import, :ok, body(test_pid, linked))

      assert result == {:exited, {:shutdown, 70}}
      assert_stdout(out, aborted(:import, :body), s)
      refute_leak(log, s)
    end

    test "an awaited Task crashing", %{sentinel: s} do
      test_pid = self()

      awaited = fn ->
        Task.async(fn -> raise "synthetic task " <> s end) |> Task.await()
        :ok
      end

      {result, out, log} = boundary(:import, :ok, body(test_pid, awaited))

      assert result == {:exited, {:shutdown, 70}}
      assert_stdout(out, aborted(:import, :body), s)
      refute_leak(log, s)
    end

    test "the body's process killed", %{sentinel: s} do
      test_pid = self()

      {result, out, log} =
        boundary(:import, :ok, body(test_pid, fn -> Process.exit(self(), :kill) end))

      assert result == {:exited, {:shutdown, 70}}
      assert_stdout(out, aborted(:import, :body), s)
      refute_leak(log, s)
    end
  end

  describe "attach and entry refusals never call the body" do
    test "an attach result other than :ok aborts at stage attach", %{sentinel: s} do
      for attached <- [{:error, :attach_failed}, {:error, :not_implemented}, nil] do
        test_pid = self()

        {result, out, log} = boundary(:provision, attached, body(test_pid, fn -> :ok end))

        assert result == {:exited, {:shutdown, 70}}
        assert_stdout(out, aborted(:provision, :attach), s)
        refute_leak(log, s)
        refute_received {:body_ran, _pid, _callers}
      end
    end

    test "an unknown task aborts with the withheld line and raises nothing", %{sentinel: s} do
      for task <- [:bogus, "import", nil] do
        test_pid = self()

        {result, out, _log} = boundary(task, :ok, body(test_pid, fn -> :ok end))

        assert result == {:exited, {:shutdown, 70}}
        assert_stdout(out, @withheld, s)
        refute_received {:body_ran, _pid, _callers}
      end
    end

    test "a body that is not a zero-arity function aborts at stage entry", %{sentinel: s} do
      for bad <- [nil, :ok, fn _arg -> :ok end] do
        {result, out, _log} = boundary(:setup, :ok, bad)

        assert result == {:exited, {:shutdown, 70}}
        assert_stdout(out, aborted(:setup, :entry), s)
      end
    end

    test "an invalid task is checked before the attach result", %{sentinel: s} do
      test_pid = self()

      {result, out, _log} =
        boundary(:bogus, {:error, :attach_failed}, body(test_pid, fn -> :ok end))

      assert result == {:exited, {:shutdown, 70}}
      assert_stdout(out, @withheld, s)
      refute_received {:body_ran, _pid, _callers}
    end
  end

  describe "nesting: only the outermost boundary presents" do
    test "a nested call runs its body inline and returns its result", %{sentinel: s} do
      test_pid = self()
      id = Ecto.UUID.generate()

      outer = fn ->
        inner = fn ->
          send(test_pid, {:inner_ran, self()})
          SafeLog.say(:op_result, command: :status, id: id, result: :refused, reason: :forbidden)
          :refused
        end

        TaskBoundary.run(:op, :ok, inner)
      end

      {result, out, _log} = boundary(:import, :ok, body(test_pid, outer))

      assert result == {:exited, {:shutdown, 2}}

      assert_stdout(
        out,
        "prototype: op_result command=status id=#{id} result=refused reason=forbidden\n",
        s
      )

      assert_received {:body_ran, outer_pid, _callers}
      assert_received {:inner_ran, inner_pid}
      assert inner_pid == outer_pid
    end

    test "a nested failure is presented once, by the outer boundary", %{sentinel: s} do
      test_pid = self()
      outer = fn -> TaskBoundary.run(:op, :ok, fn -> raise "synthetic nested " <> s end) end

      {result, out, log} = boundary(:import, :ok, body(test_pid, outer))

      assert result == {:exited, {:shutdown, 70}}
      assert_stdout(out, aborted(:import, :body), s)
      refute_leak(log, s)
    end
  end

  describe "the VM-wide crash-dump setting" do
    test "a call that reaches the body sets ERL_CRASH_DUMP_BYTES to 0", %{sentinel: s} do
      System.delete_env(@dump_var)
      test_pid = self()

      {result, out, _log} = boundary(:import, :ok, body(test_pid, fn -> :ok end))

      assert result == {:returned, :ok}
      assert_stdout(out, "", s)
      assert System.get_env(@dump_var) == "0"
    end

    test "an attach refusal leaves it unchanged", %{sentinel: s} do
      System.delete_env(@dump_var)
      test_pid = self()

      {result, out, _log} =
        boundary(:import, {:error, :attach_failed}, body(test_pid, fn -> :ok end))

      assert result == {:exited, {:shutdown, 70}}
      assert_stdout(out, aborted(:import, :attach), s)
      assert System.get_env(@dump_var) == nil
    end
  end

  describe "broken stdout" do
    test "an abort whose output device refuses every write still exits {:shutdown, 70}",
         %{sentinel: s} do
      test_pid = self()
      broken = spawn(&refuse_io/0)
      original = Process.group_leader()
      Process.group_leader(self(), broken)

      result =
        try do
          summary(outcome(:import, :ok, body(test_pid, fn -> raise "synthetic " <> s end)))
        after
          Process.group_leader(self(), original)
          send(broken, :stop)
        end

      assert result == {:exited, {:shutdown, 70}}
    end
  end

  # An IO server that answers every request with an error (a broken stdout).
  defp refuse_io do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, {:error, :enospc}})
        refuse_io()

      :stop ->
        :ok
    end
  end
end
