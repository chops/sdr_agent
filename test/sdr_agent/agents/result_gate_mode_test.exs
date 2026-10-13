defmodule SdrAgent.Agents.ResultGateModeTest do
  @moduledoc """
  R0-07 slice C, the seam for slice B's row B3 (accepted, round 8): the
  result gate's mode is compiled into `SdrAgent.Agents.ResultGate`
  (default `:enforced`, set by no config file), and `active?/0` is true
  only for `:enforced`. Slice B's admission refuses every generation-2
  real call while the gate is inactive; that refusal and its refuse-only
  test seam belong to slice B.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.ResultGate

  test "the test build compiles the enforced gate" do
    assert ResultGate.mode() == :enforced
    assert ResultGate.active?()
  end

  test "no config file sets the gate mode" do
    for path <- Path.wildcard(Path.expand("../../../config/*.exs", __DIR__)) do
      # Any `config ... SdrAgent.Agents.ResultGate, ...` stanza naming `mode:`.
      refute File.read!(path) =~ ~r/Agents\.ResultGate,(?:(?!\nconfig ).)*\bmode:/s, path
    end
  end
end
