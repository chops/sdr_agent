defmodule SdrAgent.AI.ClaudeCLIReaperReceiptTest do
  @moduledoc """
  C2-02b2α RED (interface PASS `c00ed69`, section 3 "The Reaper cleanup
  receipt", R4): the coordinator registers a fresh private ref with the
  server's own reaper **synchronously** before it stops the server, and
  counts cleanup as confirmed only on the exact ref's receipt. The reaper
  sends it after every tracked tree is confirmed stopped, its workspace
  removed and **its own** lease released, before it exits, so the receipt
  precedes the reaper's `DOWN`. An unidentified launch (the reaper exits
  holding the lease) sends no receipt. A subscriber's death drops its
  subscription; a ref is single-use.

  Every launch is a harmless `/usr/bin/true`; no CLI, no model call.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.Test.LaunchAdmission

  @spawn {:spawn_executable, "/usr/bin/true"}
  @port_opts {[:binary, :exit_status], {[], []}}
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup do
    name = :"reaper_receipt_#{System.unique_integer([:positive])}"
    on_exit(fn -> Reaper.release(name) end)
    %{name: name}
  end

  describe "subscribe/2" do
    test "is acknowledged synchronously with the caller's ref", %{tmp_dir: tmp, name: name} do
      {owner, reaper, _result} = launch(name, tmp, [])
      api!(:subscribe, 2)
      ref = make_ref()

      assert {:subscribed, ^ref} = Reaper.subscribe(reaper, ref)

      stop_owner(owner, reaper)
    end

    test "a reaper that is not running answers an error, bounded", %{name: name} do
      api!(:subscribe, 2)
      {pid, monitor} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000

      started = System.monotonic_time(:millisecond)
      assert {:error, :not_running} = Reaper.subscribe(pid, make_ref())
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert Reaper.lease(name) == nil
    end

    test "a ref is single-use: a duplicate registration is refused", %{tmp_dir: tmp, name: name} do
      {owner, reaper, _result} = launch(name, tmp, [])
      api!(:subscribe, 2)
      ref = make_ref()

      assert {:subscribed, ^ref} = Reaper.subscribe(reaper, ref)
      assert {:error, :duplicate_subscription} = Reaper.subscribe(reaper, ref)

      stop_owner(owner, reaper)
    end
  end

  describe "the cleanup receipt" do
    test "arrives after the lease is released and before the reaper's DOWN", %{
      tmp_dir: tmp,
      name: name
    } do
      {owner, reaper, result} = launch(name, tmp, [])
      assert {:ok, _port, _os_pid} = result
      api!(:subscribe, 2)
      ref = make_ref()
      assert {:subscribed, ^ref} = Reaper.subscribe(reaper, ref)
      down = Process.monitor(reaper)

      send(owner, :exit)

      # The first of the two messages must be the receipt.
      first =
        receive do
          {:reaper_cleanup_confirmed, ^ref, meta} -> {:receipt, meta, Reaper.lease(name)}
          {:DOWN, ^down, :process, ^reaper, _} -> :down_first
        after
          10_000 -> :nothing
        end

      assert {:receipt, %{name: ^name, tracked: 1}, nil} = first,
             "the receipt must precede DOWN, after the lease is released; got #{inspect(first)}"

      assert_receive {:DOWN, ^down, :process, ^reaper, _}, 10_000
      refute File.exists?(tmp)
    end

    test "an unidentified launch sends no receipt and keeps the lease", %{
      tmp_dir: tmp,
      name: name
    } do
      {owner, reaper, result} = launch(name, tmp, os_pid: fn _port -> nil end)
      assert result == {:unknown, :post_spawn_failure}
      api!(:subscribe, 2)
      ref = make_ref()
      assert {:subscribed, ^ref} = Reaper.subscribe(reaper, ref)

      stop_owner(owner, reaper)

      refute_received {:reaper_cleanup_confirmed, ^ref, _}
      assert Reaper.lease(name) == {:held, reaper}
    end

    test "a tracked-only workspace still confirms, with its count", %{tmp_dir: tmp, name: name} do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, reaper} = Reaper.start(name)
          Reaper.track(reaper, tmp)
          send(parent, {:reaper, reaper})
          receive do: (:exit -> :ok)
        end)

      assert_receive {:reaper, reaper}, 5_000
      api!(:subscribe, 2)
      ref = make_ref()
      assert {:subscribed, ^ref} = Reaper.subscribe(reaper, ref)

      stop_owner(owner, reaper)

      assert_received {:reaper_cleanup_confirmed, ^ref, %{name: ^name, tracked: 1}}
    end

    test "a dead subscriber's subscription is dropped; a fresh one is served", %{
      tmp_dir: tmp,
      name: name
    } do
      {owner, reaper, _result} = launch(name, tmp, [])
      api!(:subscribe, 2)
      parent = self()
      stale = make_ref()

      {subscriber, monitor} =
        spawn_monitor(fn -> send(parent, {:stale, Reaper.subscribe(reaper, stale)}) end)

      assert_receive {:stale, {:subscribed, ^stale}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^subscriber, _}, 5_000

      fresh = make_ref()
      assert {:subscribed, ^fresh} = Reaper.subscribe(reaper, fresh)
      stop_owner(owner, reaper)

      assert_received {:reaper_cleanup_confirmed, ^fresh, %{name: ^name}}
      refute_received {:reaper_cleanup_confirmed, ^stale, _}
    end

    test "an unnamed server's reaper confirms with a nil name", %{tmp_dir: tmp} do
      {owner, reaper, _result} = launch(nil, tmp, [])
      api!(:subscribe, 2)
      ref = make_ref()
      assert {:subscribed, ^ref} = Reaper.subscribe(reaper, ref)

      stop_owner(owner, reaper)

      assert_received {:reaper_cleanup_confirmed, ^ref, %{name: nil, tracked: 1}}
    end
  end

  describe "ClaudeCLI.reaper/1" do
    test "publishes the server's own reaper, never blocking", %{name: name} do
      {:ok, server} =
        ClaudeCLI.start_link(
          name: name,
          command: System.find_executable("elixir"),
          test_launcher: true,
          launch_admission: &LaunchAdmission.admitted/3,
          command_args: [@fake, "ready"]
        )

      api!(ClaudeCLI, :reaper, 1)
      reaper = ClaudeCLI.reaper(name)

      assert is_pid(reaper)
      assert Reaper.lease(name) == {:held, reaper}
      assert ClaudeCLI.reaper(server) == reaper
      assert ClaudeCLI.reaper(:"not_a_server_#{System.unique_integer([:positive])}") == nil

      GenServer.stop(server)
    end
  end

  # RED guard: asserted after the fixtures, so a missing function fails as
  # the intended missing behavior, not as a setup crash.
  defp api!(fun, arity), do: api!(Reaper, fun, arity)

  defp api!(module, fun, arity) do
    Code.ensure_loaded!(module)

    assert function_exported?(module, fun, arity),
           "C2-02b2α: #{inspect(module)}.#{fun}/#{arity} is not implemented"
  end

  defp launch(name, tmp, reaper_opts) do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, reaper} = Reaper.start(name, reaper_opts)
        Reaper.track(reaper, tmp)
        deadline = System.monotonic_time(:millisecond) + 5_000
        send(parent, {:opened, reaper, Reaper.open(reaper, tmp, @spawn, @port_opts, deadline)})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:opened, reaper, result}, 10_000
    {owner, reaper, result}
  end

  defp stop_owner(owner, reaper) do
    ref = Process.monitor(reaper)
    send(owner, :exit)
    assert_receive {:DOWN, ^ref, :process, ^reaper, _reason}, 10_000
  end
end
