defmodule SdrAgent.Prototype.TaskBoundaryLaunchTest do
  @moduledoc """
  `TaskBoundary.launch/3` in the shared test VM (ADR-0022; setup fix plan
  r4 acceptance A2), with synthetic sentinels only. This VM runs ExUnit,
  so the prelude is never eligible here and no case tears anything down:

  - an outermost launch is refused at stage `entry` with the one fixed
    line and `{:shutdown, 70}`, the body never runs, and the observed
    prelude targets are unchanged;
  - a bad `attached` is refused at stage `attach` first, as in `run/3`;
  - a launch from inside a `run/3` body is nested: it raises the existing
    `NestedRefusalError` with no line of its own and never runs its body;
    the outer boundary alone presents (stage `body`).

  "Unchanged" compares, privately and as one boolean, each fixed
  Mix.Supervisor child (its entry, pid included, and its child spec, so a
  restart shows), the Logger handler ids, and the stored `ssl_handler`
  fields (passive raw read, no handler callback); neither side is shown.
  `run/3` sets the VM-wide `ERL_CRASH_DUMP_BYTES`, so setup restores it,
  as `TaskBoundaryTest` does.

  The success path needs a fresh no-start VM and is the separate external
  proof (A1). `launch/3` is reached through a dynamic call, so a build
  without it compiles and every case fails on the missing function.
  Assertions compare closed summaries; a failure never renders a caught
  value or captured text.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias SdrAgent.Prototype.TaskBoundary

  @dump_var "ERL_CRASH_DUMP_BYTES"
  @fixed_children [Mix.PubSub, Mix.Sync.PubSub]
  @ssl_fields [:module, :level, :filter_default, :filters, :formatter, :config]

  setup do
    previous = System.get_env(@dump_var)

    on_exit(fn ->
      if previous,
        do: System.put_env(@dump_var, previous),
        else: System.delete_env(@dump_var)
    end)

    {:ok, sentinel: "S4-LAUNCH-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}
  end

  defp launch(task, attached, body),
    do: Function.capture(TaskBoundary, :launch, 3).(task, attached, body)

  defp boundary(fun) do
    {{result, out}, log} = with_log(fn -> with_io(fn -> outcome(fun) end) end)
    {summary(result), out, log}
  end

  defp outcome(fun) do
    {:returned, fun.()}
  catch
    :exit, reason -> {:exited, reason}
    kind, _reason -> {:raised, kind}
  end

  defp summary({:returned, :ok}), do: {:returned, :ok}
  defp summary({:returned, _other}), do: {:returned, :other}
  defp summary({:exited, {:shutdown, n}}) when is_integer(n), do: {:exited, {:shutdown, n}}
  defp summary({:exited, _reason}), do: {:exited, :other}
  defp summary({:raised, kind}), do: {:raised, kind}

  defp aborted(task, stage), do: "prototype: task_aborted task=#{task} stage=#{stage}\n"

  # Fixed-name observations only, compared as one boolean and never shown.
  defp tooling do
    children =
      if Process.whereis(Mix.Supervisor) do
        entries =
          for {id, _pid, _type, _modules} = entry <- Supervisor.which_children(Mix.Supervisor),
              id in @fixed_children,
              do: {entry, :supervisor.get_childspec(Mix.Supervisor, id)}

        Enum.sort(entries)
      else
        :absent
      end

    ssl =
      case :logger_config.get(:logger, :ssl_handler) do
        {:ok, raw} when is_map(raw) -> Map.take(raw, @ssl_fields)
        _absent -> :absent
      end

    {children, Enum.sort(:logger.get_handler_ids()), ssl}
  end

  defp assert_closed(out, log, expected, sentinel) do
    leaked? = String.contains?(out, sentinel) or String.contains?(log, sentinel)
    refute leaked?, "the sentinel was printed or logged"
    same? = out == expected
    assert same?, "stdout is not exactly the expected closed line"
  end

  test "an outermost launch under ExUnit is refused at entry with no prelude effect",
       %{sentinel: sentinel} do
    before = tooling()
    test_pid = self()

    {result, out, log} =
      boundary(fn ->
        launch(:import, :ok, fn ->
          send(test_pid, :body_ran)
          IO.puts(sentinel)
          :ok
        end)
      end)

    assert result == {:exited, {:shutdown, 70}}
    assert_closed(out, log, aborted(:import, :entry), sentinel)
    refute_received :body_ran
    unchanged? = tooling() == before
    assert unchanged?, "a prelude target changed"
  end

  test "a bad attach result is refused at attach before any prelude", %{sentinel: sentinel} do
    before = tooling()
    test_pid = self()

    {result, out, log} =
      boundary(fn ->
        launch(:import, {:error, :attach_failed}, fn -> send(test_pid, :body_ran) end)
      end)

    assert result == {:exited, {:shutdown, 70}}
    assert_closed(out, log, aborted(:import, :attach), sentinel)
    refute_received :body_ran
    unchanged? = tooling() == before
    assert unchanged?, "a prelude target changed"
  end

  test "a launch nested in a run/3 body raises silently; the outer boundary alone presents",
       %{sentinel: sentinel} do
    before = tooling()
    test_pid = self()

    {result, out, log} =
      boundary(fn ->
        TaskBoundary.run(:import, :ok, fn ->
          try do
            launch(:import, :ok, fn ->
              send(test_pid, :inner_ran)
              IO.puts(sentinel)
              :ok
            end)
          rescue
            error ->
              # Only the exception's module is reported, never its contents.
              send(test_pid, {:inner_raised, error.__struct__})
              reraise error, __STACKTRACE__
          end
        end)
      end)

    assert result == {:exited, {:shutdown, 70}}
    assert_closed(out, log, aborted(:import, :body), sentinel)
    refute_received :inner_ran
    assert_received {:inner_raised, TaskBoundary.NestedRefusalError}
    unchanged? = tooling() == before
    assert unchanged?, "a prelude target changed"
  end
end
