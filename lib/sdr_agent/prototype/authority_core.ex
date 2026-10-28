# The D-237 prototype authority exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs; ADR-0005 D-237 amendment item 2 "Development build only").
# The production build contains neither module below.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Authority do
    @moduledoc """
    The D-237 prototype authority behind `SdrAgent.Prototype` (interfaces r6
    IF-1, IF-2). Compiled only under `:prototype_authority_compiled`.

    Entry points (the facade's and the setup and provision tasks'):

    - `bootstrap/1`: setup phase 2, one `SdrAgent.Audit.transaction`
      creating the tenant, the credential-less anchor, the optional
      auditor (`auditor_password:`), the binding and the setup session's
      delegation (`agent:`, `session_correlation:`); `{:ok, %{tenant:,
      anchor:, auditor:, binding:, delegation:}}`, or
      `{:error, :bootstrap_failed}` with everything rolled back;
    - `snapshot/1`: the `SdrAgent.Prototype.Binding` of a binding row;
    - `resolve_delegation/2`: resolver steps 3-7 of IF-1 for a boot snapshot
      and a delegation row (or nil);
    - setup phase 0/1 checks: `check_repo_target/1`, `check_app_stopped/0`,
      `write_credential/1`, `check_fresh/0`, `check_resumable/0`,
      `pinned_migrations/0`;
    - `check_worksheet/3`: the IF-2 budget worksheet with byte-resolved
      evidence under a root.

    RED stage (D-237 S1, non-permissive declarations): every function
    returns `{:error, :not_implemented}`; none fabricates success.
    """

    @doc "Setup phase 2; see the moduledoc."
    @spec bootstrap(keyword()) :: {:ok, map()} | {:error, atom()}
    def bootstrap(_opts), do: red({:error, :not_implemented})

    @doc "The boot snapshot of a binding row."
    @spec snapshot(struct()) :: {:ok, SdrAgent.Prototype.Binding.t()} | {:error, atom()}
    def snapshot(_binding), do: red({:error, :not_implemented})

    @doc "Resolver steps 3-7 (IF-1) for `snapshot` and a delegation row or nil."
    @spec resolve_delegation(SdrAgent.Prototype.Binding.t(), struct() | nil) ::
            {:ok, SdrAgent.Actor.t()} | {:error, atom()}
    def resolve_delegation(_snapshot, _delegation), do: red({:error, :not_implemented})

    @doc "`:ok` when a Repo config targets exactly the prototype socket, port and database."
    @spec check_repo_target(keyword()) :: :ok | {:error, :repo_target_mismatch}
    def check_repo_target(_config), do: red({:error, :not_implemented})

    @doc "`:ok` when no Oban, endpoint or provider name is alive; otherwise `:app_running`."
    @spec check_app_stopped() :: :ok | {:error, :app_running}
    def check_app_stopped, do: red({:error, :not_implemented})

    @doc "Creates the auditor credential file exclusively (0600) and returns its password."
    @spec write_credential(Path.t()) :: {:ok, String.t()} | {:error, atom()}
    def write_credential(_path), do: red({:error, :not_implemented})

    @doc "`:ok` when the database holds no tenant, user, binding, delegation, head or business row."
    @spec check_fresh() :: :ok | {:error, :database_not_fresh}
    def check_fresh, do: red({:error, :not_implemented})

    @doc "`:ok` when the database holds exactly the pinned migrations and no row (bounded resume)."
    @spec check_resumable() :: :ok | {:error, :database_not_resumable}
    def check_resumable, do: red({:error, :not_implemented})

    @doc "The pinned migration set, `[{version, name}]` in order."
    @spec pinned_migrations() :: [{integer(), String.t()}] | {:error, atom()}
    def pinned_migrations, do: red({:error, :not_implemented})

    @doc "Checks the IF-2 budget worksheet `bytes` (its sha256 hex, the evidence root)."
    @spec check_worksheet(binary(), String.t(), Path.t()) ::
            {:ok, %{sha256: String.t(), remaining: non_neg_integer()}} | {:error, atom()}
    def check_worksheet(_bytes, _sha256_hex, _evidence_root), do: red({:error, :not_implemented})

    # RED stub result, typed dynamic() so callers compile against the stub
    # (Elixir 1.20 infers literal returns). Read-only: nothing writes the key
    # (ruling e); removed in GREEN.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end

  # The hermetic test seam (interfaces r6 ruling a): only in builds that also
  # set `prototype_test_seams: true` (config/test.exs alone).
  if Application.compile_env(:sdr_agent, :prototype_test_seams, false) do
    defmodule SdrAgent.Prototype.Authority.TestSeam do
      @moduledoc """
      Test-build-only D-237 seam (interfaces r6 ruling a). It never exists
      in dev or prod builds, and the authority flag alone does not enable it.

      - `enter_runtime/1` fixes prototype runtime with a
        `SdrAgent.Prototype.Binding` snapshot for the calling process only;
        `SdrAgent.Prototype.runtime/0` then reads it from that process, or
        from an explicit local `$callers` ancestor (as `SdrAgent.Clock`
        does). An unrelated process, or a dead caller, contributes nothing.
      - `put_live_identity/1` overrides fields of the live database identity
        (`database`, `database_oid`, `system_identifier`) or makes its read
        raise (`:raise`), for the calling process; by default the test
        database reads as `sdr_agent_prototype`.
      - `leave_runtime/0` returns the process to ordinary runtime;
        `clear/0` removes every seam key of the process (deterministic
        cleanup).

      RED stage (D-237 S1): every function returns `{:error, :not_implemented}`.
      """

      @doc "Enters prototype runtime with `snapshot` for the calling process."
      @spec enter_runtime(SdrAgent.Prototype.Binding.t()) :: :ok | {:error, atom()}
      def enter_runtime(_snapshot), do: red({:error, :not_implemented})

      @doc "Returns the calling process to ordinary runtime."
      @spec leave_runtime() :: :ok | {:error, atom()}
      def leave_runtime, do: red({:error, :not_implemented})

      @doc "Overrides the live identity for the calling process (`map` or `:raise`)."
      @spec put_live_identity(map() | :raise) :: :ok | {:error, atom()}
      def put_live_identity(_overrides), do: red({:error, :not_implemented})

      @doc "Removes every seam key of the calling process."
      @spec clear() :: :ok | {:error, atom()}
      def clear, do: red({:error, :not_implemented})

      # RED stub result, typed dynamic() (see SdrAgent.Prototype.Authority).
      defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
    end
  end
end
