defmodule SdrAgent.AI.ClaudeCLIClockFromTest do
  @moduledoc """
  R0-07 packet 8.14.10 (contract PASS at 2b454d5): the test-seam ClaudeCLI
  start option `clock_from: pid`. The server follows that process's clock
  from `init/1` on, before its first attestation note; without the option
  it reads its own clock, as today. A malformed value refuses the start.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Clock

  @frozen ~U[2026-10-15 12:00:00.000000Z]

  setup do
    assert function_exported?(Clock, :follow, 1), "Clock.follow/1 is not defined"
    Clock.freeze(@frozen)
    on_exit(&Clock.unfreeze/0)
    :ok
  end

  test "with clock_from, the first attestation is stamped with the followed time" do
    # Reading it live (not a copy taken at init) is pinned by the Clock
    # tests and by calibrate's launch-boundary test.
    server = start!(clock_from: self())
    assert ClaudeCLI.attestation(server).at == @frozen
  end

  test "without clock_from, the server reads its own clock" do
    server = start!([])
    refute ClaudeCLI.attestation(server).at == @frozen
  end

  test "a malformed clock_from refuses the start" do
    for bad <- [:me, "pid", 42] do
      assert {:error, _reason} = start(clock_from: bad), inspect(bad)
    end
  end

  ## Fixtures

  defp start!(opts) do
    {:ok, server} = start(opts)
    server
  end

  defp start(opts) do
    opts = Keyword.merge([profile: :claude_cli_opus, command: "/usr/bin/true"], opts)

    capture_log(fn ->
      send(
        self(),
        {:started, start_supervised(%{id: make_ref(), start: {ClaudeCLI, :start_link, [opts]}})}
      )
    end)

    receive do
      {:started, {:ok, server}} -> {:ok, server}
      {:started, {:error, reason}} -> {:error, reason}
    end
  end
end
