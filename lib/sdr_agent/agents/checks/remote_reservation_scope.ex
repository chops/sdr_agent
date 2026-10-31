defmodule SdrAgent.Agents.Checks.RemoteReservationScope do
  @moduledoc """
  Policy check for `SdrAgent.Agents.RemoteModelCall :create` (S-B2; plan
  P1): the reservation-owned scope, not the generic RemoteCalls scope.

  It passes only when the changeset's context carries the reservation
  reference bound to the CURRENT process by
  `SdrAgent.Agents.Changes.CreateRemoteCall.with_reservation/1`, inside a
  transaction, under the trusted `:remote` transport, and when its
  `model_invocation_id` is the invocation that this reservation's own
  `:reserve` create recorded
  (`SdrAgent.Agents.Changes.CreateRemoteCall.reserved?/2`).
  """
  use Ash.Policy.SimpleCheck

  alias SdrAgent.Agents.Changes.CreateRemoteCall

  @impl true
  def describe(_opts), do: "the create runs in this process's own remote reservation"

  @impl true
  def match?(_actor, %{subject: %Ash.Changeset{context: context} = changeset}, _opts),
    do:
      CreateRemoteCall.reserved?(
        context,
        Ash.Changeset.get_attribute(changeset, :model_invocation_id)
      )

  def match?(_actor, _authorizer, _opts), do: false
end
