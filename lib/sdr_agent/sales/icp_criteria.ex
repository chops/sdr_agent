defmodule SdrAgent.Sales.IcpCriteria do
  @moduledoc """
  Embedded ICP criteria (S2 IcpDefinition.criteria): optional employee-count
  bounds (each ≥ 0, max ≥ min when both are given) and lists of industries,
  geographies, personas and buying triggers. Hashed canonically into
  `IcpDefinition.criteria_sha256`.
  """
  use Ash.Resource, data_layer: :embedded

  validations do
    validate compare(:employee_count_max, greater_than_or_equal_to: :employee_count_min),
      where: [present([:employee_count_min, :employee_count_max])]
  end

  attributes do
    attribute :employee_count_min, :integer, public?: true, constraints: [min: 0]
    attribute :employee_count_max, :integer, public?: true, constraints: [min: 0]
    attribute :industries, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :geographies, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :personas, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :triggers, {:array, :string}, allow_nil?: false, default: [], public?: true
  end
end
