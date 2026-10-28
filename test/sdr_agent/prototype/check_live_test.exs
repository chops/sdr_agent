defmodule SdrAgent.Prototype.CheckLiveTest do
  @moduledoc """
  IF-1 `check_live/0` (interfaces r6; F1): one plain read of the singleton
  row and the live identity, compared field by field with the boot
  snapshot; any difference, missing row or exception is
  `{:error, :binding_mismatch}`. Also the two S1 boundary rows: the operator
  action check and the task entry.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Checks.OperatorAction

  test "an exact binding is :ok" do
    bound!()
    assert Prototype.check_live() == :ok
  end

  test "any snapshot field differing from the row is a mismatch" do
    fx = bound!()

    changes = [
      id: Ecto.UUID.generate(),
      tenant_id: Ecto.UUID.generate(),
      instance_id: Ecto.UUID.generate(),
      operator_user_id: Ecto.UUID.generate(),
      auditor_user_id: Ecto.UUID.generate(),
      policy_entry_sha256: String.duplicate("0", 64),
      database_oid: fx.snapshot.database_oid + 1,
      system_identifier: fx.snapshot.system_identifier + 1,
      bound_at: DateTime.add(fx.snapshot.bound_at, 1, :second)
    ]

    for {field, value} <- changes do
      assert PrototypeFixtures.enter_runtime(Map.put(fx.snapshot, field, value)) == :ok

      assert Prototype.check_live() == {:error, :binding_mismatch},
             "a snapshot differing in #{field} was accepted"
    end
  end

  test "a live identity differing from the row is a mismatch, and an exception denies" do
    bound!()

    for overrides <- [
          %{database: "sdr_agent_dev"},
          %{database_oid: 1},
          %{system_identifier: 42},
          :raise
        ] do
      assert PrototypeFixtures.put_live_identity(overrides) == :ok

      assert Prototype.check_live() == {:error, :binding_mismatch},
             "live identity #{inspect(overrides)} was accepted"
    end
  end

  test "a snapshot with no bound row is a mismatch" do
    fx = bound!(enter_runtime: false)
    assert PrototypeFixtures.enter_runtime(%{fx.snapshot | id: Ecto.UUID.generate()}) == :ok
    assert Prototype.check_live() == {:error, :binding_mismatch}
  end

  describe "S1 boundary rows" do
    test "an operator action is forbidden on a live mismatch" do
      fx = bound!()
      assert OperatorAction.match?(fx.actor, %{subject: nil}, action: :assign)
      assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok
      refute OperatorAction.match?(fx.actor, %{subject: nil}, action: :assign)
    end

    test "the operator check refuses an action atom outside the closed list" do
      fx = bound!()
      refute OperatorAction.match?(fx.actor, %{subject: nil}, action: :administer)
    end

    test "the task entry refuses with :binding_mismatch" do
      bound!()
      assert PrototypeFixtures.put_live_identity(%{system_identifier: 7}) == :ok

      assert Prototype.enter_session(:claude_code, "task-entry-0001") ==
               {:error, :binding_mismatch}
    end
  end
end
