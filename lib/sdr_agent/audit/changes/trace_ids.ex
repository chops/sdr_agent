defmodule SdrAgent.Audit.Changes.TraceIds do
  @moduledoc """
  Shared create change (ADR-0005, ADR-0009 "Trace correlation"): stamps the
  row with the `trace_id`/`span_id` of the span the write runs in (the Ash
  action span), opening one when none is active.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Trace

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      {trace_id, span_id} = Trace.row_ids()

      changeset
      |> Ash.Changeset.force_change_attribute(:trace_id, trace_id)
      |> Ash.Changeset.force_change_attribute(:span_id, span_id)
    end)
  end
end
