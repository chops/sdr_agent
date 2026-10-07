defmodule SdrAgent.SDR.Signals do
  @moduledoc """
  The SDR agent's signal vocabulary (spec §5) and its ledger record.

  `build/3` makes a `Jido.Signal` (source `/sdr_agent/sdr`, a UUIDv7 id) of a
  known type with id-only data. `record/3` appends the signal to the audit
  chain (S2 "Not persisted as their own entities": category `signal`,
  `event_type` the signal type, `causation_id` the signal id) — Jido's own
  persistence restores execution state only; the ledger is the record.

  S7 routes the assignment, research, qualification, draft, suppression and
  campaign-pause signals (`SdrAgent.SDR.SDRAgent`); approval, delivery,
  reply and follow-up signals are declared here for S8/S9.
  """

  alias SdrAgent.Audit

  @source "/sdr_agent/sdr"
  @types ~w(sdr.lead.assigned sdr.research.requested sdr.research.completed
            sdr.qualification.requested sdr.qualification.completed
            sdr.draft.requested sdr.draft.completed
            sdr.approval.granted sdr.approval.rejected
            sdr.delivery.completed sdr.delivery.failed
            sdr.reply.received sdr.followup.due
            sdr.lead.suppressed sdr.campaign.paused)

  @doc "Every signal type of spec §5."
  def types, do: @types

  @doc "The signal source of the SDR agent plane."
  def source, do: @source

  @doc "Builds a signal of `type` with `data` (ids only). Option `:id` restores a stored signal."
  def build(type, data, opts \\ []) when is_map(data) do
    if type in @types do
      attrs = %{type: type, source: @source, data: data}
      attrs = if id = Keyword.get(opts, :id), do: Map.put(attrs, :id, id), else: attrs
      Jido.Signal.new(attrs)
    else
      {:error, :unknown_signal_type}
    end
  end

  @doc "Portable map of a signal (for Oban job args)."
  def dump(%Jido.Signal{} = signal),
    do: %{"id" => signal.id, "type" => signal.type, "data" => stringify(signal.data)}

  @doc "Rebuilds a signal from `dump/1`."
  def load(%{"id" => id, "type" => type, "data" => data}),
    do:
      build(type, Map.new(data, fn {key, value} -> {String.to_existing_atom(key), value} end),
        id: id
      )

  @doc """
  Appends `signal` to the audit chain as `actor`. `opts`: `:run` (the
  AgentRun it belongs to), `:subject` (`{resource, id}`; default the lead
  in the data), `:parent` (the signal that caused it).
  """
  def record(%Jido.Signal{} = signal, actor, opts \\ []) do
    run = Keyword.get(opts, :run)
    {resource, id} = Keyword.get_lazy(opts, :subject, fn -> subject(signal) end)

    Audit.append(
      %{
        event_type: signal.type,
        category: :signal,
        subject_resource: resource,
        subject_id: id,
        action: "emit",
        causation_id: signal.id,
        correlation_id: run && run.correlation_id,
        agent_run_id: run && run.id,
        payload: %{
          "signal_id" => signal.id,
          "source" => signal.source,
          "data" => stringify(signal.data),
          "parent_signal_id" => Keyword.get(opts, :parent)
        }
      },
      actor: actor
    )
  end

  defp subject(%{data: %{lead_id: id}}), do: {"SdrAgent.Sales.Lead", id}
  defp subject(%{data: %{campaign_id: id}}), do: {"SdrAgent.Sales.Campaign", id}

  defp stringify(data), do: Map.new(data, fn {key, value} -> {to_string(key), value} end)
end
