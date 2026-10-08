defmodule SdrAgent.Operations.Changes.ConsumeRetryRequest do
  @moduledoc """
  `WebhookEvent :record_retry_failed` (S13b B4): after the event row is
  locked (list this change after `get_and_lock_for_update()`), consumes
  exactly the event's unconsumed retry request — its ordinal comes from the
  ledger, never from the caller. With no pending request (none made, or
  already consumed by an earlier or concurrent failure) nothing is written.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias SdrAgent.Operations.WebhookRetryLedger, as: Ledger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ledger.pending(changeset.data) do
        nil ->
          Ash.Changeset.add_error(
            changeset,
            InvalidArgument.exception(field: :ordinal, message: "no pending retry request")
          )

        ordinal ->
          Ash.Changeset.set_argument(changeset, :ordinal, ordinal)
      end
    end)
  end
end
