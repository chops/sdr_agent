defmodule SdrAgent.AI.ClaudeCLIPostSpawnTest do
  @moduledoc """
  R0-07 slice E integration review (Codex, 524ba3f): a failure after
  `Port.open` has started a process is never a known no-spawn failure.
  Once the port is open the launch is tracked, the call's outcome is
  unknown (`{:unknown, :post_spawn_failure}`), and the tree is stopped and
  confirmed gone before admission reopens. Only a failure of `Port.open`
  itself is `{:error, {:launch_failed, _}}` (the calibration outcome map
  reads that as `launch_failed`). Hermetic: the fake CLI in `hang` mode, no
  model call.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  test "a failure after the port opened is unknown, and the tree is stopped", %{tmp_dir: tmp} do
    parent = self()

    hook = fn os_pid ->
      send(parent, {:spawned, os_pid})
      raise "synthetic post-spawn failure"
    end

    {:ok, server} =
      ClaudeCLI.start_link(
        command: System.find_executable("elixir"),
        test_launcher: true,
        command_args: [@fake, "hang", Path.join(tmp, "hang")],
        launch_admission: &SdrAgent.Test.LaunchAdmission.admitted/3,
        reaper: [on_open: hook]
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    result = ClaudeCLI.complete(request(), server: server)
    assert_receive {:spawned, os_pid}, 5_000

    try do
      refute match?({:error, {:launch_failed, _}}, result),
             "a process was started, so this is not a known no-spawn: #{inspect(result)}"

      assert result == {:unknown, :post_spawn_failure}
      refute Reaper.alive?(os_pid), "the started tree must be stopped before the call returns"
      assert ClaudeCLI.admission(server) == %{admission: :open}
    after
      if Reaper.alive?(os_pid), do: Reaper.kill_tree(os_pid)
    end
  end

  defp request do
    %{
      id: "post-spawn",
      operation: "model.complete",
      prompt: "synthetic",
      schema: Zoi.object(%{answer: Zoi.string()}),
      witness: %{
        model_invocation_id: Ash.UUIDv7.generate(),
        traceparent: "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
      }
    }
  end
end
