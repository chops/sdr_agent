defmodule SdrAgent.Agents.Checks.ReleasedOutputRead do
  @moduledoc """
  Field-policy check: the read is the released-output read
  (`SdrAgent.Agents.released_output/2`), marked by a private query context
  key (R0-07 REQ-07-5). The mark alone releases nothing: the
  `ModelInvocation.parsed_output` field policy additionally requires a
  `:released` `SdrAgent.Agents.ModelResultRelease` for the row.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_released_output_read

  @impl true
  def describe(_opts), do: "request is the released-output read"

  @impl true
  def match?(_actor, %{subject: %{context: context}}, _opts) when is_map(context),
    do: Map.get(context, @marker) == true

  def match?(_actor, _context, _opts), do: false

  @doc "The context map `SdrAgent.Agents.released_output/2` attaches to its read."
  def context, do: %{@marker => true}
end
