defmodule SdrAgent.SDR.DefinitionBootstrapEnvelopeTest do
  @moduledoc """
  C3-02 G3 (Codex ec0eab31 review, important items 1 and 2): regression
  tests of the definition bootstrap's bounded-call envelope
  (`within_deadline/2`, reached through the test-build export
  `DefinitionBootstrap.within_deadline_for_test/2`). No database: the
  calls are plain functions.

  Covered: a value, raise, throw and exit come back to the caller as if
  the call had run there; past the deadline plus the 250 ms grace the
  caller gets `{:error, :timeout}` with the call process already dead (its
  `:DOWN` awaited); a caller killed while waiting takes the call process
  with it; the caller's `trap_exit` flag and its unrelated messages
  (including another link's `:EXIT` for a trapping caller) are preserved,
  and no envelope message (result, `:DOWN`, `:EXIT`) is left behind. The
  success branch demonitors and unlinks without awaiting the call
  process's `:DOWN`, so it asserts no exit there.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.SDR.DefinitionBootstrap

  @grace_ms 250

  setup do
    assert Code.ensure_loaded?(DefinitionBootstrap)

    assert function_exported?(DefinitionBootstrap, :within_deadline_for_test, 2),
           "the test build exports the envelope"

    :ok
  end

  describe "transport" do
    test "a value comes back" do
      assert envelope(5_000, fn -> {:ok, :value} end) == {:ok, :value}
      assert mailbox() == []
    end

    test "a raise is re-raised in the caller" do
      assert_raise RuntimeError, "c302 envelope", fn ->
        envelope(5_000, fn -> raise "c302 envelope" end)
      end

      assert mailbox() == []
    end

    test "a throw is re-thrown in the caller" do
      assert catch_throw(envelope(5_000, fn -> throw(:c302) end)) == :c302
      assert mailbox() == []
    end

    test "an exit is re-raised as the caller's exit" do
      assert catch_exit(envelope(5_000, fn -> exit(:c302) end)) == :c302
      assert mailbox() == []
    end
  end

  describe "the deadline" do
    test "past the deadline and grace: :timeout, the call process dead on return" do
      parent = self()

      {elapsed_us, result} =
        :timer.tc(fn ->
          envelope(50, fn ->
            send(parent, {:c302_call, self()})
            Process.sleep(10_000)
          end)
        end)

      assert result == {:error, :timeout}
      assert_received {:c302_call, call}
      refute Process.alive?(call), "the timeout branch awaits the call process's :DOWN"
      assert elapsed_us >= (50 + @grace_ms) * 1_000
      assert elapsed_us < 5_000_000
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
      assert mailbox() == [], "no result, :DOWN or :EXIT is left behind"
    end

    test "a caller killed while waiting takes the call process with it" do
      parent = self()

      caller =
        spawn(fn ->
          envelope(10_000, fn ->
            send(parent, {:c302_call, self()})
            Process.sleep(10_000)
          end)
        end)

      # Owner-side cleanup on every exit path (Codex fb5166a important): the
      # unlinked caller is killed and its :DOWN awaited, which also ends the
      # call process linked to it.
      on_exit(fn -> kill_and_await!(caller) end)

      assert_receive {:c302_call, call}, 5_000
      ref = Process.monitor(call)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^call, _reason}, 5_000
    end
  end

  describe "the caller's own state" do
    test "unrelated messages survive the timeout branch, in order" do
      parent = self()
      send(self(), {:c302_unrelated, 1})

      result =
        envelope(50, fn ->
          send(parent, {:c302_unrelated, 2})
          Process.sleep(10_000)
        end)

      assert result == {:error, :timeout}
      assert mailbox() == [{:c302_unrelated, 1}, {:c302_unrelated, 2}]
    end

    test "a trapping caller stays trapping and keeps another link's :EXIT" do
      previous = Process.flag(:trap_exit, true)
      other = spawn_link(fn -> receive(do: (:go -> exit(:c302_other))) end)

      result =
        envelope(50, fn ->
          send(other, :go)
          Process.sleep(10_000)
        end)

      assert result == {:error, :timeout}
      assert Process.info(self(), :trap_exit) == {:trap_exit, true}
      assert mailbox() == [{:EXIT, other, :c302_other}]
      Process.flag(:trap_exit, previous)
    end

    test "a trapping caller is left no :EXIT by a returned call" do
      previous = Process.flag(:trap_exit, true)
      assert envelope(5_000, fn -> :value end) == :value
      # The success branch does not await the call process's exit; let it end.
      Process.sleep(50)
      assert Process.info(self(), :trap_exit) == {:trap_exit, true}
      assert mailbox() == []
      Process.flag(:trap_exit, previous)
    end

    test "a non-trapping caller stays non-trapping on both branches" do
      assert envelope(5_000, fn -> :value end) == :value
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
      assert envelope(50, fn -> Process.sleep(10_000) end) == {:error, :timeout}
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
      assert mailbox() == []
    end
  end

  defp envelope(deadline_ms, call) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    DefinitionBootstrap.within_deadline_for_test(deadline, call)
  end

  defp kill_and_await!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("the spawned caller did not terminate")
    end
  end

  defp mailbox do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end
end
