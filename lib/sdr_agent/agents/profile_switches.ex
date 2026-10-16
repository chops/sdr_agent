defmodule SdrAgent.Agents.ProfileSwitches do
  @moduledoc """
  The model profile switch records (C2-02a, slice a of #52;
  `docs/product/r0/c2-02a-interface.md`), behind the `SdrAgent.Agents`
  functions `request_profile_switch/2`, `complete_profile_switch/3`,
  `fail_profile_switch/3`, `block_profile_switch/3`,
  `get_profile_setting/1` and `list_profile_switches/1`.

  Each write runs in one `SdrAgent.Audit.transaction/1` and through
  `SdrAgent.Audit.Guard` (an auditor's attempt is refused and audited), and
  opens its `SdrAgent.Agents.Checks.ProfileSwitchContext` phase itself:

    * **request** (a current human admin, re-read): reads the tenant's
      setting `FOR UPDATE`, or creates it with the `:initialize` upsert
      under an id generated here (inserted iff the returned id is that id);
      checks `to` (a reviewed real profile, not the desired one), the
      revision and the generation; refuses while a pending or blocked
      switch exists; then creates the pending switch, whose action appends
      `setting_initialized` (only if this transaction inserted the row) and
      `switch_requested`. Any refusal rolls everything back;
    * **complete, fail, block** (`model_runtime` of the switch's tenant):
      under `:transition`, lock the setting, then the switch; refuse a
      stale `server_generation` first; a replay with the same generation
      in the action's result status is a no-op success; complete or fail
      on a blocked switch is `{:error, :switch_blocked}`; any other
      finished switch is `{:error, :switch_already_finished}`. `complete`
      then moves to `:apply`, applies the switch to the setting and
      completes it; `fail` and `block` never write the setting.

  **The attended resolution (C2-02b2β,
  `docs/product/r0/c2-02b2b-interface.md`)**, behind
  `SdrAgent.Agents.blocked_switch_facts/2` and
  `SdrAgent.Agents.resolve_blocked_switch/3`: an active human admin decides
  (the actor, re-read), the registered coordinator executes
  (`SdrAgent.AI.ModelProvider.Coordinator.resolve_blocked/2`):

    * **the caller** stamps one monotonic deadline (now + 15 s) before
      dispatch, checks the actor, the attestation's closed shape
      (`SdrAgent.Agents.SwitchResolution.checked_attestation/2`) and the first replay read (one stored read
      by `attestation_id`, unique per tenant: an exact semantic match is
      `{:ok, %{switch: stored, replay: true}}` with no effect, any other
      row `:attestation_conflict`), then calls the coordinator with a call
      timeout of the time left plus 500 ms;
    * **the write** (`commit_resolution/2`, in the coordinator only, as the
      admin, phase `:resolve`; one bounded `LedgerCall`) takes b2α's lock
      order setting → counter `FOR SHARE` → switch → latest start `FOR
      SHARE` → head and, after the locks: the actor is still an active
      admin; the third replay read (the locked switch carrying this id, or
      another switch carrying it, before any state refusal); the switch is
      blocked; the latest start is the attested one, of the coordinator's
      boot; no other switch is open. Any refusal rolls back. It writes only
      the switch (`resolve_blocked`) and its `switch_resolved` event, never
      the setting, a start or a lease;
    * **settlement** (`settle_resolution/2`) of an unknown outcome (a
      timeout, a lost reply, a connection error): one bounded `LedgerCall`
      in the read-only phase `:settle` takes the same locks in the same
      order (the barrier: the switch row lock proves the original
      transaction has ended), then re-reads the switch and the row carrying
      this id: an exact match is the replay result; the switch still
      blocked with no such row is a definite `:resolve_timeout`; another
      row is `:attestation_conflict`; a switch resolved under another id is
      `:switch_not_blocked`; no barrier or no read is `:resolve_uncertain`.
      Elapsed time is never proof.

  `complete` and `fail` refuse a blocked switch (`:switch_blocked`), the
  current owner's `block` on it stays a no-write replay, and `fail` on a
  **resolved** switch is `:switch_already_finished` (checked after the
  existing owner, boot and generation guards), never a `fail` replay.

  Reads are scoped to the actor's tenant; an auditor's read appends a
  `record_view` AuditAccess first (fail closed). `model_runtime` has no
  read here.

  Test builds only (`:claude_cli_test_seams`): the caller option `faults:
  [replay_read: fn -> :read | :unavailable end]` and the write option
  `faults: [locked_replay_read: ...]`; other builds raise `ArgumentError`
  on either.
  """
  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias Ash.Error.Query.NotFound
  alias SdrAgent.Accounts.User
  alias SdrAgent.Agents.Checks.CoordinatorProcess
  alias SdrAgent.Agents.Checks.CurrentAdmin
  alias SdrAgent.Agents.LedgerCall
  alias SdrAgent.Agents.ModelProfileSetting
  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Agents.ModelServerCounter
  alias SdrAgent.Agents.ModelServerStart
  alias SdrAgent.Agents.ServerStarts
  alias SdrAgent.Agents.SwitchResolution
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo

  @results %{complete: :completed, fail: :failed, block: :blocked}
  # The open phases of this process, by token (see "Phases" below).
  @phases {__MODULE__, :phases}
  @binding_keys [
    :action,
    :tenant_id,
    :switch_id,
    :server_generation,
    :actor,
    :attestation,
    :boot_id,
    :start_id
  ]
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  # The C2-02b2β runtime owner, called at run time only.
  @coordinator SdrAgent.AI.ModelProvider.Coordinator
  @resolve_budget_ms 15_000
  @settle_budget_ms 2_000
  @attested [:attestation_id, :attested_start_id, :attested_generation, :attested_lease_kind]

  ## Reads

  @doc "ADM, AUD (audited), AGT: the tenant's setting, or `{:ok, nil}` before the first one."
  def get_setting(opts) do
    actor = Keyword.get(opts, :actor)

    ModelProfileSetting
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.read_one()
    |> audited(actor, ModelProfileSetting, "model profile setting")
  end

  @doc "ADM, AUD (audited), AGT: the tenant's switches, newest first."
  def list_switches(opts) do
    actor = Keyword.get(opts, :actor)

    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.sort(requested_at: :desc, id: :desc)
    |> Ash.read()
    |> audited(actor, ModelProfileSwitch, "model profile switches")
  end

  defp audited({:ok, result}, %User{role: :auditor} = actor, resource, purpose) do
    case Audit.record_access(:record_view, inspect(resource), ref(result), purpose, actor: actor) do
      {:ok, _access} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  defp audited(result, _actor, _resource, _purpose), do: result

  defp ref(nil), do: "none"
  defp ref([]), do: "none"
  defp ref(records) when is_list(records), do: Enum.map_join(records, ",", & &1.id)
  defp ref(record), do: record.id

  ## Request

  @doc "ADM: requests a switch to `to_profile_id` (see the moduledoc)."
  def request(attrs, opts) do
    actor = current_operator(Keyword.get(opts, :actor))
    attrs = Map.new(attrs)

    transaction(fn -> guard(:request, nil, actor, fn -> admin_request(attrs, actor) end) end)
  end

  defp admin_request(attrs, actor) do
    with :ok <- admin(actor) do
      binding = %{action: :request, tenant_id: actor.tenant_id, actor: actor}
      with_phase(:initialize, binding, &do_request(attrs, actor, &1))
    end
  end

  defp do_request(attrs, actor, context) do
    with {:ok, input} <- request_input(attrs),
         {:ok, setting} <- setting_for_request(actor, context),
         :ok <- requestable(input, setting),
         :ok <- no_open_switch(actor) do
      ModelProfileSwitch
      |> Ash.Changeset.for_create(
        :request,
        %{
          from_profile_id: setting.desired_profile_id,
          to_profile_id: input.to_profile_id,
          server_generation: input.server_generation
        },
        actor: actor,
        context: context
      )
      |> Ash.create()
    end
  end

  defp request_input(attrs) do
    to = Map.get(attrs, :to_profile_id)
    revision = Map.get(attrs, :expected_revision)
    generation = Map.get(attrs, :server_generation)

    cond do
      not ModelProfiles.real?(to) ->
        invalid(:to_profile_id, "must be a reviewed real profile")

      not positive?(revision) ->
        invalid(:expected_revision, "must be a positive integer")

      not positive?(generation) ->
        invalid(:server_generation, "must be a positive integer")

      true ->
        {:ok, %{to_profile_id: to, expected_revision: revision, server_generation: generation}}
    end
  end

  # The tenant's setting, locked; created by the `:initialize` upsert when
  # absent. A concurrent first request waits on the unique index and then
  # gets the winner's row, unchanged and locked.
  defp setting_for_request(actor, context) do
    ModelProfileSetting
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(tenant_id == ^actor.tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> initialize(actor, context)
      other -> other
    end
  end

  defp initialize(actor, context) do
    id = Ash.UUIDv7.generate()

    ModelProfileSetting
    |> Ash.Changeset.for_create(:initialize, %{id: id, tenant_id: actor.tenant_id},
      actor: actor,
      context: context
    )
    |> Ash.create(touch_update_defaults?: false)
    |> case do
      {:ok, %{id: ^id} = setting} ->
        with :ok <- record_evidence(context, :initialized, setting),
             do: {:ok, setting}

      other ->
        other
    end
  end

  defp requestable(input, setting) do
    cond do
      input.expected_revision != setting.revision ->
        invalid(:expected_revision, "is stale")

      input.to_profile_id == setting.desired_profile_id ->
        invalid(:to_profile_id, "is already the desired profile")

      true ->
        :ok
    end
  end

  defp no_open_switch(actor) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(tenant_id == ^actor.tenant_id and status in [:pending, :blocked])
    |> Ash.exists()
    |> case do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :switch_open}
      {:error, error} -> {:error, error}
    end
  end

  ## Complete, fail, block

  @doc """
  MRT, in the registered coordinator only (C2-02b2α): `action`
  (`:complete`, `:fail` or `:block`) on `switch` for `server_generation`,
  `boot_id` and `start_id` (and `failure_reason` for fail and block), as one
  bounded ledger call (`budget_ms:`, at most 2 s).
  """
  def transition(action, %ModelProfileSwitch{id: switch_id}, attrs, opts)
      when is_map_key(@results, action) do
    actor = Keyword.get(opts, :actor)
    attrs = Map.new(attrs)

    LedgerCall.run(&guarded_transition(action, switch_id, attrs, actor, &1), opts)
  end

  defp guarded_transition(action, switch_id, attrs, actor, step) do
    guard(action, switch_id, actor, fn ->
      with :ok <- coordinator(actor),
           do: runtime_transition(action, switch_id, attrs, actor, step)
    end)
  end

  # C2-02b2α: executed only in the registered coordinator (section 1a).
  defp coordinator(%SdrAgent.Actor{type: :model_runtime}) do
    if CoordinatorProcess.coordinator?(), do: :ok, else: forbidden()
  end

  defp coordinator(_actor), do: forbidden()

  defp runtime_transition(action, switch_id, attrs, actor, step) do
    with :ok <- runtime(actor),
         :ok <- generation_input(attrs),
         :ok <- owner_input(attrs) do
      binding = %{
        action: action,
        tenant_id: actor.tenant_id,
        switch_id: switch_id,
        server_generation: attrs.server_generation,
        actor: actor
      }

      with_phase(
        :transition,
        binding,
        &do_transition(action, switch_id, attrs, actor, &1, step)
      )
    end
  end

  # Lock order setting → counter → switch → latest start → head (C2-02b2α
  # section 1b); the stale-generation check runs first, then the boot fence
  # and the action's prerequisites on the locked latest start (1a).
  defp do_transition(action, switch_id, attrs, actor, context, step) do
    with {:ok, setting} <- lock(ModelProfileSetting, switch_id, actor, context),
         :ok <- step.(),
         {:ok, counter} <- ServerStarts.share_counter(actor),
         :ok <- step.(),
         {:ok, switch} <- lock(ModelProfileSwitch, switch_id, actor, context),
         :ok <- same_generation(switch, attrs.server_generation),
         :ok <- step.(),
         {:ok, latest} <- ServerStarts.fence(counter, attrs.start_id, attrs.boot_id, actor),
         :ok <- prerequisite(action, latest, switch),
         :ok <- step.() do
      case decide(action, switch) do
        :proceed -> write(action, setting, switch, attrs, actor, context)
        :replay -> {:ok, switch}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp owner_input(%{boot_id: boot_id, start_id: start_id})
       when is_binary(boot_id) and is_binary(start_id),
       do: :ok

  defp owner_input(_attrs),
    do: invalid(:start_id, "the coordinator's boot_id and start_id are required")

  # The disjoint per-action prerequisites on the locked latest start (1a).
  defp prerequisite(:complete, start, switch) do
    if start.status == :ready and start.reason == :activation and start.switch_id == switch.id and
         start.profile_id == switch.to_profile_id and start.ready_evidence == :spawn_preflight,
       do: :ok,
       else: invalid(:start_id, "complete needs this boot's ready activation for the switch")
  end

  defp prerequisite(:fail, start, switch) do
    if start.status == :ready and start.reason == :rollback and start.switch_id == switch.id and
         start.profile_id == switch.from_profile_id and start.ready_evidence == :spawn_preflight,
       do: :ok,
       else: invalid(:start_id, "fail needs this boot's ready rollback for the switch")
  end

  defp prerequisite(:block, _start, _switch), do: :ok

  defp generation_input(attrs) do
    if positive?(Map.get(attrs, :server_generation)),
      do: :ok,
      else: invalid(:server_generation, "must be a positive integer")
  end

  # Setting first, then the switch (`TransitionLock` refuses the reverse).
  defp lock(resource, switch_id, actor, context) do
    resource
    |> Ash.Query.for_read(:lock_for_transition, %{switch_id: switch_id},
      actor: actor,
      context: context
    )
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, NotFound.exception(resource: resource)}
      other -> other
    end
  end

  defp same_generation(%{server_generation: generation}, generation), do: :ok
  defp same_generation(_switch, _generation), do: invalid(:server_generation, "is stale")

  # C2-02b2β: a resolved switch is `:failed`, which would otherwise read as
  # a replay of α's own `fail`; it is refused here, after the owner, boot
  # and generation guards above.
  defp decide(:fail, %ModelProfileSwitch{status: :failed, resolution: resolution})
       when not is_nil(resolution),
       do: {:error, :switch_already_finished}

  defp decide(action, %ModelProfileSwitch{status: status}) do
    cond do
      Map.fetch!(@results, action) == status -> :replay
      status == :pending -> :proceed
      status == :blocked -> {:error, :switch_blocked}
      true -> {:error, :switch_already_finished}
    end
  end

  defp write(:complete, setting, switch, _attrs, actor, context) do
    context = advance(context)

    with {:ok, _setting} <-
           setting
           |> Ash.Changeset.for_update(:apply_switch, %{switch_id: switch.id},
             actor: actor,
             context: context
           )
           |> Ash.update() do
      switch
      |> Ash.Changeset.for_update(:complete, %{}, actor: actor, context: context)
      |> Ash.update()
    end
  end

  defp write(action, _setting, switch, attrs, actor, context) do
    switch
    |> Ash.Changeset.for_update(action, %{failure_reason: Map.get(attrs, :failure_reason)},
      actor: actor,
      context: context
    )
    |> Ash.update()
  end

  ## The attended resolution (C2-02b2β)

  @doc """
  ADM: the facts a blocked switch's resolution is attested on
  (`SdrAgent.AI.ModelProvider.Coordinator.resolution_facts/2`, read-only):
  `{:ok, %{switch, boot_id, latest_start, hold, covered_starts,
  lease_kind}}`, `{:error, :observation_unknown}`, `{:error,
  :switch_not_blocked}`, NotFound for a switch outside the tenant, or
  Forbidden for any actor but an active human admin.
  """
  def blocked_facts(switch, opts) do
    actor = current_operator(Keyword.get(opts, :actor))
    id = switch_id(switch)

    guard(:blocked_switch_facts, id, actor, fn ->
      with :ok <- admin(actor),
           {:ok, _stored} <- tenant_switch(actor, id) do
        @coordinator.resolution_facts(id, actor: actor)
      end
    end)
  end

  @doc """
  ADM: resolves blocked `switch` to `:failed` under `attestation` (see the
  moduledoc): `{:ok, %{switch: s}}` (committed; the server is not
  necessarily ready), `{:ok, %{switch: s, replay: true}}`, `{:error,
  :resolve_timeout}` (definitely not committed), `{:error,
  :resolve_uncertain}`, or a typed refusal.
  """
  def resolve_blocked(switch, attestation, opts) do
    deadline = System.monotonic_time(:millisecond) + @resolve_budget_ms
    faults = caller_faults(opts)
    actor = current_operator(Keyword.get(opts, :actor))
    id = switch_id(switch)

    guard(:resolve_blocked, id, actor, fn ->
      with :ok <- admin(actor),
           {:ok, attestation} <- SwitchResolution.checked_attestation(id, attestation),
           {:ok, nil} <- caller_replay(actor, attestation, faults),
           {:ok, _stored} <- tenant_switch(actor, id) do
        dispatch(%{switch_id: id, attestation: attestation, actor: actor}, deadline)
      else
        {:ok, %ModelProfileSwitch{} = stored} ->
          SwitchResolution.resolution_result(stored, attestation, actor.id)

        other ->
          other
      end
    end)
  end

  @doc """
  The resolution write, in the registered coordinator only, as the admin
  (`request`: `%{switch_id, attestation, actor, boot_id, start_id}`), as one
  bounded ledger call of `budget_ms:` (see the moduledoc). Returns
  `SdrAgent.Agents.LedgerCall.attempt/2`'s outcome: `{:ok, {:resolved,
  switch}}`, `{:ok, {:replay, switch}}` (the locked switch already carries
  this exact attestation; nothing written), `{:rolled_back, reason}` or
  `{:unknown, reason}`.
  """
  def commit_resolution(request, opts) do
    faults = write_faults(opts)

    LedgerCall.attempt(
      &guarded_resolution(request, faults, &1),
      budget_ms: Keyword.fetch!(opts, :budget_ms)
    )
  end

  @doc """
  The settlement barrier and exact re-read of an unknown resolution
  (`request`: `%{switch_id, attestation, resolver_id}`), as `actor` — the
  resolving admin, or `model_runtime` in the registered coordinator. One
  bounded ledger call (2 s) in the read-only `:settle` phase; returns the
  settled result (the replay, `:resolve_timeout`, `:attestation_conflict`
  or `:switch_not_blocked`), Forbidden, or `{:error, :resolve_uncertain}`
  when the barrier or the read is not obtained.
  """
  def settle_resolution(request, actor) do
    fn step -> settle_in_phase(request, actor, step) end
    |> LedgerCall.attempt(budget_ms: @settle_budget_ms)
    |> case do
      {:ok, {:settled, result}} -> result
      {:rolled_back, %Ash.Error.Forbidden{} = forbidden} -> {:error, forbidden}
      _unproven -> {:error, :resolve_uncertain}
    end
  end

  # An unknown outcome (a caller timeout, a lost reply, the coordinator's
  # death) is settled by the caller; a coordinator's answer is final.
  defp dispatch(request, deadline) do
    @coordinator.resolve_blocked(request, deadline)
  catch
    :exit, _unknown ->
      settle_resolution(
        %{
          switch_id: request.switch_id,
          attestation: request.attestation,
          resolver_id: request.actor.id
        },
        request.actor
      )
  end

  defp caller_replay(actor, attestation, faults) do
    case fault(faults, :replay_read) do
      :unavailable ->
        {:error, :observation_unknown}

      :read ->
        SwitchResolution.replay_lookup(actor.tenant_id, attestation.attestation_id, actor: actor)
    end
  end

  # The admin's own tenant only: another tenant's switch is not found.
  defp tenant_switch(actor, id) when is_binary(id) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(tenant_id == ^actor.tenant_id and id == ^id)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelProfileSwitch{} = switch} -> {:ok, switch}
      {:ok, nil} -> not_found()
      {:error, error} -> {:error, error}
    end
  end

  defp tenant_switch(_actor, _id), do: not_found()

  defp not_found,
    do: {:error, Ash.Error.to_error_class(NotFound.exception(resource: ModelProfileSwitch))}

  defp guarded_resolution(request, faults, step) do
    %{switch_id: id, actor: actor} = request

    guard(:resolve_blocked, id, actor, fn ->
      with :ok <- resolve_authority(actor),
           {:ok, attestation} <- SwitchResolution.checked_attestation(id, request.attestation) do
        binding = %{
          action: :resolve_blocked,
          tenant_id: actor.tenant_id,
          switch_id: id,
          actor: actor,
          attestation: Map.take(attestation, @attested),
          boot_id: request.boot_id,
          start_id: request.start_id
        }

        with_phase(:resolve, binding, &locked_resolution(request, attestation, faults, &1, step))
      end
    end)
  end

  defp resolve_authority(actor) do
    if CoordinatorProcess.coordinator?() and CurrentAdmin.match?(actor, %{}, []),
      do: :ok,
      else: forbidden()
  end

  # b2α's lock order (setting → counter FOR SHARE → switch → latest start
  # FOR SHARE → head), then, after the locks: the admin, the third replay
  # read, blocked, the attested fence, no other open switch.
  defp locked_resolution(request, attestation, faults, context, step) do
    %{switch_id: id, actor: actor} = request
    tenant_id = actor.tenant_id

    with {:ok, _setting} <- lock(ModelProfileSetting, id, actor, context),
         :ok <- step.(),
         {:ok, counter} <- shared(ModelServerCounter, tenant_id, nil),
         :ok <- step.(),
         {:ok, switch} <- lock(ModelProfileSwitch, id, actor, context),
         :ok <- step.(),
         {:ok, latest} <- shared(ModelServerStart, tenant_id, counter),
         :ok <- step.(),
         :ok <- resolve_authority(actor),
         {:ok, nil} <- locked_replay(switch, attestation, actor, faults),
         :ok <- still_blocked(switch),
         :ok <- attested_fence(latest, attestation, request),
         :ok <- no_other_open_switch(tenant_id, id),
         :ok <- step.() do
      resolve_write(switch, attestation, actor, context)
    else
      {:replay, switch} -> {:ok, {:replay, switch}}
      other -> other
    end
  end

  # A share lock on the tenant's counter, or on its latest start (the
  # counter's generation), read as the kernel in this transaction.
  defp shared(ModelServerCounter, tenant_id, nil) do
    ModelServerCounter
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one()
    |> case do
      {:ok, %ModelServerCounter{} = counter} -> {:ok, counter}
      {:ok, nil} -> {:error, :stale_attestation}
      error -> error
    end
  end

  defp shared(ModelServerStart, tenant_id, %ModelServerCounter{last_generation: generation}) do
    ModelServerStart
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and generation == ^generation)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read_one()
    |> case do
      {:ok, %ModelServerStart{} = start} -> {:ok, start}
      {:ok, nil} -> {:error, :stale_attestation}
      error -> error
    end
  end

  # The third replay read, before any state refusal: the locked switch
  # carrying this id is the replay (exact) or a conflict; another switch
  # carrying it is a conflict; an unreadable lookup refuses.
  defp locked_replay(switch, attestation, actor, faults) do
    cond do
      fault(faults, :locked_replay_read) == :unavailable ->
        {:error, :observation_unknown}

      switch.attestation_id == attestation.attestation_id ->
        case SwitchResolution.resolution_result(switch, attestation, actor.id) do
          {:ok, _replay} -> {:replay, switch}
          error -> error
        end

      true ->
        case SwitchResolution.replay_lookup(
               actor.tenant_id,
               attestation.attestation_id,
               Kernel.opts(actor.tenant_id)
             ) do
          {:ok, nil} -> {:ok, nil}
          {:ok, %ModelProfileSwitch{}} -> {:error, :attestation_conflict}
          error -> error
        end
    end
  end

  defp still_blocked(%ModelProfileSwitch{status: :blocked, resolution: nil}), do: :ok
  defp still_blocked(_switch), do: {:error, :switch_not_blocked}

  # The b2α fence: the latest start is the attested one and of the
  # coordinator's boot (its own bound start).
  defp attested_fence(latest, attestation, request) do
    if latest.id == attestation.attested_start_id and
         latest.generation == attestation.attested_generation and
         latest.id == request.start_id and latest.boot_id == request.boot_id,
       do: :ok,
       else: {:error, :stale_attestation}
  end

  defp no_other_open_switch(tenant_id, id) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and id != ^id and status in [:pending, :blocked])
    |> Ash.exists()
    |> case do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :switch_open}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_write(switch, attestation, actor, context) do
    switch
    |> Ash.Changeset.for_update(:resolve_blocked, Map.take(attestation, @attested),
      actor: actor,
      context: context
    )
    |> Ash.update()
    |> case do
      {:ok, resolved} ->
        {:ok, {:resolved, resolved}}

      {:error, error} ->
        if attestation_taken?(error), do: {:error, :attestation_conflict}, else: {:error, error}
    end
  end

  # The per-tenant unique attestation id, taken by another switch.
  defp attestation_taken?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%{field: :attestation_id}, &1))

  defp attestation_taken?(_error), do: false

  # The barrier: the write's locks, in the write's order, read-only; then
  # the exact re-read.
  defp settle_in_phase(request, actor, step) do
    with :ok <- settle_actor(actor) do
      binding = %{
        action: :settle,
        tenant_id: actor.tenant_id,
        switch_id: request.switch_id,
        actor: actor
      }

      with_phase(:settle, binding, &settle_barrier(request, actor, &1, step))
    end
  end

  defp settle_barrier(request, actor, context, step) do
    %{switch_id: id, attestation: attestation, resolver_id: resolver_id} = request
    tenant_id = actor.tenant_id

    with {:ok, _setting} <- lock(ModelProfileSetting, id, actor, context),
         :ok <- step.(),
         {:ok, _counter} <- settle_counter(tenant_id),
         :ok <- step.(),
         {:ok, switch} <- lock(ModelProfileSwitch, id, actor, context),
         :ok <- step.(),
         {:ok, found} <-
           SwitchResolution.replay_lookup(
             tenant_id,
             attestation.attestation_id,
             Kernel.opts(tenant_id)
           ) do
      {:ok, {:settled, settled(switch, found, attestation, resolver_id)}}
    end
  end

  defp settle_actor(%User{} = actor),
    do: if(CurrentAdmin.match?(actor, %{}, []), do: :ok, else: forbidden())

  defp settle_actor(%SdrAgent.Actor{type: :model_runtime, tenant_id: tenant_id})
       when is_binary(tenant_id) do
    if CoordinatorProcess.coordinator?(), do: :ok, else: forbidden()
  end

  defp settle_actor(_actor), do: forbidden()

  # The barrier's counter lock (the write's order); a tenant without one
  # has no start, which the re-read does not need.
  defp settle_counter(tenant_id) do
    case shared(ModelServerCounter, tenant_id, nil) do
      {:error, :stale_attestation} -> {:ok, nil}
      other -> other
    end
  end

  defp settled(_switch, %ModelProfileSwitch{} = found, attestation, resolver_id),
    do: SwitchResolution.resolution_result(found, attestation, resolver_id)

  defp settled(%ModelProfileSwitch{status: :blocked}, nil, _attestation, _resolver_id),
    do: {:error, :resolve_timeout}

  defp settled(_switch, nil, _attestation, _resolver_id), do: {:error, :switch_not_blocked}

  defp switch_id(%{id: id}) when is_binary(id), do: id
  defp switch_id(id) when is_binary(id), do: id
  defp switch_id(_switch), do: nil

  # A test fault's answer; `:read` without one.
  defp fault(faults, key) do
    case Keyword.get(faults, key) do
      fun when is_function(fun, 0) -> fun.()
      nil -> :read
    end
  end

  # `faults:` exist only in test builds (`:claude_cli_test_seams`).
  if @test_seams do
    defp caller_faults(opts), do: Keyword.get(opts, :faults, [])
    defp write_faults(opts), do: Keyword.get(opts, :faults, [])
  else
    defp caller_faults(opts), do: no_faults!(opts)
    defp write_faults(opts), do: no_faults!(opts)

    defp no_faults!(opts) do
      if Keyword.has_key?(opts, :faults),
        do: raise(ArgumentError, "faults: exist only in test builds"),
        else: []
    end
  end

  ## Phases (`SdrAgent.Agents.Checks.ProfileSwitchContext`)

  # A phase is opened only here, by the private `with_phase/3` and
  # `advance/1`: no exported function opens or advances one, so the internal
  # actions can't be reached outside this orchestration (a test build adds
  # a seam below). The binding lives in this process under a fresh
  # reference; the context passed to the actions carries only that
  # reference. Evidence recorded in it never proves a database effect on its
  # own: `SdrAgent.Agents.Changes.ProfileSwitchGuard` re-locks and re-checks
  # the stored rows.

  @doc """
  The open phase binding a context names (`{:ok, binding}`), or `:error`.
  Read-only; used by the phase check, the lock reads and the write guards.
  """
  def phase(%{profile_switch: %{token: token}}) when is_reference(token),
    do: Map.fetch(Process.get(@phases, %{}), token)

  def phase(_context), do: :error

  @doc """
  Adds evidence `key` to the open phase a context names (the lock reads
  record the rows they locked; the request records the row it inserted).
  It never opens a phase: `{:error, :no_profile_switch_phase}` without one.
  """
  def record_evidence(context, key, value) do
    case phase(context) do
      {:ok, binding} ->
        put_phase(context.profile_switch.token, put_in(binding, [:evidence, key], value))
        :ok

      :error ->
        {:error, :no_profile_switch_phase}
    end
  end

  defp with_phase(phase, binding, fun)
       when phase in [:initialize, :transition, :resolve, :settle] do
    token = make_ref()

    binding =
      binding
      |> Map.take(@binding_keys)
      |> Map.merge(%{phase: phase, evidence: %{}})

    put_phase(token, binding)

    try do
      fun.(%{profile_switch: %{token: token}})
    after
      Process.put(@phases, Map.delete(Process.get(@phases, %{}), token))
    end
  end

  # `complete` only: its `:transition` phase moves to `:apply`, keeping the
  # lock evidence.
  defp advance(context) do
    case phase(context) do
      {:ok, %{phase: :transition, action: :complete} = binding} ->
        put_phase(context.profile_switch.token, %{binding | phase: :apply})
        context

      _other ->
        raise ArgumentError, "no open :transition phase of complete to advance"
    end
  end

  defp put_phase(token, binding),
    do: Process.put(@phases, Map.put(Process.get(@phases, %{}), token, binding))

  if @test_seams do
    @doc false
    # Test builds only (`:claude_cli_test_seams`): opens a phase directly so
    # the write guards can be exercised behind a genuine phase.
    def with_test_phase(phase, binding, fun), do: with_phase(phase, Map.new(binding), fun)

    @doc false
    def advance_test_phase(context), do: advance(context)
  end

  ## Shared

  defp admin(actor) do
    if CurrentAdmin.match?(actor, %{}, []), do: :ok, else: forbidden()
  end

  defp runtime(%SdrAgent.Actor{type: :model_runtime, tenant_id: tenant_id})
       when is_binary(tenant_id),
       do: :ok

  defp runtime(_actor), do: forbidden()

  defp forbidden, do: {:error, Ash.Error.Forbidden.exception([])}

  defp positive?(value), do: is_integer(value) and value >= 1

  defp invalid(field, message),
    do:
      {:error,
       Ash.Error.to_error_class(InvalidArgument.exception(field: field, message: message))}

  # One transaction per write; `fun` returns `{:ok, value}` to commit or
  # `{:error, error}` to roll everything back.
  defp transaction(fun) do
    fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, error} -> Repo.rollback(error)
      end
    end
    |> Audit.transaction()
    |> case do
      {:error, %Ash.Changeset{errors: errors}} -> {:error, Ash.Error.to_error_class(errors)}
      other -> other
    end
  end

  # Auditor attempts are refused and audited by the guard (S2 auditor
  # contract); other denials return Forbidden, as for lead assignment (an
  # actor naming a tenant without a chain has nowhere to append one).
  defp guard(action, subject_id, actor, fun) do
    Guard.run(
      %{resource: ModelProfileSwitch, action: action, subject_id: subject_id},
      actor,
      fun
    )
  end

  # The operator's current row, so the events carry the current role
  # (CurrentAdmin re-reads it again). A struct naming another tenant than
  # its stored row keeps that tenant, so the admin check refuses it.
  defp current_operator(%User{id: id, tenant_id: tenant_id} = user) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, %User{tenant_id: ^tenant_id} = fresh} -> fresh
      _ -> user
    end
  end

  defp current_operator(actor), do: actor

  defp tenant_scope(query, %{tenant_id: tenant_id}) when is_binary(tenant_id),
    do: Ash.Query.filter(query, tenant_id == ^tenant_id)

  defp tenant_scope(query, _actor), do: Ash.Query.filter(query, false)
end
