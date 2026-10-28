defmodule SdrAgent.PrototypeFixtures do
  @moduledoc """
  Test fixtures for the D-237 prototype (interfaces r6 IF-1..IF-3), used by
  every slice's tests. Synthetic `.test`/`.invalid` data only.

  - `bind/1` runs the real setup phase-2 bootstrap inside the test's
    sandbox (tenant, credential-less anchor, optional auditor, the binding
    with the live identity, the setup session's delegation) and, unless
    `enter_runtime: false`, enters prototype runtime for the calling test
    process (and the processes it starts, through `$callers`). It returns
    `{:ok, %{tenant:, anchor:, auditor:, binding:, snapshot:, delegation:,
    actor:}}`. Options: `auditor: true`, `agent:`, `session_correlation:`,
    `enter_runtime:`.
  - `enter_runtime/1` fixes prototype runtime with a given
    `SdrAgent.Prototype.Binding` snapshot for this test process only (a
    test-seam build feature; other test processes keep ordinary runtime);
    `leave_runtime/0` returns it to ordinary.
  - `put_live_identity/1` overrides fields of the live database identity
    (`database`, `database_oid`, `system_identifier`, or `:raise`) for this
    test process; by default the test database reads as
    `sdr_agent_prototype`.
  - `switch/1` is the switch value of a bound fixture.

  RED stage (D-237 S1): every function returns `{:error, :not_implemented}`.
  """

  @doc "Binds a prototype in the sandbox; see the moduledoc."
  @spec bind(keyword()) :: {:ok, map()} | {:error, term()}
  def bind(_opts \\ []), do: red({:error, :not_implemented})

  @doc "Enters prototype runtime with `snapshot` for this test process."
  @spec enter_runtime(SdrAgent.Prototype.Binding.t()) :: :ok | {:error, term()}
  def enter_runtime(_snapshot), do: red({:error, :not_implemented})

  @doc "Returns this test process to ordinary runtime."
  @spec leave_runtime() :: :ok | {:error, term()}
  def leave_runtime, do: red({:error, :not_implemented})

  @doc "Overrides the live database identity for this test process."
  @spec put_live_identity(map() | :raise) :: :ok | {:error, term()}
  def put_live_identity(_overrides), do: red({:error, :not_implemented})

  @doc "The switch value of a bound fixture."
  @spec switch(map()) :: map() | {:error, term()}
  def switch(_fixture), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
