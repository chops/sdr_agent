defmodule SdrAgentWeb.Provenance do
  @moduledoc """
  Evidence provenance shown to reviewers (ADR-0026). Evidence the hosted
  owner typed into the intake form (`ResearchArtifact.provider ==
  :owner_intake`) is labelled "Owner-supplied, unverified" wherever it is
  cited. The rule reads the artifact's provider only; no other field or
  caller claim makes evidence owner-supplied or verified.
  """
  use Phoenix.Component

  @doc "True when `artifact` is evidence from an owner intake."
  @spec owner_supplied?(term()) :: boolean()
  def owner_supplied?(%{provider: :owner_intake}), do: true
  def owner_supplied?(_artifact), do: false

  @doc "True when any of `artifacts` is owner-supplied."
  @spec any_owner_supplied?(Enumerable.t()) :: boolean()
  def any_owner_supplied?(artifacts), do: Enum.any?(artifacts, &owner_supplied?/1)

  @doc "The owner-supplied label for `artifact`; renders nothing for other evidence."
  attr :artifact, :any, required: true

  def label(assigns) do
    ~H"""
    <span
      :if={owner_supplied?(@artifact)}
      data-provenance="owner_intake"
      class="inline-flex items-center gap-1 rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-inset ring-amber-200"
    >
      Owner-supplied, unverified
    </span>
    """
  end
end
