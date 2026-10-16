defmodule SdrAgent.Agents.RunSettings.ResearchBrief do
  @moduledoc """
  The editable research guidance (C4 section 3.2; D-050, D-051; embedded
  in a `SettingsRevision`): `guidance`, settings text of 1..12,000
  characters, and `depth`, the one MVP depth `:standard` (D-052). It holds
  no Fixed rule: those live with the prompt templates and always frame
  this text.
  """
  use Ash.Resource, data_layer: :embedded

  @depths [:standard]

  changes do
    change {SdrAgent.Agents.RunSettings.Changes.ApplyContentRules, text: [guidance: {1, 12_000}]}
  end

  attributes do
    attribute :guidance, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :depth, :atom do
      allow_nil? false
      public? true
      constraints one_of: @depths
    end
  end
end
