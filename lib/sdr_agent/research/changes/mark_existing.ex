defmodule SdrAgent.Research.Changes.MarkExisting do
  @moduledoc """
  Idempotent create on an identity (S2 ResearchArtifact: "returns existing
  row"). The action is a never-updating upsert (`INSERT … ON CONFLICT`,
  ADR-0009 amendment), so a repeated or concurrent record of the same source
  returns the stored row; this change marks such a row `:sdr_replayed`, so
  `SdrAgent.Audit.Changes.AppendEvent` appends no second event. Must come
  before `AppendEvent`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      if record.id == Ash.Changeset.get_attribute(changeset, :id),
        do: {:ok, record},
        else: {:ok, Ash.Resource.put_metadata(record, :sdr_replayed, true)}
    end)
  end
end
