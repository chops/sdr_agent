defmodule SdrAgent.Prototype.TaskBoundaryEntryTokenTest do
  @moduledoc """
  RED for the K0 entry token's adoption by `SdrAgent.Prototype.TaskBoundary`
  and for `ContainmentGuard.guard/1` inside the body (D-237 S4 K0/guard RED
  packet r1).

  Contract encoded (packet section 4 cites each line):

  - TaskBoundary is the ONLY token adopter (plan r3 section 2; RP-1b). The
    BODY process holds the token of its task, set before the body's first
    statement; the caller holds none; no process the body starts inherits
    it (r3 section 2, r5 entity row "Entry token"; S1b plan r4 section 3
    "body-process token setter", "no permissive fallback");
  - the guard runs inside the body (S3 entity ruling Q2) and a refusal is
    returned by the body unchanged: TaskBoundary's item 7 makes any result
    other than `:ok`/`:refused` an abort at stage `:body`, exit
    `{:shutdown, 70}`, with only the fixed abort line (S1b `run/3` at
    68eac1ea; S3 ruling Q1, Q3). The code text never reaches stdout,
    stderr or the log (Q3).

  `:export` is a TaskBoundary task with no containment kind: adoption
  refuses it closed at stage `:entry`, exit 70, body never called (packet
  r2 E2; no new kind). Any other non-`:ok`, raised or malformed adoption
  outcome also aborts at `:entry` without the body; that closed clause is a
  source-review obligation, as no seam can make `put_entry/1` fail in an
  outermost call. Out of scope: a nested call with a different task (O-6);
  `Session.enter/1` before the guard (S3's T4 rows).

  The body runs in its own process and every body first checks that it is
  not the test process (S1b P1 host safety). SafeLog and
  `ERL_CRASH_DUMP_BYTES` are VM-wide: async false, detached and restored
  after every test. Assertions compare closed summaries, never captured
  values.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias SdrAgent.Prototype.Containment
  alias SdrAgent.Prototype.SafeLog
  alias SdrAgent.Prototype.TaskBoundary

  @guard SdrAgent.Prototype.ContainmentGuard
  @seam SdrAgent.Prototype.ContainmentGuard.TestSeam
  @dump_var "ERL_CRASH_DUMP_BYTES"
  @kinds [:setup, :provision, :import, :op, :serve]
  @unadopted {:error, :entry_unadopted}
  @adopter "lib/sdr_agent/prototype/task_boundary.ex"

  setup do
    names = System.get_env() |> Map.keys()
    refute Enum.any?(names, &String.starts_with?(&1, "OTEL_")), "precondition: an OTEL_ name"
    refute "PHX_SERVER" in names, "precondition: PHX_SERVER is set"

    previous = System.get_env(@dump_var)
    :ok = SafeLog.attach(file: nil)

    on_exit(fn ->
      SafeLog.detach()

      if previous,
        do: System.put_env(@dump_var, previous),
        else: System.delete_env(@dump_var)
    end)

    :ok
  end

  defp guard_api! do
    assert Code.ensure_loaded?(@guard), "SdrAgent.Prototype.ContainmentGuard is not available"
    assert function_exported?(@guard, :guard, 1), "ContainmentGuard.guard/1 is not implemented"
    assert function_exported?(@guard, :codes, 0), "ContainmentGuard.codes/0 is not implemented"
    assert Code.ensure_loaded?(@seam), "ContainmentGuard.TestSeam is not available"
    assert function_exported?(@seam, :with_refusal, 2), "TestSeam.with_refusal/2 is absent"
    assert function_exported?(@seam, :refusal_hits, 0), "TestSeam.refusal_hits/0 is absent"
    assert function_exported?(@seam, :with_read_log, 1), "TestSeam.with_read_log/1 is absent"
  end

  defp guard(kind), do: Function.capture(@guard, :guard, 1).(kind)
  defp codes, do: Function.capture(@guard, :codes, 0).()
  defp with_refusal(code, fun), do: Function.capture(@seam, :with_refusal, 2).(code, fun)
  defp refusal_hits, do: Function.capture(@seam, :refusal_hits, 0).()
  defp with_read_log(fun), do: Function.capture(@seam, :with_read_log, 1).(fun)

  # Runs the boundary in the test process with stdout, stderr and the log
  # captured: {closed outcome summary, stdout, stderr, log}.
  defp boundary(task, body) do
    {{{result, out}, err}, log} =
      with_log(fn ->
        with_io(:standard_error, fn -> with_io(fn -> outcome(task, body) end) end)
      end)

    {summary(result), out, err, log}
  end

  defp outcome(task, body) do
    {:returned, TaskBoundary.run(task, :ok, body)}
  catch
    :exit, reason -> {:exited, reason}
    kind, _reason -> {:raised, kind}
  end

  defp summary({:returned, :ok}), do: {:returned, :ok}
  defp summary({:returned, _other}), do: {:returned, :other}
  defp summary({:exited, {:shutdown, n}}) when is_integer(n), do: {:exited, {:shutdown, n}}
  defp summary({:exited, _reason}), do: {:exited, :other}
  defp summary({:raised, kind}), do: {:raised, kind}

  # A body that runs `fun` only outside the test process.
  defp body(test_pid, fun) do
    fn -> if self() == test_pid, do: :ran_in_test_process, else: fun.() end
  end

  # Sends `message` and returns :ok (a completed body).
  defp reply(pid, message) do
    send(pid, message)
    :ok
  end

  defp aborted(task, stage), do: "prototype: task_aborted task=#{task} stage=#{stage}\n"

  # In a body: the entry/0 of a plain spawned child and of a Task child.
  defp children_entries do
    parent = self()
    spawn(fn -> send(parent, {:plain_entry, Containment.entry()}) end)
    task = Task.async(&Containment.entry/0) |> Task.await(5_000)

    receive do
      {:plain_entry, plain} -> {plain, task}
    after
      5_000 -> {:timeout, task}
    end
  end

  describe "adoption (S1b body-process token setter)" do
    test "the body holds its task's token from its first statement; the caller holds none" do
      test_pid = self()

      for task <- @kinds do
        report = fn -> reply(test_pid, {:body_entry, task, Containment.entry()}) end
        {result, out, err, _log} = boundary(task, body(test_pid, report))
        assert result == {:returned, :ok}, "task #{task}: the boundary did not complete"
        assert {out, err} == {"", ""}
        assert_received {:body_entry, ^task, entry}
        assert entry == {:ok, task}, "task #{task}: the body does not hold its token"
      end

      assert Containment.entry() == @unadopted, "the caller (test process) holds a token"
    end

    test "processes the body starts hold no token" do
      test_pid = self()
      report = fn -> reply(test_pid, {:children, children_entries()}) end
      {result, _out, _err, _log} = boundary(:import, body(test_pid, report))
      assert result == {:returned, :ok}
      assert_received {:children, children}
      assert children == {@unadopted, @unadopted}, "a child of the body inherited the token"
    end

    test ":export has no containment kind: it aborts at :entry and never calls the body" do
      test_pid = self()
      ran = body(test_pid, fn -> reply(test_pid, :export_body_ran) end)
      {result, out, err, _log} = boundary(:export, ran)
      assert result == {:exited, {:shutdown, 70}}, ":export did not abort with exit 70"
      assert out == aborted(:export, :entry), "stdout is not exactly the :entry abort line"
      assert err == ""
      refute_received :export_body_ran, "the :export body was called"
    end
  end

  describe "guard(:import) inside the body" do
    test "the body's guard passes stage A with the adopted token and reaches stage B" do
      guard_api!()
      test_pid = self()
      report = fn -> reply(test_pid, {:verdict, guard(:import)}) end

      {{result, _out, _err, _log}, reads} =
        with_read_log(fn -> boundary(:import, body(test_pid, report)) end)

      assert result == {:returned, :ok}
      assert_received {:verdict, verdict}
      refute verdict == @unadopted, "the body's own guard refused its adopted token"
      assert verdict == :ok or match?({:error, _code}, verdict)
      assert reads.env == 1, "stage B did not run once in the body"
    end

    test "each refusal returned by the body exits 70 with only the abort line and no code text" do
      guard_api!()
      test_pid = self()

      for code <- codes() do
        refuse = body(test_pid, fn -> guard(:import) end)

        {{result, out, err, log}, hits} =
          with_refusal(code, fn -> {boundary(:import, refuse), refusal_hits()} end)

        text = Atom.to_string(code)
        assert hits == 1, "#{code}: the body's guard did not claim the refusal"
        assert result == {:exited, {:shutdown, 70}}, "#{code}: not exit 70"
        assert out == aborted(:import, :body), "#{code}: stdout is not exactly the abort line"
        assert err == "", "#{code}: the boundary wrote to stderr"
        refute String.contains?(err, text), "#{code}: code text reached stderr"
        refute String.contains?(log, text), "#{code}: code text reached the log"
      end
    end

    test "a guard in a process the body starts refuses entry_unadopted, even under a scope" do
      guard_api!()
      test_pid = self()

      child_guard = fn ->
        verdict = Task.async(fn -> guard(:import) end) |> Task.await(5_000)
        reply(test_pid, {:child_verdict, verdict})
      end

      {{result, _out, _err, _log}, hits} =
        with_refusal(:otel_env, fn ->
          {boundary(:import, body(test_pid, child_guard)), refusal_hits()}
        end)

      assert result == {:returned, :ok}
      assert_received {:child_verdict, verdict}
      assert verdict == @unadopted, "a process the body started passed the token stage"
      assert hits == 0, "the scope's claim was consumed without a token"
    end
  end

  describe "source row RP-1b: the sole adopter" do
    test "the only lib call of put_entry/1 is in TaskBoundary, exactly once" do
      calls =
        for path <- Path.wildcard("lib/**/*.ex"),
            count = call_count(path),
            count > 0,
            do: {path, count}

      assert calls == [{@adopter, 1}], "put_entry/1 call sites: #{inspect(calls)}"
    end
  end

  # Qualified `Containment.put_entry(` call sites in one file (a text scan;
  # an AST row is OPEN item O-7).
  defp call_count(path),
    do: length(Regex.scan(~r/\bContainment\.put_entry\(/, File.read!(path)))
end
