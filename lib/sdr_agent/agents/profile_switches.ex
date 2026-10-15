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

  Reads are scoped to the actor's tenant; an auditor's read appends a
  `record_view` AuditAccess first (fail closed). `model_runtime` has no
  read here.
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
  alias SdrAgent.Agents.ServerStarts
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Guard
  alias SdrAgent.Repo

  @results %{complete: :completed, fail: :failed, block: :blocked}
  # The open phases of this process, by token (see "Phases" below).
  @phases {__MODULE__, :phases}
  @binding_keys [:action, :tenant_id, :switch_id, :server_generation, :actor]
  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

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
      case decide(action, switch.status) do
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

  defp decide(action, status) do
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

  defp with_phase(phase, binding, fun) when phase in [:initialize, :transition] do
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
