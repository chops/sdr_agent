defmodule SdrAgent.ClockFollowTest do
  @moduledoc """
  R0-07 packet 8.14.10 (contract PASS at 2b454d5, Codex 6e317e34): the
  test-seam `Clock.follow/1`. A process may follow one other local process
  whose freeze `utc_now/0` and `source/0` then consult live, after its own
  freeze and before `$callers`. A dead or unfrozen followed process
  contributes nothing; `$callers` is never changed.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Clock

  @mine ~U[2026-10-15 12:00:00.000000Z]
  @theirs ~U[2026-10-16 08:30:00.000000Z]
  @callers ~U[2026-10-17 09:00:00.000000Z]

  setup do
    on_exit(&Clock.unfreeze/0)
    :ok
  end

  test "a followed process's freeze is read live, on every read" do
    leader = frozen_process(@theirs)
    follow_defined!()

    in_process(fn ->
      assert Clock.follow(leader) == :ok
      assert {Clock.utc_now(), Clock.source()} == {@theirs, :test_fixed}

      later = DateTime.add(@theirs, 3_600)
      refreeze(leader, later)
      assert Clock.utc_now() == later
    end)
  end

  test "precedence: own freeze, then the followed process, then $callers, then UTC" do
    leader = frozen_process(@theirs)
    caller = frozen_process(@callers)
    follow_defined!()

    in_process(
      fn ->
        assert Clock.follow(leader) == :ok
        assert {Clock.utc_now(), Clock.source()} == {@theirs, :test_fixed}

        Clock.freeze(@mine)
        assert {Clock.utc_now(), Clock.source()} == {@mine, :test_fixed}

        Clock.unfreeze()
        refreeze(leader, nil)
        assert {Clock.utc_now(), Clock.source()} == {@callers, :test_fixed}
        assert Process.get(:"$callers") == [caller]

        refreeze(caller, nil)
        assert Clock.source() == :system_utc
      end,
      callers: [caller]
    )
  end

  test "an unfrozen or dead followed process contributes nothing" do
    leader = frozen_process(nil)
    follow_defined!()

    in_process(fn ->
      assert Clock.follow(leader) == :ok
      assert Clock.source() == :system_utc

      refreeze(leader, @theirs)
      assert Clock.utc_now() == @theirs

      stop(leader)
      assert Clock.source() == :system_utc
      refute Clock.utc_now() == @theirs
    end)
  end

  test "only a local pid is followed; anything else is refused and changes nothing" do
    remote = remote_pid()
    assert node(remote) != node()
    follow_defined!()

    in_process(fn ->
      for bad <- [nil, :leader, "pid", 42, remote] do
        assert Clock.follow(bad) == {:error, :invalid_pid}, inspect(bad)
        assert Clock.source() == :system_utc
      end
    end)
  end

  ## Fixtures

  # After the fixtures: a missing seam fails as an assertion.
  defp follow_defined!,
    do: assert(function_exported?(Clock, :follow, 1), "Clock.follow/1 is not defined")

  # Runs `fun` in a fresh process (with optional `$callers`), so this
  # test's own dictionary is never the subject.
  defp in_process(fun, opts \\ []) do
    test = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        Process.put(:"$callers", Keyword.get(opts, :callers, []))

        result =
          try do
            fun.()
            :ok
          rescue
            error -> {:error, error, __STACKTRACE__}
          end

        send(test, {ref, result})
      end)

    cleanup(pid)

    receive do
      {^ref, :ok} -> :ok
      {^ref, {:error, error, stack}} -> reraise error, stack
    after
      5_000 -> flunk("#{inspect(pid)} did not finish")
    end
  end

  # Every helper process is stopped when its test ends, however it ends.
  defp cleanup(pid), do: on_exit(fn -> Process.exit(pid, :kill) end)

  # A process holding `at` frozen (nil: unfrozen) until told otherwise.
  defp frozen_process(at) do
    pid = spawn(fn -> hold(at) end)
    cleanup(pid)
    refreeze(pid, at)
    pid
  end

  defp hold(_at) do
    receive do
      {:freeze, at, from, ref} ->
        if at, do: Clock.freeze(at), else: Clock.unfreeze()
        send(from, {ref, :ok})
        hold(at)

      :stop ->
        :ok
    end
  end

  defp refreeze(pid, at) do
    ref = make_ref()
    send(pid, {:freeze, at, self(), ref})
    assert_receive {^ref, :ok}
  end

  defp stop(pid) do
    monitor = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
  end

  # A pid of another node, built from this node's own pid encoding.
  defp remote_pid do
    local = Atom.to_string(node())
    other = String.replace(local, ~r/^./, "x")

    self()
    |> :erlang.term_to_binary()
    |> :binary.replace(local, other)
    |> :erlang.binary_to_term()
  end
end
