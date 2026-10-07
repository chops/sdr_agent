defmodule SdrAgent.Research.SourceLocation do
  @moduledoc """
  Embedded location of an evidence quote in its artifact's content: the
  half-open range `[char_start, char_end)` in Unicode code points
  (`char_start ≥ 0`, `char_end > char_start`).
  """
  use Ash.Resource, data_layer: :embedded

  validations do
    validate compare(:char_end, greater_than: :char_start)
  end

  attributes do
    attribute :char_start, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :char_end, :integer, allow_nil?: false, public?: true, constraints: [min: 1]
  end
end
