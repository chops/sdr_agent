defmodule SdrAgent.Prototype.TransportTest do
  @moduledoc """
  The D-237 S1 transport delta (Codex sequencing ruling 22d1b279; the S1
  pending items 1 and 3), structurally:

  - `ModelInvocation :reserve` accepts the argument `prototype_authority`
    (a map) and lists it in the `model.invocation.reserved` event's
    argument allowlist; no attribute (no persisted column) is added;
  - `ModelResultRelease.gate_classifications/0` gains `:reconciled`, last,
    for the prototype gate's `witness_mode_mismatch` refusal of a reconciled
    receipt (Codex 2c9450b7 ruling 3b).

  These are presence checks only. The refusal of a caller-supplied
  authority, the server-derived authority on the one original reservation
  event, and the classification's restriction are S2's behaviour, proven
  by S2's tests; nothing here exercises them.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Audit.Changes.AppendEvent

  defp reserved_event_options do
    ModelInvocation
    |> Ash.Resource.Info.action(:reserve)
    |> Map.fetch!(:changes)
    |> Enum.find_value(fn
      %{change: {AppendEvent, opts}} ->
        if opts[:event_type] == "model.invocation.reserved", do: opts

      _other ->
        nil
    end)
  end

  describe "ModelInvocation :reserve" do
    test "accepts the argument prototype_authority as a map" do
      argument =
        ModelInvocation
        |> Ash.Resource.Info.action(:reserve)
        |> Map.fetch!(:arguments)
        |> Enum.find(&(&1.name == :prototype_authority))

      assert argument, ":reserve has no prototype_authority argument"
      assert argument.type == Ash.Type.Map
    end

    test "records it in the model.invocation.reserved event's argument allowlist" do
      opts = reserved_event_options()
      assert opts, "no model.invocation.reserved AppendEvent change on :reserve"

      assert opts[:arguments] == [
               :calibration_tuple,
               :calibration_claim,
               :calibration_binding,
               :prototype_authority
             ]
    end

    test "persists no prototype_authority attribute" do
      assert Ash.Resource.Info.attribute(ModelInvocation, :prototype_authority) == nil
    end
  end

  test "the gate classifications gain :reconciled, last" do
    assert ModelResultRelease.gate_classifications() == [
             :mismatch,
             :store_unconfigured,
             :store_unreadable,
             :capture_pending,
             :method_not_enabled,
             :ambiguous,
             :unclassified,
             :unsupported,
             :no_exchange,
             :inferred,
             :interrupted,
             :reconciled
           ]
  end
end
