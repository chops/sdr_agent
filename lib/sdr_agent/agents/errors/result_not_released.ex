defmodule SdrAgent.Agents.Errors.ResultNotReleased do
  @moduledoc """
  A business read of a generation-2 ClaudeCLI model output that has no
  `:released` `SdrAgent.Agents.ModelResultRelease` (R0-07 REQ-07-5; ADR-0005
  R0 amendment item 4, "No bypass"). Raised as a changeset error (class
  `:invalid`, on `field`) by the output consumers; the plain-API form is
  `{:error, :result_not_released}`.
  """
  use Splode.Error, fields: [:field, :model_invocation_id], class: :invalid

  def message(error),
    do:
      "model output of invocation #{error.model_invocation_id} is not released (result_not_released)"
end
