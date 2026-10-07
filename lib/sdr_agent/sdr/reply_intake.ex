defmodule SdrAgent.SDR.ReplyIntake do
  @moduledoc """
  Agent-plane implementation of `SdrAgent.Outreach.ReplyIntake`: records the
  `sdr.reply.received` signal (data `reply_id`, `lead_id`, `campaign_id`,
  `enrollment_id`; actor the webhook ingestor) in the matched reply's
  transaction.
  """
  @behaviour SdrAgent.Outreach.ReplyIntake

  alias SdrAgent.SDR.Signals

  @impl true
  def received(reply, match, actor) do
    with {:ok, signal} <-
           Signals.build("sdr.reply.received", %{
             reply_id: reply.id,
             lead_id: match.lead_id,
             campaign_id: match.campaign_id,
             enrollment_id: match.enrollment_id
           }),
         {:ok, _event} <- Signals.record(signal, actor),
         do: :ok
  end
end
