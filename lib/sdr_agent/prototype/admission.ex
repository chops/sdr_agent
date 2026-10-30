# D-237: the prototype gate exists only in builds that set
# `config :sdr_agent, prototype_authority_compiled: true` (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Admission do
    @moduledoc """
    The prototype branch of real-call admission (ADR-0005 D-237 amendment
    item 4 "Partitioned admission"; interfaces r6 IF-4; Codex A1 and P1). In
    prototype runtime `SdrAgent.Agents.Admission.Gate` dispatches here before
    any scope or eligibility check, and only this path exists: a refusal is
    final, never a fallback to the ordinary promoted-tuple or store checks.

    Refusals are `{:error, :prototype_not_authorized, check}`; an inactive
    result gate stays `{:error, :result_gate_inactive, :inactive}`.

      * **Reservation** (`reservation/4`, under the reservation's locks and
        head, before any grant is read, so a refusal is uncharged), in this
        order: a `:proof` run (`proof_run`); a calibration authority
        (`scope_mismatch`); the live binding against the boot snapshot and
        the compiled policy entry's digest, and the run in the bound tenant
        (`binding_mismatch`); the active result gate; the absent witness
        store (`witness_mode_mismatch`: the snapshot says absent, no root is
        configured and none was observed); the run's origin, the call's
        explicit purpose and its profile in the policy entry and the funded
        scope (`scope_mismatch`).
      * **This binding's grant** (`candidates/1`, then `register/4` from
        `Admission.admit/5` after the room check; Codex ff812f6d rulings
        a-b): the only candidate is the grant the ORIGINAL provisioned event
        links (`Provisioning.lookup/1`; none or untrusted is
        `grant_not_eligible`); then, in order, its status
        (`grant_not_eligible`), the anchor as creator and updater
        (`operator_mismatch`) and the exact funding-entry terms and
        allocation set (`grant_not_eligible`). The 14-key authority is built
        here, never taken from a caller, and recorded under a registration.
      * **The registry** (mechanism note r3 section B): `register/4` owns
        the entry in this process, bound to the reservation it may fund and
        to the transaction id and a transaction-local marker.
        `verify/2` and `registered?/1` are read-only: the entry and the
        reservation facts are compared before any SQL, then the
        transaction state. `AdmissionCharge` verifies at build time and
        `consume/2`s once, immediately before the insert. `pending/0`
        counts owned live, stale and consumed entries; `discard/1` removes
        only the caller's own equal entry; `with_owned_registrations/1`
        discards exactly the entries made during its call. A trusted
        in-process convention, not a capability against server code.
      * **Launch** (`launch/3`, under `Admission.lock_charge/1` and the head,
        so a refusal keeps its charge; amendment item 4 "Re-derived at
        launch"): a `:proof` run, the live binding, the active gate and the
        absent store as above; then the `prototype_authority` recorded by
        the invocation's one original `model.invocation.reserved` event (a
        missing, duplicated or non-map record is `authority_unrecorded`);
        then that record as a closed dictionary: exactly the 14 keys, each
        strictly typed (`grant_revision` a non-negative integer, every
        other value a string; no coercion), else `authority_mismatch`; then
        every recorded value but the revision against the live binding and
        the invocation's own charge (profile, purpose, grant, allocation),
        the general keys first (`authority_mismatch`), then the operator
        anchor (`operator_mismatch`), then the witness mode
        (`witness_mode_mismatch`); then the charged grant's current row:
        this binding's provenance grant, its status, the anchor as creator
        and updater and the exact terms and allocation set, in the
        registration's order and codes, and finally the recorded revision
        against the current one (`grant_changed`). The ordinary launch
        checks that follow (switch fence, grant window, allocation) are
        unchanged, so a launch at the window's end keeps
        `grant_ineligible_at_launch`/`grant_expired`.

    The release decision (`SdrAgent.Prototype.Release`) reuses `live/0`,
    `recorded/1`, the closed comparator `check_recorded/3` and the charged
    grant's checks `check_charge/3` (the launch's own order and codes). A
    returned read error of the charged grant is never a refusal: it leaves
    through the owning transaction's rollback with its identity (S2-A).
    """

    require Ash.Query

    alias SdrAgent.Agents.Admission.Gate
    alias SdrAgent.Agents.Checks.AdmissionContext.Registration
    alias SdrAgent.Agents.ModelCallAllocation
    alias SdrAgent.Agents.ModelCallGrant
    alias SdrAgent.Agents.Witness
    alias SdrAgent.Audit.Canonical
    alias SdrAgent.Audit.Kernel, as: AuditKernel
    alias SdrAgent.Prototype
    alias SdrAgent.Prototype.Provisioning
    alias SdrAgent.Repo

    @reason :prototype_not_authorized
    @registry {__MODULE__, :admission_registry}
    @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

    ## Reservation

    @doc """
    The reservation gate in prototype runtime for `call`
    (`%{profile_id:, purpose:}`) in the locked `run`; `observation` is the
    store observation (`Gate.observe_store/0`) and `calibration` the
    calibration marker's scope. `{:ok, nil}` (no calibration tuple) or
    `{:error, reason, check}`.
    """
    def reservation(run, %{profile_id: profile_id, purpose: purpose}, observation, calibration) do
      with :ok <- not_proof(run),
           :ok <- no_calibration(calibration),
           {:ok, live} <- live(),
           :ok <- same_tenant(run, live),
           :ok <- gate_active(),
           :ok <- witness_absent(live.binding, observation),
           :ok <- in_scope(run.usage_origin, purpose, profile_id, live) do
        {:ok, nil}
      end
    end

    ## Launch

    @doc """
    The launch gate in prototype runtime for the owned reserved `invocation`
    of the locked `run`, its charged grant and its one charged allocation
    share-locked (`Admission.lock_charge/1`) and the head held: `:ok` or
    `{:error, reason, check}` (see the moduledoc for the order and codes).
    """
    def launch(run, invocation, observation) do
      with :ok <- not_proof(run),
           {:ok, live} <- live(),
           :ok <- same_tenant(run, live),
           :ok <- gate_active(),
           :ok <- witness_absent(live.binding, observation),
           {:ok, recorded} <- recorded(invocation),
           :ok <- check_recorded(recorded, live, invocation),
           {:ok, _grant} <- check_charge(invocation, live, recorded) do
        :ok
      end
    end

    @doc """
    The closed comparator of a `recorded` 14-key prototype authority (the
    launch's and the release decision's): the closed dictionary (exactly the
    14 keys, each strictly typed), else `authority_mismatch`; then every
    recorded value but the revision against the `live` binding and the
    invocation's own charge, the general keys first (`authority_mismatch`),
    then the operator anchor (`operator_mismatch`), then the witness mode
    (`witness_mode_mismatch`). `:ok` or `{:error, reason, check}`.

    An INTERNAL helper: its only remote caller is `SdrAgent.Prototype.Release`
    (`ReleaseGuardTest`); `launch/3` uses it locally.
    """
    @spec check_recorded(map(), map(), struct()) :: :ok | {:error, atom(), atom()}
    def check_recorded(recorded, live, invocation) do
      with :ok <- closed_authority(recorded), do: recorded_values(recorded, live, invocation)
    end

    @doc """
    The charged grant's current checks (the launch's and the release
    decision's): this binding's provenance grant (`grant_not_eligible`), its
    status (`grant_not_eligible`), the anchor as creator and updater
    (`operator_mismatch`), the exact terms and allocation set
    (`grant_not_eligible`), then the `recorded` revision against the current
    one (`grant_changed`). `{:ok, grant}` or `{:error, reason, check}`.

    S2-A (Codex 3122b0d4 Q6): an absent grant (`{:ok, nil}`) is the business
    refusal `grant_not_eligible`; a returned read error is never folded into
    a refusal: it leaves through `Repo.rollback/1` of the caller's owning
    transaction (the launch's `audit_transact`, the gate's attempt), with
    its identity, before any refusal, `mark_sent` or decision is written. A
    raise propagates. An INTERNAL helper: its only remote caller is
    `SdrAgent.Prototype.Release` (`ReleaseGuardTest`); `launch/3` uses it
    locally.
    """
    @spec check_charge(struct(), map(), map()) :: {:ok, struct()} | {:error, atom(), atom()}
    def check_charge(invocation, live, recorded) do
      with {:ok, grant, allocations} <- charged_grant(invocation),
           :ok <- provenance(grant, live),
           :ok <- provisioned(grant, allocations, live),
           :ok <- same_revision(recorded, grant) do
        {:ok, grant}
      end
    end

    @authority_keys ~w(allocation_id binding_id dataset_class entry_sha256 funding_id grant_id
                       grant_revision instance_id operator_user_id policy_id profile_id purpose
                       tenant_id witness_mode)

    # The closed dictionary: exactly the 14 keys, each strictly typed.
    defp closed_authority(recorded) do
      if Enum.sort(Map.keys(recorded)) == @authority_keys and
           Enum.all?(recorded, fn {key, value} -> typed?(key, value) end),
         do: :ok,
         else: refuse(:authority_mismatch)
    end

    defp typed?("grant_revision", value), do: is_integer(value) and value >= 0
    defp typed?(_key, value), do: is_binary(value)

    # Every recorded value but the revision, against the live binding and
    # the invocation's own charge: the general keys first, then the operator
    # anchor, then the witness mode, each with its own code.
    @value_order (@authority_keys -- ~w(grant_revision operator_user_id witness_mode)) ++
                   ~w(operator_user_id witness_mode)

    defp recorded_values(recorded, live, invocation) do
      expected =
        expected(
          live,
          invocation,
          %{id: invocation.grant_id, revision: nil},
          invocation.allocation_id
        )

      case Enum.find(@value_order, &(Map.fetch!(recorded, &1) != Map.fetch!(expected, &1))) do
        nil -> :ok
        "operator_user_id" -> refuse(:operator_mismatch)
        "witness_mode" -> refuse(:witness_mode_mismatch)
        _other -> refuse(:authority_mismatch)
      end
    end

    # The charged grant's current row and its allocation set (id order),
    # read as the kernel in the invocation's tenant (as
    # `Provisioning.lock_grant/2`, without a lock clause). The launch's
    # `Admission.lock_charge/1` share-locks only the charged grant and the
    # ONE charged allocation, not every row of this set; the supported
    # allocation edits (`ModelCallGrant` actions through `GrantBundle`) lock
    # the parent grant `FOR UPDATE` first, so they serialize on that grant
    # lock. No per-row lock is claimed for the other rows, and nothing here
    # proves concurrency against SQL written behind the application.
    #
    # RED-b2c seam (Codex 79819840 R1): in test-seam builds only, an injected
    # result replaces these reads (`charged_grant_read/1` below); it takes the
    # SAME path as a real one. S2-A (Codex 3122b0d4 Q6): `{:ok, nil}` is the
    # business refusal `grant_not_eligible`; a returned error leaves through
    # the owning transaction's rollback with its identity (see
    # `check_charge/3`). Every other build has no seam path.
    defp charged_grant(%{grant_id: grant_id} = invocation) when is_binary(grant_id) do
      case charged_grant_read(invocation) do
        {:ok, %ModelCallGrant{} = grant, allocations} -> {:ok, grant, allocations}
        {:ok, nil} -> refuse(:grant_not_eligible)
        {:error, error} -> Repo.rollback(error)
      end
    end

    defp charged_grant(_invocation), do: refuse(:grant_not_eligible)

    defp read_charged_grant(%{grant_id: grant_id, tenant_id: tenant_id}) do
      opts = AuditKernel.opts(tenant_id)

      with {:ok, %ModelCallGrant{} = grant} <-
             ModelCallGrant
             |> Ash.Query.for_read(:read, %{}, opts)
             |> Ash.Query.filter(id == ^grant_id and tenant_id == ^tenant_id)
             |> Ash.read_one(),
           {:ok, allocations} <-
             ModelCallAllocation
             |> Ash.Query.for_read(:read, %{}, opts)
             |> Ash.Query.filter(grant_id == ^grant_id and tenant_id == ^tenant_id)
             |> Ash.Query.sort(id: :asc)
             |> Ash.read() do
        {:ok, grant, allocations}
      end
    end

    if @test_seams do
      # Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): a
      # `charged_grant_read: fun/1` in this module's Application env, given
      # the invocation, returns the read result to use. Without it the real
      # reads run.
      defp charged_grant_read(invocation) do
        case Keyword.get(Application.get_env(:sdr_agent, __MODULE__, []), :charged_grant_read) do
          fun when is_function(fun, 1) -> fun.(invocation)
          _none -> read_charged_grant(invocation)
        end
      end
    else
      defp charged_grant_read(invocation), do: read_charged_grant(invocation)
    end

    defp same_revision(%{"grant_revision" => revision}, %{revision: revision}), do: :ok
    defp same_revision(_recorded, _grant), do: refuse(:grant_changed)

    ## This binding's grant (C2 r2 provenance; Codex ff812f6d ruling a)

    @doc """
    The admission candidates in prototype runtime: of the locked
    `candidate_ids`, only this binding's grant, the one the ORIGINAL
    `model.grant.provisioned` event links (`Provisioning.lookup/1`), never one
    found by its name. `{:ok, ids}` (empty when that grant is not a current
    candidate, so the ordinary grant-window reasons stay), or
    `{:error, reason, :grant_not_eligible}` when the binding has no trusted
    provisioned grant.
    """
    def candidates(candidate_ids) do
      with {:ok, live} <- live() do
        case Provisioning.lookup(live.binding) do
          {:one, grant_id, _event} -> {:ok, Enum.filter(candidate_ids, &(&1 == grant_id))}
          _none_or_untrusted -> refuse(:grant_not_eligible)
        end
      end
    end

    @doc """
    After the room check, for the admitted `call` in the locked `run` charged
    to `grant` (its allocations loaded) and `allocation` at `admitted_at`:
    validates the grant (this binding's provenance grant; then status, the
    anchor as creator and updater, the exact funding-entry terms and
    allocation set), builds the 14-key authority and registers the charge
    (mechanism note r3 B). `{:ok, registration, authority}` or
    `{:error, reason, check}` (`grant_not_eligible`, `operator_mismatch`,
    `binding_mismatch`). The authority is never a caller input.

    An INTERNAL producer helper, not an admission API: its sole caller is
    `SdrAgent.Agents.Admission.admit/5`, after the room check, under the
    reservation's locks and head (a source and xref guard in
    `test/sdr_agent/prototype/admission_register_guard_test.exs` pins it).
    """
    def register(run, call, {grant, allocation}, admitted_at) do
      with {:ok, live} <- live(),
           :ok <- same_tenant(run, live),
           :ok <- provenance(grant, live),
           :ok <- provisioned(grant, grant.allocations, live) do
        authority = expected(live, call, grant, allocation.id)
        marker = "sdr_admission.r" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
        Repo.query!("SELECT set_config($1, '1', true)", [marker])

        registration = %Registration{
          ref: make_ref(),
          tenant_id: run.tenant_id,
          agent_run_id: run.id,
          provider: :claude_cli,
          profile_id: call.profile_id,
          purpose: call.purpose,
          grant_id: grant.id,
          allocation_id: allocation.id,
          reserved_at: admitted_at,
          authority_sha256: sha256(authority),
          xact_id: transaction_state(marker) |> elem(0),
          savepoint_marker: marker
        }

        put_entry(registration.ref, %{
          registration: registration,
          authority: authority,
          consumed?: false
        })

        {:ok, registration, authority}
      end
    end

    defp provenance(grant, live) do
      case Provisioning.lookup(live.binding) do
        {:one, grant_id, _event} when grant_id == grant.id -> :ok
        _other -> refuse(:grant_not_eligible)
      end
    end

    # Status, then the anchor as creator and updater, then the exact terms
    # and allocation set (Codex ff812f6d ruling b; the revision is recorded).
    defp provisioned(grant, allocations, %{binding: binding}) do
      cond do
        grant.status != :active ->
          refuse(:grant_not_eligible)

        grant.created_by_id != binding.operator_user_id or
            grant.updated_by_id != binding.operator_user_id ->
          refuse(:operator_mismatch)

        not Provisioning.unchanged?(grant, allocations) ->
          refuse(:grant_not_eligible)

        true ->
          :ok
      end
    end

    @doc false
    # The 14-key authority of `call` charged to `grant` and `allocation_id`,
    # from the boot snapshot.
    def expected(%{binding: binding}, call, grant, allocation_id) do
      %{
        "policy_id" => binding.policy_id,
        "entry_sha256" => binding.policy_entry_sha256,
        "funding_id" => binding.funding_id,
        "binding_id" => binding.id,
        "instance_id" => binding.instance_id,
        "tenant_id" => binding.tenant_id,
        "operator_user_id" => binding.operator_user_id,
        "dataset_class" => binding.dataset_class,
        "witness_mode" => binding.witness_mode,
        "profile_id" => Atom.to_string(call.profile_id),
        "purpose" => Atom.to_string(call.purpose),
        "grant_id" => grant.id,
        "grant_revision" => grant.revision,
        "allocation_id" => allocation_id
      }
    end

    ## The registry (mechanism note r3 section B)

    @doc """
    Read-only: `{:ok, authority}` when `registration` is equal to this
    process's own unconsumed entry and agrees with `facts` (the reservation
    being written; every given key must match), both compared BEFORE any
    SQL, and the current transaction id and the entry's transaction-local
    marker still match. Otherwise `:error`. Nothing is consumed.
    """
    def verify(registration, facts \\ %{})

    def verify(%Registration{ref: ref} = registration, facts) when is_reference(ref) do
      with %{registration: ^registration, consumed?: false, authority: authority} <-
             Map.get(registry(), ref),
           true <- facts_match?(registration, facts),
           true <- Repo.in_transaction?(),
           true <-
             transaction_state(registration.savepoint_marker) ==
               {registration.xact_id, "1"} do
        {:ok, authority}
      else
        _refused -> :error
      end
    end

    def verify(_registration, _facts), do: :error

    @doc """
    Verifies `registration` against the reservation being written (`facts`)
    and consumes it, once: `{:ok, authority}` or `:error`. Only the
    authorized `:reserve` action calls this, immediately before its insert.
    """
    def consume(registration, facts) do
      with {:ok, authority} <- verify(registration, facts) do
        put_entry(registration.ref, %{Map.fetch!(registry(), registration.ref) | consumed?: true})
        {:ok, authority}
      end
    end

    @doc "Whether `registration` is live, unconsumed and owned here (read-only)."
    def registered?(registration), do: match?({:ok, _}, verify(registration))

    @doc "Every registration this process owns: live, stale and consumed ones."
    def pending, do: map_size(registry())

    @doc "Removes this process's own entry equal to `registration`; nothing else."
    def discard(%Registration{ref: ref} = registration) when is_reference(ref) do
      case Map.get(registry(), ref) do
        %{registration: ^registration} -> delete_entry(ref)
        _other -> :ok
      end
    end

    def discard(_registration), do: :ok

    @doc """
    Runs `fun`, then discards ONLY the registrations this process created
    during it (by owned ref), whatever `fun` returns or raises: its result is
    returned and its raise re-raised unchanged. It always reads this
    process's registry before and after `fun`, in ordinary runtime too
    (where no registration is created, so nothing is discarded).
    """
    def with_owned_registrations(fun) when is_function(fun, 0) do
      before = registry() |> Map.keys() |> MapSet.new()

      try do
        fun.()
      after
        for ref <- Map.keys(registry()), not MapSet.member?(before, ref), do: delete_entry(ref)
      end
    end

    @facts [
      :tenant_id,
      :agent_run_id,
      :provider,
      :profile_id,
      :purpose,
      :grant_id,
      :allocation_id,
      :reserved_at
    ]

    defp facts_match?(registration, facts) when is_map(facts) do
      Enum.all?(Map.take(facts, @facts), fn {key, value} ->
        Map.fetch!(registration, key) == value
      end)
    end

    defp facts_match?(_registration, _facts), do: false

    # The current transaction id and a marker's value, in one query (no lock
    # clause); as `ReleaseDecision.Prelocked`.
    defp transaction_state(marker) do
      %{rows: [[id, value]]} =
        Repo.query!("SELECT pg_current_xact_id()::text, current_setting($1, true)", [marker])

      {id, value}
    rescue
      _aborted -> {nil, nil}
    end

    defp registry, do: Process.get(@registry, %{})

    defp put_entry(ref, entry), do: Process.put(@registry, Map.put(registry(), ref, entry))

    defp delete_entry(ref) do
      case Map.delete(registry(), ref) do
        empty when empty == %{} -> Process.delete(@registry)
        rest -> Process.put(@registry, rest)
      end

      :ok
    end

    ## Shared checks (also used by the release decision)

    @doc """
    The live prototype state: `{:ok, %{binding:, entry:, funding:}}` when the
    runtime is prototype, `check_live/0` passes and the snapshot records the
    compiled policy entry's digest; `{:error, reason, :binding_mismatch}`
    otherwise.
    """
    def live do
      with :prototype <- Prototype.runtime(),
           :ok <- Prototype.check_live(),
           {:ok, binding} <- Prototype.binding(),
           {:ok, entry} <- Prototype.policy_entry(),
           {:ok, funding} <- Prototype.funding_entry(),
           true <- binding.policy_entry_sha256 == sha256(entry) do
        {:ok, %{binding: binding, entry: entry, funding: funding}}
      else
        _not_live -> refuse(:binding_mismatch)
      end
    end

    @doc """
    D-237 TF-2: one raw, read-only state probe of the CURRENT transaction,
    for a consumer that just received a returned `binding_mismatch` from
    `live/0` (Codex c83a34e9 Q-T1). `:ok` when the transaction is usable;
    otherwise `{:error, error}` with the probe's own error unchanged (a
    typed `in_failed_sql_transaction` for an aborted owner, or any other
    error as it is). It never retries, repairs, rescues or parses text, and
    it writes nothing. The caller exits through its owner (plan r2 §3).
    """
    @spec state_probe() :: :ok | {:error, term()}
    def state_probe do
      case Repo.query("SELECT 1", []) do
        {:ok, _result} -> :ok
        {:error, error} -> {:error, error}
      end
    end

    @doc """
    The `prototype_authority` recorded by `invocation`'s one original
    `model.invocation.reserved` event: `{:ok, map}` or
    `{:error, reason, :authority_unrecorded}`.
    """
    def recorded(invocation) do
      case Gate.recorded_prototype_authority(invocation) do
        {:ok, %{} = authority} -> {:ok, authority}
        _missing_duplicated_or_malformed -> refuse(:authority_unrecorded)
      end
    end

    ## Internals

    defp refuse(check), do: {:error, @reason, check}

    defp not_proof(%{usage_origin: :proof}), do: refuse(:proof_run)
    defp not_proof(_run), do: :ok

    defp no_calibration(nil), do: :ok
    defp no_calibration(_authority), do: refuse(:scope_mismatch)

    defp same_tenant(%{tenant_id: tenant_id}, %{binding: %{tenant_id: tenant_id}}), do: :ok
    defp same_tenant(_run, _live), do: refuse(:binding_mismatch)

    defp gate_active,
      do: if(Gate.active?(), do: :ok, else: {:error, :result_gate_inactive, :inactive})

    # The store is absent: the snapshot says so, no root is configured, and
    # no root was observed. A pure comparison (no filesystem I/O).
    defp witness_absent(binding, observation) do
      observed_root? = match?(%{root: root} when not is_nil(root), observation)

      if binding.witness_mode == "absent" and is_nil(Witness.store_root()) and not observed_root?,
        do: :ok,
        else: refuse(:witness_mode_mismatch)
    end

    # The run's origin, the call's purpose and its profile are in the policy
    # entry and in the funding entry's funded scope.
    defp in_scope(origin, purpose, profile_id, %{entry: entry, funding: funding}) do
      funded? =
        Enum.any?(funding.funded_scope, fn {funded_origin, purposes} ->
          funded_origin == origin and purpose in purposes
        end)

      if origin in entry.usage_origins and purpose in entry.purposes and
           profile_id in entry.identity.profile_ids and profile_id in funding.profile_ids and
           funded?,
         do: :ok,
         else: refuse(:scope_mismatch)
    end

    defp sha256(term), do: Base.encode16(Canonical.sha256(term), case: :lower)
  end
end
