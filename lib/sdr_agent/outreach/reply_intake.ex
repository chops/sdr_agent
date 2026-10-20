defmodule SdrAgent.Outreach.ReplyIntake do
  @moduledoc """
  The seam through which a matched reply reaches the agent plane (spec §16
  "… → Oban → sdr.reply.received → Jido") without Outreach depending on it
  (Outreach is the highest domain; the agent plane sits above it and calls
  its code interfaces). `SdrAgent.Outreach.Webhooks` calls the configured
  implementation (`config :sdr_agent, :reply_intake, Module`; default
  `SdrAgent.SDR.ReplyIntake`) inside the reply's transaction, so whatever it
  records commits with the Reply or not at all; a deferral records nothing.
  """

  @doc """
  Called once per matched reply, as the webhook ingestor, inside the reply
  transaction: `match` has `lead_id`, `campaign_id`, `enrollment_id`.

  Returns `:ok` (handed off), `{:error, term}` (the whole event rolls back
  and retries) or, C3-02 (plan r8 section 6.7; D-174 Q-O5),
  `{:deferred, :agent_definition_unavailable}`: the callee wrote nothing,
  the reply phase commits without the hand-off and the event stays
  unprocessed, so a later attempt of the same event performs it.
  """
  @callback received(reply :: struct(), match :: map(), actor :: SdrAgent.Actor.t()) ::
              :ok | {:deferred, :agent_definition_unavailable} | {:error, term()}

  @doc "The configured implementation."
  def impl, do: Application.fetch_env!(:sdr_agent, :reply_intake)
end
