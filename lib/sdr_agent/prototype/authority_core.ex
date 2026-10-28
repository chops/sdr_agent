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
      `{:error, :bootstrap_failed}` with everything rolled back. It is top
      level only: inside an already-open transaction it refuses with
      `{:error, :bootstrap_failed}` before any query or write. In a
      test-seam build only (`:prototype_test_seams`), inside that
      transaction after the binding write and before the delegation's, it
      calls the one-argument hook `{SdrAgent.Prototype.Authority,
      :before_delegation}` from the calling process's dictionary with the
      rows created so far (the rollback proof's late-failure point);
    - `snapshot/1`: the `SdrAgent.Prototype.Binding` of a binding row;
    - `resolve_delegation/2`: resolver steps 3-7 of IF-1 for a boot snapshot
      and a delegation row (or nil);
    - setup phase 0/1 checks: `check_repo_target/1`, `check_app_stopped/0,1`
      with `app_names/0`, `write_credential/1` (still a stub; the credential
      is owner-held), `check_fresh/0`, `check_resumable/0`,
      `public_tables/0` and `pinned_migrations/0`;
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
    only), B1a's self-only `runtime/0` and `binding/0` (Codex b743eb5d),
    B2a's `bootstrap/1` with `live_identity/0` (its one plain identity read),
    B2b1's `snapshot/1`, and B2b2's `check_live/0`, `operator_actor/1`,
    `resolve_delegation/2` and `operator?/1`, `assurance/0`, and C1's pure
    `check_worksheet/3` steps 1-3 are implemented. Every other
    function is still a non-permissive RED declaration returning
    `{:error, :not_implemented}`; none fabricates success.
    """

    import Kernel, except: [binding: 0]

    require Ash.Query

    alias SdrAgent.Accounts.User
    alias SdrAgent.Actor
    alias SdrAgent.Audit
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.Audit.Kernel, as: AuditKernel
    alias SdrAgent.Operations.PrototypeDatabaseBinding
    alias SdrAgent.Operations.PrototypeDelegation
    alias SdrAgent.Prototype.Binding
    alias SdrAgent.Prototype.BoundedJson
    alias SdrAgent.Prototype.Checks.KernelMarker
    alias SdrAgent.Repo

    @test_seams Application.compile_env(:sdr_agent, :prototype_test_seams, false)
    @database "sdr_agent_prototype"
    @label "UNVERIFIED (PROTOTYPE)"
    @agents [:claude_code, :codex_cli]
    @correlation ~r/\A[A-Za-z0-9._:-]{8,128}\z/
    @identity_sql "SELECT current_database()::text, d.oid::bigint, " <>
                    "(pg_control_system()).system_identifier FROM pg_database d " <>
                    "WHERE d.datname = current_database()"

    # IF-2 provisioning: the budget worksheet (F7).
    @shared_total 60
    @funded_ceiling 50
    @window_starts_at "2026-10-28T02:38:32.000000Z"
    @worksheet_max_bytes 16_384
    # A conservative processing bound per counts-only evidence receipt (the
    # worksheet's own 16 KiB; accepted by Codex 47825d4a). It is not an IF-2
    # value: IF-2 states no evidence size. Larger is :budget_unbounded.
    @evidence_max_bytes 16_384
    @worksheet_keys ~w(schema shared_total window_starts_at as_of routes previous_bindings)
    @route_keys ~w(route basis consumed evidence)
    @evidence_keys ~w(path sha256)
    @previous_keys ~w(consumed evidence)
    @worksheet_known_keys Enum.uniq(
                            @worksheet_keys ++ @route_keys ++ @evidence_keys ++ @previous_keys
                          )
    @budget_routes ~w(prototype_binding owner_dev owner_calibration hosted other_owner)
    @bases ~w(agent_receipt owner_attestation owner_aggregate)
    @owner_bases ~w(owner_attestation owner_aggregate)

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
      label: @label,
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

    @runtime_key {SdrAgent.Prototype, :runtime}

    # The fixed runtime: nil (unfixed), :ordinary or {:prototype, snapshot}.
    # A test-seam build reads the calling process (then its $callers) through
    # `SdrAgent.Prototype.Authority.TestSeam`; any other build reads the VM
    # value that `SdrAgent.Prototype.BootCheck.verify!/1` fixed once.
    if @test_seams do
      defp current, do: SdrAgent.Prototype.Authority.TestSeam.lookup(@runtime_key)
      defp store(:ordinary), do: SdrAgent.Prototype.Authority.TestSeam.leave_runtime()

      defp store({:prototype, snapshot}),
        do: SdrAgent.Prototype.Authority.TestSeam.enter_runtime(snapshot)

      defp serial(fun), do: fun.()
    else
      defp current, do: :persistent_term.get(@runtime_key, nil)

      defp store(fixed) do
        :persistent_term.put(@runtime_key, fixed)
        :ok
      end

      # persistent_term is not compare-and-set: the first fix is serialized on
      # one VM-local lock (Codex 23b4603a G1).
      # A fixed resource id, a per-process requester (Codex 026058ec); the
      # read, compare and write all run inside; a failed lock refuses.
      defp serial(fun) do
        case :global.trans({{SdrAgent.Prototype.BootCheck, :runtime_fix}, self()}, fun, [node()]) do
          :aborted -> {:error, :binding_not_exact}
          result -> result
        end
      end
    end

    @doc """
    The write-once runtime transition (G1, Codex 23b4603a), for
    `SdrAgent.Prototype.BootCheck.verify!/1` only: unfixed takes the checked
    result; the identical fixed result is idempotent; any other transition
    (ordinary → prototype, prototype → another prototype, prototype →
    ordinary) is `{:error, :binding_not_exact}` and changes nothing.
    """
    @spec fix_runtime({:ok, :ordinary | {:prototype, Binding.t()}}) ::
            :ok | {:error, :binding_not_exact}
    def fix_runtime({:ok, wanted}) when wanted == :ordinary or elem(wanted, 0) == :prototype,
      do: serial(fn -> transition(current(), wanted) end)

    defp transition(nil, wanted), do: store(wanted)
    defp transition(same, same), do: :ok
    defp transition(_fixed, _other), do: {:error, :binding_not_exact}

    @doc """
    Creates or replays this agent session's delegation (IF-3), from the boot
    snapshot only, in this order: the snapshot (else
    `:not_prototype_runtime`), an exactly supported agent (`:invalid_agent`),
    a bounded correlation (`:invalid_correlation`) and the live check
    (`:binding_mismatch`, on every call, replays included). Then, in one
    `SdrAgent.Audit.transaction/1`, a replay of (binding, agent,
    correlation) returns the existing id with no row or event; otherwise
    `PrototypeDelegation :enter` creates exactly one row and one event, as
    the kernel with the `:task_entry` marker, with binding, tenant and
    anchor forced from the snapshot.

    A concurrent creator's unique violation on that identity, as the
    failure's SOLE error, is re-read only AFTER the failed top-level
    transaction has rolled back, never inside the aborted transaction; any
    other failure, including that error together with any other, is
    `:binding_mismatch`, never a replay. A call inside an already-open
    transaction (a nested Audit or Repo transaction is not a savepoint) is
    refused with `:binding_mismatch` after the input checks and before any
    query or write; the one caller, the task entry, never nests.
    """
    @spec enter_session(term(), term()) ::
            {:ok, Ecto.UUID.t()} | {:error, SdrAgent.Prototype.enter_error()}
    def enter_session(agent, correlation) do
      with {:ok, snapshot} <- binding(),
           {:ok, agent} <- setup_agent(agent),
           {:ok, correlation} <- setup_correlation(correlation),
           :ok <- not_nested(),
           :ok <- check_live() do
        enter(snapshot, agent, correlation)
      end
    end

    # A nested Audit.transaction is a plain nested Repo.transaction, not a
    # savepoint (Codex a95a89fb R1): the unique-race recovery could only run
    # in an aborted caller transaction. The task entry is the one caller and
    # never nests, so an already-open transaction is refused before any
    # query or write.
    defp not_nested, do: if(Repo.in_transaction?(), do: {:error, :binding_mismatch}, else: :ok)

    defp enter(snapshot, agent, correlation) do
      fn -> replay_or_create(snapshot, agent, correlation) end
      |> Audit.transaction()
      |> case do
        {:ok, id} ->
          {:ok, id}

        {:error, failure} ->
          # The transaction (or savepoint) has rolled back: only now may a
          # unique conflict on the session identity be re-read.
          if session_conflict?(failure),
            do: reread_session(snapshot, agent, correlation),
            else: {:error, :binding_mismatch}
      end
    end

    defp replay_or_create(snapshot, agent, correlation) do
      case seam_lookup(find_session(snapshot.id, agent, correlation)) do
        {:ok, %PrototypeDelegation{id: id}} -> id
        {:ok, nil} -> create_session(snapshot, agent, correlation)
        _error -> Repo.rollback(:binding_mismatch)
      end
    end

    defp create_session(snapshot, agent, correlation) do
      seam(:before_session_create, snapshot)

      PrototypeDelegation
      |> Ash.Changeset.for_create(
        :enter,
        %{agent: agent, session_correlation: correlation},
        actor: Actor.system(:kernel, snapshot.tenant_id),
        context: KernelMarker.context(:task_entry)
      )
      |> Ash.create()
      |> case do
        {:ok, delegation} -> delegation.id
        {:error, error} -> Repo.rollback(error)
      end
    end

    defp reread_session(snapshot, agent, correlation) do
      case find_session(snapshot.id, agent, correlation) do
        {:ok, %PrototypeDelegation{id: id}} -> {:ok, id}
        _none_or_error -> {:error, :binding_mismatch}
      end
    end

    # Exactly the identity's unique violation (AshPostgres reports it as
    # InvalidAttribute with the constraint name), whether Ash rolled the
    # transaction back with its changeset or returned the error class.
    @session_identity_index "prototype_delegations_unique_session_index"

    defp session_conflict?(%Ash.Changeset{errors: errors}), do: unique_session?(errors)
    defp session_conflict?(%Ash.Error.Invalid{errors: errors}), do: unique_session?(errors)
    defp session_conflict?(_other), do: false

    # Codex 54f4263b P0-1: recoverable only when the failure carries exactly
    # one error and it is the session unique constraint. A mixed list (that
    # error with any other) or a repeated one is never a recoverable race.
    defp unique_session?([%Ash.Error.Changes.InvalidAttribute{private_vars: vars}])
         when is_list(vars),
         do: vars[:constraint_type] == :unique and vars[:constraint] == @session_identity_index

    defp unique_session?(_errors), do: false

    defp find_session(binding_id, agent, correlation) do
      PrototypeDelegation
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts())
      |> Ash.Query.filter(
        binding_id == ^binding_id and agent == ^agent and session_correlation == ^correlation
      )
      |> Ash.read_one()
    end

    @doc """
    The IF-5 assurance block, in prototype runtime only: the constant label,
    the boot snapshot's policy id, instance and dataset class, and the
    compiled policy entry's digest. It confers no authority.
    """
    @spec assurance() :: {:ok, map()} | {:error, :not_prototype_runtime}
    def assurance do
      with {:ok, snapshot} <- binding() do
        {:ok,
         %{
           "label" => @label,
           "policy_id" => snapshot.policy_id,
           "entry_sha256" => policy_entry_sha256(),
           "instance_id" => snapshot.instance_id,
           "dataset_class" => snapshot.dataset_class
         }}
      end
    end

    @doc "Setup phase 2; see the moduledoc."
    @spec bootstrap(keyword()) :: {:ok, map()} | {:error, :bootstrap_failed}
    def bootstrap(opts) do
      with :ok <- bootstrap_top_level(),
           {:ok, agent} <- setup_agent(Keyword.get(opts, :agent)),
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

    # Codex 54f4263b P0-2: top level only. A caller's open transaction would
    # make phase 2 share its physical transaction (no savepoint), so it is
    # refused first, before any query or write; Repo.in_transaction?/0 issues
    # no query.
    defp bootstrap_top_level,
      do: if(Repo.in_transaction?(), do: {:error, :nested_transaction}, else: :ok)

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
    database's own name reads as `sdr_agent_prototype`, and then the
    `TestSeam.put_live_identity/1` override of this process (or of its first
    `$callers` entry that has one) applies: a map replaces those fields, and
    `:raise` makes the identity unavailable. Without an override every other
    value is the real one.
    """
    @spec live_identity() ::
            {:ok,
             %{database: String.t(), database_oid: pos_integer(), system_identifier: integer()}}
            | {:error, :live_identity_unavailable}
    def live_identity do
      case identity_query() do
        {:ok, %{rows: [[name, oid, system_identifier]]}}
        when is_binary(name) and is_integer(oid) and oid > 0 and is_integer(system_identifier) ->
          {:ok,
           seam_identity(%{
             database: name,
             database_oid: oid,
             system_identifier: system_identifier
           })}

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

      # The test database's name alias, then this process's (or a caller's)
      # `TestSeam.put_live_identity/1` override: a map of fields, or `:raise`.
      defp seam_identity(identity) do
        aliased = test_alias(identity)

        case SdrAgent.Prototype.Authority.TestSeam.lookup({SdrAgent.Prototype, :live_identity}) do
          :raise -> raise ArgumentError, "test seam: live identity unavailable"
          overrides when is_map(overrides) -> Map.merge(aliased, overrides)
          _none -> aliased
        end
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

      # The unique-race proof: when the calling process sets
      # `{SdrAgent.Prototype.Authority, :miss_session_lookup}` to true, the
      # in-transaction session lookup reports none (a competitor that
      # committed after the lookup). The post-rollback re-read is unaffected.
      defp seam_lookup(result) do
        if Process.get({__MODULE__, :miss_session_lookup}) == true,
          do: {:ok, nil},
          else: result
      end

      # Codex dd9c0f20 F1: the synthetic catalog seam. When the calling
      # process sets `{SdrAgent.Prototype.Authority, :catalog_tables}` to a
      # one-argument function, the observed public-table list passes
      # through it; no schema object changes.
      defp seam_catalog(tables) do
        case Process.get({__MODULE__, :catalog_tables}) do
          hook when is_function(hook, 1) -> hook.(tables)
          _none -> tables
        end
      end
    else
      defp seam_identity(identity), do: identity
      defp seam(_name, _arg), do: :ok
      defp seam_lookup(result), do: result
      defp seam_catalog(tables), do: tables
    end

    @doc """
    The boot snapshot of a binding row: exactly the `SdrAgent.Prototype.Binding`
    fields of a real `PrototypeDatabaseBinding` struct. Anything else (a map,
    another resource's row, nil) is `{:error, :not_a_binding}`.
    """
    @spec snapshot(term()) :: {:ok, Binding.t()} | {:error, :not_a_binding}
    def snapshot(%PrototypeDatabaseBinding{} = row),
      do: {:ok, struct!(Binding, Map.new(Binding.fields(), &{&1, Map.fetch!(row, &1)}))}

    def snapshot(_other), do: {:error, :not_a_binding}

    @doc """
    Re-reads the singleton binding row (one plain kernel read) and the live
    identity, and compares every field with the boot snapshot. A missing or
    second row, any difference, an unavailable identity or an exception is
    `{:error, :binding_mismatch}`. Nothing is cached.
    """
    @spec check_live() :: :ok | {:error, :not_prototype_runtime | :binding_mismatch}
    def check_live do
      with {:ok, snapshot} <- binding() do
        if live_matches?(snapshot), do: :ok, else: {:error, :binding_mismatch}
      end
    end

    defp live_matches?(snapshot) do
      with {:ok, [row]} <- read_bindings(),
           {:ok, ^snapshot} <- snapshot(row),
           {:ok, live} <- live_identity() do
        live == %{
          database: row.database,
          database_oid: row.database_oid,
          system_identifier: row.system_identifier
        }
      else
        _mismatch -> false
      end
    rescue
      _error -> false
    end

    defp read_bindings_real do
      PrototypeDatabaseBinding
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts())
      |> Ash.Query.limit(2)
      |> Ash.read()
    end

    defp delegation_read_real(uuid) do
      PrototypeDelegation
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts())
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.read_one()
    end

    # The three live reads (the binding read, the identity query, the
    # delegation read). In a test-seam build each consults
    # `TestSeam.claim_live_fault/1` immediately before its real read
    # (proposal r2, Codex 382437da): `:returned_error` replaces the read's
    # result and `:raise` raises in its place (no target SQL; the caller's
    # own handling and rescue are unchanged), `:abort` runs one tagged real
    # `SELECT 1 / 0` and then the REAL read. Any other build is the plain
    # read, with no reference to the seam.
    if @test_seams do
      defp read_bindings,
        do: live_fault(:binding_read, &ash_fault/0, &read_bindings_real/0)

      defp identity_query,
        do: live_fault(:identity_read, &query_fault/0, fn -> Repo.query(@identity_sql, []) end)

      defp delegation_read(uuid),
        do: live_fault(:delegation_read, &ash_fault/0, fn -> delegation_read_real(uuid) end)

      defp live_fault(stage, synthetic, read) do
        case SdrAgent.Prototype.Authority.TestSeam.claim_live_fault(stage) do
          nil ->
            read.()

          :returned_error ->
            synthetic.()

          :raise ->
            raise ArgumentError, "test seam: live-stage fault"

          :abort ->
            _ = Repo.query("SELECT 1 / 0", [], telemetry_options: [d237_live_fault: stage])
            read.()
        end
      end

      defp ash_fault,
        do:
          {:error, Ash.Error.Unknown.UnknownError.exception(error: "test seam: live-stage fault")}

      defp query_fault, do: {:error, %Postgrex.Error{message: "test seam: live-stage fault"}}
    else
      defp read_bindings, do: read_bindings_real()
      defp identity_query, do: Repo.query(@identity_sql, [])
      defp delegation_read(uuid), do: delegation_read_real(uuid)
    end

    @doc """
    The authoritative operator resolver (IF-1): the boot snapshot, a live
    check, one plain kernel read of the delegation, then
    `resolve_delegation/2`; on every call, nothing cached.
    """
    @spec operator_actor(term()) ::
            {:ok, Actor.t()} | {:error, SdrAgent.Prototype.resolve_error()}
    def operator_actor(delegation_id) do
      with {:ok, snapshot} <- binding(),
           :ok <- check_live(),
           {:ok, delegation} <- read_delegation(delegation_id) do
        resolve_delegation(snapshot, delegation)
      end
    end

    # One plain kernel read of the delegation. A malformed id is rejected
    # (read as nil) before any typed UUID query; a read error or an exception
    # is `:binding_mismatch`.
    defp read_delegation(id) do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          uuid
          |> delegation_read()
          |> case do
            {:ok, delegation} -> {:ok, delegation}
            {:error, _error} -> {:error, :binding_mismatch}
          end

        :error ->
          {:ok, nil}
      end
    rescue
      _error -> {:error, :binding_mismatch}
    end

    @doc "Resolver steps 4-7 for `snapshot` and a delegation row (nil: `:delegation_not_found`)."
    @spec resolve_delegation(Binding.t(), struct() | nil) ::
            {:ok, Actor.t()} | {:error, SdrAgent.Prototype.resolve_error()}
    def resolve_delegation(_snapshot, nil), do: {:error, :delegation_not_found}

    def resolve_delegation(%Binding{} = snapshot, delegation) do
      cond do
        delegation.tenant_id != snapshot.tenant_id ->
          {:error, :delegation_foreign_tenant}

        delegation.binding_id != snapshot.id ->
          {:error, :delegation_wrong_binding}

        delegation.operator_user_id != snapshot.operator_user_id ->
          {:error, :anchor_mismatch}

        true ->
          {:ok,
           %Actor{type: :prototype_operator, id: delegation.id, tenant_id: snapshot.tenant_id}}
      end
    end

    @doc "True only when `operator_actor(actor.id)` resolves to exactly `actor`."
    @spec operator?(term()) :: boolean()
    def operator?(%Actor{type: :prototype_operator, id: id} = actor) when is_binary(id),
      do: operator_actor(id) == {:ok, actor}

    def operator?(_actor), do: false

    # IF-2 phase 0: the one Repo target, sorted by key.
    @repo_target [database: @database, port: 5541, socket_dir: "/private/tmp/d237-pg"]
    # Every Repo option that selects a PostgreSQL target (Postgrex/Ecto).
    @target_selectors [:database, :endpoints, :hostname, :port, :socket, :socket_dir, :url]

    @doc """
    `:ok` when a Repo config (a keyword list) targets exactly the prototype
    socket directory, port and database: each selector at most once, no
    `:socket`, `:url` or `:endpoints`, and `:hostname` absent or
    `"localhost"` (Postgrex gives `:socket_dir` precedence over it).
    Anything else is `:repo_target_mismatch`.
    """
    @spec check_repo_target(term()) :: :ok | {:error, :repo_target_mismatch}
    def check_repo_target(config) when is_list(config) do
      if Keyword.keyword?(config) and exact_target?(config),
        do: :ok,
        else: {:error, :repo_target_mismatch}
    end

    def check_repo_target(_config), do: {:error, :repo_target_mismatch}

    defp exact_target?(config) do
      selectors = for {key, _value} = entry <- config, key in @target_selectors, do: entry
      keys = Keyword.keys(selectors)

      # Codex dd9c0f20 F2: DBConnection runs a :configure fun or MFA
      # before each connect, which could redirect the target; only nil is
      # accepted, and the callback is never called here.
      keys == Enum.uniq(keys) and
        Enum.all?(Keyword.get_values(config, :configure), &is_nil/1) and
        Enum.sort(Keyword.delete(selectors, :hostname)) == @repo_target and
        Keyword.get(selectors, :hostname, "localhost") == "localhost"
    end

    # IF-2 phase 0: Oban, the endpoint and the model provider tree
    # (`SdrAgent.AI.ModelProvider.ProfileSupervisor`'s children and the
    # `ClaudeCLI.server/0` name).
    @app_names [
      {:oban, Oban},
      {:process, SdrAgentWeb.Endpoint},
      {:process, SdrAgent.AI.ModelProvider.ProfileSupervisor},
      {:process, SdrAgent.AI.ModelProvider.ServerSupervisor},
      {:process, SdrAgent.AI.ModelProvider.Coordinator},
      {:process, SdrAgent.AI.ModelProvider.OperationSupervisor},
      {:process, SdrAgent.AI.ModelProvider.ClaudeCLI}
    ]

    @doc "`:ok` when none of `app_names/0` is alive; otherwise `:app_running`."
    @spec check_app_stopped() :: :ok | {:error, :app_running}
    def check_app_stopped, do: check_app_stopped(@app_names)

    @doc """
    As `check_app_stopped/0`, for an explicit list of `app_names/0`-shaped
    names: an Oban instance is alive when `Oban.whereis/1` finds it, any
    other name when it resolves to a live pid. A malformed entry counts as
    alive (fail closed).
    """
    @spec check_app_stopped(term()) :: :ok | {:error, :app_running}
    def check_app_stopped(names) when is_list(names) do
      if Enum.any?(names, &alive?/1), do: {:error, :app_running}, else: :ok
    end

    def check_app_stopped(_names), do: {:error, :app_running}

    @doc "The IF-2 app-running names: Oban, the endpoint and the model provider tree."
    @spec app_names() :: [{:oban | :process, atom()}]
    def app_names, do: @app_names

    defp alive?({:oban, name}) when is_atom(name), do: is_pid(Oban.whereis(name))

    defp alive?({:process, name}) when is_atom(name) do
      case Process.whereis(name) do
        nil -> false
        pid when is_pid(pid) -> Process.alive?(pid)
        _port -> true
      end
    end

    defp alive?(_malformed), do: true

    @doc "Creates the auditor credential file exclusively (0600) and returns its password."
    @spec write_credential(Path.t()) :: {:ok, String.t()} | {:error, atom()}
    def write_credential(_path), do: red({:error, :not_implemented})

    # The exact migration set setup runs (`priv/repo/migrations`, in
    # version order); a new migration must be added here, or resume refuses.
    @pinned_migrations [
      {20_261_006_212_538, "initialize_extensions_1"},
      {20_261_006_212_604, "add_authentication_resources_extensions_1"},
      {20_261_006_212_605, "add_authentication_resources"},
      {20_261_006_212_617, "add_oban"},
      {20_261_007_021_151, "s3_audit_kernel"},
      {20_261_007_030_213, "s11_anchoring_export"},
      {20_261_007_033_707, "s11_security_fix"},
      {20_261_007_042_000, "preserve_key_retirement"},
      {20_261_007_043_305, "s5_domain"},
      {20_261_007_051_155, "s7_operations"},
      {20_261_007_142_841, "s8a_outreach"},
      {20_261_007_150_632, "s8b_delivery"},
      {20_261_007_155_131, "s9a_replies"},
      {20_261_007_160_142, "s9b_reply_assessments"},
      {20_261_007_175_954, "s12b_wire_witness"},
      {20_261_012_181_602, "c9_model_call_grants"},
      {20_261_012_182_415, "c9_run_usage_origin"},
      {20_261_012_182_416, "c9_admission"},
      {20_261_012_214_848, "r0_07a_result_release"},
      {20_261_014_220_246, "c1_inbox_indexes"},
      {20_261_015_074_454, "c2_02a_profile_switch"},
      {20_261_015_164_737, "c2_02b2a_model_server_starts"},
      {20_261_016_011_853, "c4_01a_run_settings"},
      {20_261_016_041_646, "c2_02b2b_resolve"},
      {20_261_016_052_435, "c2_02b2b_resolution_check"},
      {20_261_021_101_539, "v4_mismatch_lineage"},
      {20_261_026_033_738, "ash_functions_v7_extensions_1"},
      {20_261_028_052_008, "d237_01_users"},
      {20_261_028_052_100, "d237_02_actor_types"},
      {20_261_028_052_135, "d237_03_prototype_database_bindings"},
      {20_261_028_052_139, "d237_04_prototype_delegations"},
      {20_261_028_052_257, "d237_05_release_decisions"},
      {20_261_028_052_400, "d237_06_sources"},
      {20_261_028_052_425, "d237_07_dossier"}
    ]

    # IF-2 phase 1 (Codex dd9c0f20 F1): the fixed public base-table
    # inventory of the pinned migration set, sorted. It includes the five
    # IF-2 named tables (audit_chain_heads, prototype_database_bindings,
    # prototype_delegations, tenants, users), every business table and
    # Oban's two; schema_migrations is checked separately. A new table must
    # be added here with its migration, or setup refuses.
    @public_tables Enum.sort(~w(
      accounts agent_definitions agent_runs anchor_sink_receipts approvals
      audit_accesses audit_anchors audit_chain_heads audit_events audit_exports
      audit_signing_keys campaign_enrollments campaigns contacts decisions
      delivery_operations delivery_receipts dossier_entries dossier_sources
      draft_revisions drafts evidence_claims failures icp_definitions leads
      model_call_allocations model_call_grants model_invocations
      model_profile_settings model_profile_switches model_result_releases
      model_server_counters model_server_starts oban_jobs oban_peers operations
      payloads prototype_database_bindings prototype_delegations
      provenance_snapshots qualification_evidences qualifications replies
      reply_assessments research_artifacts retention_markers revision_citations
      run_settings_snapshots send_quota_days sequence_steps sequences
      settings_revisions suppressions tenants tokens tool_invocations users
      webhook_events wire_witness_links
    ))

    @doc """
    `:ok` when the public schema's base tables other than `schema_migrations`
    are exactly `public_tables/0`, no more and no fewer (an extra public
    table refuses as well as a missing one), and none of them holds a row.
    It reads the catalog and row presence only, never row content. Any
    other outcome, including a failed read, is `:database_not_fresh`.
    """
    @spec check_fresh() :: :ok | {:error, :database_not_fresh}
    def check_fresh, do: if(rowless?(), do: :ok, else: {:error, :database_not_fresh})

    @doc """
    `:ok` for the bounded resume: `schema_migrations` holds exactly the
    versions of `pinned_migrations/0`, no more and no fewer, and
    `check_fresh/0`'s tables hold no row. Anything else, or a failed read,
    is `:database_not_resumable`.
    """
    @spec check_resumable() :: :ok | {:error, :database_not_resumable}
    def check_resumable do
      if migrated_exactly?() and rowless?(),
        do: :ok,
        else: {:error, :database_not_resumable}
    end

    # The catalog must equal the fixed inventory; only then is row presence
    # read, over the fixed inventory. Each outcome is matched on its own;
    # every one but `{:ok, exact, no row}` refuses.
    defp rowless? do
      case catalog_tables() do
        {:ok, @public_tables} ->
          case Repo.query(any_row_sql(@public_tables), []) do
            {:ok, %{rows: [[false]]}} -> true
            {:ok, %{rows: [[true]]}} -> false
            {:error, _read_failed} -> false
          end

        {:ok, _missing_or_extra} ->
          false

        {:error, _read_failed} ->
          false
      end
    end

    defp catalog_tables do
      case Repo.query(
             "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' " <>
               "AND tablename <> 'schema_migrations' ORDER BY tablename",
             []
           ) do
        {:ok, %{rows: rows}} ->
          {:ok, Enum.sort(seam_catalog(Enum.map(rows, fn [table] -> table end)))}

        {:error, _read_failed} = failed ->
          failed
      end
    end

    # One statement: does any of `tables` hold a row (identifiers quoted).
    defp any_row_sql(tables) do
      "SELECT " <>
        Enum.map_join(tables, " OR ", fn table ->
          ~s[EXISTS (SELECT 1 FROM "public"."#{String.replace(table, ~s["], ~s[""])}")]
        end)
    end

    defp migrated_exactly? do
      # Codex dd9c0f20 F3: qualified, as the row checks are, so no
      # search_path or pg_temp shadow can answer for the public table.
      case Repo.query("SELECT version FROM public.schema_migrations ORDER BY version", []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [version] -> version end) ==
            Enum.map(@pinned_migrations, &elem(&1, 0))

        {:error, _error} ->
          false
      end
    end

    @doc "The pinned public base-table inventory of the pinned migration set (F1)."
    @spec public_tables() :: [String.t()]
    def public_tables, do: @public_tables

    @doc """
    `:ok` when `public.schema_migrations` holds exactly the pinned migration
    set, no more and no fewer (setup fresh mode, after its migration);
    otherwise `{:error, :migration_failed}`. Not a resumability check: rows
    are not examined. RED: not implemented (setup contract r2).
    """
    @spec check_migrated() :: :ok | {:error, :migration_failed | :not_implemented}
    def check_migrated, do: red({:error, :not_implemented})

    @doc "The pinned migration set, `[{version, name}]` in version order."
    @spec pinned_migrations() :: [{integer(), String.t()}]
    def pinned_migrations, do: @pinned_migrations

    @doc """
    Checks the IF-2 budget worksheet `bytes` against its sha256 hex, with its
    evidence under `evidence_root`; `{:ok, %{sha256:, remaining:}}` or a
    closed refusal atom. Steps, in order:

    1. The sha256 of `bytes` equals `sha256_hex`; the general parser rules
       (`SdrAgent.Prototype.BoundedJson`, at most 16 KiB, depth 4); exact
       key sets, types and counts (0..60); the fixed schema, total and
       window start; `as_of` RFC 3339 with an offset, not before the window
       start. Otherwise `:worksheet_invalid`.
    2. Exactly the five routes, each once; an owner or hosted route only on
       an owner basis. Otherwise `:budget_unbounded` (unknown is not zero).
    3. `60 − Σ consumed − previous_bindings.consumed` below 50 is
       `:budget_below_ceiling`: the recorded counts already refuse, whatever
       the evidence.
    4. Every evidence reference resolves under the root to its exact bytes.
       Otherwise `:budget_unbounded`.

    Step 4 reads each of the six references (five routes and
    `previous_bindings`) once through S1b's reviewed private reader,
    `SdrAgent.Prototype.BoundedJson.read_private/4` (Codex 983296fb): the
    IF-2 path grammar, a 0700 real root, no group- or other-writable
    directory, a 0600 regular leaf, one handle and the exact sha256. Any
    refusal of the reader is `:budget_unbounded`; no evidence byte is
    returned or logged.
    """
    @spec check_worksheet(binary(), String.t(), Path.t()) ::
            {:ok, %{sha256: String.t(), remaining: non_neg_integer()}}
            | {:error, :worksheet_invalid | :budget_unbounded | :budget_below_ceiling}
    def check_worksheet(bytes, sha256_hex, evidence_root)
        when is_binary(bytes) and is_binary(sha256_hex) and is_binary(evidence_root) do
      with :ok <- worksheet_digest(bytes, sha256_hex),
           {:ok, worksheet} <- worksheet_decode(bytes),
           :ok <- worksheet_shape(worksheet),
           :ok <- routes_bounded(worksheet["routes"]),
           {:ok, remaining} <- worksheet_remaining(worksheet),
           :ok <- evidence_resolved(worksheet, evidence_root) do
        {:ok, %{sha256: sha256_hex, remaining: remaining}}
      end
    end

    def check_worksheet(_bytes, _sha256_hex, _evidence_root), do: {:error, :worksheet_invalid}

    defp worksheet_digest(bytes, sha256_hex) do
      if hex(:crypto.hash(:sha256, bytes)) == sha256_hex,
        do: :ok,
        else: {:error, :worksheet_invalid}
    end

    defp worksheet_decode(bytes) do
      case BoundedJson.decode(bytes,
             max_bytes: @worksheet_max_bytes,
             max_depth: 4,
             known_keys: @worksheet_known_keys
           ) do
        {:ok, %{} = worksheet} -> {:ok, worksheet}
        _invalid -> {:error, :worksheet_invalid}
      end
    end

    defp worksheet_shape(worksheet) do
      with :ok <- BoundedJson.exact_keys(worksheet, @worksheet_keys, []),
           "d237-budget-worksheet/1" <- worksheet["schema"],
           @shared_total <- worksheet["shared_total"],
           @window_starts_at <- worksheet["window_starts_at"],
           true <- as_of_in_window?(worksheet["as_of"]),
           routes when is_list(routes) <- worksheet["routes"],
           true <- Enum.all?(routes, &route_shape?/1),
           %{} = previous <- worksheet["previous_bindings"],
           :ok <- BoundedJson.exact_keys(previous, @previous_keys, ["previous_bindings"]),
           true <- consumed?(previous["consumed"]),
           true <- evidence_shape?(previous["evidence"]) do
        :ok
      else
        _invalid -> {:error, :worksheet_invalid}
      end
    end

    defp as_of_in_window?(as_of) when is_binary(as_of) do
      {:ok, window_start, _offset} = DateTime.from_iso8601(@window_starts_at)

      case DateTime.from_iso8601(as_of) do
        {:ok, at, _offset} -> DateTime.compare(at, window_start) != :lt
        _invalid -> false
      end
    end

    defp as_of_in_window?(_as_of), do: false

    defp route_shape?(%{} = route) do
      BoundedJson.exact_keys(route, @route_keys, ["routes"]) == :ok and
        is_binary(route["route"]) and route["basis"] in @bases and
        consumed?(route["consumed"]) and evidence_shape?(route["evidence"])
    end

    defp route_shape?(_route), do: false

    defp consumed?(n), do: is_integer(n) and n >= 0 and n <= @shared_total

    defp evidence_shape?(%{} = evidence) do
      BoundedJson.exact_keys(evidence, @evidence_keys, ["evidence"]) == :ok and
        is_binary(evidence["path"]) and is_binary(evidence["sha256"])
    end

    defp evidence_shape?(_evidence), do: false

    # Exactly the five routes, each once; owner and hosted routes only on an
    # owner basis.
    defp routes_bounded(routes) do
      names = Enum.map(routes, & &1["route"])

      if Enum.sort(names) == Enum.sort(@budget_routes) and Enum.all?(routes, &basis_allowed?/1),
        do: :ok,
        else: {:error, :budget_unbounded}
    end

    defp basis_allowed?(%{"route" => "prototype_binding"}), do: true
    defp basis_allowed?(%{"basis" => basis}), do: basis in @owner_bases

    defp worksheet_remaining(worksheet) do
      consumed =
        Enum.sum(Enum.map(worksheet["routes"], & &1["consumed"])) +
          worksheet["previous_bindings"]["consumed"]

      remaining = @shared_total - consumed

      if remaining >= @funded_ceiling,
        do: {:ok, remaining},
        else: {:error, :budget_below_ceiling}
    end

    # Step 4: every reference resolves under the root to its exact bytes
    # through the shared reader (Codex a6850b13 D4); the bytes are dropped.
    defp evidence_resolved(worksheet, evidence_root) do
      references = [
        worksheet["previous_bindings"]["evidence"]
        | Enum.map(worksheet["routes"], & &1["evidence"])
      ]

      # A duplicated reference (the same path twice) is unbounded (IF-2).
      distinct? = Enum.uniq_by(references, & &1["path"]) == references

      if distinct? and Enum.all?(references, &resolves?(&1, evidence_root)),
        do: :ok,
        else: {:error, :budget_unbounded}
    end

    defp resolves?(%{"path" => path, "sha256" => sha256}, root) do
      match?({:ok, _bytes}, BoundedJson.read_private(root, path, sha256, @evidence_max_bytes))
    end

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
      - `put_boot_switch/1` sets the calling process's boot-switch input:
        the switch `SdrAgent.Prototype.BootCheck.verify!/0` reads in a test
        build, independent of the fixed runtime (Codex 026058ec); an
        explicit `verify!(switch: ...)` takes precedence. Process-local
        only (never read from `$callers`).
      - `leave_runtime/0` returns the process to ordinary runtime;
        `clear/0` removes every seam key of the process (deterministic
        cleanup).
      - `with_live_fault/3` and `live_fault_hits/1`: the live-read fault
        seam (proposal r2; Codex 7ba6d116, 382437da). A scope arms ONE
        fault of a kind at one live-read stage (`:binding_read`,
        `:identity_read`, `:delegation_read`) for the calling process and
        every process that inherits it through `$callers`; the first read
        at that stage that wins the scope's shared atomic claim fires it,
        exactly once per scope. The scope's prior binding is restored on
        return, raise, throw and exit. `clear/0` never touches a live-fault
        scope. A copied scope is not revoked from work still running after
        its scope ends: join inheriting work inside the scope.

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
      @boot_switch_key {SdrAgent.Prototype, :boot_switch}
      @live_stages [:binding_read, :identity_read, :delegation_read]
      @live_kinds [:returned_error, :raise, :abort]

      @typedoc "A live-read stage of the fault seam."
      @type live_stage :: :binding_read | :identity_read | :delegation_read

      @typedoc "A live-read fault kind."
      @type live_kind :: :returned_error | :raise | :abort

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

      @doc "Sets the calling process's boot-switch input (`:off` or a switch map)."
      @spec put_boot_switch(term()) :: :ok
      def put_boot_switch(switch) do
        Process.put(@boot_switch_key, switch)
        :ok
      end

      @doc "The calling process's own boot-switch input, or nil (process-local)."
      @spec boot_switch() :: term()
      def boot_switch, do: Process.get(@boot_switch_key)

      @doc """
      Runs `fun` inside a live-fault scope and returns its result; a raise,
      throw or exit of `fun` passes through unchanged.

      The scope binds `{kind, ref}` (`ref` a fresh one-slot atomics array)
      to `stage` in the calling process, shadowing any outer scope of the
      same stage; scopes of other stages compose. The first read at
      `stage`, in this process or in one that finds this scope through its
      `$callers`, whose claim (`compare_exchange` 0 -> 1) succeeds fires the
      fault: `:returned_error` replaces the read's result, `:raise` raises
      in its place, `:abort` runs one real `SELECT 1 / 0` and then the real
      read. Every later read at `stage` in the scope is real (a claimed
      scope never falls through to an outer one). On exit, the prior
      binding of `stage` is restored, or removed when there was none.
      """
      @spec with_live_fault(live_stage(), live_kind(), (-> result)) :: result when result: term()
      def with_live_fault(stage, kind, fun)
          when stage in @live_stages and kind in @live_kinds and is_function(fun, 0) do
        key = live_key(stage)
        previous = Process.put(key, {kind, :atomics.new(1, signed: false)})

        try do
          fun.()
        after
          restore(key, previous)
        end
      end

      @doc """
      The fired count (0 or 1) of the innermost `stage` scope visible to the
      calling process (itself, then its `$callers`), or 0 when none is.
      """
      @spec live_fault_hits(live_stage()) :: 0 | 1
      def live_fault_hits(stage) when stage in @live_stages do
        case lookup(live_key(stage)) do
          {_kind, ref} -> :atomics.get(ref, 1)
          nil -> 0
        end
      end

      @doc false
      # The live read's claim (`SdrAgent.Prototype.Authority`'s read sites
      # only): the kind of the innermost visible `stage` scope when this
      # call wins its claim, else nil.
      @spec claim_live_fault(live_stage()) :: live_kind() | nil
      def claim_live_fault(stage) when stage in @live_stages do
        case lookup(live_key(stage)) do
          {kind, ref} -> if :atomics.compare_exchange(ref, 1, 0, 1) == :ok, do: kind
          nil -> nil
        end
      end

      defp live_key(:binding_read), do: {SdrAgent.Prototype, :live_fault_binding_read}
      defp live_key(:identity_read), do: {SdrAgent.Prototype, :live_fault_identity_read}
      defp live_key(:delegation_read), do: {SdrAgent.Prototype, :live_fault_delegation_read}

      defp restore(key, nil), do: Process.delete(key)
      defp restore(key, previous), do: Process.put(key, previous)

      @doc """
      Removes the seam's keys (runtime, live identity and boot switch) from
      the calling process only; no caller or other process is touched. A
      live-fault scope is left alone: it belongs to its `with_live_fault/3`
      call, which alone restores it, and its shared claim is never reset.
      """
      @spec clear() :: :ok
      def clear do
        Process.delete(@runtime_key)
        Process.delete(@identity_key)
        Process.delete(@boot_switch_key)
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
