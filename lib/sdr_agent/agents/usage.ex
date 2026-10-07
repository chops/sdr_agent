defmodule SdrAgent.Agents.ModelInvocation.Usage do
  @moduledoc "Embedded token and plan-call usage reported for one model call."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :input_tokens, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0],
      public?: true

    attribute :output_tokens, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0],
      public?: true

    attribute :plan_calls, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0],
      public?: true
  end
end
