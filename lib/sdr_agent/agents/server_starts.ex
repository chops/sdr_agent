defmodule SdrAgent.Agents.ServerStarts do
  @moduledoc """
  The model server start allocator and lifecycle (C2-02b2α,
  `docs/product/r0/c2-02b2-interface.md` sections 1, 1a and 1b), behind the
  `SdrAgent.Agents` functions `allocate_server_start/2`,
  `mark_server_start/4` and `list_server_starts/1`, and the boot fence the
  switch finalizers take (`fence/4`).

  **Who may write.** Every write runs in the registered coordinator
  process as `model_runtime` (`SdrAgent.Agents.Checks.CoordinatorProcess`);
  any other caller is refused `Forbidden` before a transaction opens. Each
  write is one bounded call (`SdrAgent.Agents.LedgerCall`, `budget_ms:` at
  most 2 s; a spent bound is `{:error, :ledger_timeout}` and commits
  nothing).

  **Allocation** (lock order counter → switch → head): the tenant's
  counter is upserted and locked `FOR UPDATE`; in a new statement the
  latest start is read; the start is inserted at `last_generation + 1`
  (activation and rollback name their switch, whose FK takes `KEY SHARE`);
  the counter is bumped; the event is appended. A unique-generation
  violation is `{:error, :allocation_conflict}`.

  **Transitions** (counter `FOR SHARE` → latest start `FOR UPDATE` →
  head): the start must be the tenant's latest and of the caller's
  `boot_id`. `:started` from `:allocated`, recording the observed `pid`,
  `node` and `reaper_pid`; `:ready` from `:started` with the recorded
  `pid` and a `ready_evidence` (`:adopted` only on a replacement);
  `:failed` from `:allocated` or `:started`. A same-stage replay with the
  same facts returns the stored row and writes nothing; any other replay
  or backward move is refused.

  **Reads:** admin, auditor (audited), `agent_runtime`.
  """
  require Ash.Query

  alias Ash.Error.Changes.InvalidArgument
  alias SdrAgent.Accounts.User
  alias SdrAgent.Agents.Checks.CoordinatorProcess
  alias SdrAgent.Agents.LedgerCall
  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Agents.ModelServerCounter
  alias SdrAgent.Agents.ModelServerStart
  alias SdrAgent.Audit

  @switch_reasons [:activation, :rollback]
  @reasons [:boot, :replacement | @switch_reasons]
  @evidence [:spawn_preflight, :adopted]

  ## Reads

  @doc "ADM, AUD (audited), AGT: the tenant's starts, by generation."
  def list(opts) do
    actor = Keyword.get(opts, :actor)

    ModelServerStart
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> tenant_scope(actor)
    |> Ash.Query.sort(generation: :asc)
    |> Ash.read()
    |> audited(actor)
  end

  ## Allocation

  @doc """
  MRT, in the coordinator: allocates the tenant's next start —
  `%{boot_id, profile_id, reason, switch_id?}`.
  """
  def allocate(attrs, opts) do
    actor = Keyword.get(opts, :actor)
    attrs = Map.new(attrs)

    with :ok <- coordinator(actor),
         :ok <- allocation_input(attrs) do
      LedgerCall.run(&do_allocate(attrs, actor, &1), opts)
    end
  end

  defp allocation_input(%{reason: reason} = attrs) when reason in @reasons do
    case {reason in @switch_reasons, is_binary(Map.get(attrs, :switch_id))} do
      {true, true} -> :ok
      {false, false} -> :ok
      {true, false} -> invalid(:switch_id, "is required for #{reason}")
      {false, true} -> invalid(:switch_id, "must be absent for #{reason}")
    end
  end

  defp allocation_input(_attrs), do: invalid(:reason, "must be one of #{inspect(@reasons)}")

  defp do_allocate(attrs, actor, step) do
    with {:ok, _opened} <- open_counter(actor),
         :ok <- step.(),
         {:ok, counter} <- lock_counter(actor, :for_update),
         :ok <- step.(),
         :ok <- same_tenant_switch(attrs, actor),
         :ok <- step.() do
      insert(attrs, counter, actor, step)
    end
  end

  defp open_counter(actor) do
    ModelServerCounter
    |> Ash.Changeset.for_create(:open, %{}, actor: actor)
    |> Ash.create(return_skipped_upsert?: true)
  end

  # A switch named by an activation or rollback must be the tenant's.
  defp same_tenant_switch(%{switch_id: switch_id}, actor) when is_binary(switch_id) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Audit.Kernel.opts(actor.tenant_id))
    |> Ash.Query.filter(id == ^switch_id and tenant_id == ^actor.tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelProfileSwitch{}} -> :ok
      _missing -> invalid(:switch_id, "is not a switch of this tenant")
    end
  end

  defp same_tenant_switch(_attrs, _actor), do: :ok

  defp insert(attrs, counter, actor, step) do
    generation = counter.last_generation + 1

    result =
      ModelServerStart
      |> Ash.Changeset.for_create(
        :allocate,
        attrs
        |> Map.take([:boot_id, :profile_id, :reason, :switch_id])
        |> Map.put(:generation, generation),
        actor: actor
      )
      |> Ash.create()

    with {:ok, start} <- conflict(result),
         :ok <- step.(),
         {:ok, _counter} <- bump(counter, actor) do
      {:ok, start}
    end
  end

  defp conflict({:error, %Ash.Error.Invalid{errors: errors}} = error) do
    if Enum.any?(errors, &generation_conflict?/1),
      do: {:error, :allocation_conflict},
      else: error
  end

  defp conflict(result), do: result

  defp generation_conflict?(%{fields: fields}) when is_list(fields),
    do: :generation in fields or :tenant_id in fields

  defp generation_conflict?(_error), do: false

  defp bump(counter, actor) do
    counter
    |> Ash.Changeset.for_update(:bump, %{}, actor: actor)
    |> Ash.update()
  end

  ## Transitions

  @doc """
  MRT, in the coordinator: moves `start` to `status` (`:started`,
  `:ready` or `:failed`) — `%{boot_id}` plus, for `:started`, `pid`,
  `node`, `reaper_pid`; for `:ready`, `pid` and `ready_evidence`.
  """
  def mark(%ModelServerStart{id: start_id}, status, attrs, opts)
      when status in [:started, :ready, :failed] do
    actor = Keyword.get(opts, :actor)
    attrs = Map.new(attrs)

    with :ok <- coordinator(actor),
         :ok <- transition_input(status, attrs) do
      LedgerCall.run(&do_mark(start_id, status, attrs, actor, &1), opts)
    end
  end

  defp transition_input(:started, attrs) do
    if is_pid(attrs[:pid]) and is_atom(attrs[:node]) and not is_nil(attrs[:node]) and
         is_pid(attrs[:reaper_pid]),
       do: boot_input(attrs),
       else: invalid(:pid, "started needs the observed pid, node and reaper_pid")
  end

  defp transition_input(:ready, attrs) do
    if is_pid(attrs[:pid]) and attrs[:ready_evidence] in @evidence,
      do: boot_input(attrs),
      else: invalid(:ready_evidence, "ready needs the recorded pid and its evidence")
  end

  defp transition_input(:failed, attrs), do: boot_input(attrs)

  defp boot_input(%{boot_id: boot_id}) when is_binary(boot_id), do: :ok
  defp boot_input(_attrs), do: invalid(:boot_id, "is required")

  defp do_mark(start_id, status, attrs, actor, step) do
    with {:ok, latest} <- fenced_latest(start_id, attrs.boot_id, actor, step),
         :ok <- step.() do
      transition(latest, status, attrs, actor)
    end
  end

  # The boot fence of a transition (sections 1a, 1b): counter `FOR SHARE`,
  # then the latest start `FOR UPDATE`.
  defp fenced_latest(start_id, boot_id, actor, step) do
    with {:ok, counter} <- share_counter(actor),
         :ok <- step.() do
      fence(counter, start_id, boot_id, actor)
    end
  end

  @doc """
  The finalizers' first ledger lock, after the setting (section 1b): the
  tenant's counter `FOR SHARE`, in the caller's transaction.
  """
  def share_counter(actor), do: lock_counter(actor, :for_share)

  @doc """
  The stored fence, after `share_counter/1` (section 1a): reads the
  tenant's latest start `FOR UPDATE` and returns it only if it is
  `start_id` and of `boot_id`.
  """
  def fence(counter, start_id, boot_id, actor) do
    with {:ok, latest} <- lock_latest(counter, actor) do
      if latest.id == start_id and latest.boot_id == boot_id,
        do: {:ok, latest},
        else: invalid(:start_id, "is not the latest start of this boot")
    end
  end

  defp transition(%{status: :allocated} = start, :started, attrs, actor) do
    update(start, :mark_started, observed(attrs), actor)
  end

  defp transition(%{status: :started} = start, :started, attrs, _actor) do
    if start.pid == inspect(attrs.pid),
      do: {:ok, start},
      else: invalid(:pid, "the start is already started by another server")
  end

  defp transition(%{status: :started} = start, :ready, attrs, actor) do
    cond do
      start.pid != inspect(attrs.pid) ->
        invalid(:pid, "is not the recorded server")

      attrs.ready_evidence == :adopted and start.reason != :replacement ->
        invalid(:ready_evidence, "adopted is only for a replacement")

      true ->
        update(start, :mark_ready, %{ready_evidence: attrs.ready_evidence}, actor)
    end
  end

  defp transition(%{status: :ready} = start, :ready, attrs, _actor) do
    if start.pid == inspect(attrs.pid) and start.ready_evidence == attrs.ready_evidence,
      do: {:ok, start},
      else: invalid(:ready_evidence, "a replay cannot change the stored facts")
  end

  defp transition(%{status: status} = start, :failed, _attrs, actor)
       when status in [:allocated, :started],
       do: update(start, :mark_failed, %{}, actor)

  defp transition(%{status: :failed} = start, :failed, _attrs, _actor), do: {:ok, start}

  defp transition(%{status: from}, to, _attrs, _actor),
    do: invalid(:status, "cannot move from #{from} to #{to}")

  defp observed(attrs),
    do: %{
      pid: inspect(attrs.pid),
      node: Atom.to_string(attrs.node),
      reaper_pid: inspect(attrs.reaper_pid)
    }

  defp update(start, action, args, actor) do
    start
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update()
  end

  ## Locks

  defp lock_counter(actor, mode) do
    ModelServerCounter
    |> Ash.Query.for_read(:lock, %{}, actor: actor)
    |> Ash.Query.lock(lock_mode(mode))
    |> Ash.read_one()
    |> case do
      {:ok, %ModelServerCounter{} = counter} -> {:ok, counter}
      {:ok, nil} -> invalid(:start_id, "the tenant has no server start")
      error -> error
    end
  end

  defp lock_mode(:for_update), do: :for_update
  defp lock_mode(:for_share), do: "FOR SHARE"

  defp lock_latest(counter, actor) do
    ModelServerStart
    |> Ash.Query.for_read(:latest, %{generation: counter.last_generation}, actor: actor)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelServerStart{} = start} -> {:ok, start}
      {:ok, nil} -> invalid(:start_id, "the tenant has no server start")
      error -> error
    end
  end

  ## Shared

  defp coordinator(%SdrAgent.Actor{type: :model_runtime, tenant_id: tenant})
       when is_binary(tenant) do
    if CoordinatorProcess.coordinator?(), do: :ok, else: forbidden()
  end

  defp coordinator(_actor), do: forbidden()

  defp forbidden, do: {:error, Ash.Error.Forbidden.exception([])}

  defp invalid(field, message),
    do:
      {:error,
       Ash.Error.to_error_class(InvalidArgument.exception(field: field, message: message))}

  defp audited({:ok, starts}, %User{role: :auditor} = actor) do
    ref = if starts == [], do: "none", else: Enum.map_join(starts, ",", & &1.id)

    case Audit.record_access(:record_view, inspect(ModelServerStart), ref, "model server starts",
           actor: actor
         ) do
      {:ok, _access} -> {:ok, starts}
      {:error, error} -> {:error, error}
    end
  end

  defp audited(result, _actor), do: result

  defp tenant_scope(query, %{tenant_id: tenant_id}) when is_binary(tenant_id),
    do: Ash.Query.filter(query, tenant_id == ^tenant_id)

  defp tenant_scope(query, _actor), do: Ash.Query.filter(query, false)
end
