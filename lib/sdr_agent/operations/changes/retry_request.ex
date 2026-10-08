defmodule SdrAgent.Operations.Changes.RetryRequest do
  @moduledoc """
  `WebhookEvent :request_retry` (S13b B2): the audited `ordinal` and
  `oban_job_id` arguments come only from the orchestration marker
  (`SdrAgent.Operations.Checks.WebhookRetryContext`); anything the caller
  passed is overwritten. Without the marker the action is Forbidden.
  """
  use Ash.Resource.Change

  alias Ash.Error.Forbidden
  alias SdrAgent.Operations.Checks.WebhookRetryContext

  @impl true
  def change(changeset, _opts, _context) do
    case WebhookRetryContext.request(changeset.context) do
      %{ordinal: ordinal, oban_job_id: job_id} ->
        changeset
        |> Ash.Changeset.set_argument(:ordinal, ordinal)
        |> Ash.Changeset.set_argument(:oban_job_id, job_id)

      nil ->
        Ash.Changeset.add_error(changeset, Forbidden.exception([]))
    end
  end
end
