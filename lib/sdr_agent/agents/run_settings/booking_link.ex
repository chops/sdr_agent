defmodule SdrAgent.Agents.RunSettings.BookingLink do
  @moduledoc """
  The owner's scheduling page (C4 section 3.2, C4-R13; embedded in a
  `SettingsRevision`): `url` (`https`, a host name, no user info, no IP literal or local host, port
  absent or 443, at most 2,048 bytes, not secret-shaped, and a host the
  real-data guard accepts at save;
  `SdrAgent.Agents.RunSettings.Changes.ApplyContentRules`), stored exactly as
  given. The guard is checked again at every use
  (`SdrAgent.Agents.RunSettings.booking_link_for_use/1`). It has no built-in
  default (C4-R7).
  """
  use Ash.Resource, data_layer: :embedded

  changes do
    change {SdrAgent.Agents.RunSettings.Changes.ApplyContentRules, urls: [:url]}
  end

  attributes do
    attribute :url, :string do
      allow_nil? false
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end
  end
end
