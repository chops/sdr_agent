defmodule SdrAgent.Outreach.FollowUps do
  @moduledoc """
  The follow-up switch: `config :sdr_agent, :follow_ups, :enabled | :disabled`.

  Follow-ups run only where the setting is exactly `:enabled` (config/dev.exs,
  config/test.exs). Production sets `:disabled` (config/prod.exs) for the
  hosted copy's containment (D-218 item 9: the D-206 suppression fix of the
  follow-up worker's lookup is deferred only under it); a missing setting or
  any other value is disabled too (fail closed). It is read at each use, so a
  release's own configuration decides.

  Enforced where a follow-up starts, each refusal logged with ids only:

    * scheduling — `SdrAgent.Outreach.Delivery` inserts no follow-up job after
      an accepted delivery (the enrollment still advances);
    * execution — `SdrAgent.SDR.FollowupWorker` cancels a queued job before
      any read: no decision, suppression lookup or `sdr.followup.due` signal.
  """
  require Logger

  @doc "True only when `config :sdr_agent, :follow_ups` is exactly `:enabled`."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:sdr_agent, :follow_ups) == :enabled

  @doc """
  Logs a refused follow-up at `stage` (`:scheduling` or `:execution`) for an
  enrollment and step position (ids only, no row content).
  """
  @spec log_refusal(:scheduling | :execution, String.t(), integer()) :: :ok
  def log_refusal(stage, enrollment_id, step_position) when stage in [:scheduling, :execution] do
    Logger.warning(
      "follow-up #{stage} refused: follow-ups are disabled " <>
        "(enrollment #{enrollment_id}, step #{step_position})"
    )
  end
end
