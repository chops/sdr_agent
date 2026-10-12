defmodule SdrAgent.Agents.Changes.AdmissionCharge do
  @moduledoc """
  `ModelInvocation :reserve` change (C9): the grant and allocation a call
  is charged to come only from the admission context
  (`SdrAgent.Agents.Checks.AdmissionContext`), never from inputs (the
  action accepts neither). On the cast `provider`:

    * `:claude_cli` — refused (Forbidden) unless the context carries an
      admitted charge, which is then force-set on the row;
    * any other provider — refused (Forbidden) if a charge is present.
  """
  use Ash.Resource.Change

  alias Ash.Error.Forbidden
  alias SdrAgent.Agents.Checks.AdmissionContext

  @impl true
  def change(changeset, _opts, _context) do
    provider = Ash.Changeset.get_attribute(changeset, :provider)

    case {provider, AdmissionContext.charge(changeset.context)} do
      {:claude_cli, %{grant_id: grant_id, allocation_id: allocation_id}} ->
        Ash.Changeset.force_change_attributes(changeset, %{
          grant_id: grant_id,
          allocation_id: allocation_id
        })

      {:claude_cli, _missing} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))

      {_provider, nil} ->
        changeset

      {_provider, _charge} ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))
    end
  end
end
