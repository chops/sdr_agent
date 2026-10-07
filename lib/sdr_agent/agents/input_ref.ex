defmodule SdrAgent.Agents.Decision.InputRef do
  @moduledoc """
  Embedded reference to a record a Decision used as input: its resource,
  id and `record_sha256` (lowercase hex) at decision time.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :resource, :string, allow_nil?: false, public?: true
    attribute :id, :string, allow_nil?: false, public?: true
    attribute :record_sha256, :string, public?: true
  end
end
