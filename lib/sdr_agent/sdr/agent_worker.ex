defmodule SdrAgent.SDR.AgentWorker do
  @moduledoc """
  Oban worker (queue `research`) that executes one assignment's AgentRun —
  the first Oban jobs of the agent plane (S2: Operation is the domain view
  of the job).

  The job, its Operation, the queued AgentRun and the `sdr.lead.assigned`
  signal event are written in one transaction by
  `SdrAgent.SDR.assign_lead/2` (outbox). The worker starts the Operation and
  the run, runs `SdrAgent.SDR.Runner`, and records the outcome: a finished
  run succeeds (and its Operation); a run stopped by a budget or invalid
  model output — or one that crashed, which is failed here with reason
  `crash` — fails its Operation, linking the run's attention Failure (one
  queue entry per condition). The run's and the Operation's terminal writes
  are one transaction. Agent work is never retried automatically
  (`max_attempts: 1`; ADR-0004: no retry loops) — an operator retry creates
  a new run. The job completes once the outcome is recorded.

  The model options — the runtime-selected provider by default, or one
  carried by the job — are resolved by `SdrAgent.AI.ModelProvider.Runtime`,
  which injects the one named ClaudeCLI server. If ClaudeCLI is wanted but
  that server is not running — or the job names a provider other than
  `fake` or `claude_cli` — no model call is made: the run fails with
  `provider_error` (opening its critical attention Failure, linked from the
  Operation) and the job returns `{:error, :provider_not_running}` (or
  `{:error, :unknown_model_provider}`) — never a raise, never the Fake
  instead.
  """
  use Oban.Worker, queue: :research, max_attempts: 1

  require Ash.Query

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.SDR.Runner
  alias SdrAgent.SDR.Signals

  # C9 stop reasons of a refused real-model reservation, and the R0-07
  # result gate's stop reasons (see fail_operation/3).
  @refused [:grant_exhausted, :grant_unavailable]
  @gate [:witness_mismatch, :witness_unreconciled]
  @providers %{
    "fake" => SdrAgent.AI.ModelProvider.Fake,
    "claude_cli" => SdrAgent.AI.ModelProvider.ClaudeCLI
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job), do: run(job, model: model(args))

  @doc """
  Executes the job's run with runner options (`:model`, resolved through
  `SdrAgent.AI.ModelProvider.Runtime`; default: the configured model).
  Returns `:ok`, or the refusal (`{:error, :provider_not_running}`,
  `{:error, :unknown_model_provider}`) once it is recorded.
  """
  def run(%Oban.Job{id: job_id, args: %{"tenant_id" => tenant_id, "signal" => dumped}}, opts) do
    actor = Actor.system(:agent_runtime, tenant_id)

    with {:ok, %{} = operation} <- Operations.find_operation(job_id, actor: actor),
         {:ok, run} <- Agents.find_run_by_operation(operation.id, actor: actor),
         {:ok, signal} <- Signals.load(dumped),
         {:ok, operation} <- Operations.start_operation(operation, actor: actor),
         {:ok, run} <- Agents.start_run(run, actor: actor) do
      result =
        case opts |> Keyword.get_lazy(:model, &default_model/0) |> resolve() do
          {:ok, model} -> Runner.run(run, signal, Keyword.put(opts, :model, model))
          {:refused, _reason} = refused -> refused
        end

      finish(result, run, operation, actor)
    end
  end

  # The run's and the Operation's terminal writes commit together, so a
  # crash cannot leave a terminal run with a running Operation.
  defp finish(result, run, operation, actor) do
    {:ok, :ok} = Audit.transaction(fn -> terminalize(result, run, operation, actor) end)

    case result do
      {:refused, reason} -> {:error, reason}
      _result -> :ok
    end
  end

  defp terminalize(result, run, operation, actor) do
    {:ok, run} = Agents.get_run(run.id, actor: actor)

    case {run.status, result} do
      # R0-07 slice C: an unreleased generation-2 output is never a success
      # or a crash; the run (and its Operation) stay for run recovery.
      {:running, result} ->
        if ResultGate.unreleased?(run),
          do: :ok,
          else: terminalize_running(result, run, operation, actor)

      {_terminal, _result} ->
        fail_operation(operation, run, actor)
    end
  end

  defp terminalize_running(result, run, operation, actor) do
    case result do
      {:ok, _agent} ->
        {:ok, _} = Agents.succeed_run(run, actor: actor)
        {:ok, _} = Operations.succeed_operation(operation, actor: actor)
        :ok

      {:refused, reason} ->
        {:ok, failed} =
          Agents.fail_run(
            run,
            %{status_reason: :provider_error, failure_reason: Runtime.refusal_message(reason)},
            actor: actor
          )

        fail_operation(operation, failed, actor)

      {:error, reason} ->
        {:ok, failed} =
          Agents.fail_run(run, %{status_reason: :crash, failure_reason: describe(reason)},
            actor: actor
          )

        fail_operation(operation, failed, actor)
    end
  end

  @doc """
  Fails the Operation of a stopped `run`, linking the run's attention
  Failure (one queue entry per condition).

  C9 resolution race: a run stopped by a refused reservation
  (`:grant_exhausted`, `:grant_unavailable`) links the refusal's Failure
  even if an admin resolved it before the stop. An Operation may link only a
  live Failure, so when that Failure is no longer live the Operation fails
  with its own new `budget_exhausted` Failure (subject the Operation,
  naming the resolved refusal): the run keeps the refusal as its cause, the
  failed Operation keeps a live queue entry, and nothing is recorded as a
  crash. The Operation, then the Failure are locked before the choice (lock
  order Operation → Failure → chain head, as `Operation :fail` takes them).

  R0-07 slice C: a run stopped by the result gate (`:witness_mismatch`,
  `:witness_unreconciled`) follows the same rule with its gate cause: when
  that cause is no longer live the Operation fails with its own
  `reconciliation_required` Failure naming it (critical for a mismatch,
  else a warning). There is no generic provider-error fallback.
  """
  def fail_operation(operation, %{status_reason: reason} = run, actor)
      when reason in @refused or reason in @gate do
    # The locks must hold from the liveness check to the Operation change,
    # so this always runs in one transaction (joining the caller's, if any).
    {:ok, :ok} =
      Audit.transaction(fn ->
        {:ok, operation} = lock_operation(operation, actor)

        attrs =
          if live_failure?(run.attention_failure_id, actor),
            do: %{failure_id: run.attention_failure_id},
            else: %{failure: resolved_cause_failure(run)}

        {:ok, _} = Operations.fail_operation(operation, attrs, actor: actor)
        :ok
      end)

    :ok
  end

  def fail_operation(operation, run, actor) do
    {:ok, _} =
      Operations.fail_operation(operation, %{failure_id: run.attention_failure_id}, actor: actor)

    :ok
  end

  defp lock_operation(operation, actor) do
    Operations.Operation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^operation.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
  end

  # Read FOR UPDATE, so a resolution cannot slip between this check and the
  # Operation's link of the same Failure.
  defp live_failure?(id, actor) do
    Operations.Failure
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, %{status: status}} ->
        status in [:open, :acknowledged]

      # A missing row or a read error is not a human resolution: fail loudly
      # rather than open a Failure that claims the cause was resolved.
      {:ok, nil} ->
        raise "cause Failure #{id} not found for its run"

      {:error, error} ->
        raise "could not read cause Failure #{id}: #{Exception.message(error)}"
    end
  end

  defp resolved_cause_failure(%{status_reason: reason} = run) when reason in @gate do
    %{
      class: :reconciliation_required,
      severity: if(reason == :witness_mismatch, do: :critical, else: :warning),
      retryable: false,
      message:
        "agent run #{run.status}: #{run.status_reason}; its result gate cause " <>
          "(Failure #{run.attention_failure_id}) was resolved before the run stopped"
    }
  end

  defp resolved_cause_failure(run) do
    %{
      class: :budget_exhausted,
      severity: :critical,
      retryable: false,
      message:
        "agent run #{run.status}: #{run.status_reason}; its model call reservation " <>
          "refusal (Failure #{run.attention_failure_id}) was resolved before the run stopped"
    }
  end

  # Fixture responders and provider choice may travel with the job (tests,
  # demo); only the two reviewed providers can be named.
  # A provider name outside the two reviewed ones is refused, never run on
  # the Fake.
  defp model(%{"model" => %{} = model}) do
    options =
      case model["responder"] do
        nil -> []
        responder -> [responder: Module.safe_concat([responder])]
      end

    case Map.fetch(@providers, model["provider"]) do
      {:ok, provider} -> [provider: provider, provider_options: options]
      :error -> {:refused, :unknown_model_provider}
    end
  end

  defp model(_args), do: default_model()

  defp resolve({:refused, _reason} = refused), do: refused

  defp resolve(model) do
    case Runtime.resolve(model) do
      {:ok, model} -> {:ok, model}
      {:error, reason} -> {:refused, reason}
    end
  end

  defp default_model,
    do: :sdr_agent |> Application.get_env(SdrAgent.SDR, []) |> Keyword.get(:model, [])

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason, limit: 5)
end
