defmodule SdrAgent.Operations.Changes.BindDelegation do
  @moduledoc """
  `PrototypeDelegation` create change (interfaces r6 IF-3): forces
  `binding_id`, `tenant_id` and `operator_user_id` from the singleton
  prototype binding row, read by the audit kernel inside the action's
  transaction (`from: :row`, setup phase 2's `:create_setup`, which runs in
  the same transaction that created the binding). The caller never supplies
  them: the action accepts only `agent` and `session_correlation`, and the
  composite foreign key refuses any other anchor.

  No binding row, or more than one, is an error on the changeset; nothing
  is written.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.PrototypeDatabaseBinding

  @impl true
  def change(changeset, opts, _context) do
    case Keyword.fetch!(opts, :from) do
      :row ->
        Ash.Changeset.before_action(changeset, &from_row/1)
    end
  end

  defp from_row(changeset) do
    PrototypeDatabaseBinding
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.Query.limit(2)
    |> Ash.read()
    |> case do
      {:ok, [binding]} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:binding_id, binding.id)
        |> Ash.Changeset.force_change_attribute(:tenant_id, binding.tenant_id)
        |> Ash.Changeset.force_change_attribute(:operator_user_id, binding.operator_user_id)

      _none_or_many ->
        Ash.Changeset.add_error(changeset,
          field: :binding_id,
          message: "no single prototype binding"
        )
    end
  end
end
