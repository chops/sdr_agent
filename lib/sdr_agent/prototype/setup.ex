# The D-237 setup orchestration exists only in builds that compile the
# prototype authority (config/dev.exs and config/test.exs); the production
# build contains no setup code.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Setup do
    @moduledoc """
    The D-237 setup orchestration (interfaces r6 IF-2 "Setup bootstrap
    contract"; setup contract r3, Codex 85ab1090 and 57fc6bb4): one pure
    orchestrator over a map of closed, injected effects (`real_effects/1`
    in the task, a recording stub in tests).

    - `run/2` runs phase 0 (preflight), phase 1 (storage before
      `with_repo`, then inside its callback the no-inherited-transaction
      guard, the target identity, the migration or resume checks and the
      freshness check), phase 2 (`bootstrap/1`, which commits) and phase 3
      (`BootCheck.verify!/0`, the operator actor and the seed, all at top
      level), each step stopping on its refusal.
    - `preflight/2` (phase 0) returns the internal `Setup.Context` (the
      marker's identifier and the exact validated seed, handed on to the
      seed unchanged); `prepare_storage/2` is phase 1's storage steps;
      `cluster_identity_check/2` is phase 0's pure identity decision.

    Results are `{:ok, %{binding_id:, delegation_id:}}` or `{:error, f}`,
    with `f` the exact three-key `setup_phase` map (a reason of
    `SdrAgent.Prototype.SafeLog.reasons(:setup)`), `{:unexpected, phase}` or
    `{:sink_unavailable, 0}` (value-free; their terminal form is S1b's).
    `args` are the task's exact strings (`agent:` "claude_code" or
    "codex_cli", compared exactly); the context and `bootstrap/1` carry the
    normalized agent atom. Every returned bootstrap or Seed code is
    presented as `:refused` (no code establishes a rollback). Effects are
    supplied by trusted internal task code only. Supported entry is the
    top-level task process: the storage effects run before the
    nested-transaction guard (setup contract r3 §4).

    Stage (D-237 S1): RED declarations only (Codex 85ab1090 bounded GO).
    Every function is non-permissive: it calls no effect and returns
    `{:error, :not_implemented}` (`real_effects/1`: an empty map).
    """

    defmodule Context do
      @moduledoc """
      The internal result of a successful setup phase 0 (never logged or
      printed): the marker's `system_identifier`, the EXACT validated seed
      term `read_seed` returned (handed to the seed unchanged, never read
      again), its four pins, the mode, the agent and the session
      correlation.
      """

      defstruct [:system_identifier, :seed, :seed_sha256s, :mode, :agent, :session_correlation]

      @type t :: %__MODULE__{
              system_identifier: pos_integer() | nil,
              seed: map() | nil,
              seed_sha256s: map() | nil,
              mode: :fresh | :resume | nil,
              agent: :claude_code | :codex_cli | nil,
              session_correlation: String.t() | nil
            }
    end

    @type effects :: %{optional(atom()) => function()}
    @type args :: map()
    @type failure ::
            %{phase: 0..3, result: :refused | :rolled_back, reason: atom()}
            | {:unexpected, 0..3}
            | {:sink_unavailable, 0}

    @doc "Runs setup phases 0-3 over `effects`; see the moduledoc. RED: not implemented."
    @spec run(effects(), args()) ::
            {:ok, %{binding_id: String.t(), delegation_id: String.t()}}
            | {:error, failure() | :not_implemented}
    def run(_effects, _args), do: red({:error, :not_implemented})

    @doc "Setup phase 0; see the moduledoc. RED: not implemented."
    @spec preflight(effects(), args()) ::
            {:ok, Context.t()} | {:error, failure() | :not_implemented}
    def preflight(_effects, _args), do: red({:error, :not_implemented})

    @doc "Setup phase 1's storage steps, before `with_repo`. RED: not implemented."
    @spec prepare_storage(effects(), Context.t()) :: :ok | {:error, failure() | :not_implemented}
    def prepare_storage(_effects, _context), do: red({:error, :not_implemented})

    @doc """
    Phase 0's pure identity decision between the marker and the maintenance
    identity. RED: not implemented.
    """
    @spec cluster_identity_check(term(), term()) ::
            :ok | {:error, :cluster_identity_mismatch | :unexpected | :not_implemented}
    def cluster_identity_check(_marker, _identity), do: red({:error, :not_implemented})

    @doc "The real effects for one run's `args` (held). RED: an empty map."
    @spec real_effects(args()) :: effects()
    def real_effects(_args), do: red(%{})

    # RED stub result, typed dynamic() so callers compile against the stub
    # (Elixir 1.20 infers literal returns). Read-only: nothing writes the
    # key; removed in GREEN.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
