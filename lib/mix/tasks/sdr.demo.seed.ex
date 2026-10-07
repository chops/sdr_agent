defmodule Mix.Tasks.Sdr.Demo.Seed do
  @shortdoc "Seeds the deterministic demo data set (dev/test only)"

  @moduledoc """
  Seeds the fictional demo data set (`SdrAgent.Demo.Fixtures`) through the
  domain APIs as the seeder actor:

      mix sdr.demo.seed

  Refuses to run outside `MIX_ENV=dev` or `test` before starting the
  application; the domain additionally refuses every seed write unless
  `config :sdr_agent, seeding_allowed?: true` (set only in dev and test).
  Idempotent: re-running writes nothing.
  """
  use Mix.Task

  @doc false
  @impl Mix.Task
  def run(_args) do
    unless allowed_env?(Mix.env()) do
      Mix.raise("mix sdr.demo.seed runs only in dev and test (MIX_ENV=#{Mix.env()})")
    end

    Mix.Task.run("app.start")

    case SdrAgent.Demo.Seed.run() do
      {:ok, %{created: created, existing: existing}} ->
        Mix.shell().info("Demo seed: #{created} rows written, #{existing} already present.")

      {:error, reason} ->
        Mix.raise("Demo seed refused: #{inspect(reason)}")
    end
  end

  @doc "True for the Mix environments the demo seed may run in."
  @spec allowed_env?(atom()) :: boolean()
  def allowed_env?(env), do: env in [:dev, :test]
end
