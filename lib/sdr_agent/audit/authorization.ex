defmodule SdrAgent.Audit.Authorization do
  @moduledoc """
  Embedded authorization decision recorded on every AuditEvent (ADR-0002):
  `decision` (`:authorized` or `:denied`), the `action` it applied to
  (`"Resource.action"`) and the `policy_version` in force.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :decision, :atom do
      allow_nil? false
      constraints one_of: [:authorized, :denied]
      public? true
    end

    attribute :action, :string, public?: true, constraints: [trim?: false, allow_empty?: true]
    attribute :policy_version, :string, public?: true
  end
end
