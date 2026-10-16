defmodule SdrAgent.Agents.Checks.SettingsSnapshotContext do
  @moduledoc """
  Policy check for `SdrAgent.Agents.RunSettingsSnapshot :create` (C4,
  `docs/product/c4/readiness.md` sections 3.2 and 12, the `GrantContext`
  pattern made phase-bound as `ServerStartPhase` is): the create is made
  inside the phase `SdrAgent.Agents.Changes.BuildSettingsSnapshot` opened,
  in this process, for this action, actor and tenant.

  This module only reads an already open phase
  (`BuildSettingsSnapshot.phase/1`); it constructs no authority. A context
  copied out of a phase, forged with any keys, or used from another process
  names no open binding and matches nothing, so the create is Forbidden.
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Agents.Changes.BuildSettingsSnapshot

  @impl true
  def describe(_opts), do: "inside the run creation's own settings snapshot phase"

  @impl true
  def match?(actor, %{subject: %Ash.Changeset{action: %{name: action}} = changeset}, _opts) do
    case BuildSettingsSnapshot.phase(changeset.context) do
      {:ok, binding} ->
        binding.action == action and binding.actor == actor and
          Map.get(actor || %{}, :tenant_id) == binding.tenant_id

      :error ->
        false
    end
  end

  def match?(_actor, _context, _opts), do: false
end
