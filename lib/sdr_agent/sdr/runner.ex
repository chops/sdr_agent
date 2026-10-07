defmodule SdrAgent.SDR.Runner do
  @moduledoc """
  Runs one AgentRun turn by turn with `Jido.Agent.cmd/3`: the trigger signal
  is the first turn; every `Emit` directive a turn returns is appended to
  the audit chain (`SdrAgent.SDR.Signals.record/3`) and becomes the next
  turn. Jido directives are not a durable queue, so they are never
  dispatched through a live server: the Oban job that calls the runner is
  the durable unit, and every outcome is in Postgres before the next turn.

  After each turn the run's phase follows the agent's `phase`, and the
  agent's `budget` mirrors the run's counters. Signals of the S8 hand-off
  (`sdr.draft.completed`) end the turn chain. A turn bound guards against
  loops.

  Returns `{:ok, agent}` or `{:error, reason}`; actions that stop a run
  (budget, invalid output) have already written the run's terminal state.
  """

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgent.SDR.Signals
  alias SdrAgent.Telemetry.Agent, as: Spans

  @handoff ["sdr.draft.completed"]
  @max_turns 12
  @turn_timeout 900_000

  @doc """
  Runs `run` (which must be `running`) from `signal`. Options: `:model` —
  `SdrAgent.AI.ModelProvider.complete/2` options (`:provider`,
  `:provider_options`); default `config :sdr_agent, SdrAgent.SDR, model: …`.
  """
  def run(run, %Jido.Signal{} = signal, opts) do
    actor = Actor.system(:agent_runtime, run.tenant_id)

    Spans.with_span("sdr.agent.run", %{"sdr.agent_run.id" => run.id}, fn ->
      ctx = %Context{
        actor: actor,
        tenant_id: run.tenant_id,
        run_id: run.id,
        correlation_id: run.correlation_id,
        model: Keyword.get_lazy(opts, :model, &default_model/0)
      }

      agent =
        SDRAgent.new!(
          id: run.id,
          state: %{
            tenant_id: run.tenant_id,
            run_id: run.id,
            lead_id: run.lead_id,
            campaign_id: run.campaign_id
          }
        )

      turns(agent, [signal], ctx, 0)
    end)
  end

  defp turns(agent, [], _ctx, _count), do: {:ok, agent}
  defp turns(_agent, _queue, _ctx, count) when count >= @max_turns, do: {:error, :turn_limit}

  defp turns(agent, [%{type: type} | rest], ctx, count) when type in @handoff,
    do: turns(agent, rest, ctx, count)

  defp turns(agent, [signal | rest], ctx, count) do
    case turn(agent, signal, ctx) do
      {:ok, agent, emitted} -> turns(agent, rest ++ emitted, ctx, count + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp turn(agent, signal, ctx) do
    Spans.with_span("sdr.signal #{signal.type}", %{"sdr.signal.id" => signal.id}, fn ->
      evaluate(agent, signal, %{
        ctx
        | signal_id: signal.id,
          signal_type: signal.type,
          otel: Spans.current()
      })
    end)
  end

  defp evaluate(agent, signal, ctx) do
    opts = [context: %{sdr: ctx}, max_concurrency: 1, timeout: @turn_timeout]

    with {:ok, agent, directives} <- Jido.Agent.cmd(agent, signal, opts),
         {:ok, run} <- Agents.get_run(ctx.run_id, actor: ctx.actor),
         emitted = for(%Jido.Agent.Directive.Emit{signal: next} <- directives, do: next),
         :ok <- record(emitted, signal, run, ctx),
         {:ok, agent} <- sync(agent, run, ctx) do
      {:ok, agent, emitted}
    end
  end

  defp record(emitted, parent, run, ctx) do
    Enum.reduce_while(emitted, :ok, fn signal, :ok ->
      case Signals.record(signal, ctx.actor, run: run, parent: parent.id) do
        {:ok, _event} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp sync(agent, run, ctx) do
    phase = agent.state.phase

    with {:ok, run} <- maybe_set_phase(run, phase, ctx) do
      Jido.Agent.set(agent,
        budget: %{
          model_calls: run.budget.model_calls_used,
          tool_calls: run.budget.tool_calls_used
        }
      )
    end
  end

  defp maybe_set_phase(%{phase: phase} = run, phase, _ctx), do: {:ok, run}

  defp maybe_set_phase(%{status: :running} = run, phase, ctx),
    do: Agents.set_run_phase(run, phase, actor: ctx.actor)

  defp maybe_set_phase(run, _phase, _ctx), do: {:ok, run}

  defp default_model,
    do: :sdr_agent |> Application.get_env(SdrAgent.SDR, []) |> Keyword.get(:model, [])
end
