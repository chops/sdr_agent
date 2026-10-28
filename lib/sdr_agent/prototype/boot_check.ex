defmodule SdrAgent.Prototype.BootCheck do
  @moduledoc """
  The one D-237 boot check (interfaces r6 IF-2; amendment item 2 "Boot"),
  used by every process kind: setup (after the phase-2 commit), the task
  entry (before any read and before Oban), and serve and every other start
  (as a supervision child after the Repo and before the model provider).

  | Switch | Binding | Witness store root | Result |
  |---|---|---|---|
  | off | absent | (ordinary rules) | ordinary runtime |
  | on | present and exact | unset | prototype runtime |
  | on | present and exact | set | refuse |
  | on | absent | any | refuse |
  | off | present | any | refuse |

  "Exact": the binding row exists exactly once; its instance and policy
  digest equal the switch and the compiled entry; the live database name,
  oid and `system_identifier` equal the row's; the suppression check is the
  Store implementation; the users are exactly the anchor plus at most the
  one bound auditor; no agent-environment (C2*) configuration is set.

  - `check/1` decides one switch value (`:off` or
    `%{policy_id: String.t(), instance_id: String.t()}`) and returns
    `{:ok, :ordinary}`, `{:ok, :prototype, SdrAgent.Prototype.Binding.t()}`
    or `{:error, code}` with a code of `reasons/0`;
  - `verify!/0` runs `check/1` on the configured switch and, on success,
    fixes `SdrAgent.Prototype.runtime/0` for the VM; on failure it raises
    `SdrAgent.Prototype.BootCheck.Refusal` carrying one fixed code;
  - `start_link/1` (the supervision child) runs `verify!/0` and returns
    `:ignore` on success or `{:error, code}`, which fails the start.

  RED stage (D-237 S1): `check/1`, `verify!/0` and `start_link/1` return
  `{:error, :not_implemented}`.
  """

  @doc "The closed set of boot refusal codes (`SdrAgent.Prototype.SafeLog.reasons(:boot)`)."
  @spec reasons() :: [atom()]
  def reasons, do: SdrAgent.Prototype.SafeLog.reasons(:boot) -- [:none]

  @doc "Decides one switch value; see the moduledoc."
  @spec check(:off | %{policy_id: String.t(), instance_id: String.t()}) ::
          {:ok, :ordinary}
          | {:ok, :prototype, SdrAgent.Prototype.Binding.t()}
          | {:error, atom()}
  def check(_switch), do: red({:error, :not_implemented})

  @doc "Runs the check on the configured switch and fixes the runtime, or raises one code."
  @spec verify!() :: :ok | {:error, :not_implemented}
  def verify!, do: red({:error, :not_implemented})

  @doc "As `verify!/0`; `switch:` replaces the configured switch (the child and tests)."
  @spec verify!(keyword()) :: :ok | {:error, :not_implemented}
  def verify!(_opts), do: red({:error, :not_implemented})

  @doc "The supervision child spec (see `start_link/1`)."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary, type: :worker}
  end

  @doc "Runs `verify!/0`; `:ignore` on success, `{:error, code}` on refusal."
  @spec start_link(term()) :: :ignore | {:error, atom()}
  def start_link(_arg), do: red({:error, :not_implemented})

  # RED stub result, typed dynamic() so success clauses of callers compile
  # against the stub (Elixir 1.20 infers literal returns); nothing sets the key.
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end

defmodule SdrAgent.Prototype.BootCheck.Refusal do
  @moduledoc """
  Raised by `SdrAgent.Prototype.BootCheck.verify!/0` with one fixed boot
  refusal `code`; its message is `"prototype boot refused: <code>"` and holds
  no value.
  """
  defexception [:code]

  @impl true
  def message(%{code: code}), do: "prototype boot refused: #{code}"
end
