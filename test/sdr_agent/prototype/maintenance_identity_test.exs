defmodule SdrAgent.Prototype.MaintenanceIdentityTest do
  @moduledoc """
  Setup phase 0's maintenance identity read (S1 I4 r2 §2; Codex c18f8134):
  the pinned target, the pure result decoder, and the helper lifecycle
  against the scripted test connector `SdrAgent.PrototypeMaintenanceFake`.

  Nothing here opens a socket, reads a cluster or touches the prototype
  socket directory: `TestSeam.put_maintenance/1` replaces the connector
  in the calling process before `maintenance_identity/0` starts anything.
  Lifecycle checks are exact and tagged: the fake's own start notice, the
  helper and pool pids it names, this process's links and monitors, and
  the read's own message tags; no mailbox or process census.

  GREEN primitives: all typed-result, boundary and owned-process oracles
  must pass, including later decoder inputs and all 200 race rounds.
  This file never uses the real connector or proves a real socket.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.Authority
  alias SdrAgent.Prototype.Authority.TestSeam
  alias SdrAgent.PrototypeMaintenanceFake, as: Fake

  @data_dir "/Users/charles/.local/state/sdr-agent/prototype/d237-5542/pgdata"
  @id 7_400_000_000_000_000_001
  @facts %{database: "postgres", system_identifier: @id, data_directory: @data_dir}

  describe "the pinned target and the pure decoder" do
    test "the target is the prototype socket, the maintenance database and the superuser" do
      assert Authority.maintenance_target() == [
               database: "postgres",
               port: 5542,
               socket_dir: "/private/tmp/d237-pg-5542",
               username: "postgres"
             ]
    end

    test "the decoder accepts exactly one typed row" do
      assert Authority.maintenance_result({:ok, result([["postgres", @id, @data_dir]])}) ==
               {:ok, @facts}
    end

    test "the decoder refuses every other shape as :maintenance_unavailable" do
      for input <- [
            {:ok, result([])},
            {:ok, result([["postgres", @id, @data_dir], ["postgres", @id, @data_dir]])},
            {:ok, result([["postgres", 0, @data_dir]])},
            {:ok, result([["postgres", -1, @data_dir]])},
            {:ok, result([["postgres", "7400000000000000001", @data_dir]])},
            {:ok, result([[nil, @id, @data_dir]])},
            {:ok, result([["postgres", @id, nil]])},
            {:ok, result([["postgres", @id]])},
            {:ok, %{rows: [["postgres", @id, @data_dir]]}},
            {:error, %Postgrex.Error{message: "synthetic"}},
            :start_failed,
            nil
          ] do
        assert Authority.maintenance_result(input) == {:error, :maintenance_unavailable},
               inspect(input)
      end
    end
  end

  describe "the helper lifecycle (scripted connector; no connection)" do
    test "without a seam a test build starts nothing and is unavailable" do
      before = links_and_monitors()

      assert Authority.maintenance_identity() == {:error, :maintenance_unavailable}
      assert links_and_monitors() == before
      refute_received {_alias, :maintenance_starting}
    end

    test "success gives the facts only after the helper and its pool are down" do
      seam(:ok)
      before = links_and_monitors()

      assert Authority.maintenance_identity() == {:ok, @facts}
      assert_received {:maintenance_fake, :started, helper, pool}
      refute Process.alive?(helper)
      refute Process.alive?(pool)
      assert links_and_monitors() == before
      refute_own_messages(helper, pool)
    end

    test "a generic start failure without an announced pool leaves cleanup unacknowledged" do
      seam(:start_error)
      before = links_and_monitors()

      assert Authority.maintenance_identity() == {:error, :maintenance_cleanup_unacknowledged}
      refute_received {:maintenance_fake, :started, _helper, _pool}
      assert links_and_monitors() == before
      refute_received {_alias, :maintenance_reply, _result}
      refute_received {_alias, :maintenance_starting}
    end

    test "a query error is unavailable, after the pool is down" do
      seam(:query_error)
      before = links_and_monitors()

      assert Authority.maintenance_identity() == {:error, :maintenance_unavailable}
      assert_received {:maintenance_fake, :started, helper, pool}
      refute Process.alive?(helper)
      refute Process.alive?(pool)
      assert links_and_monitors() == before
      refute_own_messages(helper, pool)
    end

    test "a stop that never completes is never success; the pool's death is awaited" do
      seam(:stop_hang, %{stop_ms: 50})
      before = links_and_monitors()

      assert Authority.maintenance_identity() == {:error, :maintenance_unavailable}
      assert_received {:maintenance_fake, :started, helper, pool}
      refute Process.alive?(helper)
      refute Process.alive?(pool)
      assert links_and_monitors() == before
      refute_own_messages(helper, pool)
    end

    test "at the reply bound the helper is killed and its pool's death is awaited" do
      seam(:hang_query, %{reply_ms: 50})
      before = links_and_monitors()

      assert Authority.maintenance_identity() == {:error, :maintenance_unavailable}
      assert_received {:maintenance_fake, :started, helper, pool}
      refute Process.alive?(helper)
      refute Process.alive?(pool)
      assert links_and_monitors() == before
      refute_own_messages(helper, pool)
    end

    test "a reply racing the reply bound is used or drained, never left behind" do
      before = links_and_monitors()

      for _round <- 1..200 do
        seam(:ok, %{reply_ms: 0})
        outcome = Authority.maintenance_identity()

        assert outcome in [
                 {:ok, @facts},
                 {:error, :maintenance_unavailable},
                 {:error, :maintenance_cleanup_unacknowledged}
               ],
               inspect(outcome)

        receive do
          {:maintenance_fake, :started, helper, pool} ->
            if outcome != {:error, :maintenance_cleanup_unacknowledged} do
              refute Process.alive?(helper)
              refute Process.alive?(pool)
            end

            await_dead(helper)
            await_dead(pool)
            refute_own_messages(helper, pool)
        after
          0 -> :ok
        end
      end

      assert links_and_monitors() == before
    end

    test "a pool that outlives its helper is reported as unacknowledged cleanup" do
      seam(:pool_survives, %{reply_ms: 50, down_ms: 50})
      before = links_and_monitors()

      assert Authority.maintenance_identity() == {:error, :maintenance_cleanup_unacknowledged}
      assert_received {:maintenance_fake, :started, helper, pool}
      refute Process.alive?(helper)
      assert Process.alive?(pool)
      assert links_and_monitors() == before
      refute_own_messages(helper, pool)
      await_dead(pool)
    end

    test "a caller that dies leaves a helper that finishes its bounded steps and stops its pool" do
      test = self()

      caller =
        spawn(fn ->
          TestSeam.put_maintenance(seam_map(:slow_query, test, %{}))
          Authority.maintenance_identity()
        end)

      assert_receive {:maintenance_fake, :started, helper, pool}, 1_000
      Process.exit(caller, :kill)
      helper_ref = Process.monitor(helper)
      pool_ref = Process.monitor(pool)
      assert_receive {:DOWN, ^helper_ref, :process, ^helper, _reason}, 2_000
      assert_receive {:DOWN, ^pool_ref, :process, ^pool, _reason}, 2_000
    end
  end

  test "a foreign maintenance connector is rejected before storage or start" do
    assert TestSeam.maintenance() == nil
    invalid = seam_map(:ok, self(), %{})
    invalid = %{invalid | connector: {__MODULE__, %{}}}

    assert_raise ArgumentError, "test seam: malformed maintenance seam", fn ->
      TestSeam.put_maintenance(invalid)
    end

    assert TestSeam.maintenance() == nil
    refute_received {:maintenance_fake, :started, _helper, _pool}
  end

  test "a timely saved reply cannot succeed after the absolute helper deadline" do
    seam(:hold_after_reply, %{reply_ms: 1_000})
    before = links_and_monitors()

    assert Authority.maintenance_identity() == {:error, :maintenance_unavailable}
    assert_received {:maintenance_fake, :started, helper, pool}
    assert_received {:maintenance_fake, :replied, ^helper, sent_at, deadline}
    assert sent_at < deadline
    refute Process.alive?(helper)
    refute Process.alive?(pool)
    assert links_and_monitors() == before
    refute_own_messages(helper, pool)
  end

  ## Helpers

  defp seam(mode, overrides \\ %{}),
    do: TestSeam.put_maintenance(seam_map(mode, self(), overrides))

  defp seam_map(mode, notify, overrides) do
    Map.merge(
      %{
        connector: {Fake, %{mode: mode, notify: notify}},
        reply_ms: 1_000,
        down_ms: 1_000,
        stop_ms: 1_000
      },
      overrides
    )
  end

  defp result(rows),
    do: %Postgrex.Result{command: :select, rows: rows, num_rows: length(rows)}

  defp links_and_monitors, do: Process.info(self(), [:links, :monitors])

  # The read's own tags and the two pids' DOWNs only (never a census).
  defp refute_own_messages(helper, pool) do
    refute_received {:DOWN, _ref, :process, ^helper, _reason}
    refute_received {:DOWN, _ref, :process, ^pool, _reason}
    refute_received {_alias, :maintenance_starting}
    refute_received {_alias, :maintenance_pool, _pid}
    refute_received {_alias, :maintenance_reply, _result}
  end

  # Test-owned hygiene for a pid this test was told about: kill it if it
  # is still alive and wait for its death through a monitor of this test.
  defp await_dead(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end
end
