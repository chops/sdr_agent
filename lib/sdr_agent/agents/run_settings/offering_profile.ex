defmodule SdrAgent.Agents.RunSettings.OfferingProfile do
  @moduledoc """
  What the owner sells (C4 section 3.2, embedded in a `SettingsRevision`):
  `name` (1..120), `summary` (1..1,500), `audience` (0..1,500, nil when
  empty) and `items` (1..30 `SdrAgent.Agents.RunSettings.OfferingItem`s with
  unique ids). Every text field follows the settings text rules
  (`SdrAgent.Agents.RunSettings.Changes.ApplyContentRules`); the canonical
  encoding of the whole profile is at most 16 KiB. It has no built-in default (C4-R7).
  """
  use Ash.Resource, data_layer: :embedded

  alias SdrAgent.Agents.RunSettings.Changes.ApplyContentRules
  alias SdrAgent.Agents.RunSettings.OfferingItem
  alias SdrAgent.Agents.RunSettings.Validations.OfferingShape

  changes do
    change {ApplyContentRules, text: [name: {1, 120}, summary: {1, 1_500}, audience: {0, 1_500}]}
  end

  validations do
    validate OfferingShape
  end

  attributes do
    attribute :name, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :summary, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :audience, :string do
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :items, {:array, OfferingItem} do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 30
    end
  end
end
