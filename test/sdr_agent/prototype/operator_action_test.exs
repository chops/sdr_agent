defmodule SdrAgent.Prototype.OperatorActionTest do
  @moduledoc """
  `SdrAgent.Prototype.Checks.OperatorAction` (interfaces r6 IF-3), directly:
  the policy check every prototype operator action goes through.

  - The real bound operator actor passes for each atom of the closed list
    (`actions/0`), in prototype runtime with the exact live binding.
  - It re-resolves on every call (no cached boolean): a live mismatch
    refuses, and the exact snapshot passes again.
  - It refuses an atom outside the list and a missing option; a human, a
    kernel actor, a forged operator id, the operator's id under another
    tenant, a plain map and nil; and the real operator actor in ordinary
    runtime.

  The live mismatch is a snapshot changed in one field, entered through
  the seam (no live-identity override). Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Prototype.Checks.OperatorAction

  @authorizer %{subject: nil}

  defp passes?(actor, opts), do: OperatorAction.match?(actor, @authorizer, opts)

  test "the bound operator passes for every action of the closed list" do
    fx = bound!()

    for action <- OperatorAction.actions() do
      assert passes?(fx.actor, action: action), "the operator was refused #{inspect(action)}"
    end
  end

  test "it re-resolves on every call: a live mismatch refuses, the exact snapshot passes again" do
    fx = bound!()
    assert passes?(fx.actor, action: :assign), "the operator was refused :assign"

    enter!(%{snapshot: %{fx.snapshot | database_oid: fx.snapshot.database_oid + 1}})
    refute passes?(fx.actor, action: :assign), "a live mismatch was accepted"

    enter!(fx)
    assert passes?(fx.actor, action: :assign), "the exact snapshot was refused again"
  end

  test "an atom outside the closed list or a missing option is refused" do
    fx = bound!()

    for opts <- [[action: :administer], [action: "assign"], []] do
      refute passes?(fx.actor, opts), "#{inspect(opts)} was accepted"
    end
  end

  test "anything but the real operator actor is refused" do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    enter!(fx)

    refused = [
      admin: admin,
      kernel: system_actor(:kernel, fx.tenant),
      forged_operator: %Actor{
        type: :prototype_operator,
        id: Ecto.UUID.generate(),
        tenant_id: fx.tenant.id
      },
      other_tenant: %{fx.actor | tenant_id: Ecto.UUID.generate()},
      wrong_type: %{fx.actor | type: :agent_runtime},
      plain_map: Map.from_struct(fx.actor),
      nil: nil
    ]

    for {name, actor} <- refused, action <- [:assign, :review_read] do
      refute passes?(actor, action: action), "#{name} passed #{inspect(action)}"
    end
  end

  test "the real operator actor is refused in ordinary runtime" do
    fx = bound!()
    assert PrototypeFixtures.leave_runtime() == :ok
    refute passes?(fx.actor, action: :assign), "ordinary runtime accepted the operator"
  end
end
