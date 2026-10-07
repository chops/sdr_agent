defmodule SdrAgent.Operations.Checks.FailureResolver do
  @moduledoc """
  Policy check for Failure `:resolve` by a system actor (S2 row Failure:
  "REC and the causing system actor resolve with a system note when the
  condition clears"). Passes for the reconciler, and for a system actor
  whose type is the one that opened the Failure — taken from trusted,
  recorded provenance: the actor type of the Failure's
  `operations.failure.opened` AuditEvent in the hash-chained ledger. Any
  other system actor is refused. (ADM and REV are authorized by role in the
  resource policy.)
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel

  @impl true
  def describe(_opts), do: "actor is the reconciler or the system actor that opened the failure"

  @impl true
  def match?(%SdrAgent.Actor{type: :reconciler}, _context, _opts), do: true

  def match?(%SdrAgent.Actor{type: type}, %{subject: %Ash.Changeset{data: failure}}, _opts),
    do: opener_type(failure) == type

  def match?(_actor, _context, _opts), do: false

  defp opener_type(%{id: id, tenant_id: tenant_id}) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and event_type == "operations.failure.opened" and
        subject_id == ^id
    )
    |> Ash.Query.select([:actor_type])
    |> Ash.Query.limit(1)
    |> Ash.read_one()
    |> case do
      {:ok, %{actor_type: type}} -> type
      _ -> nil
    end
  end
end
