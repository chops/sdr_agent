defmodule SdrAgent.Agents.RunSettings.OfferingItem do
  @moduledoc """
  One structured item of an offering profile (C4 section 3.2): `id`
  (`^[a-z0-9][a-z0-9_-]{0,39}$`, unique within its profile), `kind`
  (`:feature | :use_case | :outcome | :limit | :proof_point`) and `text`
  (settings text, 1..400 characters). The content rules are applied by
  `SdrAgent.Agents.RunSettings.Changes.ApplyContentRules`. Research and drafts cite an item as
  `(revision id, item id)`, so a citation resolves against the exact
  revision.
  """
  use Ash.Resource, data_layer: :embedded

  @kinds [:feature, :use_case, :outcome, :limit, :proof_point]

  changes do
    change {SdrAgent.Agents.RunSettings.Changes.ApplyContentRules,
            text: [text: {1, 400}], ids: [:id]}
  end

  attributes do
    attribute :id, :string do
      allow_nil? false
      public? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :text, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end
  end

  @doc "The closed set of item kinds."
  def kinds, do: @kinds
end
