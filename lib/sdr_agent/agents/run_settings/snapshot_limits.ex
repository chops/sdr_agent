defmodule SdrAgent.Agents.RunSettings.SnapshotLimits do
  @moduledoc """
  The twelve operational limits in effect when a run settings snapshot was
  taken (C4 section 3.2, embedded in `SdrAgent.Agents.RunSettingsSnapshot`):
  each field is the saved revision's or built-in default's value. It is
  never rewritten; the allowance at use is computed, not stored
  (`SdrAgent.Agents.RunSettings.allowance/2`).
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    for field <- SdrAgent.Agents.RunSettings.Safeguards.limit_fields() do
      attribute field, :integer do
        allow_nil? false
        public? true
      end
    end
  end
end
