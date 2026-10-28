defmodule SdrAgent.Prototype.BindPathDenialTest do
  @moduledoc """
  The fail-closed contracts of the live check and the operator resolver
  (interfaces r6 IF-1), reached directly before any positive authority
  (Codex 5ede3806 must-fix): no `bind/1`, no successful resolver.

  - `check_live/0` is `{:error, :binding_mismatch}` for a snapshot that
    differs from the real bootstrap row in any one field, and, with no
    binding row at all, for an independent synthetic snapshot.
  - `resolve_delegation/2` refuses nil with `:delegation_not_found` and
    test-only in-memory COPIES of the real setup delegation, each with one
    field changed, with the distinct codes `:delegation_foreign_tenant`,
    `:delegation_wrong_binding` and `:anchor_mismatch`; nothing is written
    and no event is appended. (The copies are adversarial resolver inputs,
    never persisted.)
  - `operator_actor/1` is `:delegation_not_found` for an unknown or a
    malformed id, and `:binding_mismatch` on a live mismatch.
  - `operator?/1` is false for a wrong type, tenant or id, a malformed id,
    a plain map and nil.

  Snapshots entered here are built by the test from the row's own fields,
  independently of `snapshot/1`. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Binding

  @authority SdrAgent.Prototype.Authority
  @tables ~w(tenants users prototype_database_bindings prototype_delegations)

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  # A real setup phase-2 bootstrap; a failure here is a prerequisite.
  defp bootstrapped! do
    result =
      call(@authority, :bootstrap, [
        [agent: :claude_code, session_correlation: "bind-denial-session-01"]
      ])

    assert match?({:ok, %{binding: %{}, delegation: %{}}}, result),
           "prerequisite: bootstrap returned #{inspect(result)}"

    {:ok, created} = result
    created
  end

  defp row_snapshot(row),
    do: struct!(Binding, Map.new(Binding.fields(), &{&1, Map.fetch!(row, &1)}))

  defp operator(created),
    do: %Actor{type: :prototype_operator, id: created.delegation.id, tenant_id: created.tenant.id}

  describe "check_live/0 fails closed" do
    test "a snapshot differing from the row in any one field is a mismatch" do
      snapshot = bootstrapped!().binding |> row_snapshot()

      changes = [
        id: Ecto.UUID.generate(),
        tenant_id: Ecto.UUID.generate(),
        instance_id: Ecto.UUID.generate(),
        operator_user_id: Ecto.UUID.generate(),
        auditor_user_id: Ecto.UUID.generate(),
        dataset_class: "other_class",
        policy_id: "d237-prototype/2",
        policy_entry_sha256: String.duplicate("0", 64),
        funding_id: "d237-funding/2",
        witness_mode: "present",
        database: "sdr_agent_dev",
        database_oid: snapshot.database_oid + 1,
        system_identifier: snapshot.system_identifier + 1,
        bound_at: DateTime.add(snapshot.bound_at, 1, :second)
      ]

      for {field, value} <- changes do
        enter!(%{snapshot: Map.put(snapshot, field, value)})
        result = Prototype.check_live()

        assert result == {:error, :binding_mismatch},
               "a snapshot differing in #{field}: got #{inspect(result)}"
      end
    end

    test "with no binding row, an independent synthetic snapshot is a mismatch" do
      assert count("prototype_database_bindings") == 0

      synthetic = %Binding{
        id: Ecto.UUID.generate(),
        tenant_id: Ecto.UUID.generate(),
        instance_id: Ecto.UUID.generate(),
        operator_user_id: Ecto.UUID.generate(),
        auditor_user_id: nil,
        dataset_class: "real_prototype",
        policy_id: "d237-prototype/1",
        policy_entry_sha256: String.duplicate("a", 64),
        funding_id: "d237-funding/1",
        witness_mode: "absent",
        database: "sdr_agent_prototype",
        database_oid: 16_384,
        system_identifier: 7_000_000_000_000_000_001,
        bound_at: ~U[2026-10-28 06:00:00.000000Z]
      }

      enter!(%{snapshot: synthetic})
      result = Prototype.check_live()
      assert result == {:error, :binding_mismatch}, "no binding row: got #{inspect(result)}"
    end
  end

  describe "resolve_delegation/2 fails closed" do
    test "nil and each one-field copy of the real delegation get their own code; nothing is written" do
      created = bootstrapped!()
      snapshot = row_snapshot(created.binding)
      delegation = created.delegation
      before_rows = Map.new(@tables, &{&1, count(&1)})
      before_events = length(events(created.tenant))

      # Test-only adversarial inputs: in-memory copies of the real row with
      # one field changed; none is persisted.
      cases = [
        {"nil", nil, :delegation_not_found},
        {"foreign tenant", %{delegation | tenant_id: Ecto.UUID.generate()},
         :delegation_foreign_tenant},
        {"wrong binding", %{delegation | binding_id: Ecto.UUID.generate()},
         :delegation_wrong_binding},
        {"wrong anchor", %{delegation | operator_user_id: Ecto.UUID.generate()}, :anchor_mismatch}
      ]

      for {name, input, code} <- cases do
        result = call(@authority, :resolve_delegation, [snapshot, input])

        assert result == {:error, code},
               "#{name}: expected {:error, #{inspect(code)}}, got #{inspect(result)}"
      end

      assert Map.new(@tables, &{&1, count(&1)}) == before_rows
      assert length(events(created.tenant)) == before_events
    end
  end

  describe "operator_actor/1 fails closed" do
    test "an unknown or a malformed delegation id is :delegation_not_found" do
      created = bootstrapped!()
      enter!(%{snapshot: row_snapshot(created.binding)})

      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        result = Prototype.operator_actor(id)

        assert result == {:error, :delegation_not_found},
               "#{inspect(id)}: got #{inspect(result)}"
      end
    end

    test "a live mismatch refuses the real delegation with :binding_mismatch" do
      created = bootstrapped!()
      snapshot = row_snapshot(created.binding)
      enter!(%{snapshot: %{snapshot | database_oid: snapshot.database_oid + 1}})
      result = Prototype.operator_actor(created.delegation.id)
      assert result == {:error, :binding_mismatch}, "got #{inspect(result)}"
    end
  end

  describe "operator?/1 fails closed" do
    test "false for a wrong type, tenant or id, a malformed id, a plain map and nil" do
      created = bootstrapped!()
      enter!(%{snapshot: row_snapshot(created.binding)})
      actor = operator(created)

      refused = [
        wrong_type: %{actor | type: :kernel},
        wrong_tenant: %{actor | tenant_id: Ecto.UUID.generate()},
        wrong_id: %{actor | id: Ecto.UUID.generate()},
        malformed_id: %{actor | id: "not-a-uuid"},
        plain_map: Map.from_struct(actor),
        nil: nil
      ]

      for {name, candidate} <- refused do
        refute Prototype.operator?(candidate), "#{name} was accepted as the operator"
      end
    end
  end
end
