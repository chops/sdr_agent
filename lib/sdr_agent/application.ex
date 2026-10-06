defmodule SdrAgent.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    SdrAgent.Telemetry.setup()

    children = [
      SdrAgentWeb.Telemetry,
      SdrAgent.Repo,
      {DNSCluster, query: Application.get_env(:sdr_agent, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:sdr_agent, Oban)},
      {Phoenix.PubSub, name: SdrAgent.PubSub},
      # Start a worker by calling: SdrAgent.Worker.start_link(arg)
      # {SdrAgent.Worker, arg},
      # Start to serve requests, typically the last entry
      SdrAgentWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :sdr_agent]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SdrAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SdrAgentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
