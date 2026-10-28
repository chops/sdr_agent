defmodule SdrAgent.Prototype.DelegationTest do
  @moduledoc """
  IF-3 session delegation (interfaces r6; F1): `enter_session/2` is the only
  creator; `:enter` accepts only the agent and the correlation; the
  composite foreign key refuses any other anchor; a replay returns the
  existing id; the table is create-only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype

  @delegation SdrAgent.Operations.PrototypeDelegation

  defp delegations(binding_id) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM prototype_delegations WHERE binding_id = $1", [
        Ecto.UUID.dump!(binding_id)
      ])

    n
  end

  describe "enter_session/2" do
    test "creates one D-243 delegation from the boot snapshot, and a replay returns its id" do
      fx = bound!()
      before = delegations(fx.binding.id)

      assert {:ok, id} = Prototype.enter_session(:codex_cli, "codex-session:0001")
      assert Prototype.enter_session(:codex_cli, "codex-session:0001") == {:ok, id}
      assert delegations(fx.binding.id) == before + 1

      %{rows: [[binding_id, tenant_id, operator_user_id, ref, agent, correlation]]} =
        Repo.query!(
          "SELECT binding_id, tenant_id, operator_user_id, delegation_ref, agent, " <>
            "session_correlation FROM prototype_delegations WHERE id = $1",
          [Ecto.UUID.dump!(id)]
        )

      assert Ecto.UUID.cast!(binding_id) == fx.binding.id
      assert Ecto.UUID.cast!(tenant_id) == fx.tenant.id
      assert Ecto.UUID.cast!(operator_user_id) == fx.anchor.id
      assert {ref, agent, correlation} == {"D-243", "codex_cli", "codex-session:0001"}

      assert Prototype.operator_actor(id) ==
               {:ok, %SdrAgent.Actor{type: :prototype_operator, id: id, tenant_id: fx.tenant.id}}

      assert [_] =
               events_of_type(fx.tenant, "prototype.delegation.created")
               |> Enum.filter(&(&1.subject_id == id))
    end

    test "refuses an unknown agent and a malformed correlation" do
      bound!()
      assert Prototype.enter_session(:other_agent, "session-valid-01") == {:error, :invalid_agent}

      for bad <- ["short", String.duplicate("a", 129), "has space 123", "semi;colon-123", nil] do
        assert Prototype.enter_session(:claude_code, bad) == {:error, :invalid_correlation},
               "correlation #{inspect(bad)} was accepted"
      end
    end

    test "refuses with :binding_mismatch when the live identity differs" do
      bound!()
      assert PrototypeFixtures.put_live_identity(%{database_oid: 1}) == :ok

      assert Prototype.enter_session(:claude_code, "session-valid-02") ==
               {:error, :binding_mismatch}
    end
  end

  # The unique-race mechanism, proved apart from the replay count (Codex
  # ca4624a1 A) with two test-seam keys of the authority, read only in a
  # test-seam build: one makes the in-transaction lookup miss an existing
  # session (a competitor that committed after the lookup), the other runs
  # a hook just before the create. No external concurrency run.
  describe "enter_session/2 unique race" do
    @authority SdrAgent.Prototype.Authority

    defp created_events(tenant),
      do: length(events_of_type(tenant, "prototype.delegation.created"))

    test "a unique conflict re-reads after the rollback and returns the existing id, writing nothing" do
      fx = bound!()
      first = Prototype.enter_session(:codex_cli, "codex-session:race-0001")
      assert match?({:ok, _id}, first), "prerequisite: first session: #{inspect(first)}"
      {:ok, id} = first
      rows_before = delegations(fx.binding.id)
      events_before = created_events(fx.tenant)

      Process.put({@authority, :miss_session_lookup}, true)
      result = Prototype.enter_session(:codex_cli, "codex-session:race-0001")

      assert result == {:ok, id}, "conflict re-read: #{inspect(result)}"
      assert delegations(fx.binding.id) == rows_before
      assert created_events(fx.tenant) == events_before
    end

    test "an unrelated failure after the lookup is never taken for a replay" do
      fx = bound!()
      first = Prototype.enter_session(:codex_cli, "codex-session:race-0002")
      assert match?({:ok, _id}, first), "prerequisite: first session: #{inspect(first)}"
      rows_before = delegations(fx.binding.id)
      events_before = created_events(fx.tenant)

      Process.put({@authority, :miss_session_lookup}, true)

      Process.put({@authority, :before_session_create}, fn _snapshot ->
        Repo.rollback(:injected)
      end)

      result = Prototype.enter_session(:codex_cli, "codex-session:race-0002")

      assert result == {:error, :binding_mismatch}, "unrelated failure: #{inspect(result)}"
      assert delegations(fx.binding.id) == rows_before
      assert created_events(fx.tenant) == events_before
    end
  end

  # Codex a95a89fb R1: a nested Audit.transaction is a plain nested
  # Repo.transaction, not a savepoint, so the recovery path cannot run
  # inside a caller's transaction. The entry refuses an already-open
  # transaction early: a fixed code, no query, no write, and the caller's
  # transaction stays usable.
  describe "enter_session/2 inside an already-open transaction" do
    @authority SdrAgent.Prototype.Authority

    defp in_outer_transaction(fun) do
      SdrAgent.Audit.transaction(fn ->
        inner = fun.()
        {inner, Repo.query("SELECT 1")}
      end)
    end

    test "with a forced lookup miss on an existing session: refused early, the outer transaction usable" do
      fx = bound!()
      first = Prototype.enter_session(:codex_cli, "codex-session:nested-0001")
      assert match?({:ok, _id}, first), "prerequisite: first session: #{inspect(first)}"
      rows_before = delegations(fx.binding.id)
      events_before = length(events_of_type(fx.tenant, "prototype.delegation.created"))

      Process.put({@authority, :miss_session_lookup}, true)

      outer =
        in_outer_transaction(fn ->
          Prototype.enter_session(:codex_cli, "codex-session:nested-0001")
        end)

      assert match?({:ok, {{:error, :binding_mismatch}, {:ok, %{rows: [[1]]}}}}, outer),
             "nested entry: #{inspect(outer)}"

      assert delegations(fx.binding.id) == rows_before
      assert length(events_of_type(fx.tenant, "prototype.delegation.created")) == events_before
    end

    test "a new session inside an open transaction is refused early, writing nothing" do
      fx = bound!()
      rows_before = delegations(fx.binding.id)

      outer =
        in_outer_transaction(fn ->
          Prototype.enter_session(:codex_cli, "codex-session:nested-0002")
        end)

      assert match?({:ok, {{:error, :binding_mismatch}, {:ok, %{rows: [[1]]}}}}, outer),
             "nested new entry: #{inspect(outer)}"

      assert delegations(fx.binding.id) == rows_before
    end
  end

  describe "the setup-only and task-entry actions" do
    test ":enter and :create_setup are refused for an operator, a user and an auditor" do
      fx = bound!(auditor: true, enter_runtime: false)
      admin = human(:admin, fx.tenant)
      enter!(fx)
      loaded!(@delegation)

      for action <- [:enter, :create_setup], actor <- [fx.actor, admin, fx.auditor, fx.anchor] do
        result =
          @delegation
          |> Ash.Changeset.for_create(
            action,
            %{agent: "claude_code", session_correlation: "forged-session-01"},
            actor: actor
          )
          |> Ash.create()

        assert match?({:error, %Ash.Error.Forbidden{}}, result),
               "#{action} by #{inspect(actor.__struct__)} was not forbidden: #{inspect(result)}"
      end
    end

    test ":enter accepts no binding, tenant or anchor input" do
      fx = bound!(enter_runtime: false)
      other = human(:reviewer, fx.tenant)
      enter!(fx)
      loaded!(@delegation)
      accepted = Ash.Resource.Info.action(@delegation, :enter).accept
      assert Enum.sort(accepted) == [:agent, :session_correlation]

      result =
        @delegation
        |> Ash.Changeset.for_create(
          :enter,
          %{
            agent: "claude_code",
            session_correlation: "forged-anchor-01",
            operator_user_id: other.id
          },
          actor: fx.actor
        )
        |> Ash.create()

      assert match?({:error, _}, result), "an :enter with an operator_user_id input succeeded"
    end

    test "the composite foreign key refuses a delegation naming another anchor" do
      fx = bound!(enter_runtime: false)
      other = human(:reviewer, fx.tenant)
      enter!(fx)

      result =
        raw_error(
          "INSERT INTO prototype_delegations (id, tenant_id, binding_id, operator_user_id, " <>
            "delegation_ref, agent, session_correlation, started_at, trace_id, span_id) VALUES " <>
            "($1, $2, $3, $4, 'D-243', 'claude_code', 'forged-anchor-02', now(), $5, $6)",
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(fx.tenant.id),
            Ecto.UUID.dump!(fx.binding.id),
            Ecto.UUID.dump!(other.id),
            String.duplicate("a", 32),
            String.duplicate("b", 16)
          ]
        )

      assert match?({:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}}, result),
             "a delegation naming another anchor was not refused: #{inspect(result)}"
    end

    test "delegations and the binding are create-only" do
      fx = bound!()

      for {table, id} <- [
            {"prototype_delegations", fx.delegation.id},
            {"prototype_database_bindings", fx.binding.id}
          ] do
        update = raw_error("UPDATE #{table} SET id = id WHERE id = $1", [Ecto.UUID.dump!(id)])
        delete = raw_error("DELETE FROM #{table} WHERE id = $1", [Ecto.UUID.dump!(id)])

        for {op, result} <- [update: update, delete: delete] do
          assert match?(
                   {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}},
                   result
                 ),
                 "#{op} on #{table} was not refused: #{inspect(result)}"
        end
      end
    end
  end
end
