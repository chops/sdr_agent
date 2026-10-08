defmodule SdrAgent.Operations.Changes.RetryRequest do
  @moduledoc """
  `WebhookEvent :request_retry` (S13b B2). Without the orchestration marker
  (`SdrAgent.Operations.Checks.WebhookRetryContext`) the action is
  Forbidden. With it, the marker is a claim, not evidence: after the event
  row is locked (list this change after `get_and_lock_for_update()`), the
  marked ordinal must equal the requests already in the ledger plus one
  (and be at most 3), and the marked job must be the event's exact,
  locked, not-live original job. Otherwise nothing is written. The audited
  `ordinal` and `oban_job_id` arguments are then set from the verified
  values; anything the caller passed is overwritten.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Forbidden
  alias SdrAgent.Operations.Checks.WebhookRetryContext
  alias SdrAgent.Operations.WebhookRetryLedger, as: Ledger

  @impl true
  def change(changeset, _opts, _context) do
    case WebhookRetryContext.request(changeset.context) do
      nil -> Ash.Changeset.add_error(changeset, Forbidden.exception([]))
      request -> Ash.Changeset.before_action(changeset, &verify(&1, request))
    end
  end

  defp verify(changeset, %{ordinal: ordinal, oban_job_id: job_id}) do
    event = changeset.data

    with :ok <- next_ordinal(event, ordinal),
         :ok <- original_job(event, job_id) do
      changeset
      |> Ash.Changeset.set_argument(:ordinal, ordinal)
      |> Ash.Changeset.set_argument(:oban_job_id, job_id)
    else
      {:error, field, message} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: field, message: message)
        )
    end
  end

  defp next_ordinal(event, ordinal) do
    if ordinal == Ledger.requested(event) + 1 and ordinal <= Ledger.limit(),
      do: :ok,
      else: {:error, :ordinal, "is not the event's next retry request"}
  end

  defp original_job(event, job_id) do
    case Ledger.lock_original_job(event) do
      {:ok, %{id: ^job_id, state: state}} ->
        if state in Ledger.live_states(),
          do: {:error, :oban_job_id, "the original job is still live"},
          else: :ok

      _ ->
        {:error, :oban_job_id, "is not the event's original job"}
    end
  end
end
