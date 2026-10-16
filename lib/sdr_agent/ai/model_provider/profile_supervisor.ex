defmodule SdrAgent.AI.ModelProvider.ProfileSupervisor do
  @moduledoc """
  The C2-02b2α model server tree (`docs/product/r0/c2-02b2-interface.md`
  section 2), `:rest_for_one`, registered under this module's name:

    1. `SdrAgent.AI.ModelProvider.ServerSupervisor`: a `DynamicSupervisor`
       whose children are `:temporary`, so no ClaudeCLI server restarts on
       its own;
    2. `SdrAgent.AI.ModelProvider.Coordinator`: the only process that
       starts, stops or replaces a server, and the only writer of the b2
       ledger;
    3. `SdrAgent.AI.ModelProvider.OperationSupervisor`: a `Task.Supervisor`
       for the coordinator's switch worker, so no worker outlives its
       coordinator.

  Options (passed to the coordinator): `server:` (`fn profile_id ->
  ClaudeCLI start options end`, configuration), `cleanup_wait_ms:` (at
  most 10 s); in test builds only, `manual: true` and `faults:` (see the
  coordinator's moduledoc, including the C2-02b2β resolution faults).
  """
  use Supervisor

  alias SdrAgent.AI.ModelProvider.Coordinator

  @doc false
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      {DynamicSupervisor,
       name: SdrAgent.AI.ModelProvider.ServerSupervisor, strategy: :one_for_one},
      {Coordinator, opts},
      {Task.Supervisor, name: SdrAgent.AI.ModelProvider.OperationSupervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
