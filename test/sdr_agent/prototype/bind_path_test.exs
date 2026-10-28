defmodule SdrAgent.Prototype.BindPathTest do
  @moduledoc """
  The steps of the binding fixture's real path (interfaces r6 IF-1, IF-2),
  each reached directly over a real setup phase-2 bootstrap rather than
  through `SdrAgent.PrototypeFixtures.bind/1`, so that one step's absence
  never hides another's (Codex 97b19ad4, B2 dependency order):

  - `Authority.snapshot/1` is the `SdrAgent.Prototype.Binding` of the row,
    field for field, and refuses anything but a binding row;
  - with the row's exact snapshot entered (test seam), `check_live/0` is
    `:ok`, `operator_actor/1` resolves the setup delegation to the operator
    actor of the binding's tenant, and `operator?/1` is true for exactly
    that actor.

  The snapshot entered in the middle three cases is built here from the
  row, independently of `snapshot/1`. Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Binding

  @authority SdrAgent.Prototype.Authority

  setup do
    result =
      call(@authority, :bootstrap, [
        [agent: :claude_code, session_correlation: "bind-path-session-01"]
      ])

    assert match?({:ok, %{binding: %{}, delegation: %{}}}, result),
           "prerequisite: bootstrap returned #{inspect(result)}"

    {:ok, created} = result
    %{created: created}
  end

  # The row's snapshot, built by the test from the row's own fields.
  defp row_snapshot(row),
    do: struct!(Binding, Map.new(Binding.fields(), &{&1, Map.fetch!(row, &1)}))

  # Enters the row's own snapshot (`SdrAgent.PrototypeCase.enter!/1`).
  defp enter_row!(created), do: enter!(%{snapshot: row_snapshot(created.binding)})

  defp operator(created),
    do: %Actor{type: :prototype_operator, id: created.delegation.id, tenant_id: created.tenant.id}

  test "snapshot/1 is the Binding of the row, field for field", %{created: created} do
    assert call(@authority, :snapshot, [created.binding]) == {:ok, row_snapshot(created.binding)}
  end

  test "snapshot/1 refuses anything but a binding row", %{created: created} do
    for other <- [created.delegation, %{}, nil] do
      assert call(@authority, :snapshot, [other]) == {:error, :not_a_binding},
             "snapshot/1 accepted #{inspect(other)}"
    end
  end

  test "with the row's exact snapshot entered, check_live/0 is :ok", %{created: created} do
    enter_row!(created)
    assert Prototype.check_live() == :ok
  end

  test "operator_actor/1 resolves the setup delegation to the operator actor", %{
    created: created
  } do
    enter_row!(created)
    assert Prototype.operator_actor(created.delegation.id) == {:ok, operator(created)}
  end

  test "operator?/1 is true for exactly the resolved actor", %{created: created} do
    enter_row!(created)
    actor = operator(created)
    assert Prototype.operator?(actor)
    refute Prototype.operator?(%{actor | tenant_id: Ecto.UUID.generate()})
    refute Prototype.operator?(%{actor | id: Ecto.UUID.generate()})
  end
end
