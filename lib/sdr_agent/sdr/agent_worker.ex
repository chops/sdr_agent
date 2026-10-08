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
  that server is not running, no model call is made: the run fails with
  `provider_error` (opening its critical attention Failure, linked from the
  Operation) and the job returns `{:error, :provider_not_running}` — never
  a raise, never the Fake instead.
  """
  use Oban.Worker, queue: :research, max_attempts: 1

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Audit
  alias SdrAgent.Operations
  alias SdrAgent.SDR.Runner
  alias SdrAgent.SDR.Signals

  @providers %{
    "fake" => SdrAgent.AI.ModelProvider.Fake,
    "claude_cli" => SdrAgent.AI.ModelProvider.ClaudeCLI
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job), do: run(job, model: model(args))

  @doc """
  Executes the job's run with runner options (`:model`, resolved through
  `SdrAgent.AI.ModelProvider.Runtime`; default: the configured model).
  Returns `:ok`, or `{:error, :provider_not_running}` once that refusal is
  recorded.
  """
  def run(%Oban.Job{id: job_id, args: %{"tenant_id" => tenant_id, "signal" => dumped}}, opts) do
    actor = Actor.system(:agent_runtime, tenant_id)

    with {:ok, %{} = operation} <- Operations.find_operation(job_id, actor: actor),
         {:ok, run} <- Agents.find_run_by_operation(operation.id, actor: actor),
         {:ok, signal} <- Signals.load(dumped),
         {:ok, operation} <- Operations.start_operation(operation, actor: actor),
         {:ok, run} <- Agents.start_run(run, actor: actor) do
      result =
        case opts |> Keyword.get_lazy(:model, &default_model/0) |> Runtime.resolve() do
          {:ok, model} -> Runner.run(run, signal, Keyword.put(opts, :model, model))
          {:error, :provider_not_running} = refused -> refused
        end

      finish(result, run, operation, actor)
    end
  end

  # The run's and the Operation's terminal writes commit together, so a
  # crash cannot leave a terminal run with a running Operation.
  defp finish(result, run, operation, actor) do
    {:ok, :ok} = Audit.transaction(fn -> terminalize(result, run, operation, actor) end)

    case result do
      {:error, :provider_not_running} = refused -> refused
      _result -> :ok
    end
  end

  defp terminalize(result, run, operation, actor) do
    {:ok, run} = Agents.get_run(run.id, actor: actor)

    case {run.status, result} do
      {:running, {:ok, _agent}} ->
        {:ok, _} = Agents.succeed_run(run, actor: actor)
        {:ok, _} = Operations.succeed_operation(operation, actor: actor)
        :ok

      {:running, {:error, :provider_not_running}} ->
        {:ok, failed} =
          Agents.fail_run(
            run,
            %{
              status_reason: :provider_error,
              failure_reason:
                "model provider claude_cli is not running: no supervised ClaudeCLI " <>
                  "server (select it with SDR_MODEL_PROVIDER=claude_cli); no model call was made"
            },
            actor: actor
          )

        fail_operation(operation, failed, actor)

      {:running, {:error, reason}} ->
        {:ok, failed} =
          Agents.fail_run(run, %{status_reason: :crash, failure_reason: describe(reason)},
            actor: actor
          )

        fail_operation(operation, failed, actor)

      {_terminal, _result} ->
        fail_operation(operation, run, actor)
    end
  end

  defp fail_operation(operation, run, actor) do
    {:ok, _} =
      Operations.fail_operation(operation, %{failure_id: run.attention_failure_id}, actor: actor)

    :ok
  end

  # Fixture responders and provider choice may travel with the job (tests,
  # demo); only the two reviewed providers can be named.
  defp model(%{"model" => %{} = model}) do
    options =
      case model["responder"] do
        nil -> []
        responder -> [responder: Module.safe_concat([responder])]
      end

    [
      provider: Map.get(@providers, model["provider"], SdrAgent.AI.ModelProvider.Fake),
      provider_options: options
    ]
  end

  defp model(_args), do: default_model()

  defp default_model,
    do: :sdr_agent |> Application.get_env(SdrAgent.SDR, []) |> Keyword.get(:model, [])

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason, limit: 5)
end
