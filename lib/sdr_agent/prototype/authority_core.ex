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
      `{:error, :bootstrap_failed}` with everything rolled back. In a
      test-seam build only (`:prototype_test_seams`), inside that
      transaction after the binding write and before the delegation's, it
      calls the one-argument hook `{SdrAgent.Prototype.Authority,
      :before_delegation}` from the calling process's dictionary with the
      rows created so far (the rollback proof's late-failure point);
    - `snapshot/1`: the `SdrAgent.Prototype.Binding` of a binding row;
    - `resolve_delegation/2`: resolver steps 3-7 of IF-1 for a boot snapshot
      and a delegation row (or nil);
    - setup phase 0/1 checks: `check_repo_target/1`, `check_app_stopped/0`,
      `write_credential/1`, `check_fresh/0`, `check_resumable/0`,
      `pinned_migrations/0`;
    - `check_worksheet/3`: the IF-2 budget worksheet with byte-resolved
      evidence under a root;
    - the compiled entries (amendment items 1 and 4, `max_contacts: 3` per
      F3): `policy_entry/0` (`d237-prototype/1`) and `funding_entry/0`
      (`d237-funding/1`, a 50-attempt ceiling, the window's end
      exclusive), with `policy_entry_sha256/0` and `funding_entry_sha256/0`,
      the lowercase hex of their `sdr-canonical-json/1` digests
      (`SdrAgent.Audit.Canonical.sha256/1` returns the raw 32 bytes).
      These are constants of this dev/test module: they confer no runtime
      authority and no provisioning eligibility, take no caller or
      environment input, and the facade's `policy_entry/0` and
      `funding_entry/0` stay runtime-gated.

    - `runtime/0` and `binding/0`: `:prototype` and the boot snapshot while
      one is in effect, else `:ordinary` and
      `{:error, :not_prototype_runtime}`. In a test-seam build
      (`:prototype_test_seams`, config/test.exs alone) the snapshot is the
      calling process's only (`SdrAgent.Prototype.Authority.TestSeam`); any
      other build stays ordinary until `SdrAgent.Prototype.BootCheck.verify!/0`
      fixes the VM runtime (increment G, not implemented).

    Stage (D-237 S1): the four entry accessors (Codex bd3eb9e1, constants
    only), B1a's self-only `runtime/0` and `binding/0` (Codex b743eb5d), and
    B2a's `bootstrap/1` with `live_identity/0` (its one plain identity read)
    are implemented. Every other
    function is still a non-permissive RED declaration returning
    `{:error, :not_implemented}`; none fabricates success.
    """

    alias SdrAgent.Accounts.User
    alias SdrAgent.Actor
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.Operations.PrototypeDatabaseBinding
    alias SdrAgent.Operations.PrototypeDelegation
    alias SdrAgent.Prototype.Binding
    alias SdrAgent.Prototype.Checks.KernelMarker
    alias SdrAgent.Repo

    @test_seams Application.compile_env(:sdr_agent, :prototype_test_seams, false)
    @database "sdr_agent_prototype"
    @agents [:claude_code, :codex_cli]
    @correlation ~r/\A[A-Za-z0-9._:-]{8,128}\z/
    @identity_sql "SELECT current_database()::text, d.oid::bigint, " <>
                    "(pg_control_system()).system_identifier FROM pg_database d " <>
                    "WHERE d.datname = current_database()"

    # Amendment item 1 (D-249: accepted interior text 54769 B), exact.
    @policy_entry %{
      database: "sdr_agent_prototype",
      dataset_class: :real_prototype,
      identity: %{provider: :claude_cli, ledger_generation: 2, profile_ids: [:claude_cli_opus]},
      usage_origins: [:assignment],
      purposes: [:qualification, :evidence_extraction, :outreach_proposal],
      witness_mode: :absent,
      funding_id: "d237-funding/1",
      max_contacts: 3,
      label: "UNVERIFIED (PROTOTYPE)",
      acceptance_ref: "D-249",
      text_sha256: "99a2869ea7501eeeb4615137f23f830de5ddabc2ac746ae6638fbc6fafde9ac0"
    }

    # Amendment item 4, exact: `total_attempts` is a ceiling, not a target;
    # `expires_at` is exclusive.
    @funding_entry %{
      total_attempts: 50,
      starts_at: ~U[2026-10-28 02:38:32.000000Z],
      expires_at: ~U[2026-11-07 07:00:00.000000Z],
      profile_ids: [:claude_cli_opus],
      funded_scope: [{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}],
      allocations: [%{key: :b1, applies_to: [:b1], profile_id: :claude_cli_opus, attempts: 50}],
      decision_refs: ["D-238", "D-239", "D-243"]
    }

    @doc "The compiled `d237-prototype/1` policy entry, exact."
    @spec policy_entry() :: map()
    def policy_entry, do: @policy_entry

    @doc "The compiled `d237-funding/1` funding entry, exact."
    @spec funding_entry() :: map()
    def funding_entry, do: @funding_entry

    @doc "Lowercase hex of the policy entry's `sdr-canonical-json/1` sha256."
    @spec policy_entry_sha256() :: String.t()
    def policy_entry_sha256, do: hex(Canonical.sha256(@policy_entry))

    @doc "Lowercase hex of the funding entry's `sdr-canonical-json/1` sha256 (the golden vector)."
    @spec funding_entry_sha256() :: String.t()
    def funding_entry_sha256, do: hex(Canonical.sha256(@funding_entry))

    @doc "`:prototype` while a boot snapshot is in effect; otherwise `:ordinary`."
    @spec runtime() :: SdrAgent.Prototype.runtime()
    def runtime do
      case current() do
        {:prototype, %Binding{}} -> :prototype
        _ordinary -> :ordinary
      end
    end

    @doc "The boot snapshot, in prototype runtime only."
    @spec binding() :: {:ok, Binding.t()} | {:error, :not_prototype_runtime}
    def binding do
      case current() do
        {:prototype, %Binding{} = snapshot} -> {:ok, snapshot}
        _ordinary -> {:error, :not_prototype_runtime}
      end
    end

    # The runtime in effect. A test-seam build reads the calling process only
    # (`SdrAgent.Prototype.Authority.TestSeam`); no global lookup. Any other
    # build keeps its RED declaration until BootCheck fixes the VM runtime
    # (increment G): ordinary, typed dynamic through `red/1`, never written.
    if @test_seams do
      @runtime_key {SdrAgent.Prototype, :runtime}

      defp current, do: SdrAgent.Prototype.Authority.TestSeam.lookup(@runtime_key)
    else
      defp current, do: red(:ordinary)
    end

    @doc "Setup phase 2; see the moduledoc."
    @spec bootstrap(keyword()) :: {:ok, map()} | {:error, :bootstrap_failed}
    def bootstrap(opts) do
      with {:ok, agent} <- setup_agent(Keyword.get(opts, :agent)),
           {:ok, correlation} <- setup_correlation(Keyword.get(opts, :session_correlation)),
           {:ok, created} <-
             Audit.transaction(fn -> bootstrap_steps(opts, agent, correlation) end) do
        {:ok, created}
      else
        _failed -> {:error, :bootstrap_failed}
      end
    rescue
      _error -> {:error, :bootstrap_failed}
    end

    # Inside the transaction: any error rolls every write back.
    defp bootstrap_steps(opts, agent, correlation) do
      with {:ok, tenant} <- Audit.bootstrap(slug: "d237", name: "D-237 prototype"),
           setup = [
             actor: Actor.system(:kernel, tenant.id),
             context: KernelMarker.context(:setup)
           ],
           {:ok, anchor} <- create(User, :create_prototype_anchor, %{}, setup),
           {:ok, auditor} <- create_auditor(Keyword.get(opts, :auditor_password), setup),
           {:ok, identity} <- prototype_identity(),
           {:ok, binding} <-
             create(
               PrototypeDatabaseBinding,
               :create,
               %{
                 instance_id: Keyword.get_lazy(opts, :instance_id, &Ecto.UUID.generate/0),
                 operator_user_id: anchor.id,
                 auditor_user_id: auditor && auditor.id,
                 policy_entry_sha256: policy_entry_sha256(),
                 database_oid: identity.database_oid,
                 system_identifier: identity.system_identifier
               },
               setup
             ),
           created = %{
             tenant: tenant,
             anchor: anchor,
             auditor: auditor,
             binding: binding,
             delegation: nil
           },
           :ok <- seam(:before_delegation, created),
           {:ok, delegation} <-
             create(
               PrototypeDelegation,
               :create_setup,
               %{agent: agent, session_correlation: correlation},
               setup
             ) do
        %{created | delegation: delegation}
      else
        _failed -> Repo.rollback(:bootstrap_failed)
      end
    end

    defp setup_agent(agent) when agent in @agents, do: {:ok, Atom.to_string(agent)}
    defp setup_agent(_agent), do: {:error, :invalid_agent}

    defp setup_correlation(correlation) when is_binary(correlation) do
      if Regex.match?(@correlation, correlation),
        do: {:ok, correlation},
        else: {:error, :invalid_correlation}
    end

    defp setup_correlation(_correlation), do: {:error, :invalid_correlation}

    defp create_auditor(nil, _setup), do: {:ok, nil}

    defp create_auditor(password, setup),
      do: create(User, :create_prototype_auditor, %{password: password}, setup)

    defp create(resource, action, params, opts) do
      resource
      |> Ash.Changeset.for_create(action, params, opts)
      |> Ash.create()
    end

    # The live identity, read inside the open transaction; the database must
    # be the prototype database.
    defp prototype_identity do
      case live_identity() do
        {:ok, %{database: @database} = identity} -> {:ok, identity}
        _other -> {:error, :not_the_prototype_database}
      end
    end

    @doc """
    The live database name, its `pg_database` oid and the cluster's
    `system_identifier`, in one plain read; any failure is
    `{:error, :live_identity_unavailable}`. In a test-seam build the test
    database's own name reads as `sdr_agent_prototype` (every other value is
    the real one).
    """
    @spec live_identity() ::
            {:ok,
             %{database: String.t(), database_oid: pos_integer(), system_identifier: integer()}}
            | {:error, :live_identity_unavailable}
    def live_identity do
      case Repo.query(@identity_sql, []) do
        {:ok, %{rows: [[name, oid, system_identifier]]}}
        when is_binary(name) and is_integer(oid) and oid > 0 and is_integer(system_identifier) ->
          {:ok,
           test_alias(%{database: name, database_oid: oid, system_identifier: system_identifier})}

        _other ->
          {:error, :live_identity_unavailable}
      end
    rescue
      _error -> {:error, :live_identity_unavailable}
    end

    if @test_seams do
      # The test database reads as the prototype database (the binding's
      # CHECK fixes `database` to it); only the name is aliased.
      defp test_alias(%{database: name} = identity) do
        test_database = Keyword.get(Application.get_env(:sdr_agent, Repo, []), :database)
        if name == test_database, do: %{identity | database: @database}, else: identity
      end

      # A one-argument hook from the calling process's dictionary at a named
      # boundary (the rollback proof's late-failure point).
      defp seam(name, arg) do
        case Process.get({__MODULE__, name}) do
          hook when is_function(hook, 1) -> hook.(arg)
          _none -> nil
        end

        :ok
      end
    else
      defp test_alias(identity), do: identity
      defp seam(_name, _arg), do: :ok
    end

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

    defp hex(digest), do: Base.encode16(digest, case: :lower)

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

      Keys are `{SdrAgent.Prototype, atom}` in the calling process's
      dictionary; `lookup/1` reads them.

      Stage (D-237 S1): B1a `enter_runtime/1` (Codex b743eb5d) and B1b
      `leave_runtime/0`, the `put_live_identity/1` storage and the
      `$callers` `lookup/1` (Codex b591e1a6) are implemented. Nothing reads
      the stored live identity yet (its consumer is B2). `clear/0` (Codex
      4d315a96) deletes exactly those two keys from the calling process.
      """

      alias SdrAgent.Prototype.Binding

      @runtime_key {SdrAgent.Prototype, :runtime}
      @identity_key {SdrAgent.Prototype, :live_identity}

      @doc "Enters prototype runtime with `snapshot` for the calling process."
      @spec enter_runtime(Binding.t()) :: :ok
      def enter_runtime(%Binding{} = snapshot) do
        Process.put(@runtime_key, {:prototype, snapshot})
        :ok
      end

      @doc """
      Returns the calling process to ordinary runtime. It stores `:ordinary`
      rather than deleting the key, so a caller's prototype runtime is not
      re-inherited through `$callers`.
      """
      @spec leave_runtime() :: :ok
      def leave_runtime do
        Process.put(@runtime_key, :ordinary)
        :ok
      end

      @doc "Overrides the live identity for the calling process (`map` or `:raise`)."
      @spec put_live_identity(map() | :raise) :: :ok
      def put_live_identity(overrides) when overrides == :raise or is_map(overrides) do
        Process.put(@identity_key, overrides)
        :ok
      end

      @doc """
      Removes the seam's two keys (runtime and live identity) from the
      calling process only; no caller or other process is touched.
      """
      @spec clear() :: :ok
      def clear do
        Process.delete(@runtime_key)
        Process.delete(@identity_key)
        :ok
      end

      @doc false
      # The value of `key` in the calling process, else in the first of its
      # explicit `$callers` that has it, read as `SdrAgent.Clock` reads them
      # (clock.ex:76-87); a dead caller contributes nil, and `$callers` is
      # never changed.
      @spec lookup(term()) :: term()
      def lookup(key) do
        Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
          if pid == self(), do: Process.get(key), else: remote(pid, key)
        end)
      end

      defp remote(pid, key) do
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> dict |> List.keyfind(key, 0, {key, nil}) |> elem(1)
          nil -> nil
        end
      end
    end
  end
end
