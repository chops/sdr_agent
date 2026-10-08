defmodule SdrAgent.SDR.Retry do
  @moduledoc """
  Operator retry of an agent run (S13b; soft-stop v3 PASS, Codex reply
  9a400910) — the implementation behind `SdrAgent.SDR.retry_run/2`, the
  only path to `AgentRun :retry`.

  Supported triggers: `sdr.lead.assigned` (an `AgentWorker` job on
  `research` with a new `research_lead` Operation) and `sdr.reply.received`
  (a `ReplyWorker` job on `agent` carrying the new run's id). Everything is
  one `SdrAgent.Audit.transaction/1`; a refusal returns `{:error, reason}`
  and writes nothing.

  Locks, in order (consistent with assignment and the hand-off): Lead
  `FOR UPDATE` → Campaign `FOR SHARE` → prior AgentRun `FOR UPDATE` → its
  Operation → its attention Failure → the original Oban job → the audit
  chain head (first append).

  Checks, in order: one child per prior run (`:already_retried`); prior in
  `failed | budget_exhausted | cancelled` (`:not_retryable`); at most
  `max_retries/0` retries after the original (`:retry_limit_reached`); no
  other queued or running run on the lead (`:assignment_active`); a
  supported trigger (`:unsupported_trigger`); the original job — exactly one
  row with the expected worker, queue, tenant and binding and the trigger
  signal (`:original_job_missing | :original_job_ambiguous |
  :original_job_corrupt`), not live (`:prior_work_live`); no `sent` model
  call of the prior run (`:prior_model_call_unsettled`); the durable trigger
  signal (`:trigger_signal_missing`), and for a reply a matched Reply of the
  lead with no assessment yet (`:already_assessed`); the lead
  (`:lead_not_retryable`) and campaign (`:campaign_not_active`) gates. The
  lead's state is never changed by a retry; no approval or send permission
  is implied.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias Ash.Error.Forbidden
  alias Ash.Error.Query.NotFound
  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Checks.RetryContext
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Outreach
  alias SdrAgent.Repo
  alias SdrAgent.Sales
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.ReplyWorker
  alias SdrAgent.SDR.Signals

  @hard_limit 3
  @live_states ~w(available scheduled executing retryable)
  @retryable [:failed, :budget_exhausted, :cancelled]
  @closed_leads [:stopped, :disqualified, :converted, :nurture]
  @researching [:assigned, :researching, :qualifying]
  @workers %{
    "sdr.lead.assigned" => {"SdrAgent.SDR.AgentWorker", "research"},
    "sdr.reply.received" => {"SdrAgent.SDR.ReplyWorker", "agent"}
  }

  @doc "Retries allowed after an original run: `min(config, 3)` (`config :sdr_agent, SdrAgent.SDR, max_run_retries:`)."
  @spec max_retries() :: non_neg_integer()
  def max_retries do
    configured =
      :sdr_agent
      |> Application.get_env(SdrAgent.SDR, [])
      |> Keyword.get(:max_run_retries, @hard_limit)

    configured |> min(@hard_limit) |> max(0)
  end

  @doc "Runs the retry for an authorized active admin `actor` (see the moduledoc)."
  def run(run_id, %User{role: :admin, status: :active, tenant_id: tenant_id} = actor)
      when is_binary(tenant_id) do
    with {:ok, seen} <- Agents.get_run(run_id, actor: actor) do
      Audit.transaction(fn -> committed(locked(seen, actor)) end)
    end
  end

  def run(_run_id, _actor), do: {:error, Forbidden.exception([])}

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Repo.rollback(reason)

  defp locked(seen, actor) do
    with {:ok, lead} <- lock(Sales.Lead, seen.lead_id, actor, :for_update),
         {:ok, campaign} <- lock(Sales.Campaign, seen.campaign_id, actor, "FOR SHARE"),
         {:ok, prior} <- lock(AgentRun, seen.id, actor, :for_update),
         :ok <- no_child(prior),
         :ok <- retryable(prior),
         :ok <- within_limit(prior),
         :ok <- no_active_run(prior),
         {:ok, {worker, queue}} <- supported(prior),
         {:ok, operation} <- lock_operation(prior, actor),
         :ok <- lock_failure(prior, actor),
         {:ok, signal} <- trigger_signal(prior),
         {:ok, _job} <- original_job(prior, operation, signal, worker, queue),
         :ok <- settled(prior, actor),
         :ok <- reply_open(prior, signal, actor),
         :ok <- lead_open(prior, lead),
         :ok <- campaign_active(campaign) do
      enqueue(prior, lead, signal, actor)
    end
  end

  defp lock(resource, id, actor, mode) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^actor.tenant_id)
    |> Ash.Query.lock(mode)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: resource)}
      other -> other
    end
  end

  defp no_child(prior) do
    case children(prior.id, prior.tenant_id) do
      [] -> :ok
      _ -> {:error, :already_retried}
    end
  end

  defp children(run_id, tenant_id) do
    AgentRun
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(retry_of_id == ^run_id)
    |> Ash.read!()
  end

  defp retryable(%{status: status}) when status in @retryable, do: :ok
  defp retryable(_prior), do: {:error, :not_retryable}

  # Depth of `prior` in its retry lineage (0 = the original), walked at most
  # hard_limit + 1 steps, same tenant, cycle-safe.
  defp within_limit(prior) do
    case depth(prior, 0, MapSet.new()) do
      {:ok, depth} when depth < 3 ->
        if depth < max_retries(), do: :ok, else: {:error, :retry_limit_reached}

      _ ->
        {:error, :retry_limit_reached}
    end
  end

  defp depth(%{retry_of_id: nil}, depth, _seen), do: {:ok, depth}

  defp depth(run, depth, seen) do
    if depth > @hard_limit or MapSet.member?(seen, run.id) do
      :error
    else
      case Ash.get(AgentRun, run.retry_of_id, Kernel.opts(run.tenant_id)) do
        {:ok, %{tenant_id: tenant_id} = parent} when tenant_id == run.tenant_id ->
          depth(parent, depth + 1, MapSet.put(seen, run.id))

        _ ->
          :error
      end
    end
  end

  defp no_active_run(prior) do
    case Agents.active_runs_for_lead(prior.lead_id, actor: Kernel.opts(prior.tenant_id)[:actor]) do
      {:ok, []} -> :ok
      {:ok, _runs} -> {:error, :assignment_active}
      error -> error
    end
  end

  defp supported(%{trigger_signal_type: type}) do
    case Map.fetch(@workers, type) do
      {:ok, worker} -> {:ok, worker}
      :error -> {:error, :unsupported_trigger}
    end
  end

  defp lock_operation(%{operation_id: nil}, _actor), do: {:ok, nil}

  defp lock_operation(%{operation_id: id}, actor),
    do: lock(Operations.Operation, id, actor, :for_update)

  defp lock_failure(%{attention_failure_id: nil}, _actor), do: :ok

  defp lock_failure(%{attention_failure_id: id}, actor) do
    with {:ok, _failure} <- lock(Operations.Failure, id, actor, :for_update), do: :ok
  end

  # The durable record of the trigger: its `signal` AuditEvent (same tenant).
  defp trigger_signal(prior) do
    Audit.AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(prior.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^prior.tenant_id and category == :signal and
        causation_id == ^prior.trigger_signal_id and event_type == ^prior.trigger_signal_type
    )
    |> Ash.read()
    |> case do
      {:ok, [event]} ->
        with {:ok, signal} <-
               Signals.load(%{
                 "id" => prior.trigger_signal_id,
                 "type" => prior.trigger_signal_type,
                 "data" => event.payload["data"] || %{}
               }),
             true <- signal_matches?(signal, prior) do
          {:ok, signal}
        else
          _ -> {:error, :trigger_signal_missing}
        end

      _ ->
        {:error, :trigger_signal_missing}
    end
  end

  defp signal_matches?(%{type: "sdr.lead.assigned", data: data}, prior),
    do: data[:lead_id] == prior.lead_id and data[:campaign_id] == prior.campaign_id

  defp signal_matches?(%{type: "sdr.reply.received", data: data}, prior),
    do: data[:lead_id] == prior.lead_id and is_binary(data[:reply_id])

  # The prior run's own job: exactly one row of the expected worker and
  # queue, of the run's tenant, bound to the run (assignment: its
  # Operation's job id; reply: args.run_id), carrying the trigger signal.
  defp original_job(prior, operation, signal, worker, queue) do
    query =
      case operation do
        %{oban_job_id: job_id} when is_integer(job_id) ->
          from(j in Oban.Job, where: j.id == ^job_id, lock: "FOR UPDATE")

        nil ->
          from(j in Oban.Job,
            where: j.worker == ^worker and fragment("?->>'run_id' = ?", j.args, ^prior.id),
            lock: "FOR UPDATE"
          )

        _ ->
          nil
      end

    case query && Repo.all(query) do
      [job] -> check_job(job, prior, signal, worker, queue)
      [_, _ | _] -> {:error, :original_job_ambiguous}
      _ -> {:error, :original_job_missing}
    end
  end

  defp check_job(job, prior, signal, worker, queue) do
    dumped = Signals.dump(signal)

    cond do
      job.worker != worker or job.queue != queue or job.args["tenant_id"] != prior.tenant_id or
          job.args["signal"] != dumped ->
        {:error, :original_job_corrupt}

      job.state in @live_states ->
        {:error, :prior_work_live}

      true ->
        {:ok, job}
    end
  end

  defp settled(prior, actor) do
    case Agents.list_model_invocations(prior.id, actor: actor) do
      {:ok, invocations} ->
        if Enum.any?(invocations, &(&1.status == :sent)),
          do: {:error, :prior_model_call_unsettled},
          else: :ok

      error ->
        error
    end
  end

  defp reply_open(%{trigger_signal_type: "sdr.reply.received"} = prior, signal, actor) do
    reply_id = signal.data[:reply_id]

    with {:ok, reply} <- Outreach.fetch(Outreach.Reply, reply_id, actor: actor),
         true <- reply.match_status == :matched and reply.lead_id == prior.lead_id,
         {:ok, []} <-
           Outreach.list_records(Outreach.ReplyAssessment,
             filter: [reply_id: reply_id],
             actor: actor
           ) do
      :ok
    else
      {:ok, [_ | _]} -> {:error, :already_assessed}
      _ -> {:error, :trigger_signal_missing}
    end
  end

  defp reply_open(_prior, _signal, _actor), do: :ok

  defp lead_open(_prior, %{status: status}) when status in @closed_leads,
    do: {:error, :lead_not_retryable}

  defp lead_open(%{trigger_signal_type: "sdr.lead.assigned"}, %{status: status})
       when status not in @researching,
       do: {:error, :lead_not_retryable}

  defp lead_open(_prior, _lead), do: :ok

  defp campaign_active(%{status: :active}), do: :ok
  defp campaign_active(_campaign), do: {:error, :campaign_not_active}

  ## Writes (same transaction)

  defp enqueue(%{trigger_signal_type: "sdr.lead.assigned"} = prior, lead, signal, actor) do
    agent = Actor.system(:agent_runtime, prior.tenant_id)

    with {:ok, job} <-
           %{"tenant_id" => prior.tenant_id, "signal" => Signals.dump(signal)}
           |> AgentWorker.new()
           |> Oban.insert(),
         {:ok, operation} <-
           Operations.create_operation(
             %{
               kind: :research_lead,
               queue: :research,
               oban_job_id: job.id,
               subject_resource: "SdrAgent.Sales.Lead",
               subject_id: lead.id,
               idempotency_key: "retry:" <> prior.id,
               correlation_id: prior.correlation_id,
               max_attempts: 1
             },
             actor: agent
           ),
         {:ok, run} <- retry_action(prior, operation.id, actor) do
      {:ok, %{run: run, operation: operation, job: job}}
    end
  end

  defp enqueue(%{trigger_signal_type: "sdr.reply.received"} = prior, _lead, signal, actor) do
    with {:ok, run} <- retry_action(prior, nil, actor),
         {:ok, job} <-
           %{"tenant_id" => prior.tenant_id, "run_id" => run.id, "signal" => Signals.dump(signal)}
           |> ReplyWorker.new()
           |> Oban.insert() do
      {:ok, %{run: run, operation: nil, job: job}}
    end
  end

  defp retry_action(prior, operation_id, actor) do
    args =
      if operation_id,
        do: %{run_id: prior.id, operation_id: operation_id},
        else: %{run_id: prior.id}

    AgentRun
    |> Ash.Changeset.for_create(:retry, args, actor: actor, context: RetryContext.context())
    |> Ash.create()
  end
end
