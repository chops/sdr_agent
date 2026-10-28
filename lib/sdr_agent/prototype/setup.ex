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

    - `run/2` runs phase 0 (preflight), phase 1 (the early `repo_state/0`
      check, storage before `with_repo`, then inside its callback the
      no-inherited-transaction guard, the target identity, the migration
      or resume checks and the freshness check), phase 2 (`bootstrap/1`,
      which commits) and phase 3 (`BootCheck.verify!/0`, the operator actor
      and the seed, all at top level), each step stopping on its refusal.
    - `preflight/2` (phase 0) returns the internal `Setup.Context` (the
      marker's identifier and the exact validated seed, handed on to the
      seed unchanged); `prepare_storage/2` is phase 1's storage steps;
      `cluster_identity_check/2` is phase 0's pure identity decision;
      `repo_state_check/1` is phase 1's pure decision on `repo_state/0`.

    Results are `{:ok, %{binding_id:, delegation_id:}}` or `{:error, f}`,
    with `f` the exact three-key `setup_phase` map (a reason of
    `SdrAgent.Prototype.SafeLog.reasons(:setup)`), `{:unexpected, phase}` or
    `{:sink_unavailable, 0}` (value-free; their terminal form is S1b's).
    `args` are the task's exact strings (`agent:` "claude_code" or
    "codex_cli", compared exactly); the context and `bootstrap/1` carry the
    normalized agent atom. Every returned bootstrap or Seed code is
    presented as `:refused` (no code establishes a rollback). Effects are
    supplied by trusted internal task code only. Supported entry is the
    top-level task process: a positively established Repo transaction
    refuses before any storage effect (setup contract r4 Q-C), and the
    nested-transaction guard inside the callback is kept.

    Each effect's success shape is exact and typed; only its documented
    refusal family maps to a closed reason, any other value is
    `{:unexpected, phase}`, and a raise propagates (the one rescue is the
    typed `BootCheck.Refusal` around `verify`). `with_repo/1` gets one
    single-use callback per run: its first call runs phases 1b-3 and
    returns `{ref, result}`, any later call runs nothing, and only
    `{:ok, {^ref, result}, apps}` with a proper list of apps is accepted
    (single use is not a replay detector; the wrapper is trusted). Phase 2
    commits inside `bootstrap/1`; no setup transaction wraps phases 2-3,
    and a phase-3 refusal leaves the phase-2 rows ("bound, unseeded").

    Stage (D-237 S1, Codex b8ac3654 bounded I3): the orchestration is
    implemented; `real_effects/1` stays deny-only (an empty map, I4).
    """

    alias SdrAgent.Accounts.User
    alias SdrAgent.Actor
    alias SdrAgent.Audit.Tenant
    alias SdrAgent.Operations.PrototypeDatabaseBinding
    alias SdrAgent.Operations.PrototypeDelegation
    alias SdrAgent.Prototype.Authority
    alias SdrAgent.Prototype.BootCheck

    @args_keys [
      :agent,
      :auditor_credential_out,
      :mode,
      :seed_dir,
      :seed_sha256s,
      :session_correlation
    ]
    @pin_keys [:campaign, :offering_profile, :provenance, :writing_guide]
    @agents %{"claude_code" => :claude_code, "codex_cli" => :codex_cli}
    @resolve_errors [
      :not_prototype_runtime,
      :binding_mismatch,
      :delegation_not_found,
      :delegation_foreign_tenant,
      :delegation_wrong_binding,
      :anchor_mismatch
    ]
    @seed_refusals [:seed_failed, :not_prototype_runtime, :binding_mismatch, :forbidden]
    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    @digest ~r/\A[0-9a-f]{64}\z/

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
            %{phase: 0..3, result: :refused, reason: atom()}
            | {:unexpected, 0..3}
            | {:sink_unavailable, 0}

    @doc "Runs setup phases 0-3 over `effects`; see the moduledoc."
    @spec run(effects(), args()) ::
            {:ok, %{binding_id: String.t(), delegation_id: String.t()}} | {:error, failure()}
    def run(effects, args) do
      with {:ok, context} <- preflight(effects, args),
           :ok <- prepare_storage(effects, context) do
        in_repo(effects, context)
      end
    end

    @doc "Setup phase 0; see the moduledoc."
    @spec preflight(effects(), args()) :: {:ok, Context.t()} | {:error, failure()}
    def preflight(effects, args) do
      with :ok <- attached(effects.attach_log.()),
           {:ok, agent} <- check_args(args),
           :ok <- check_environment(effects.environment.()),
           :ok <- check_repo(effects.repo_config.()),
           {:ok, marker} <- marker(effects.cluster_marker.()),
           {:ok, identity} <- maintenance(effects.maintenance_identity.()),
           :ok <- identity_result(cluster_identity_check(marker, identity)),
           :ok <- app_stopped(effects.app_stopped.()),
           {:ok, seed} <- read_seed(effects.read_seed.(args.seed_dir, args.seed_sha256s)) do
        {:ok,
         %Context{
           system_identifier: marker.system_identifier,
           seed: seed,
           seed_sha256s: args.seed_sha256s,
           mode: args.mode,
           agent: agent,
           session_correlation: args.session_correlation
         }}
      end
    end

    @doc "Setup phase 1's storage steps, before `with_repo`; see the moduledoc."
    @spec prepare_storage(effects(), Context.t()) :: :ok | {:error, failure()}
    def prepare_storage(effects, %Context{mode: mode}) do
      with :ok <- repo_state(repo_state_check(effects.repo_state.())),
           :ok <- storage(mode, effects.storage_status.()) do
        create_storage(mode, effects)
      end
    end

    @doc """
    Phase 0's pure identity decision between the marker
    (`%{system_identifier: pos_integer, data_dir: absolute path}`) and the
    maintenance identity (`%{database:, system_identifier:,
    data_directory:}`): `:ok` when both are exactly typed, the database is
    `"postgres"`, the identifiers are equal and the directories are equal;
    valid typed facts that differ are `:cluster_identity_mismatch`; any
    untyped, missing or malformed fact is `:unexpected`, never equal.
    """
    @spec cluster_identity_check(term(), term()) ::
            :ok | {:error, :cluster_identity_mismatch | :unexpected}
    def cluster_identity_check(marker, identity) do
      cond do
        not (typed_marker?(marker) and typed_identity?(identity)) -> {:error, :unexpected}
        same_cluster?(marker, identity) -> :ok
        true -> {:error, :cluster_identity_mismatch}
      end
    end

    @doc """
    Phase 1's pure decision on the early `repo_state/0` effect (setup
    contract r4 Q-C), before any storage effect: `:not_started` and
    `{:started, false}` proceed, `{:started, true}` is the explicit nested
    refusal, anything else is unexpected.
    """
    @spec repo_state_check(term()) :: :ok | {:error, :nested | :unexpected}
    def repo_state_check(:not_started), do: :ok
    def repo_state_check({:started, false}), do: :ok
    def repo_state_check({:started, true}), do: {:error, :nested}
    def repo_state_check(_state), do: {:error, :unexpected}

    @doc "The real effects for one run's `args` (held). RED: an empty map."
    @spec real_effects(args()) :: effects()
    def real_effects(_args), do: red(%{})

    # RED stub result, typed dynamic() so callers compile against the stub
    # (Elixir 1.20 infers literal returns). Read-only: nothing writes the
    # key; removed in GREEN.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)

    ## Phase 0

    defp attached(:ok), do: :ok
    defp attached({:error, reason}) when is_atom(reason), do: {:error, {:sink_unavailable, 0}}
    defp attached(_other), do: unexpected(0)

    # Exactly the six keys; then the agent, the correlation and the rest,
    # compared exactly (no trimming, case folding or coercion).
    defp check_args(args) when is_map(args) and map_size(args) == 6 do
      if Enum.sort(Map.keys(args)) == @args_keys,
        do: check_fields(args),
        else: refused(0, :invalid_arguments)
    end

    defp check_args(_args), do: refused(0, :invalid_arguments)

    defp check_fields(args) do
      with {:ok, agent} <- agent(args.agent),
           :ok <- correlation(args.session_correlation),
           :ok <- arguments(args) do
        {:ok, agent}
      end
    end

    # A closed two-entry map, never String.to_atom.
    defp agent(value) when is_binary(value) do
      case Map.fetch(@agents, value) do
        {:ok, agent} -> {:ok, agent}
        :error -> refused(0, :invalid_agent)
      end
    end

    defp agent(_value), do: refused(0, :invalid_agent)

    defp correlation(value) do
      if Authority.valid_correlation?(value),
        do: :ok,
        else: refused(0, :invalid_correlation)
    end

    defp arguments(%{seed_dir: dir, seed_sha256s: pins, mode: mode, auditor_credential_out: nil})
         when is_binary(dir) and mode in [:fresh, :resume] do
      if pins?(pins), do: :ok, else: refused(0, :invalid_arguments)
    end

    defp arguments(_args), do: refused(0, :invalid_arguments)

    defp pins?(pins) when is_map(pins) and map_size(pins) == 4,
      do: Enum.sort(Map.keys(pins)) == @pin_keys and Enum.all?(Map.values(pins), &digest?/1)

    defp pins?(_pins), do: false

    defp digest?(value) when is_binary(value), do: Regex.match?(@digest, value)
    defp digest?(_value), do: false

    # Exactly the five keys with an atom and four booleans (else
    # unexpected); then the refusals in order.
    defp check_environment(
           %{
             mix_env: mix_env,
             flag?: flag,
             switch?: switch,
             instance?: instance,
             session?: session
           } = environment
         )
         when map_size(environment) == 5 do
      if is_atom(mix_env) and Enum.all?([flag, switch, instance, session], &is_boolean/1),
        do: environment_refusal(mix_env, flag, switch and instance, session),
        else: unexpected(0)
    end

    defp check_environment(_environment), do: unexpected(0)

    defp environment_refusal(mix_env, _flag, _switch, _session) when mix_env != :dev,
      do: refused(0, :wrong_env)

    defp environment_refusal(_mix_env, false, _switch, _session), do: refused(0, :flag_unset)
    defp environment_refusal(_mix_env, _flag, false, _session), do: refused(0, :switch_unset)
    defp environment_refusal(_mix_env, _flag, _switch, false), do: refused(0, :session_unset)
    defp environment_refusal(_mix_env, _flag, _switch, _session), do: :ok

    defp check_repo(config) do
      case Authority.check_repo_target(config) do
        :ok -> :ok
        {:error, :repo_target_mismatch} -> refused(0, :repo_target_mismatch)
      end
    end

    # S4's family is not pinned: any non-success is unexpected (r3 R3).
    defp marker({:ok, marker}), do: {:ok, marker}
    defp marker(_other), do: unexpected(0)

    defp maintenance({:ok, identity}), do: {:ok, identity}
    defp maintenance(_other), do: unexpected(0)

    defp identity_result(:ok), do: :ok

    defp identity_result({:error, :cluster_identity_mismatch}),
      do: refused(0, :cluster_identity_mismatch)

    defp identity_result({:error, :unexpected}), do: unexpected(0)

    defp typed_marker?(%{system_identifier: id, data_dir: data_dir} = marker)
         when map_size(marker) == 2,
         do: positive?(id) and absolute?(data_dir)

    defp typed_marker?(_marker), do: false

    defp typed_identity?(
           %{database: database, system_identifier: id, data_directory: data_directory} =
             identity
         )
         when map_size(identity) == 3,
         do: is_binary(database) and positive?(id) and absolute?(data_directory)

    defp typed_identity?(_identity), do: false

    defp positive?(value), do: is_integer(value) and value > 0

    defp absolute?(path) when is_binary(path) and path != "", do: Path.type(path) == :absolute
    defp absolute?(_path), do: false

    defp same_cluster?(marker, identity) do
      identity.database == "postgres" and
        marker.system_identifier == identity.system_identifier and
        marker.data_dir == identity.data_directory
    end

    defp app_stopped(:ok), do: :ok
    defp app_stopped({:error, :app_running}), do: refused(0, :app_running)
    defp app_stopped(_other), do: unexpected(0)

    defp read_seed({:ok, seed}) when is_map(seed), do: {:ok, seed}

    defp read_seed({:error, {file, reason}}) when is_binary(file) and is_atom(reason),
      do: refused(0, :seed_invalid)

    defp read_seed(_other), do: unexpected(0)

    ## Phase 1: storage

    defp repo_state(:ok), do: :ok
    defp repo_state({:error, :nested}), do: refused(1, :bootstrap_failed)
    defp repo_state({:error, :unexpected}), do: unexpected(1)

    defp storage(:fresh, :down), do: :ok
    defp storage(:fresh, :up), do: refused(1, :database_exists)
    defp storage(:resume, :up), do: :ok
    defp storage(:resume, :down), do: refused(1, :database_not_resumable)
    defp storage(_mode, {:error, _reason}), do: refused(1, :storage_failed)
    defp storage(_mode, _other), do: unexpected(1)

    defp create_storage(:resume, _effects), do: :ok

    defp create_storage(:fresh, effects) do
      case effects.storage_up.() do
        :ok -> :ok
        {:error, :already_up} -> refused(1, :database_exists)
        {:error, _reason} -> refused(1, :storage_failed)
        _other -> unexpected(1)
      end
    end

    ## Phase 1: with_repo and its single-use callback

    # One callback per run: the first call (atomics compare-exchange 0 to 1)
    # runs phases 1b-3 and returns {ref, result}; any later call runs no
    # effect. Only {:ok, {^ref, result}, apps} with a proper list of apps
    # returns the result.
    defp in_repo(effects, context) do
      ref = make_ref()
      once = :atomics.new(1, [])

      callback = fn ->
        case :atomics.compare_exchange(once, 1, 0, 1) do
          :ok -> {ref, in_callback(effects, context)}
          _taken -> :replayed
        end
      end

      case effects.with_repo.(callback) do
        {:ok, {^ref, result}, apps} when is_list(apps) ->
          if proper_list?(apps), do: result, else: unexpected(1)

        _other ->
          unexpected(1)
      end
    end

    defp in_callback(effects, context) do
      with :ok <- top_level(effects.in_transaction.()),
           :ok <- target(effects.target_identity.(), context),
           :ok <- schema(context.mode, effects),
           :ok <- fresh(effects.check_fresh.()),
           {:ok, created} <- bootstrap(effects, context),
           :ok <- verify(effects.verify, created),
           {:ok, actor} <- actor(effects.operator_actor.(created.delegation.id), created) do
        seed(effects.seed_run.(context.seed, actor), created)
      end
    end

    defp top_level(false), do: :ok
    defp top_level(true), do: refused(1, :bootstrap_failed)
    defp top_level(_other), do: unexpected(1)

    defp target(
           {:ok, %{database: database, database_oid: oid, system_identifier: id} = identity},
           %Context{system_identifier: expected}
         )
         when map_size(identity) == 3 and is_binary(database) and is_integer(oid) and oid > 0 and
                is_integer(id) and id > 0 do
      if database == "sdr_agent_prototype" and id == expected,
        do: :ok,
        else: refused(1, :cluster_identity_mismatch)
    end

    defp target(_other, _context), do: unexpected(1)

    defp schema(:fresh, effects) do
      with :ok <- migrated(effects.migrate.()) do
        case effects.check_migrated.() do
          :ok -> :ok
          {:error, :migration_failed} -> refused(1, :migration_failed)
          _other -> unexpected(1)
        end
      end
    end

    defp schema(:resume, effects) do
      case effects.check_resumable.() do
        :ok -> :ok
        {:error, :database_not_resumable} -> refused(1, :database_not_resumable)
        _other -> unexpected(1)
      end
    end

    defp migrated({:ok, versions}) when is_list(versions) do
      if proper_list?(versions) and Enum.all?(versions, &is_integer/1),
        do: :ok,
        else: unexpected(1)
    end

    defp migrated(_other), do: unexpected(1)

    defp fresh(:ok), do: :ok
    defp fresh({:error, :database_not_fresh}), do: refused(1, :database_not_fresh)
    defp fresh(_other), do: unexpected(1)

    ## Phase 2

    defp bootstrap(effects, context) do
      case effects.bootstrap.(
             agent: context.agent,
             session_correlation: context.session_correlation
           ) do
        {:ok, created} -> if created?(created), do: {:ok, created}, else: unexpected(2)
        {:error, :bootstrap_failed} -> refused(2, :bootstrap_failed)
        _other -> unexpected(2)
      end
    end

    # r3 R2 row 17: exactly the five keys, the domain structs, no auditor,
    # one tenant, the anchor as operator, the delegation on the binding, and
    # canonical UUID ids.
    defp created?(
           %{
             tenant: %Tenant{id: tenant},
             anchor: %User{id: anchor, tenant_id: tenant},
             auditor: nil,
             binding: %PrototypeDatabaseBinding{
               id: binding,
               tenant_id: tenant,
               operator_user_id: anchor
             },
             delegation: %PrototypeDelegation{
               id: delegation,
               tenant_id: tenant,
               binding_id: binding,
               operator_user_id: anchor
             }
           } = created
         )
         when map_size(created) == 5,
         do: Enum.all?([tenant, anchor, binding, delegation], &uuid?/1)

    defp created?(_created), do: false

    defp uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
    defp uuid?(_value), do: false

    ## Phase 3

    # The one rescue: the typed boot refusal raised by `verify`.
    defp verify(verify_effect, created) do
      case verify_effect.(created) do
        :ok -> :ok
        _other -> unexpected(3)
      end
    rescue
      BootCheck.Refusal -> refused(3, :boot_refused)
    end

    defp actor(
           {:ok, %Actor{type: :prototype_operator, id: id, tenant_id: tenant} = actor},
           %{delegation: %{id: id}, tenant: %{id: tenant}}
         ),
         do: {:ok, actor}

    defp actor({:ok, %Actor{}}, _created), do: refused(3, :boot_refused)

    defp actor({:error, code}, _created) when code in @resolve_errors,
      do: refused(3, :boot_refused)

    defp actor(_other, _created), do: unexpected(3)

    defp seed({:ok, result}, created) when is_map(result),
      do: {:ok, %{binding_id: created.binding.id, delegation_id: created.delegation.id}}

    defp seed({:error, code}, _created) when code in @seed_refusals, do: refused(3, :seed_failed)
    defp seed(_other, _created), do: unexpected(3)

    ## Shapes

    defp refused(phase, reason), do: {:error, %{phase: phase, result: :refused, reason: reason}}
    defp unexpected(phase), do: {:error, {:unexpected, phase}}

    defp proper_list?([]), do: true
    defp proper_list?([_head | tail]), do: proper_list?(tail)
    defp proper_list?(_improper), do: false
  end
end
