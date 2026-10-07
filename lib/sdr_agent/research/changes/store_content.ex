defmodule SdrAgent.Research.Changes.StoreContent do
  @moduledoc """
  `ResearchArtifact :record`: stores the full source content (argument
  `content`, verbatim, never truncated) as a content-addressed Payload in
  the action's transaction, sets `content_sha256`, and checks that the
  `excerpt` is a substring of that content (S2).
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Payload

  @impl true
  def change(changeset, _opts, context) do
    content = Ash.Changeset.get_argument(changeset, :content)
    excerpt = Ash.Changeset.get_attribute(changeset, :excerpt)

    cond do
      not is_binary(content) ->
        changeset

      is_binary(excerpt) and not String.contains?(content, excerpt) ->
        Ash.Changeset.add_error(changeset,
          field: :excerpt,
          message: "must be a substring of the content"
        )

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(:content_sha256, :crypto.hash(:sha256, content))
        |> Ash.Changeset.before_action(&store(&1, content, context.actor))
    end
  end

  defp store(changeset, content, actor) do
    content_type = Ash.Changeset.get_argument(changeset, :content_type)

    Payload
    |> Ash.Changeset.for_create(:store, %{content: content, content_type: content_type},
      actor: actor
    )
    |> Ash.create(return_notifications?: true)
    |> case do
      # The payload store has no notifiers; its (empty) notifications are dropped.
      {:ok, _payload, _notifications} -> changeset
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end
end
