defmodule SdrAgent.Prototype.PrincipalTest do
  @moduledoc """
  IF-1 operator resolver and IF-3 machine principal (interfaces r6; F1):
  the seven-step resolver, actor-struct forgery, audit identity of operator
  events and accesses, and the database's password-role rule.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Prototype

  @authority SdrAgent.Prototype.Authority

  test "the system actor types include :prototype_operator" do
    assert :prototype_operator in Actor.types()
  end

  describe "operator_actor/1" do
    test "resolves the delegation to the operator actor of the binding's tenant" do
      fx = bound!()

      assert Prototype.operator_actor(fx.delegation.id) ==
               {:ok,
                %Actor{type: :prototype_operator, id: fx.delegation.id, tenant_id: fx.tenant.id}}
    end

    test "an unknown delegation is :delegation_not_found" do
      bound!()
      assert Prototype.operator_actor(Ecto.UUID.generate()) == {:error, :delegation_not_found}
    end

    test "steps 4-6 refuse a foreign-tenant, wrong-binding or wrong-anchor delegation" do
      fx = bound!()
      d = fx.delegation

      resolve = fn delegation ->
        call(@authority, :resolve_delegation, [fx.snapshot, delegation])
      end

      assert resolve.(%{d | tenant_id: Ecto.UUID.generate()}) ==
               {:error, :delegation_foreign_tenant}

      assert resolve.(%{d | binding_id: Ecto.UUID.generate()}) ==
               {:error, :delegation_wrong_binding}

      assert resolve.(%{d | operator_user_id: Ecto.UUID.generate()}) == {:error, :anchor_mismatch}
      assert resolve.(nil) == {:error, :delegation_not_found}

      assert resolve.(d) ==
               {:ok, %Actor{type: :prototype_operator, id: d.id, tenant_id: fx.tenant.id}}
    end
  end

  describe "operator?/1" do
    test "true only for a resolvable delegation id with the binding's tenant" do
      fx = bound!()
      assert Prototype.operator?(fx.actor)

      forged = %Actor{
        type: :prototype_operator,
        id: Ecto.UUID.generate(),
        tenant_id: fx.tenant.id
      }

      refute Prototype.operator?(forged)

      tampered = %{fx.actor | tenant_id: Ecto.UUID.generate()}
      refute Prototype.operator?(tampered)

      wrong_type = %{fx.actor | type: :agent_runtime}
      refute Prototype.operator?(wrong_type)
      refute Prototype.operator?(fx.anchor)
    end
  end

  describe "audit identity" do
    test "an operator event records actor type prototype_operator and the delegation id" do
      fx = bound!()

      result =
        SdrAgent.Audit.append(
          %{event_type: "test.prototype.operator_event", category: :domain_change},
          actor: fx.actor
        )

      assert match?({:ok, _}, result), "operator event refused: #{inspect(result)}"
      {:ok, event} = result
      assert event.actor_type == :prototype_operator
      assert event.actor_id == fx.delegation.id
      assert event.actor_role == nil
    end

    test "an operator access records actor type prototype_operator" do
      fx = bound!()

      result =
        SdrAgent.Audit.record_access(:payload_view, "Test", "ref-1", "d237_test", actor: fx.actor)

      assert match?({:ok, _}, result), "operator access refused: #{inspect(result)}"
      {:ok, access} = result
      assert access.actor_type == :prototype_operator
      assert access.actor_id == fx.delegation.id
    end
  end

  describe "the anchor's database rules" do
    # The password-role CHECK of IF-3: (role = 'agent_operator') = (hashed_password IS NULL).
    @password_check "users_agent_operator_password"

    test "a passwordless non-anchor user and an anchor with a password violate the password-role CHECK" do
      tenant = bootstrap!()

      insert = fn email, hash, role ->
        raw_error(
          "INSERT INTO users (id, email, hashed_password, role, status, display_name, tenant_id, " <>
            "inserted_at, updated_at) VALUES ($1, $2, $3, $4, 'active', 'Fixture', $5, now(), now())",
          [Ecto.UUID.dump!(Ecto.UUID.generate()), email, hash, role, Ecto.UUID.dump!(tenant.id)]
        )
      end

      passwordless = insert.("nopass@example.test", nil, "reviewer")
      with_password = insert.("anchor2@example.test", "x", "agent_operator")

      for {name, result} <- [passwordless: passwordless, with_password: with_password] do
        assert match?(
                 {:error,
                  %Postgrex.Error{
                    postgres: %{code: :check_violation, constraint: @password_check}
                  }},
                 result
               ),
               "#{name}: expected a #{@password_check} CHECK violation, got #{inspect(result)}"
      end
    end

    test "the anchor is credential-less, of role :agent_operator, at the fixed address" do
      fx = bound!()
      assert fx.anchor.role == :agent_operator
      assert to_string(fx.anchor.email) == "d237-operator@prototype.invalid"

      %{rows: [[hash]]} =
        Repo.query!("SELECT hashed_password FROM users WHERE id = $1", [
          Ecto.UUID.dump!(fx.anchor.id)
        ])

      assert hash == nil
    end
  end
end
