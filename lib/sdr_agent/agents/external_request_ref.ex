defmodule SdrAgent.Agents.ToolInvocation.ExternalRequestRef do
  @moduledoc """
  Embedded reference to an external request made by a tool (provider,
  request id, target, and the response body's sha256 as lowercase hex).
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :request_id, :string, allow_nil?: false, public?: true
    attribute :target, :string, public?: true
    attribute :response_sha256, :string, public?: true
  end
end
