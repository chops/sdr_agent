defmodule SdrAgent.Discovery.Supervisor do
  @moduledoc """
  Isolated discovery subtree. A limiter or transport failure terminates all
  request tasks before restarting empty transient state. Paid actions are
  temporary children and are never replayed (ADR-0027).
  """
  use Supervisor

  alias SdrAgent.Discovery.ExaTransport
  alias SdrAgent.Discovery.Limiter

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Finch,
       name: SdrAgent.Discovery.Finch,
       pools: %{
         "https://api.exa.ai" => [
           size: 2,
           count: 1,
           conn_opts: ExaTransport.connection_options()
         ]
       }},
      {Task.Supervisor, name: SdrAgent.Discovery.Tasks},
      Limiter
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 10)
  end
end
