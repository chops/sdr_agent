defmodule SdrAgent.Operations.Checks.WebhookRetryContext do
  @moduledoc """
  Policy check for `WebhookEvent :request_retry` (S13b, soft-stop v3 B2):
  the request is made inside the operator webhook retry orchestration
  (`SdrAgent.Outreach.retry_webhook/2`), which sets this marker — carrying
  the computed ordinal and the original job's id — only after its locked
  checks, in the transaction that re-enqueues that job. No public domain
  function sets it, so a direct `:request_retry` is refused (same pattern
  as `SdrAgent.Agents.Checks.RetryContext`).
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_webhook_retry

  @impl true
  def describe(_opts), do: "retry requested inside the operator webhook retry orchestration"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts), do: request(context) != nil
  def match?(_actor, _context, _opts), do: false

  @doc "The orchestration's `%{ordinal, oban_job_id}` in a changeset context, or nil."
  def request(%{@marker => %{ordinal: ordinal, oban_job_id: job_id} = request})
      when ordinal in 1..3 and is_integer(job_id),
      do: request

  def request(_context), do: nil

  @doc "The context map the orchestration attaches to `:request_retry`."
  def context(ordinal, oban_job_id),
    do: %{@marker => %{ordinal: ordinal, oban_job_id: oban_job_id}}
end
