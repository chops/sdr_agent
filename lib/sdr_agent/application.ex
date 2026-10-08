defmodule SdrAgent.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias SdrAgent.AI.ModelProvider.Runtime, as: ModelProviderRuntime

  @impl true
  def start(_type, _args) do
    SdrAgent.Telemetry.setup()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SdrAgent.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc false
  # The supervision tree, in start order. The runtime-selected model
  # provider (one named ClaudeCLI server when `SDR_MODEL_PROVIDER=claude_cli`,
  # nothing for the Fake; ADR-0004) starts before Oban, so no agent job can
  # run before its provider exists.
  def children do
    SdrAgent.Telemetry.test_children() ++
      [
        SdrAgentWeb.Telemetry,
        SdrAgent.Repo,
        {DNSCluster, query: Application.get_env(:sdr_agent, :dns_cluster_query) || :ignore}
      ] ++
      ModelProviderRuntime.children() ++
      [
        {Oban, Application.fetch_env!(:sdr_agent, Oban)},
        {Phoenix.PubSub, name: SdrAgent.PubSub},
        # Relays committed audit events to live operator views (ADR-0012).
        SdrAgent.LiveEvents.Relay,
        # Start to serve requests, typically the last entry
        SdrAgentWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :sdr_agent]}
      ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SdrAgentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
