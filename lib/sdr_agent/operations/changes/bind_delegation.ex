defmodule SdrAgent.Operations.Changes.BindDelegation do
  @moduledoc """
  `PrototypeDelegation` create change (interfaces r6 IF-3): forces
  `binding_id`, `tenant_id` and `operator_user_id` from the singleton
  prototype binding row, read by the audit kernel inside the action's
  transaction (`from: :row`, setup phase 2's `:create_setup`, which runs in
  the same transaction that created the binding). The caller never supplies
  them: the action accepts only `agent` and `session_correlation`, and the
  composite foreign key refuses any other anchor.

  With `from: :snapshot` (`:enter`, called only by
  `SdrAgent.Prototype.enter_session/2`) they come from the boot snapshot
  (`SdrAgent.Prototype.binding/0`) instead.

  No binding row, more than one, or no boot snapshot is an error on the
  changeset; nothing is written. Both run in `before_action`, after
  authorization.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations.PrototypeDatabaseBinding

  @compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)

  @impl true
  def change(changeset, opts, _context) do
    case Keyword.fetch!(opts, :from) do
      :row ->
        Ash.Changeset.before_action(changeset, &from_row/1)

      :snapshot ->
        Ash.Changeset.before_action(changeset, &from_snapshot/1)
    end
  end

  # The boot snapshot exists only in a build with the prototype authority;
  # any other build (production) has none, so `:snapshot` always errors.
  if @compiled do
    defp from_snapshot(changeset) do
      case SdrAgent.Prototype.Authority.binding() do
        {:ok, snapshot} ->
          force(changeset, snapshot.id, snapshot.tenant_id, snapshot.operator_user_id)

        _not_prototype ->
          no_snapshot(changeset)
      end
    end
  else
    defp from_snapshot(changeset), do: no_snapshot(changeset)
  end

  defp no_snapshot(changeset),
    do: Ash.Changeset.add_error(changeset, field: :binding_id, message: "no boot snapshot")

  defp force(changeset, binding_id, tenant_id, operator_user_id) do
    changeset
    |> Ash.Changeset.force_change_attribute(:binding_id, binding_id)
    |> Ash.Changeset.force_change_attribute(:tenant_id, tenant_id)
    |> Ash.Changeset.force_change_attribute(:operator_user_id, operator_user_id)
  end

  defp from_row(changeset) do
    PrototypeDatabaseBinding
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.Query.limit(2)
    |> Ash.read()
    |> case do
      {:ok, [binding]} ->
        force(changeset, binding.id, binding.tenant_id, binding.operator_user_id)

      _none_or_many ->
        Ash.Changeset.add_error(changeset,
          field: :binding_id,
          message: "no single prototype binding"
        )
    end
  end
end
