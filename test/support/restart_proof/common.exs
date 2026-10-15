# Shared by the C9-04 restart proof scripts (`SdrAgent.Agents.GrantRestartProofTest`).
# Each script runs in its own fresh BEAM under `MIX_ENV=test`, against the
# one synthetic database the parent test owns.
defmodule SdrAgent.RestartProof do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Repo

  @now ~U[2026-10-20 12:00:00.000000Z]

  def now, do: @now

  # Refuses anything but the owned synthetic database on the devenv port,
  # the test build and the Fake provider; then takes a real connection.
  def connect!(database) do
    config = Repo.config()
    true = Regex.match?(~r/\Asdr_agent_test_rp[0-9a-f]{10}\z/, database)
    ^database = config[:database]
    "localhost" = config[:hostname]
    5520 = config[:port]
    :test = Mix.env()
    SdrAgent.AI.ModelProvider.Fake = Application.fetch_env!(:sdr_agent, :model_provider)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Sandbox.mode(Repo, {:shared, self()})
    SdrAgent.Clock.freeze(@now)
    :ok
  end

  def reserve(%{run: run, agent: agent}, key) do
    attrs =
      key
      |> SdrAgent.AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))

    SdrAgent.Agents.reserve_model_invocation(run, attrs, actor: agent)
  end

  def allocations(grant) do
    grant.allocations
    |> Enum.map(fn a ->
      %{
        "id" => a.id,
        "key" => to_string(a.key),
        "applies_to" => Enum.map(a.applies_to, &to_string/1),
        "attempts" => a.attempts,
        "available_from" => a.available_from && DateTime.to_iso8601(a.available_from),
        "released_at" => a.released_at && DateTime.to_iso8601(a.released_at),
        "grant_revision" => a.grant_revision
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  def consumed(filter) do
    require Ash.Query

    SdrAgent.Agents.ModelInvocation
    |> Ash.Query.filter(^filter)
    |> Ash.count!(authorize?: false)
  end
end
