defmodule SdrAgent.Audit.Checks.SeedingAllowed do
  @moduledoc """
  Policy check: the actor is the seeder (SEED) *and* this deployment allows
  seeding (ADR-0009 "IDs": seed actions are authorized only for the seeder in
  `:dev`/`:test`).

  Seeding is allowed when `config :sdr_agent, seeding_allowed?: true` — set
  only in `config/dev.exs` and `config/test.exs`; any other environment
  (absent key) refuses every seed write at the policy layer.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the seeder and seeding is allowed in this environment"

  @impl true
  def match?(%SdrAgent.Actor{type: :seeder}, _context, _opts), do: allowed?()
  def match?(_actor, _context, _opts), do: false

  @doc "True when this deployment allows seeding."
  @spec allowed?() :: boolean()
  def allowed?, do: Application.get_env(:sdr_agent, :seeding_allowed?, false) == true
end
