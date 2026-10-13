defmodule SdrAgent.Agents.Changes.RunRow do
  @moduledoc """
  AgentRun `:fail` change replacing `get_and_lock_for_update/0` (R0-07
  slice C, row G6): in a `before_action`, the run row is re-read
  `FOR UPDATE`, as before — except for a result-gate stop under the
  finalizer's verified Prelocked context
  (`SdrAgent.Agents.Changes.LinkGateCause.prelocked/1`: this run's
  invocation, this receipt), where the finalizer already holds the run
  `FOR UPDATE` before the chain head; then it is re-read with no lock
  clause. No caller Boolean, row-shaped argument or generic `context:`
  skips the lock.
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.Changes.LinkGateCause

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      lock = if LinkGateCause.prelocked(changeset) == :ok, do: nil, else: :for_update
      primary_key = Ash.Resource.Info.primary_key(changeset.resource)

      case Ash.get(
             changeset.resource,
             changeset.data |> Map.take(primary_key) |> Map.to_list(),
             domain: changeset.domain,
             tracer: context.tracer,
             actor: nil,
             authorize?: false,
             lock: lock
           ) do
        {:ok, record} -> %{changeset | data: record}
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "the run row is re-read (and normally locked) before the change"}
end
