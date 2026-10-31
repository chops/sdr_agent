defmodule SdrAgent.SDR.OfflineGate do
  @moduledoc """
  S-B6 (ADR-0024 offline queueing; plan r2): the eligibility check an agent
  job runs before its START transition.

  `check/3` returns `{:snooze, 60}` only when every one of these holds:

    * the job's resolved model is `{:ok, model}` with provider
      `SdrAgent.AI.ModelProvider.ClaudeCLI.Remote` (the trusted `:remote`
      transport);
    * the job has not started: its AgentRun is `:queued` and, for
      `SdrAgent.SDR.AgentWorker`, its Operation is `:enqueued` (`waiting?`,
      computed by the worker);
    * `ClaudeCLI.Remote.availability/1` says the Mac worker cannot take
      work now: no active worker, paused intake or no fresh heartbeat.

  Otherwise it returns `:run` and the worker's existing path is unchanged:
  a refused resolution still STARTs and fails with its attention Failure,
  and started or terminal rows keep their existing handling. A snooze
  writes nothing in the domain (no START, reservation, charge or Failure); Oban
  reschedules the same job, restoring its attempt, so `max_attempts: 1`
  is never spent by waiting. The wait is unbounded and uncharged.

  The check is a lock-free point read and never admission evidence:
  `Remote.prepare/2` applies the same availability again immediately before
  reservation, and the worker's claim rechecks under its own locks.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Remote

  @snooze_seconds 60
  @offline [:provider_not_running, :provider_held, :provider_offline]

  @doc "`{:snooze, 60}` while the Mac worker is offline for a queued job; else `:run`. See the moduledoc."
  def check({:ok, model}, waiting?, actor) when is_list(model) do
    with Remote <- model[:provider],
         true <- waiting?,
         {:error, reason} when reason in @offline <- Remote.availability(actor) do
      {:snooze, @snooze_seconds}
    else
      _admitted_or_not_gated -> :run
    end
  end

  def check(_resolved, _waiting?, _actor), do: :run
end
