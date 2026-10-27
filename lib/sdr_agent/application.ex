defmodule SdrAgent.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Boot
  alias SdrAgent.AgentEnv.Shutdown
  alias SdrAgent.Agents.Witness
  alias SdrAgent.AI.ModelProvider.Runtime, as: ModelProviderRuntime

  @impl true
  def start(_type, _args) do
    # C2* S1 (L3): an agent-environment configuration may refuse the start
    # before anything else runs; unconfigured, this is a no-op.
    Boot.check_start!()
    # S12d: an explicitly configured but untrusted or missing witness store
    # root refuses to boot, before anything starts or reads (ADR-0005).
    Witness.check_configured_root!()
    SdrAgent.Telemetry.setup()
    # ADR-0005 C4 amendment: crash reports and error logs never carry raw
    # database or Ash error values.
    :ok = SdrAgent.Logger.ExceptionFilter.attach()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SdrAgent.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc false
  # The supervision tree, in start order. The runtime-selected model
  # provider (one named ClaudeCLI server when `SDR_MODEL_PROVIDER=claude_cli`,
  # nothing for the Fake; ADR-0004) starts before Oban, so no agent job can
  # run before its provider exists. An agent-environment mode restricts or
  # extends it (`SdrAgent.AgentEnv.Boot.children/2`); unconfigured it is
  # exactly this list.
  def children do
    Boot.children(AgentEnv.mode(), base_children())
  end

  defp base_children do
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

  # C2* S1 P5: in run mode, plan the orderly exit while the tree is alive
  # (SdrAgent.AgentEnv.Shutdown); otherwise inert.
  @impl true
  def prep_stop(state) do
    if AgentEnv.mode() == :run, do: Shutdown.plan(SdrAgent.Supervisor), else: state
  end

  # C2* S1 P5: in run mode, complete the planned exit after the tree has
  # exited (a receipt only after the whole-instance barrier). Always :ok.
  @impl true
  def stop(state) do
    if AgentEnv.mode() == :run, do: Shutdown.complete(state)
    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SdrAgentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
