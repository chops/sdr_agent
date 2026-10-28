defmodule SdrAgent.PrototypeFixtures do
  @moduledoc """
  Test fixtures for the D-237 prototype (interfaces r6 IF-1..IF-3), used by
  every slice's tests. Synthetic `.test`/`.invalid` data only. Nothing here
  fabricates a result: every fixture runs the real path and returns its
  result, so an unimplemented prerequisite fails as itself.

  - `bind/1` runs the real setup phase-2 bootstrap
    (`SdrAgent.Prototype.Authority.bootstrap/1`) inside the test's sandbox,
    builds the boot snapshot of the created row
    (`SdrAgent.Prototype.Authority.snapshot/1`) and, unless
    `enter_runtime: false`, enters prototype runtime for the calling test
    process through the test-build-only seam; the operator actor comes
    from the real resolver (`SdrAgent.Prototype.operator_actor/1`), run in
    prototype runtime. It returns `{:ok, %{tenant:, anchor:, auditor:,
    binding:, snapshot:, delegation:, actor:}}` or the first error.
    Options: `auditor: true`, `agent:`, `session_correlation:`,
    `enter_runtime:`. Arrange any other users BEFORE entering prototype
    runtime (`enter_runtime: false`): prototype runtime refuses user
    administration for every actor.
  - `enter_runtime/1`, `leave_runtime/0`, `put_live_identity/1` delegate to
    `SdrAgent.Prototype.Authority.TestSeam` (test builds only).
  - `switch/1` is the switch value of a bound fixture's snapshot.
  """

  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Authority
  alias SdrAgent.Prototype.Authority.TestSeam

  @doc "Binds a prototype in the sandbox through the real bootstrap; see the moduledoc."
  @spec bind(keyword()) :: {:ok, map()} | {:error, term()}
  def bind(opts \\ []) do
    bootstrap_opts = [
      agent: Keyword.get(opts, :agent, :claude_code),
      session_correlation: Keyword.get(opts, :session_correlation, "fixture-setup-session-01"),
      auditor_password:
        if(Keyword.get(opts, :auditor, false), do: String.duplicate("A", 43), else: nil)
    ]

    with {:ok, created} <- Authority.bootstrap(bootstrap_opts),
         {:ok, snapshot} <- Authority.snapshot(created.binding),
         :ok <- TestSeam.enter_runtime(snapshot),
         {:ok, actor} <- Prototype.operator_actor(created.delegation.id),
         :ok <- leave_unless(Keyword.get(opts, :enter_runtime, true)) do
      {:ok, Map.merge(created, %{snapshot: snapshot, actor: actor})}
    end
  end

  defp leave_unless(true), do: :ok
  defp leave_unless(false), do: TestSeam.leave_runtime()

  @doc "Enters prototype runtime with `snapshot` for this test process."
  @spec enter_runtime(SdrAgent.Prototype.Binding.t()) :: :ok | {:error, term()}
  def enter_runtime(snapshot), do: TestSeam.enter_runtime(snapshot)

  @doc "Returns this test process to ordinary runtime."
  @spec leave_runtime() :: :ok | {:error, term()}
  def leave_runtime, do: TestSeam.leave_runtime()

  @doc "Overrides the live database identity for this test process."
  @spec put_live_identity(map() | :raise) :: :ok | {:error, term()}
  def put_live_identity(overrides), do: TestSeam.put_live_identity(overrides)

  @doc "The switch value of a bound fixture."
  @spec switch(map()) :: %{policy_id: String.t(), instance_id: String.t()}
  def switch(%{snapshot: %{policy_id: policy_id, instance_id: instance_id}}),
    do: %{policy_id: policy_id, instance_id: instance_id}
end
