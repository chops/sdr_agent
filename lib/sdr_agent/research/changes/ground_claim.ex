defmodule SdrAgent.Research.Changes.GroundClaim do
  @moduledoc """
  The deterministic grounding check of `EvidenceClaim :record` (S2):

    * `lead_id` equals the artifact's lead;
    * the `content` argument is the artifact's stored content —
      sha256(content) equals the artifact's `content_sha256`, so the check
      runs against the exact stored bytes (content-addressed) without
      reading Payload content outside the audited `read_content` path;
    * `content[char_start, char_end)` (Unicode code points, half-open) equals
      `quote` byte for byte.

  A failing claim is not persisted; the S7 orchestrator records the
  rejection as a Decision outcome.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Research.ResearchArtifact

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      get = &Ash.Changeset.get_attribute(changeset, &1)
      content = Ash.Changeset.get_argument(changeset, :content)
      lead_id = get.(:lead_id)

      case artifact(get.(:research_artifact_id)) do
        nil ->
          invalid(changeset, :research_artifact_id, "does not exist")

        %{lead_id: artifact_lead} when artifact_lead != lead_id ->
          invalid(changeset, :lead_id, "must be the artifact's lead")

        artifact ->
          check_span(changeset, artifact, content)
      end
    end)
  end

  defp check_span(changeset, artifact, content) do
    location = Ash.Changeset.get_attribute(changeset, :source_location)

    cond do
      :crypto.hash(:sha256, content) != artifact.content_sha256 ->
        invalid(changeset, :content, "is not the artifact's stored content")

      span(content, location) != Ash.Changeset.get_attribute(changeset, :quote) ->
        invalid(changeset, :quote, "does not match the cited span of the source")

      true ->
        changeset
    end
  end

  defp span(content, %{char_start: start, char_end: stop}) do
    points = String.codepoints(content)

    if stop <= length(points),
      do: points |> Enum.slice(start, stop - start) |> Enum.join(),
      else: :out_of_range
  end

  defp span(_content, _location), do: :no_location

  # Internal invariant read (as Ash's get_and_lock_for_update); nothing is returned.
  defp artifact(nil), do: nil

  defp artifact(id) do
    ResearchArtifact
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
  end

  defp invalid(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
