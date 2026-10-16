defmodule SdrAgent.Agents.RunSettings.WritingGuide do
  @moduledoc """
  The tone and shape of drafts (C4 section 3.2; D-053, D-065; embedded in a
  `SettingsRevision`): `text`, settings text of 1..6,000 characters. The
  built-in default is neutral generic text
  (`SdrAgent.Agents.RunSettings.CodeDefaults`, OQ-5).
  """
  use Ash.Resource, data_layer: :embedded

  changes do
    change {SdrAgent.Agents.RunSettings.Changes.ApplyContentRules, text: [text: {1, 6_000}]}
  end

  attributes do
    attribute :text, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end
  end
end
