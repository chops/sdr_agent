defmodule SdrAgent.AI.ModelProvider.Coordinator do
  @moduledoc """
  The owner of the model server lifecycle (C2-02b2α,
  `docs/product/r0/c2-02b2-interface.md` sections 1a, 2, 2a and 3; ADR-0004
  C2-02b2 amendment, accepted 2026-10-15).

  **Ownership.** The coordinator is the only process that starts, stops or
  replaces the named ClaudeCLI server, always as a `:temporary` child of
  `SdrAgent.AI.ModelProvider.ServerSupervisor`, and the only writer of the
  b2 ledger (`SdrAgent.Agents.ServerStarts`, and the switch's `complete`,
  `fail` and `block`), each write one bounded call in this process. Every
  start is allocated first, and every server is started **held**: it
  refuses newly dequeued calls until a fresh reconciled read releases it.

  **Boot** (a new `boot_id` per process start): a surviving server child is
  re-held (acknowledged; `hold: :pending` until then) and adopted under a
  new `:replacement` start (`:adopted` evidence); otherwise a `:boot` start
  runs the setting's desired profile (the default before any setting). A
  switch still pending at boot is blocked (`coordinator_restarted`) and the
  server stays held; otherwise the reconciled read releases it.

  **A switch** (`request_switch/2`): hold → the worker drains (b1, as
  `agent_runtime`) → veto (unconfirmed CLI work blocks) → the reaper's
  receipt is subscribed, then the old server stopped and its correlated
  receipt awaited (`cleanup_wait_ms`, at most 10 s; a reaper `DOWN` without
  the receipt, an absent lease or the bound blocks) → the candidate is
  allocated and started held → the worker's no-call preflight → `ready` →
  `complete` → the reconciled read releases it. A failed preflight stops the
  candidate the same way, starts a held `:rollback` at the old profile and
  `fail`s the switch. A worker death blocks (`operation_died`). An
  uncertain finalization (a spent bound, a lost reply) issues nothing else
  before the reconciled read; an unreadable read keeps the server held.

  **Status** (`status/0`) is published in a protected ETS table and never
  waits on this process: `%{boot_id, generation, profile_id, hold: :held |
  :released | :pending, stage, switch_id}`; it never holds a raw ref.

  **Stages** are observed through `[:sdr_agent, :model_coordinator,
  :stage]` telemetry (`%{stage:, switch_id:}`): the worker emits `:drained`
  and `:preflighted`, the coordinator `:old_stopping` and `:finalizing`.

  Options: `server:` (`fn profile_id -> ClaudeCLI options end`),
  `cleanup_wait_ms:`; test builds only: `manual: true` (allocates and
  starts nothing), `faults:` (`lose_reply: [:complete]`, `reconcile: fn ->
  :read | :unavailable end`) and the `test_run/2` seam.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelProfileSetting
  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Agents.ModelServerStart
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.Audit.Kernel

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @server_supervisor SdrAgent.AI.ModelProvider.ServerSupervisor
  @operation_supervisor SdrAgent.AI.ModelProvider.OperationSupervisor
  @table __MODULE__
  @stage [:sdr_agent, :model_coordinator, :stage]
  @max_cleanup_wait_ms 10_000
  @hold_attempt_ms 200
  @retry_ms 200
  @lease_poll_ms 50
  @receipt_grace_ms 100
  @drain_timeout_ms 30_000
  @replace_retry_ms 1_000

  ## API

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The published status, read from the coordinator's ETS table without
  waiting on it; nil when no coordinator runs.
  """
  def status do
    case :ets.lookup(@table, :status) do
      [{:status, status}] -> status
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  ADM: requests a switch to `%{to_profile_id, expected_revision}` at the
  current server's generation (`SdrAgent.Agents.request_profile_switch/2`,
  as the caller), then hands it to the coordinator.
  """
  def request_switch(attrs, opts) do
    case status() do
      %{generation: generation} when is_integer(generation) ->
        attrs = attrs |> Map.new() |> Map.put(:server_generation, generation)

        with {:ok, switch} <- Agents.request_profile_switch(attrs, opts) do
          GenServer.cast(__MODULE__, {:switch_requested, switch.id})
          {:ok, switch}
        end

      _not_ready ->
        {:error, :coordinator_not_ready}
    end
  end

  if @test_seams do
    @doc false
    # Test builds only: runs `fun.(binding)` in the coordinator process.
    def test_run(fun, timeout) when is_function(fun, 1),
      do: GenServer.call(__MODULE__, {:test_run, fun}, timeout)
  end

  ## Init

  @impl true
  def init(opts) do
    opts = checked(opts)
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    state = %{
      boot_id: Ecto.UUID.generate(),
      server_fun: Keyword.get(opts, :server, &SdrAgent.AI.ModelProvider.Runtime.server_options/1),
      cleanup_wait_ms:
        min(Keyword.get(opts, :cleanup_wait_ms, @max_cleanup_wait_ms), @max_cleanup_wait_ms),
      faults: Keyword.get(opts, :faults, []),
      tenant_id: nil,
      start: nil,
      server: nil,
      server_ref: nil,
      hold: nil,
      hold_state: :pending,
      op: nil,
      reconcile: nil
    }

    publish(state)

    if Keyword.get(opts, :manual, false),
      do: {:ok, state},
      else: {:ok, state, {:continue, :boot}}
  end

  # `manual:` and `faults:` exist only in test builds.
  if @test_seams do
    defp checked(opts), do: opts
  else
    defp checked(opts) do
      if Keyword.has_key?(opts, :manual) or Keyword.has_key?(opts, :faults),
        do: raise(ArgumentError, "manual: and faults: exist only in test builds"),
        else: opts
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} when is_binary(tenant_id) ->
        {:noreply, boot(%{state | tenant_id: tenant_id})}

      _none ->
        Process.send_after(self(), :boot, 1_000)
        {:noreply, state}
    end
  end

  defp boot(state) do
    result =
      case live_server() do
        pid when is_pid(pid) -> adopt(state, pid)
        nil -> start_new(state, :boot, boot_profile(state), nil)
      end

    case result do
      {:ok, state} -> after_boot(state)
      {:error, state} -> retry_replacement(state)
    end
  end

  # No server is running and none is switching: a held replacement is
  # retried (a server can die even before its init returns).
  defp retry_replacement(%{server: nil, op: nil} = state) do
    Process.send_after(self(), :replace, @replace_retry_ms)
    state
  end

  defp retry_replacement(state), do: state

  defp after_boot(state) do
    case pending_switch(state) do
      %ModelProfileSwitch{} = switch ->
        block(state, switch, "coordinator_restarted")

      nil ->
        reconcile(state, :boot)
    end
  end

  defp live_server do
    with pid when is_pid(pid) <- Process.whereis(ClaudeCLI.server()),
         true <- child?(pid) do
      pid
    else
      _ -> nil
    end
  end

  defp child?(pid) do
    @server_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.any?(fn {_id, child, _type, _modules} -> child == pid end)
  catch
    :exit, _ -> false
  end

  defp boot_profile(state) do
    ModelProfileSetting
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelProfileSetting{desired_profile_id: profile}} -> profile
      _none -> ModelProfiles.default_real()
    end
  end

  ## Adoption and starts

  # Re-holds the surviving server (acknowledged, in its mailbox order behind
  # any in-flight call), then records it under a new replacement start.
  defp adopt(state, pid) do
    ref = make_ref()

    state = %{
      state
      | server: pid,
        server_ref: Process.monitor(pid),
        hold: ref,
        hold_state: :pending
    }

    publish(state)
    hold!(pid, ref)
    state = %{state | hold_state: :held}
    profile = ClaudeCLI.profile(pid)

    with {:ok, start} <- allocate(state, :replacement, profile, nil),
         state = bind(state, start),
         {:ok, start} <- mark(state, start, :started, observed(pid)),
         {:ok, start} <- mark(state, start, :ready, %{pid: pid, ready_evidence: :adopted}) do
      {:ok, bind(state, start)}
    else
      _error -> {:error, publish(state)}
    end
  end

  defp hold!(pid, ref) do
    case ClaudeCLI.hold(pid, ref, @hold_attempt_ms) do
      {:held, ^ref} -> :ok
      {:error, :timeout} -> hold!(pid, ref)
      {:error, :not_running} -> :ok
    end
  end

  # Allocates, starts the server held, records it, and runs the no-call
  # preflight (boot and replacement); a switch's candidate and rollback are
  # preflighted by the worker instead (`preflight: false`).
  defp start_new(state, reason, profile, switch, opts \\ []) do
    with {:ok, start} <- allocate(state, reason, profile, switch),
         state = bind(state, start),
         {:ok, state} <- spawn_server(state, start) do
      if Keyword.get(opts, :preflight, true),
        do: preflighted_ready(state),
        else: {:ok, state}
    else
      {:error, %{boot_id: _} = state} -> {:error, state}
      _error -> {:error, publish(state)}
    end
  end

  defp spawn_server(state, start) do
    ref = make_ref()

    options =
      start.profile_id
      |> state.server_fun.()
      |> Keyword.merge(name: ClaudeCLI.server(), profile: start.profile_id, hold: ref)

    spec = Supervisor.child_spec({ClaudeCLI, options}, restart: :temporary)

    case DynamicSupervisor.start_child(@server_supervisor, spec) do
      {:ok, pid} ->
        state = %{
          state
          | server: pid,
            server_ref: Process.monitor(pid),
            hold: ref,
            hold_state: :held
        }

        case mark(state, start, :started, observed(pid)) do
          {:ok, start} -> {:ok, publish(bind(state, start))}
          _error -> {:error, publish(state)}
        end

      {:error, reason} ->
        Logger.error("model server start failed: #{inspect(reason)}")
        _ = mark(state, start, :failed, %{})
        {:error, publish(state)}
    end
  end

  defp preflighted_ready(state) do
    if preflight(state.server, state.start.profile_id) == :ok do
      ready(state)
    else
      Logger.error("model server preflight failed; calls stay held")
      _ = mark(state, state.start, :failed, %{})
      {:error, publish(state)}
    end
  end

  defp ready(state) do
    case mark(state, state.start, :ready, %{pid: state.server, ready_evidence: :spawn_preflight}) do
      {:ok, start} -> {:ok, publish(bind(state, start))}
      _error -> {:error, publish(state)}
    end
  end

  @doc false
  # The no-call preflight: the pinned binary (or a test build's launcher),
  # the server's own profile, open admission and the shim. Never a model
  # call; the attestation stays as it is.
  def preflight(pid, profile) do
    attestation = ClaudeCLI.attestation(pid)

    cond do
      ClaudeCLI.profile(pid) != profile ->
        {:error, :profile_mismatch}

      ClaudeCLI.admission(pid).admission != :open ->
        {:error, :admission_closed}

      attestation[:command?] != true ->
        {:error, :shim_not_found}

      not (attestation[:executable?] == true or attestation[:test_launcher?] == true) ->
        {:error, :pin}

      true ->
        :ok
    end
  end

  defp observed(pid), do: %{pid: pid, node: node(), reaper_pid: ClaudeCLI.reaper(pid)}

  ## Reconciliation and release

  # A fresh read of the stored outcome before any release (section 2a).
  defp reconcile(state, expected) do
    case readable(state, expected) do
      :read -> release_if_reconciled(state, expected)
      :unavailable -> retry_reconcile(state, expected)
    end
  end

  # The test-build `reconcile:` fault gates only a switch's reconciliation,
  # never the boot release.
  defp readable(state, {:switch, _id, _status}) do
    case Keyword.get(state.faults, :reconcile) do
      fun when is_function(fun, 0) -> fun.()
      nil -> :read
    end
  end

  defp readable(_state, :boot), do: :read

  defp retry_reconcile(state, expected) do
    Process.send_after(self(), {:reconcile, expected}, @retry_ms)
    publish(%{state | reconcile: expected})
  end

  defp release_if_reconciled(state, expected) do
    with {:ok, latest} <- latest_start(state),
         true <- latest.id == state.start.id and latest.status == :ready,
         true <- outcome_stored?(state, expected) do
      release(state)
    else
      _not_reconciled -> publish(%{state | reconcile: nil})
    end
  end

  defp outcome_stored?(state, :boot), do: pending_switch(state) == nil
  defp outcome_stored?(state, {:switch, id, status}), do: switch_status(state, id) == status

  defp release(%{server: pid, hold: ref} = state) when is_pid(pid) and is_reference(ref) do
    case ClaudeCLI.release_hold(pid, ref) do
      :ok -> publish(%{state | hold: nil, hold_state: :released, reconcile: nil})
      _error -> publish(%{state | reconcile: nil})
    end
  end

  defp release(state), do: publish(state)

  ## The switch

  @impl true
  def handle_cast({:switch_requested, switch_id}, %{op: nil, start: %{}} = state) do
    case switch(state, switch_id) do
      %ModelProfileSwitch{status: :pending} = switch -> {:noreply, begin_switch(state, switch)}
      _other -> {:noreply, state}
    end
  end

  def handle_cast({:switch_requested, _switch_id}, state), do: {:noreply, state}

  defp begin_switch(state, switch) do
    state = rehold(state)
    token = make_ref()
    coordinator = self()
    agent = SdrAgent.Actor.system(:agent_runtime, state.tenant_id)

    {:ok, worker} =
      Task.Supervisor.start_child(@operation_supervisor, fn ->
        worker(coordinator, token, switch, agent)
      end)

    op = %{
      switch: switch,
      token: token,
      worker: worker,
      worker_ref: Process.monitor(worker),
      stage: :draining,
      from: switch.from_profile_id,
      to: switch.to_profile_id,
      continue: nil,
      receipt: nil
    }

    publish(%{state | op: op})
  end

  # A new hold of the current server for the switch (acknowledged).
  defp rehold(%{server: pid, hold: nil} = state) when is_pid(pid) do
    ref = make_ref()
    hold!(pid, ref)
    publish(%{state | hold: ref, hold_state: :held})
  end

  defp rehold(state), do: state

  @impl true
  def handle_info({:op, token, message}, %{op: %{token: token}} = state),
    do: {:noreply, step(state, message)}

  def handle_info({:op, _token, _message}, state), do: {:noreply, state}

  def handle_info(
        {:reaper_cleanup_confirmed, ref, _meta},
        %{op: %{receipt: %{ref: ref}}} = state
      ),
      do: {:noreply, cleaned(state)}

  # A forged, stale or duplicate receipt never counts.
  def handle_info({:reaper_cleanup_confirmed, _ref, _meta}, state), do: {:noreply, state}

  def handle_info({:lease_check, ref}, %{op: %{receipt: %{ref: ref}}} = state),
    do: {:noreply, lease_check(state)}

  def handle_info({:cleanup_timeout, ref}, %{op: %{receipt: %{ref: ref}}} = state),
    do: {:noreply, unconfirmed(state)}

  def handle_info(
        {:DOWN, mref, :process, _reaper, _reason},
        %{op: %{receipt: %{monitor: mref}}} = state
      ),
      do: {:noreply, unconfirmed(state)}

  def handle_info({:DOWN, mref, :process, _worker, reason}, %{op: %{worker_ref: mref}} = state) do
    if reason == :normal,
      do: {:noreply, state},
      else:
        {:noreply,
         block(%{state | op: %{state.op | worker: nil}}, state.op.switch, "operation_died")}
  end

  def handle_info({:DOWN, mref, :process, _server, _reason}, %{server_ref: mref} = state),
    do: {:noreply, server_down(state)}

  def handle_info({:reconcile, expected}, %{reconcile: expected} = state),
    do: {:noreply, reconcile(state, expected)}

  def handle_info(:boot, state), do: {:noreply, state, {:continue, :boot}}

  def handle_info(:replace, %{server: nil, op: nil, start: %{}} = state),
    do: {:noreply, server_down(state)}

  def handle_info(_message, state), do: {:noreply, state}

  if @test_seams do
    @impl true
    def handle_call({:test_run, fun}, _from, state),
      do: {:reply, fun.(%{boot_id: state.boot_id}), state}
  end

  # The worker's results drive the switch, one stage at a time.
  defp step(state, {:drained, {:ok, _refused}}) do
    if ClaudeCLI.admission(state.server).admission == :open,
      do: stop_server(state, :candidate),
      else: block(state, state.op.switch, "old_cli_not_quiescent")
  end

  defp step(state, {:drained, _error}), do: block(state, state.op.switch, "drain_failed")

  defp step(%{op: %{stage: :candidate_preflight}} = state, {:preflighted, :ok}) do
    case ready(state) do
      {:ok, state} -> finalize(state, :complete)
      {:error, state} -> block(state, state.op.switch, "candidate_not_ready")
    end
  end

  defp step(%{op: %{stage: :candidate_preflight}} = state, {:preflighted, _error}) do
    _ = mark(state, state.start, :failed, %{})
    stop_server(state, :rollback)
  end

  defp step(%{op: %{stage: :rollback_preflight}} = state, {:preflighted, :ok}) do
    case ready(state) do
      {:ok, state} -> finalize(state, :fail)
      {:error, state} -> block(state, state.op.switch, "rollback_not_ready")
    end
  end

  defp step(%{op: %{stage: :rollback_preflight}} = state, {:preflighted, _error}) do
    _ = mark(state, state.start, :failed, %{})
    block(state, state.op.switch, "rollback_preflight_failed")
  end

  defp step(state, _message), do: state

  # Subscribe (acknowledged) → stop → await the correlated receipt.
  defp stop_server(state, continue) do
    reaper = ClaudeCLI.reaper(state.server)
    ref = make_ref()

    case is_pid(reaper) and Reaper.subscribe(reaper, ref) do
      {:subscribed, ^ref} ->
        receipt = %{
          ref: ref,
          reaper: reaper,
          monitor: Process.monitor(reaper),
          name: ClaudeCLI.server()
        }

        state =
          publish(%{
            state
            | op: %{state.op | stage: :old_stopping, continue: continue, receipt: receipt}
          })

        emit(:old_stopping, state)
        Process.demonitor(state.server_ref, [:flush])
        _ = DynamicSupervisor.terminate_child(@server_supervisor, state.server)
        Process.send_after(self(), {:cleanup_timeout, ref}, state.cleanup_wait_ms)
        Process.send_after(self(), {:lease_check, ref}, @lease_poll_ms)
        %{state | server: nil, server_ref: nil, hold: nil}

      _not_subscribed ->
        block(state, state.op.switch, "old_cleanup_unconfirmed")
    end
  end

  # An absent lease, or one held by a dead reaper, without the receipt is
  # unconfirmed; the receipt (sent right after the reaper's own release) gets
  # a short grace to arrive.
  defp lease_check(%{op: %{receipt: receipt}} = state) do
    case Reaper.lease(receipt.name) do
      {:held, holder} when holder == receipt.reaper ->
        if Process.alive?(holder) do
          Process.send_after(self(), {:lease_check, receipt.ref}, @lease_poll_ms)
          state
        else
          await_receipt(state)
        end

      _absent_or_foreign ->
        await_receipt(state)
    end
  end

  defp await_receipt(%{op: %{receipt: %{ref: ref, monitor: monitor}}} = state) do
    receive do
      {:reaper_cleanup_confirmed, ^ref, _meta} -> cleaned(state)
      {:DOWN, ^monitor, :process, _reaper, _reason} -> unconfirmed(state)
    after
      @receipt_grace_ms -> unconfirmed(state)
    end
  end

  defp cleaned(%{op: %{receipt: receipt}} = state) do
    Process.demonitor(receipt.monitor, [:flush])
    state = %{state | op: %{state.op | receipt: nil}}

    case state.op.continue do
      :candidate -> start_switch_server(state, :activation, state.op.to, :candidate_preflight)
      :rollback -> start_switch_server(state, :rollback, state.op.from, :rollback_preflight)
    end
  end

  defp unconfirmed(%{op: %{receipt: receipt}} = state) do
    Process.demonitor(receipt.monitor, [:flush])
    block(%{state | op: %{state.op | receipt: nil}}, state.op.switch, "old_cleanup_unconfirmed")
  end

  defp start_switch_server(state, reason, profile, stage) do
    case start_new(state, reason, profile, state.op.switch.id, preflight: false) do
      {:ok, state} ->
        send(state.op.worker, {:preflight, state.op.token, state.server, profile})
        publish(%{state | op: %{state.op | stage: stage}})

      {:error, state} ->
        block(state, state.op.switch, "#{reason}_start_failed")
    end
  end

  defp finalize(state, action) do
    emit(:finalizing, state)
    switch = state.op.switch

    attrs = %{
      server_generation: switch.server_generation,
      boot_id: state.boot_id,
      start_id: state.start.id
    }

    result = finalizer(action).(switch, attrs, actor: actor(state))
    expected = {:switch, switch.id, Map.fetch!(%{complete: :completed, fail: :failed}, action)}

    case {result, action in Keyword.get(state.faults, :lose_reply, [])} do
      {{:ok, _switch}, false} -> finish(state, expected)
      _uncertain -> uncertain(state, switch, expected)
    end
  end

  defp finalizer(:complete), do: &Agents.complete_profile_switch/3
  defp finalizer(:fail), do: &Agents.fail_profile_switch/3

  # No other action before the reconciled read (section 1a).
  defp uncertain(state, switch, expected) do
    case readable(state, expected) do
      :read ->
        case switch_status(state, switch.id) do
          :pending -> block(state, switch, "finalization_uncertain")
          _stored -> finish(state, expected)
        end

      :unavailable ->
        finish_later(state, expected)
    end
  end

  defp finish(state, expected) do
    state = end_op(state)
    reconcile(state, expected)
  end

  defp finish_later(state, expected), do: retry_reconcile(end_op(state), expected)

  defp end_op(%{op: %{worker: worker, worker_ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    if is_pid(worker), do: send(worker, :done)
    publish(%{state | op: nil})
  end

  defp end_op(state), do: state

  # Blocks S under this boot's latest start; the server stays held.
  defp block(%{start: %{id: start_id}} = state, switch, reason) do
    attrs = %{
      server_generation: switch.server_generation,
      boot_id: state.boot_id,
      start_id: start_id,
      failure_reason: reason
    }

    Logger.warning("model profile switch #{switch.id} blocked: #{reason}")

    case Agents.block_profile_switch(switch, attrs, actor: actor(state)) do
      {:ok, _blocked} -> :ok
      error -> Logger.error("model profile switch block failed: #{inspect(error)}")
    end

    end_op(state)
  end

  defp block(state, _switch, _reason), do: end_op(state)

  # An unexpected server death outside a switch: a held replacement.
  defp server_down(%{op: nil} = state) do
    state = publish(%{state | server: nil, server_ref: nil, hold: nil, hold_state: :pending})

    case start_new(state, :replacement, state.start.profile_id, nil) do
      {:ok, state} -> reconcile(state, :boot)
      {:error, state} -> retry_replacement(state)
    end
  end

  defp server_down(state), do: %{state | server: nil, server_ref: nil}

  ## The worker (no ledger writes: the drain, then the preflight checks)

  defp worker(coordinator, token, switch, agent) do
    result =
      Agents.drain_profile_switch(
        switch,
        %{server_generation: switch.server_generation, timeout_ms: @drain_timeout_ms},
        actor: agent
      )

    emit(:drained, switch.id)
    send(coordinator, {:op, token, {:drained, drained(result)}})
    worker_loop(coordinator, token, switch)
  end

  defp drained({:ok, counts}), do: {:ok, counts}
  defp drained(_error), do: :error

  defp worker_loop(coordinator, token, switch) do
    receive do
      {:preflight, ^token, pid, profile} ->
        result = preflight(pid, profile)
        emit(:preflighted, switch.id)
        send(coordinator, {:op, token, {:preflighted, result}})
        worker_loop(coordinator, token, switch)

      :done ->
        :ok
    end
  end

  ## Ledger calls and reads

  defp actor(state), do: SdrAgent.Actor.system(:model_runtime, state.tenant_id)

  defp allocate(state, reason, profile, switch_id) do
    attrs =
      %{boot_id: state.boot_id, profile_id: profile, reason: reason}
      |> then(&if(switch_id, do: Map.put(&1, :switch_id, switch_id), else: &1))

    Agents.allocate_server_start(attrs, actor: actor(state))
  end

  defp mark(state, start, status, attrs),
    do:
      Agents.mark_server_start(start, status, Map.put(attrs, :boot_id, state.boot_id),
        actor: actor(state)
      )

  defp bind(state, %ModelServerStart{} = start), do: publish(%{state | start: start})

  defp latest_start(state) do
    ModelServerStart
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id)
    |> Ash.Query.sort(generation: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
  end

  defp pending_switch(state) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id and status == :pending)
    |> Ash.read_one()
    |> case do
      {:ok, switch} -> switch
      _error -> nil
    end
  end

  defp switch(state, id) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id and id == ^id)
    |> Ash.read_one()
    |> case do
      {:ok, switch} -> switch
      _error -> nil
    end
  end

  defp switch_status(state, id) do
    case switch(state, id) do
      %ModelProfileSwitch{status: status} -> status
      nil -> nil
    end
  end

  ## Status and stages

  defp publish(state) do
    status = %{
      boot_id: state.boot_id,
      generation: state.start && state.start.generation,
      profile_id: state.start && state.start.profile_id,
      hold: state.hold_state,
      stage: state.op && state.op.stage,
      switch_id: state.op && state.op.switch.id
    }

    :ets.insert(@table, {:status, status})
    state
  end

  defp emit(stage, %{op: %{switch: switch}}), do: emit(stage, switch.id)

  defp emit(stage, switch_id),
    do: :telemetry.execute(@stage, %{}, %{stage: stage, switch_id: switch_id})
end
