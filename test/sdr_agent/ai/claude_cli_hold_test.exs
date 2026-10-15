defmodule SdrAgent.AI.ClaudeCLIHoldTest do
  @moduledoc """
  C2-02b2α RED (interface PASS `c00ed69`, section 2a "The runtime launch
  hold", R3/D3-2; binding obligation 4): a server-side launch hold,
  separate from cleanup admission.

    * A server started with `hold: ref`, or re-held with `hold/2`, refuses
      every **newly dequeued** call before launch admission
      (`{:error, :provider_held}`): no admission, no port.
    * Only `release_hold/2` with the **current** ref releases it; an older
      or foreign ref gets `{:error, :stale_hold}` and changes nothing.
    * `hold/2` is synchronous and acknowledged (`{:held, ref}`), replaces
      the current ref, and is idempotent for the same ref. It is bounded:
      behind a call already past admission it answers `{:error,
      :timeout}`, and the request still takes effect, in mailbox order,
      before any later call. The in-flight call keeps running.
    * `Runtime.resolve/1` refuses a held server early, by name or pid.
    * The raw ref never appears in published status.

  Hermetic: the fake CLI under the test launcher; no model call.
  """
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Test.LaunchAdmission

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  describe "a server started held" do
    test "refuses a dequeued call before launch admission" do
      ref = make_ref()
      {:ok, server} = start_server("ready", hold: ref)
      api!(:release_hold, 2)

      assert {:error, :provider_held} = ClaudeCLI.complete(request(), server: server)
      refute_received {:launch_admission, _, _, _}
    end

    test "only the current ref releases it" do
      ref = make_ref()
      {:ok, server} = start_server("ready", hold: ref)
      api!(:release_hold, 2)

      assert {:error, :stale_hold} = ClaudeCLI.release_hold(server, make_ref())
      assert {:error, :provider_held} = ClaudeCLI.complete(request(), server: server)

      assert :ok = ClaudeCLI.release_hold(server, ref)
      assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
      assert result.model == "claude-opus-5-5"
      assert_received {:launch_admission, _, :claude_cli_opus, _}
    end

    test "the raw ref is not published" do
      ref = make_ref()
      {:ok, server} = start_server("ready", hold: ref)
      api!(:release_hold, 2)

      published = inspect({ClaudeCLI.admission(server), ClaudeCLI.attestation(server)})
      refute published =~ inspect(ref)
    end
  end

  describe "hold/2 on a running server" do
    test "is acknowledged, then refuses new calls" do
      {:ok, server} = start_server("ready")
      api!(:hold, 2)
      ref = make_ref()

      assert {:held, ^ref} = ClaudeCLI.hold(server, ref)
      assert {:held, ^ref} = ClaudeCLI.hold(server, ref), "the same ref is idempotent"
      assert {:error, :provider_held} = ClaudeCLI.complete(request(), server: server)
      refute_received {:launch_admission, _, _, _}
    end

    test "a new ref replaces the old one; the old ref can't release it" do
      old = make_ref()
      {:ok, server} = start_server("ready", hold: old)
      api!(:hold, 2)
      new = make_ref()

      assert {:held, ^new} = ClaudeCLI.hold(server, new)
      assert {:error, :stale_hold} = ClaudeCLI.release_hold(server, old)
      assert {:error, :provider_held} = ClaudeCLI.complete(request(), server: server)

      assert :ok = ClaudeCLI.release_hold(server, new)
      assert {:ok, _} = ClaudeCLI.complete(request(), server: server)
    end

    test "a server that is not running answers an error" do
      api!(:hold, 2)
      {:ok, server} = start_server("ready")
      GenServer.stop(server)

      assert {:error, :not_running} = ClaudeCLI.hold(server, make_ref())
      assert {:error, :not_running} = ClaudeCLI.release_hold(server, make_ref())
    end

    test "behind an in-flight call it is bounded, takes effect in order, and the call finishes" do
      dump = Path.join(System.tmp_dir!(), "sdr-claude-hold-#{System.unique_integer([:positive])}")
      on_exit(fn -> dump |> Kernel.<>(".*") |> Path.wildcard() |> Enum.each(&File.rm/1) end)
      {:ok, server} = start_server("env_dump", [], args: [dump, "600"])
      api!(:hold, 3)

      in_flight = Task.async(fn -> ClaudeCLI.complete(request(), server: server) end)
      assert_receive {:launch_admission, _, _, _}, 10_000

      ref = make_ref()
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = ClaudeCLI.hold(server, ref, 100)
      assert System.monotonic_time(:millisecond) - started < 400

      assert {:ok, _} = Task.await(in_flight, 10_000),
             "a call already past admission keeps running"

      assert {:error, :provider_held} = ClaudeCLI.complete(request(), server: server),
             "the timed-out request still holds the server before any later call"

      assert {:held, ^ref} = ClaudeCLI.hold(server, ref)
      assert :ok = ClaudeCLI.release_hold(server, ref)
      assert {:ok, _} = ClaudeCLI.complete(request(), server: server)
    end
  end

  describe "Runtime.resolve/1" do
    test "refuses a held server early, by name and by pid" do
      ref = make_ref()

      server =
        start_supervised!(
          {ClaudeCLI, base_opts("ready") |> Keyword.merge(name: ClaudeCLI.server(), hold: ref)}
        )

      api!(:release_hold, 2)

      assert {:error, :provider_held} = Runtime.resolve(provider: ClaudeCLI)

      assert {:error, :provider_held} =
               Runtime.resolve(provider: ClaudeCLI, provider_options: [server: server])

      assert :ok = ClaudeCLI.release_hold(ClaudeCLI.server(), ref)
      assert {:ok, _model} = Runtime.resolve(provider: ClaudeCLI)
    end

    test "names the refusal without a model call" do
      Code.ensure_loaded!(Runtime)

      message =
        try do
          Runtime.refusal_message(:provider_held)
        rescue
          FunctionClauseError -> nil
        end

      assert is_binary(message), "C2-02b2α: no refusal message for :provider_held"
      assert message =~ "no model call was made"
    end
  end

  defp api!(fun, arity) do
    Code.ensure_loaded!(ClaudeCLI)

    assert function_exported?(ClaudeCLI, fun, arity),
           "C2-02b2α: ClaudeCLI.#{fun}/#{arity} is not implemented"
  end

  defp base_opts(mode, extra_args \\ []) do
    [
      command: System.find_executable("elixir"),
      test_launcher: true,
      launch_admission: LaunchAdmission.recording(self()),
      command_args: [@fake, mode | extra_args]
    ]
  end

  defp start_server(mode, opts \\ [], extra \\ []) do
    mode
    |> base_opts(Keyword.get(extra, :args, []))
    |> Keyword.merge(opts)
    |> ClaudeCLI.start_link()
  end

  defp request do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %{
      id: "claude-hold-test",
      operation: "model.complete",
      prompt: "qualify",
      schema: @schema,
      witness: %{
        model_invocation_id: Ash.UUIDv7.generate(),
        traceparent: "00-#{trace}-#{span}-01"
      }
    }
  end
end
