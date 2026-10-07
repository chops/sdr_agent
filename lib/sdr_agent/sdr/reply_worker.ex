defmodule SdrAgent.SDR.ReplyWorker do
  @moduledoc """
  Oban worker (queue `agent`, spec §13) that runs the AgentRun classifying
  one matched reply (`sdr.reply.received` → `ClassifyReply`). The run, this
  job and the signal event were written in the reply's transaction
  (`SdrAgent.SDR.ReplyIntake`). Like `SdrAgent.SDR.AgentWorker`, agent work
  is never retried automatically (`max_attempts: 1`; ADR-0004): a run that
  stops (budget, invalid output) or crashes is terminal with its attention
  Failure, and the run's terminal write happens once; an exception or exit
  inside the run is caught and recorded as a `crash` failure. (A crash of
  the terminal write itself, or of the VM, still leaves the run `running`:
  abandoned-run recovery is S13's, as for `AgentWorker`.) A run that is no
  longer queued (already worked) is left alone. Integration jobs have no
  Operation row (S9 choice 12); the AgentRun is the operator record.
  """
  use Oban.Worker, queue: :agent, max_attempts: 1

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.SDR.Runner
  alias SdrAgent.SDR.Signals

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"tenant_id" => tenant_id, "run_id" => run_id, "signal" => dumped}
      }) do
    actor = Actor.system(:agent_runtime, tenant_id)

    with {:ok, %{status: :queued} = run} <- Agents.get_run(run_id, actor: actor),
         {:ok, signal} <- Signals.load(dumped),
         {:ok, run} <- Agents.start_run(run, actor: actor) do
      result = safe_run(run, signal)
      {:ok, :ok} = Audit.transaction(fn -> finish(result, run, actor) end)
      :ok
    else
      {:ok, _not_queued} -> :ok
      error -> error
    end
  end

  # An exception or exit inside the run becomes a failed run (crash), not a
  # discarded job with the run left running.
  defp safe_run(run, signal) do
    Runner.run(run, signal, model: model())
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp finish(result, run, actor) do
    {:ok, run} = Agents.get_run(run.id, actor: actor)

    case {run.status, result} do
      {:running, {:ok, _agent}} ->
        {:ok, _} = Agents.succeed_run(run, actor: actor)
        :ok

      {:running, {:error, reason}} ->
        {:ok, _} =
          Agents.fail_run(run, %{status_reason: :crash, failure_reason: describe(reason)},
            actor: actor
          )

        :ok

      {_terminal, _result} ->
        :ok
    end
  end

  defp model, do: :sdr_agent |> Application.get_env(SdrAgent.SDR, []) |> Keyword.get(:model, [])

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason, limit: 5)
end
