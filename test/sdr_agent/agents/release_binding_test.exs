defmodule SdrAgent.Agents.ReleaseBindingTest do
  @moduledoc """
  R0-07 slice C, round-7 obligation 1 (packet section 7): a withheld
  release's gate cause is read from exactly its original
  `model.result.withheld` event, scoped by tenant, resource, release and
  event type. A missing, duplicate or malformed event is not evidence that
  the cause was absent: `{:error, :binding_unavailable}`. A nil or absent
  argument on a valid original event is the legitimate no-cause case.
  """
  use SdrAgent.AuditCase, async: true

  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ReleaseDecision.Binding

  @cause "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

  defp event(arguments), do: %{payload: %{"arguments" => arguments}}

  describe "from_events/1" do
    test "a valid original event binds its cause, or legitimately none" do
      assert Binding.from_events([event(%{"gate_cause_id" => @cause})]) == {:ok, @cause}
      assert Binding.from_events([event(%{"gate_cause_id" => nil})]) == {:ok, nil}
      assert Binding.from_events([event(%{"reason" => "witness_missing"})]) == {:ok, nil}
    end

    test "a missing, duplicate or malformed event fails closed" do
      for {label, events} <- [
            {"missing", []},
            {"duplicate", [event(%{}), event(%{})]},
            {"no arguments", [%{payload: %{}}]},
            {"arguments not a map", [event(["gate_cause_id"])]},
            {"cause not a uuid", [event(%{"gate_cause_id" => "not-a-uuid"})]},
            {"cause not a string", [event(%{"gate_cause_id" => 7})]}
          ] do
        assert Binding.from_events(events) == {:error, :binding_unavailable}, label
      end
    end
  end

  test "a withheld release with no original event is unavailable, not absent" do
    tenant = bootstrap!()

    release = %ModelResultRelease{
      id: Ecto.UUID.generate(),
      tenant_id: tenant.id,
      disposition: :withheld
    }

    assert Binding.bound_cause(release) == {:error, :binding_unavailable}
  end

  test "a non-withheld release binds no cause" do
    assert Binding.bound_cause(%ModelResultRelease{disposition: :released}) == {:ok, nil}
  end
end
