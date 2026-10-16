defmodule SdrAgent.Agents.ProfileSwitchDrain do
  @moduledoc """
  The bounded drain of an open model profile switch (C2-02b1,
  `docs/product/r0/c2-02b1-interface.md`, "The drain"; interface and entity
  PASS at cda8ee5), behind `SdrAgent.Agents.drain_profile_switch/3`.

  **Authority:** `agent_runtime` of the switch's tenant only, the ledger actor
  that already admits launches and stops runs. Any other actor is
  `Forbidden`. Inputs `%{server_generation, timeout_ms}`: positive
  integers; the deadline is one monotonic budget from the call, never reset.
  Results are counts only.

  **Steps,** none holding a lock while it waits:
    1. validate the stored switch S (a fresh kernel read): of the actor's
       tenant and `pending` (else `:switch_not_open`), at the generation
       (else `:stale_server_generation`); stage `:validated`;
    2. a retried drain first settles the still-running Operation of every
       run it stopped for S (found by its `model.launch.refused` events
       naming S, bound to the run's own cause);
    3. every `:reserved` real-profile ClaudeCLI row of the tenant is refused
       in its own transaction (`Agents.refuse_reserved_for_switch/4`, which
       revalidates S after the head, so a drain never refuses work reserved
       after S closed); stage `:refused` after each commit, then the
       stopped run's Operation is settled in its own transaction
       (`SdrAgent.Agents.StoppedRunOperation`, the worker's rule);
    4. poll the tenant's reserved and sent counts (stage `:polling`), outside
       any transaction, until both are zero or the deadline passes;
    5. one final transaction, after taking the chain head: S still pending
       at the generation, no reserved or sent row, and no run stopped for S
       with a running Operation. Only then `{:ok, %{refused: n}}`.

  **Errors:** `{:error, :drain_timeout, %{reserved: n, sent: n}}` (the
  counts last observed within the deadline, each `nil` when never observed:
  never read after the budget is spent, and never evidence of a clean
  drain),
  `{:error, :drain_observation_failed}` (any failed or ambiguous read: never
  zero work), `{:error, :drain_settlement_failed}` (an Operation transaction
  failed; a retry finishes it), `{:error, :switch_not_open}`,
  `{:error, :stale_server_generation}`. Errors leave the fence as it is:
  nothing is unlocked or refunded.

  Every transaction is bounded by the remaining budget: checkout without
  queueing (retried until the budget is spent), a client-side timeout, the
  transaction-local `lock_timeout` and `statement_timeout` re-set before
  each step, and a rollback instead of a commit once the budget is spent.

  **Stage events:** `[:sdr_agent, :profile_switch, :drain]` telemetry
  (measurements empty, metadata `%{stage:, switch_id:}`). They observe
  lifecycle points and authorize nothing.
  """
  require Ash.Query

  alias SdrAgent.Agents.Admission.SwitchFence
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.StoppedRunOperation
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo

  @event [:sdr_agent, :profile_switch, :drain]
  @poll_ms 50
  @fence_errors [:switch_not_open, :stale_server_generation, :drain_observation_failed]
  # The counts last observed within the deadline (nil: never observed).
  @last_counts {__MODULE__, :last_counts}
  @unknown %{reserved: nil, sent: nil}
  # Client-side slack over the server-side timeouts, so Postgres cancels first.
  @client_slack_ms 25
  # Between checkout attempts when no pool connection is free.
  @checkout_retry_ms 10
  # DBConnection's refusal of a checkout made with `queue: false`.
  @no_connection "connection not available and queuing is disabled"

  @doc "See the moduledoc."
  def drain(switch, attrs, opts) do
    actor = Keyword.get(opts, :actor)

    with :ok <- authorized(actor),
         {:ok, generation, timeout} <- inputs(Map.new(attrs)),
         {:ok, switch_id} <- target(switch) do
      deadline = System.monotonic_time(:millisecond) + timeout
      Process.put(@last_counts, @unknown)

      try do
        run(%{switch_id: switch_id, generation: generation, deadline: deadline, actor: actor})
      after
        Process.delete(@last_counts)
      end
    end
  end

  defp target(%{id: id}) when is_binary(id), do: {:ok, id}
  defp target(_switch), do: {:error, :switch_not_open}

  defp authorized(%SdrAgent.Actor{type: :agent_runtime, tenant_id: tenant})
       when is_binary(tenant),
       do: :ok

  defp authorized(_actor), do: {:error, Ash.Error.Forbidden.exception([])}

  defp inputs(%{server_generation: generation, timeout_ms: timeout})
       when is_integer(generation) and generation >= 1 and is_integer(timeout) and timeout >= 1,
       do: {:ok, generation, timeout}

  defp inputs(_attrs) do
    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(
         field: :timeout_ms,
         message: "server_generation and timeout_ms must be positive integers"
       )
     )}
  end

  defp run(drain) do
    with :ok <- validate(drain),
         :ok <- emit(:validated, drain),
         :ok <- settle_stopped(drain),
         {:ok, refused} <- refuse_reserved(drain) do
      poll(drain, refused)
    end
  end

  defp validate(drain) do
    drain
    |> bounded(fn -> SwitchFence.named_open(tenant(drain), drain.switch_id, drain.generation) end)
    |> fence_result(drain)
  end

  ## Step 2: a retried drain's unfinished Operations

  defp settle_stopped(drain) do
    case bounded(drain, fn -> stopped_runs(drain) end) do
      {:ok, runs} -> each_settled(runs, drain)
      {:error, :drain_timeout} -> timeout(drain)
      {:error, _error} -> {:error, :drain_observation_failed}
    end
  end

  # Runs this drain stopped for S, each bound to its own cause: failed
  # :model_not_admitted on exactly the Failure its S-refusal event names.
  defp stopped_runs(drain) do
    tenant = tenant(drain)

    with {:ok, events} <-
           AuditEvent
           |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant))
           |> Ash.Query.filter(tenant_id == ^tenant and event_type == "model.launch.refused")
           |> Ash.Query.select([:id, :agent_run_id, :payload])
           |> Ash.read() do
      events
      |> Enum.filter(
        &(&1.payload["switch_id"] == drain.switch_id and
            &1.payload["reason"] == "profile_switch_fenced")
      )
      |> Enum.reduce_while({:ok, []}, &collect_bound(tenant, &1, &2))
    end
  end

  defp collect_bound(tenant, event, {:ok, acc}) do
    case bound_run(tenant, event) do
      {:ok, nil} -> {:cont, {:ok, acc}}
      {:ok, run} -> {:cont, {:ok, [run | acc]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp bound_run(tenant, %{agent_run_id: run_id, payload: %{"failure_id" => failure_id}})
       when is_binary(run_id) do
    case Ash.get(AgentRun, run_id, Kernel.opts(tenant)) do
      {:ok,
       %{status: :failed, status_reason: :model_not_admitted, attention_failure_id: ^failure_id} =
           run} ->
        {:ok, if(is_binary(run.operation_id), do: run)}

      {:ok, _other} ->
        {:ok, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  defp bound_run(_tenant, _event), do: {:ok, nil}

  defp each_settled(runs, drain) do
    Enum.reduce_while(runs, :ok, fn run, :ok ->
      case settle(run, drain) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp settle(%{operation_id: nil}, _drain), do: :ok

  # In the Operation's own transaction (Operation → Failure → head): after
  # both locks, the head is taken and S revalidated fresh before the
  # Operation changes, so a stale drain never settles after S closed.
  defp settle(run, drain) do
    result =
      bounded(drain, fn step ->
        StoppedRunOperation.settle(run.operation_id, run, drain.actor,
          step: step,
          before_write: fn -> revalidate_after_head(drain, step) end
        )
      end)

    case result do
      :ok -> :ok
      {:error, :drain_timeout} -> timeout(drain)
      {:error, reason} when reason in @fence_errors -> {:error, reason}
      {:error, _error} -> {:error, :drain_settlement_failed}
    end
  end

  defp revalidate_after_head(drain, step) do
    with :ok <- step.(),
         {:ok, _head} <- Kernel.lock_head(tenant(drain)),
         :ok <- step.() do
      SwitchFence.named_open(tenant(drain), drain.switch_id, drain.generation)
    end
  end

  ## Step 3: refuse every reserved row

  defp refuse_reserved(drain) do
    case bounded(drain, fn -> counts_rows(drain, [:reserved]) end) do
      {:ok, rows} ->
        observed(%{last_counts() | reserved: length(rows)})
        refuse_each(rows, drain, 0)

      {:error, :drain_timeout} ->
        timeout(drain)

      {:error, _error} ->
        {:error, :drain_observation_failed}
    end
  end

  defp refuse_each([], _drain, refused), do: {:ok, refused}

  defp refuse_each([row | rest], drain, refused) do
    case refuse_one(row, drain) do
      {:ok, :skipped} -> refuse_each(rest, drain, refused)
      {:ok, :refused} -> refuse_each(rest, drain, refused + 1)
      error -> error
    end
  end

  defp refuse_one(row, drain) do
    result =
      bounded(drain, fn step ->
        SdrAgent.Agents.refuse_reserved_for_switch(
          row.id,
          drain.switch_id,
          drain.generation,
          drain.actor,
          step
        )
      end)

    case result do
      {:ok, {:refused, run_id}} -> after_refusal(run_id, drain)
      {:ok, :not_running} -> with(:ok <- emit(:refused, drain), do: {:ok, :refused})
      {:ok, :skipped} -> {:ok, :skipped}
      {:error, :drain_timeout} -> timeout(drain)
      {:error, reason} when reason in @fence_errors -> {:error, reason}
      {:error, _error} -> {:error, :drain_observation_failed}
    end
  end

  # After the refusal transaction committed and released its locks: the
  # stage event, then the run's Operation in its own transaction.
  defp after_refusal(run_id, drain) do
    with :ok <- emit(:refused, drain),
         {:ok, run} <- stopped_run(run_id, drain),
         :ok <- settle(run, drain) do
      {:ok, :refused}
    end
  end

  defp stopped_run(run_id, drain) do
    case bounded(drain, fn -> Ash.get(AgentRun, run_id, Kernel.opts(tenant(drain))) end) do
      {:ok, run} -> {:ok, run}
      {:error, :drain_timeout} -> timeout(drain)
      {:error, _error} -> {:error, :drain_observation_failed}
    end
  end

  ## Steps 4 and 5: poll, then the final observation

  # The :polling stage is emitted after each count, outside any transaction.
  defp poll(drain, refused) do
    case counts(drain) do
      {:ok, %{reserved: 0, sent: 0}} ->
        :ok = emit(:polling, drain)
        final(drain, refused)

      {:ok, _counts} ->
        :ok = emit(:polling, drain)

        case remaining(drain) do
          ms when ms <= 0 ->
            timeout(drain)

          ms ->
            Process.sleep(min(@poll_ms, ms))
            poll(drain, refused)
        end

      {:error, :drain_timeout} ->
        timeout(drain)

      {:error, _error} ->
        {:error, :drain_observation_failed}
    end
  end

  defp final(drain, refused) do
    tenant = tenant(drain)

    observed =
      bounded(drain, fn step ->
        with {:ok, _head} <- Kernel.lock_head(tenant),
             :ok <- step.(),
             :ok <- SwitchFence.named_open(tenant, drain.switch_id, drain.generation),
             :ok <- step.(),
             {:ok, %{reserved: 0, sent: 0}} <- counts_unbounded(drain),
             :ok <- step.(),
             {:ok, []} <- running_operations(drain) do
          {:ok, :drained}
        else
          {:ok, %{reserved: _, sent: _} = counts} -> {:error, {:outstanding, counts}}
          {:ok, [_ | _]} -> {:error, :drain_settlement_failed}
          {:error, reason} -> {:error, reason}
        end
      end)

    case observed do
      {:ok, :drained} ->
        {:ok, %{refused: refused}}

      {:error, {:outstanding, _counts}} ->
        poll(drain, refused)

      {:error, :drain_timeout} ->
        timeout(drain)

      {:error, reason} when reason in [:drain_settlement_failed | @fence_errors] ->
        {:error, reason}

      {:error, _error} ->
        {:error, :drain_observation_failed}
    end
  end

  defp running_operations(drain) do
    with {:ok, runs} <- stopped_runs(drain) do
      runs
      |> Enum.map(& &1.operation_id)
      |> running(drain)
    end
  end

  defp running([], _drain), do: {:ok, []}

  defp running(operation_ids, drain) do
    tenant = tenant(drain)

    SdrAgent.Operations.Operation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant))
    |> Ash.Query.filter(id in ^operation_ids and status == :running)
    |> Ash.Query.select([:id])
    |> Ash.read()
  end

  ## Reads and bounds

  defp counts(drain) do
    with {:ok, counts} <- bounded(drain, fn -> counts_unbounded(drain) end) do
      observed(counts)
      {:ok, counts}
    end
  end

  defp counts_unbounded(drain) do
    with {:ok, rows} <- counts_rows(drain, [:reserved, :sent]) do
      by_status = Enum.frequencies_by(rows, & &1.status)
      {:ok, %{reserved: Map.get(by_status, :reserved, 0), sent: Map.get(by_status, :sent, 0)}}
    end
  end

  # The tenant's real-profile ClaudeCLI rows in `statuses` (ids and status
  # only), by the kernel's read.
  defp counts_rows(drain, statuses) do
    tenant = tenant(drain)
    real = ModelProfiles.real_ids()

    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant))
    |> Ash.Query.filter(
      tenant_id == ^tenant and provider == :claude_cli and profile_id in ^real and
        status in ^statuses
    )
    |> Ash.Query.select([:id, :status])
    |> Ash.read()
  end

  # Runs `fun` in one transaction under the one deadline:
  #   * the connection is checked out with `queue: false`: the pool answers
  #     at once (DBConnection's queue wait is not bounded by `:timeout`), and
  #     a busy pool is retried until the budget is spent, so no checkout is
  #     left queued to run after the drain has returned;
  #   * the transaction has a client-side timeout of the remaining budget
  #     plus a small slack;
  #   * before `fun` and before each of its steps (`fun.(step)`), the
  #     transaction-local `lock_timeout` and `statement_timeout` are set to
  #     the budget left at that moment, so no sequence of waits overruns it;
  #   * before commit the budget is checked again: once it is spent, the
  #     work rolls back as `{:error, :drain_timeout}` instead of committing.
  # The settings are restored before commit (a savepoint under a test
  # sandbox would otherwise keep them).
  defp bounded(drain, fun) do
    case remaining(drain) do
      ms when ms <= 0 ->
        {:error, :drain_timeout}

      ms ->
        fn -> audited_body(drain, fun) end
        |> Repo.transaction(timeout: ms + @client_slack_ms, queue: false)
        |> unwrap_bounded(drain)
    end
  rescue
    # Only the queue-disabled refusal is a busy pool, retried. Under the SQL
    # sandbox, DBConnection prefixes that same refusal with its owner-redirect
    # text ("could not checkout the connection owned by ... Reason: ..."),
    # so it is matched as a suffix (`SdrAgent.Agents.LedgerCall.busy?/1`
    # already accepts the sandbox form); any other reason fails closed.
    error in DBConnection.ConnectionError ->
      if String.ends_with?(error.message, @no_connection),
        do: retry_checkout(drain, fun),
        else: {:error, error}

    # A failed read or write is never read as zero outstanding work.
    error ->
      {:error, error}
  end

  defp retry_checkout(drain, fun) do
    Process.sleep(min(@checkout_retry_ms, max(remaining(drain), 0)))
    bounded(drain, fun)
  end

  defp audited_body(drain, fun) do
    fn -> bounded_body(drain, fun) end
    |> Audit.transaction()
    |> unwrap_inner()
  end

  defp bounded_body(drain, fun) do
    [[lock, statement]] =
      Repo.query!("SELECT current_setting('lock_timeout'), current_setting('statement_timeout')").rows

    step = fn -> rebound(drain) end

    with :ok <- step.(),
         result when not is_tuple(result) or elem(result, 0) != :error <- call(fun, step),
         :ok <- step.() do
      set_timeouts!(lock, statement)
      result
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp call(fun, step) when is_function(fun, 1), do: fun.(step)
  defp call(fun, _step), do: fun.()

  # The budget left now, applied to the next statements; spent: roll back.
  defp rebound(drain) do
    case remaining(drain) do
      ms when ms <= 0 ->
        {:error, :drain_timeout}

      ms ->
        set_timeouts!("#{ms}ms", "#{ms}ms")
        :ok
    end
  end

  defp set_timeouts!(lock, statement) do
    Repo.query!(
      "SELECT set_config('lock_timeout', $1, true), set_config('statement_timeout', $2, true)",
      [lock, statement]
    )
  end

  defp unwrap_inner({:ok, result}), do: result
  defp unwrap_inner({:error, error}), do: Repo.rollback(error)

  defp unwrap_bounded({:ok, result}, _drain), do: result

  defp unwrap_bounded({:error, error}, drain) do
    if remaining(drain) <= 0, do: {:error, :drain_timeout}, else: {:error, error}
  end

  # The counts last observed within the deadline: no read happens after the
  # budget is spent (a figure never observed is nil).
  defp timeout(_drain), do: {:error, :drain_timeout, last_counts()}

  defp observed(counts), do: Process.put(@last_counts, counts)
  defp last_counts, do: Process.get(@last_counts, @unknown)

  defp fence_result(:ok, _drain), do: :ok
  defp fence_result({:error, :drain_timeout}, drain), do: timeout(drain)
  defp fence_result({:error, reason}, _drain) when reason in @fence_errors, do: {:error, reason}
  defp fence_result(_error, _drain), do: {:error, :drain_observation_failed}

  defp remaining(drain), do: drain.deadline - System.monotonic_time(:millisecond)
  defp tenant(drain), do: drain.actor.tenant_id

  defp emit(stage, drain) do
    :telemetry.execute(@event, %{}, %{stage: stage, switch_id: drain.switch_id})
  end
end
