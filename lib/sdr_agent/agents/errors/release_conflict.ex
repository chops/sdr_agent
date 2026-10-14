defmodule SdrAgent.Agents.Errors.ReleaseConflict do
  @moduledoc """
  A `SdrAgent.Agents.ModelResultRelease` was decided for an invocation that
  already has a *different* release (R0-07: one immutable release per
  invocation). An identical replay returns the existing row; a conflicting
  decision fails with this error (class `:invalid`) and writes nothing.
  """
  use Splode.Error,
    fields: [:model_invocation_id, :existing_id, :existing_cause_id],
    class: :invalid

  def message(error) do
    "model invocation #{error.model_invocation_id} already has a different release " <>
      "(#{error.existing_id})"
  end
end
