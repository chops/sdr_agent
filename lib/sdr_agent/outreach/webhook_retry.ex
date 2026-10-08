defmodule SdrAgent.Outreach.WebhookRetry do
  @moduledoc """
  Operator retry of a failed WebhookEvent (S13b, soft-stop v3 B1; Codex PASS
  9a400910) — the implementation behind `SdrAgent.Outreach.retry_webhook/2`,
  the only path to `WebhookEvent :request_retry`.

  One `SdrAgent.Audit.transaction/1`. Locks, in order: the event `FOR
  UPDATE` → the exact original `WebhookWorker` job row `FOR UPDATE` → the
  audit chain head (first append). Checks, in order: the event is `valid`
  and `failed` (`:not_failed`); exactly one original job (`:retry_window_expired`
  when pruned, `:ambiguous_job`); its `tenant_id` and `webhook_event_id`
  match and its carried `raw_body` decodes and hashes to the event's
  `raw_body_sha256` (`:job_corrupt`); it is not live (`:retry_pending`);
  ordinal = earlier requests + 1 ≤ 3 (`:retry_limit_reached`). Then the
  audited request (`:request_retry`, marker context) and `Oban.retry_job/2`
  on that job, with a postcondition under the lock: the job is `available`
  with `max_attempts > attempt`, else everything rolls back (`:retry_noop`;
  Oban returns `:ok` for a no-op). The operator ordinal (1..3) is distinct
  from Oban's attempt number. Returns metadata only — the job's bytes never
  leave the server.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Ash.Error.Forbidden
  alias Ash.Error.Query.NotFound
  alias SdrAgent.Accounts.User
  alias SdrAgent.Audit
  alias SdrAgent.Operations.Checks.WebhookRetryContext
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach.Webhooks
  alias SdrAgent.Repo

  @worker "SdrAgent.Outreach.WebhookWorker"
  @limit 3
  @live_states ~w(available scheduled executing retryable)

  @doc "Runs the retry for an authorized active admin `actor` (see the moduledoc)."
  def run(event_id, %User{role: :admin, status: :active, tenant_id: tenant_id} = actor)
      when is_binary(tenant_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(event_id) |> ok_or(:not_found) do
      Audit.transaction(fn -> committed(locked(event_id, actor)) end)
    end
  end

  def run(_event_id, _actor), do: {:error, Forbidden.exception([])}

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Repo.rollback(reason)

  defp locked(event_id, actor) do
    with {:ok, event} <- lock_event(event_id, actor),
         :ok <- failed(event),
         {:ok, job} <- original_job(event),
         :ok <- intact(job, event),
         :ok <- not_live(job),
         {:ok, ordinal} <- ordinal(event),
         {:ok, _event} <- request(event, ordinal, job, actor),
         :ok <- Oban.retry_job(job.id),
         :ok <- requeued(job.id) do
      {:ok, %{event_id: event.id, ordinal: ordinal}}
    end
  end

  defp lock_event(event_id, actor) do
    WebhookEvent
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^event_id and tenant_id == ^actor.tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: WebhookEvent)}
      other -> other
    end
  end

  defp failed(%{signature_verdict: :valid, processing_status: :failed}), do: :ok
  defp failed(_event), do: {:error, :not_failed}

  defp original_job(event) do
    from(j in Oban.Job,
      where: j.worker == @worker and fragment("?->>'webhook_event_id' = ?", j.args, ^event.id),
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> case do
      [job] -> {:ok, job}
      [] -> {:error, :retry_window_expired}
      _ -> {:error, :ambiguous_job}
    end
  end

  defp intact(%{args: args}, event) do
    with true <- args["tenant_id"] == event.tenant_id and args["webhook_event_id"] == event.id,
         {:ok, raw} <- Base.decode64(Map.get(args, "raw_body", "")),
         true <- :crypto.hash(:sha256, raw) == event.raw_body_sha256 do
      :ok
    else
      _ -> {:error, :job_corrupt}
    end
  end

  defp not_live(%{state: state}) when state in @live_states, do: {:error, :retry_pending}
  defp not_live(_job), do: :ok

  defp ordinal(event) do
    requested =
      event
      |> Webhooks.retry_ledger()
      |> Enum.count(&(&1.event_type == "webhook.retry_requested"))

    if requested < @limit, do: {:ok, requested + 1}, else: {:error, :retry_limit_reached}
  end

  defp request(event, ordinal, job, actor) do
    event
    |> Ash.Changeset.for_update(:request_retry, %{},
      actor: actor,
      context: WebhookRetryContext.context(ordinal, job.id)
    )
    |> Ash.update()
  end

  defp requeued(job_id) do
    case Repo.one(
           from(j in Oban.Job,
             where: j.id == ^job_id,
             select: {j.state, j.attempt, j.max_attempts}
           )
         ) do
      {"available", attempt, max_attempts} when max_attempts > attempt -> :ok
      _ -> {:error, :retry_noop}
    end
  end
end
