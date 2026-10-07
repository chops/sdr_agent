defmodule SdrAgent.Integrations do
  @moduledoc """
  The integration plane's anti-corruption layer (spec §1, §17): behaviours
  for every outside system the agent reads, and the configured adapter for
  each. In the MVP only fixture adapters exist — deterministic, offline,
  synthetic (ADR-0001: no outbound network in tests, synthetic data only).

    * `SdrAgent.Integrations.CRM` — `SdrAgent.Integrations.FakeCRM`
    * `SdrAgent.Integrations.SearchProvider` — `SdrAgent.Integrations.FixtureSearch`
    * `SdrAgent.Integrations.WebFetch` — `SdrAgent.Integrations.FixtureWeb`

  Adapters are chosen with `config :sdr_agent, :integrations, crm: …,
  search: …, web: …`; Req lives inside a real adapter when one is added.
  """

  @defaults [
    crm: SdrAgent.Integrations.FakeCRM,
    search: SdrAgent.Integrations.FixtureSearch,
    web: SdrAgent.Integrations.FixtureWeb
  ]

  @doc "The configured CRM adapter."
  def crm, do: adapter(:crm)

  @doc "The configured search adapter."
  def search, do: adapter(:search)

  @doc "The configured web-fetch adapter."
  def web, do: adapter(:web)

  defp adapter(key) do
    :sdr_agent
    |> Application.get_env(:integrations, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
