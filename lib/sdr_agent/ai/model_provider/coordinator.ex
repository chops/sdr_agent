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
  @hold_bound_ms 15_000

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
      spawned: nil,
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
    # Re-held before any database observation, the tenant read included.
    state = rehold_survivor(state)

    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} when is_binary(tenant_id) ->
        {:noreply, boot(%{state | tenant_id: tenant_id})}

      _none ->
        {:noreply, retry_boot(state)}
    end
  end

  # Section 2: re-hold a survivor first, then one fresh read of the switch
  # state and the desired profile, then this boot's first start, then by
  # case. Any unknown read or failed allocation keeps everything held and
  # retries the boot.
  defp boot(state) do
    with {:ok, open} <- open_switch(state),
         {:ok, desired} <- desired_profile(state),
         {:ok, state} <- first_start(state, desired) do
      after_boot(state, open)
    else
      # Fail closed, no retry: this boot's own server failed its preflight,
      # or a named server runs outside the supervisor.
      {:held, %{boot_id: _} = state} -> publish(state)
      {:error, %{boot_id: _} = state} -> retry_boot(state)
      _unknown -> retry_boot(state)
    end
  end

  defp retry_boot(state) do
    Process.send_after(self(), :boot, @replace_retry_ms)
    publish(state)
  end

  defp after_boot(state, %ModelProfileSwitch{status: :pending} = switch),
    do: block(state, switch, "coordinator_restarted")

  # A blocked switch keeps the server held (section 2a); no release.
  defp after_boot(state, %ModelProfileSwitch{status: :blocked}), do: publish(state)
  defp after_boot(state, nil), do: reconcile(state, :boot)

  # A surviving named child is re-held before any database work, so no
  # startup uncertainty leaves it callable.
  defp rehold_survivor(state) do
    case named_server() do
      pid when is_pid(pid) ->
        ref = if state.server == pid and state.hold, do: state.hold, else: make_ref()
        monitor = if state.server == pid, do: state.server_ref, else: Process.monitor(pid)
        state = publish(%{state | server: pid, server_ref: monitor, hold: ref})

        case hold(pid, ref) do
          :held -> publish(%{state | hold_state: :held})
          _pending -> publish(%{state | hold_state: :pending})
        end

      nil ->
        state
    end
  end

  # The first start: adopt a survivor that meets the adoption conditions;
  # stop one that doesn't (bounded receipt protocol) and start fresh; start
  # the desired profile when none runs.
  defp first_start(%{server: pid, hold_state: :held} = state, desired) when is_pid(pid) do
    cond do
      # This boot's own server (a retried boot): never laundered into an
      # adoption; it stays held and failed.
      pid == state.spawned ->
        {:held, state}

      not child?(pid) ->
        Logger.error("a named ClaudeCLI server runs outside the model server supervisor; held")
        {:held, state}

      adoptable?(pid, desired) ->
        adopt(state, pid, desired)

      true ->
        replace_survivor(state, pid, desired)
    end
  end

  defp first_start(%{server: pid} = state, _desired) when is_pid(pid), do: {:error, state}
  defp first_start(state, desired), do: start_new(state, :boot, desired, nil)

  # The exact supervised child, at the desired profile, whose own live
  # reaper holds the named lease.
  defp adoptable?(pid, desired) do
    reaper = ClaudeCLI.reaper(pid)

    child?(pid) and ClaudeCLI.profile(pid) == desired and is_pid(reaper) and
      Process.alive?(reaper) and Reaper.lease(ClaudeCLI.server()) == {:held, reaper}
  end

  defp replace_survivor(state, pid, desired) do
    case stop_and_confirm(state, pid, nil) do
      :confirmed ->
        state = %{state | server: nil, server_ref: nil, hold: nil}
        start_new(state, :replacement, desired, nil)

      :unconfirmed ->
        # Its cleanup is unknown: nothing is started over it; the record
        # stays held and failed until an operator acts.
        state = %{state | server: nil, server_ref: nil, hold: nil, hold_state: :held}

        with {:ok, start} <- allocate(state, :replacement, desired, nil),
             state = bind(state, start),
             {:ok, start} <- mark(state, start, :failed, %{}) do
          {:ok, publish(bind(state, start))}
        else
          _error -> {:error, publish(state)}
        end
    end
  end

  # The registered named server, managed or not (absent is nil).
  defp named_server do
    case Process.whereis(ClaudeCLI.server()) do
      pid when is_pid(pid) -> pid
      nil -> nil
    end
  end

  defp child?(pid) do
    @server_supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.any?(fn {_id, child, _type, _modules} -> child == pid end)
  catch
    :exit, _ -> false
  end

  # The setting's desired profile, or the default when none exists; an
  # unreadable answer is unknown, never the default.
  defp desired_profile(state) do
    ModelProfileSetting
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelProfileSetting{desired_profile_id: profile}} -> {:ok, profile}
      {:ok, nil} -> {:ok, ModelProfiles.default_real()}
      _error -> :error
    end
  end

  ## Adoption and starts

  # Records the re-held survivor under a new replacement start (`:adopted`).
  defp adopt(state, pid, profile) do
    with {:ok, start} <- allocate(state, :replacement, profile, nil),
         state = bind(state, start),
         {:ok, start} <- mark(state, start, :started, observed(pid)),
         {:ok, start} <- mark(state, start, :ready, %{pid: pid, ready_evidence: :adopted}) do
      {:ok, bind(state, start)}
    else
      _error -> {:error, publish(state)}
    end
  end

  # An acknowledged hold, bounded overall: `:held`, `:timeout` (still
  # pending; the request stays queued in the server's mailbox) or
  # `:not_running` (not an acknowledgement).
  defp hold(pid, ref, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @hold_bound_ms
    wait = min(@hold_attempt_ms, max(deadline - System.monotonic_time(:millisecond), 0))

    case ClaudeCLI.hold(pid, ref, max(wait, 1)) do
      {:held, ^ref} ->
        :held

      {:error, :timeout} ->
        if System.monotonic_time(:millisecond) < deadline,
          do: hold(pid, ref, deadline),
          else: :timeout

      {:error, :not_running} ->
        :not_running
    end
  end

  # Allocates, starts the server held, records it, and runs the no-call
  # preflight (boot and replacement); a switch's candidate and rollback are
  # preflighted by the worker instead (`preflight: false`). A server that
  # never started is `{:not_started, state}`.
  defp start_new(state, reason, profile, switch, opts \\ []) do
    with {:ok, start} <- allocate(state, reason, profile, switch),
         state = bind(state, start),
         {:ok, state} <- spawn_server(state, start) do
      if Keyword.get(opts, :preflight, true),
        do: preflighted_ready(state),
        else: {:ok, state}
    else
      {:not_started, %{boot_id: _} = state} -> {:not_started, state}
      {:held, %{boot_id: _} = state} -> {:held, state}
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
            hold_state: :held,
            spawned: pid
        }

        case mark(state, start, :started, observed(pid)) do
          {:ok, start} -> {:ok, publish(bind(state, start))}
          _error -> {:error, publish(state)}
        end

      {:error, reason} ->
        Logger.error("model server start failed: #{inspect(reason)}")
        _ = mark(state, start, :failed, %{})
        {:not_started, publish(state)}
    end
  end

  defp preflighted_ready(state) do
    if preflight(state.server, state.start.profile_id) == :ok do
      ready(state)
    else
      Logger.error("model server preflight failed; calls stay held")
      _ = mark(state, state.start, :failed, %{})
      {:held, publish(state)}
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
      :read -> reconciled(state, expected)
      :unavailable -> retry_reconcile(state, expected)
    end
  end

  # An uncertain finalization whose switch is found still pending once the
  # read recovers takes the permitted branch (section 1a): block, under the
  # finalizer's own fresh fence; the server stays held.
  defp reconciled(state, {:switch, id, _status} = expected) do
    case switch(state, id) do
      %ModelProfileSwitch{status: :pending} = switch ->
        block(state, switch, "finalization_uncertain")

      _stored_or_unknown ->
        release_if_reconciled(state, expected)
    end
  end

  defp reconciled(state, :boot), do: release_if_reconciled(state, :boot)

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

  # Section 2a: release only the current boot's ready latest start, with
  # its exact live server at the recorded profile and that server's own
  # reaper holding the lease, and the stored outcome as expected.
  defp release_if_reconciled(state, expected) do
    with {:ok, latest} <- latest_start(state),
         true <- current_server?(state, latest),
         true <- outcome_stored?(state, expected) do
      release(state, expected)
    else
      # Not yet reconciled (a failed read or observation): held, retried.
      _not_reconciled -> retry_reconcile(state, expected)
    end
  end

  defp current_server?(%{server: pid, start: start, boot_id: boot}, latest) when is_pid(pid) do
    reaper = ClaudeCLI.reaper(pid)

    latest.id == start.id and latest.boot_id == boot and latest.status == :ready and
      latest.pid == inspect(pid) and Process.alive?(pid) and
      ClaudeCLI.profile(pid) == latest.profile_id and is_pid(reaper) and
      Reaper.lease(ClaudeCLI.server()) == {:held, reaper}
  end

  defp current_server?(_state, _latest), do: false

  defp outcome_stored?(state, :boot), do: open_switch(state) == {:ok, nil}
  defp outcome_stored?(state, {:switch, id, status}), do: switch_status(state, id) == status

  defp release(%{server: pid, hold: ref} = state, expected)
       when is_pid(pid) and is_reference(ref) do
    case ClaudeCLI.release_hold(pid, ref) do
      :ok -> publish(%{state | hold: nil, hold_state: :released, reconcile: nil})
      _error -> retry_reconcile(state, expected)
    end
  end

  defp release(state, _expected), do: publish(%{state | reconcile: nil})

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

  # A new hold of the current server for the switch, acknowledged within
  # its bound; reported held only on the acknowledgement.
  defp rehold(%{server: pid, hold: nil} = state) when is_pid(pid) do
    ref = make_ref()
    state = %{state | hold: ref}

    case hold(pid, ref) do
      :held -> publish(%{state | hold_state: :held})
      _pending -> publish(%{state | hold_state: :pending})
    end
  end

  defp rehold(state), do: state

  @impl true
  def handle_info({:op, token, message}, %{op: %{token: token}} = state),
    do: {:noreply, step(state, message)}

  def handle_info({:op, _token, _message}, state), do: {:noreply, state}

  # Receipts are awaited in the stop protocol itself; a stray one is ignored.
  def handle_info({:reaper_cleanup_confirmed, _ref, _meta}, state), do: {:noreply, state}

  def handle_info({:DOWN, mref, :process, _worker, reason}, %{op: %{worker_ref: mref}} = state) do
    if reason == :normal,
      do: {:noreply, state},
      else:
        {:noreply,
         block(%{state | op: %{state.op | worker: nil}}, state.op.switch, "operation_died")}
  end

  def handle_info({:DOWN, mref, :process, _server, _reason}, %{server_ref: mref} = state),
    do: {:noreply, server_down(state)}

  def handle_info({:retry_block, id, reason}, state),
    do: {:noreply, retry_block(state, id, reason)}

  def handle_info({:reconcile, expected}, %{reconcile: expected} = state),
    do: {:noreply, reconcile(state, expected)}

  def handle_info(:boot, state), do: {:noreply, state, {:continue, :boot}}

  def handle_info(:replace, %{server: nil, op: nil, start: %{}} = state),
    do: {:noreply, server_down(state)}

  def handle_info(:replace, %{server: nil, op: nil, start: nil} = state),
    do: {:noreply, state, {:continue, :boot}}

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

  defp stop_server(state, continue) do
    case stop_and_confirm(state, state.server, state.op.switch.id) do
      :confirmed ->
        state = publish(%{state | server: nil, server_ref: nil, hold: nil})

        case continue do
          :candidate -> start_switch_server(state, :activation, state.op.to, :candidate_preflight)
          :rollback -> start_switch_server(state, :rollback, state.op.from, :rollback_preflight)
        end

      :unconfirmed ->
        state = %{state | server: nil, server_ref: nil, hold: nil}
        block(state, state.op.switch, "old_cleanup_unconfirmed")
    end
  end

  # The receipt protocol (section 3), under one monotonic deadline from the
  # acknowledged subscription: the stop is asynchronous, so a stop that
  # blocks is charged to the same bound. Confirmed only by the exact ref's
  # receipt; the reaper's DOWN without it, an absent or foreign lease, a
  # dead holder or the deadline is unconfirmed. A server still running at
  # the deadline is killed (its reaper still cleans up; the stage blocks).
  defp stop_and_confirm(state, pid, switch_id) do
    reaper = ClaudeCLI.reaper(pid)
    ref = make_ref()

    with true <- is_pid(reaper),
         {:subscribed, ^ref} <- Reaper.subscribe(reaper, ref, state.cleanup_wait_ms) do
      # One deadline from the acknowledgement: nothing after it resets it.
      deadline = System.monotonic_time(:millisecond) + state.cleanup_wait_ms
      monitor = Process.monitor(reaper)
      if switch_id, do: emit(:old_stopping, switch_id)
      if state.server_ref, do: Process.demonitor(state.server_ref, [:flush])
      Process.exit(pid, :shutdown)
      result = await_receipt(ref, monitor, reaper, deadline)
      Process.demonitor(monitor, [:flush])
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      result
    else
      _not_subscribed -> :unconfirmed
    end
  end

  defp await_receipt(ref, monitor, reaper, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:reaper_cleanup_confirmed, ^ref, _meta} -> in_time(deadline)
      {:DOWN, ^monitor, :process, ^reaper, _reason} -> :unconfirmed
    after
      max(min(remaining, @lease_poll_ms), 0) ->
        cond do
          remaining <= 0 -> :unconfirmed
          lease_lost?(reaper) -> receipt_grace(ref, monitor, reaper, deadline)
          true -> await_receipt(ref, monitor, reaper, deadline)
        end
    end
  end

  # A receipt consumed after the deadline (one queued while this process
  # was not running, say) is not a confirmation.
  defp in_time(deadline),
    do: if(System.monotonic_time(:millisecond) <= deadline, do: :confirmed, else: :unconfirmed)

  defp lease_lost?(reaper),
    do: Reaper.lease(ClaudeCLI.server()) != {:held, reaper} or not Process.alive?(reaper)

  # The receipt follows the reaper's own lease release at once: a short
  # grace, never a reset of the deadline.
  defp receipt_grace(ref, monitor, reaper, deadline) do
    grace = min(@receipt_grace_ms, max(deadline - System.monotonic_time(:millisecond), 0))

    receive do
      {:reaper_cleanup_confirmed, ^ref, _meta} -> in_time(deadline)
      {:DOWN, ^monitor, :process, ^reaper, _reason} -> :unconfirmed
    after
      grace -> :unconfirmed
    end
  end

  # A candidate that provably never started takes the rollback path; any
  # other failure blocks (fail closed).
  defp start_switch_server(state, reason, profile, stage) do
    case start_new(state, reason, profile, state.op.switch.id, preflight: false) do
      {:ok, state} ->
        send(state.op.worker, {:preflight, state.op.token, state.server, profile})
        publish(%{state | op: %{state.op | stage: stage}})

      {:not_started, state} when reason == :activation ->
        start_switch_server(state, :rollback, state.op.from, :rollback_preflight)

      {_error, state} ->
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

  # Blocks S under this boot's latest start; the server stays held. A block
  # that fails (a spent bound, a lost connection) is retried from a fresh,
  # target-bound read of S: stored blocked is done (no second write); still
  # pending takes the same bounded block again.
  defp block(%{start: %{id: start_id}} = state, switch, reason) do
    Logger.warning("model profile switch #{switch.id} blocked: #{reason}")

    attrs = %{
      server_generation: switch.server_generation,
      boot_id: state.boot_id,
      start_id: start_id,
      failure_reason: reason
    }

    case Agents.block_profile_switch(switch, attrs, actor: actor(state)) do
      {:ok, _blocked} ->
        :ok

      error ->
        Logger.error("model profile switch block failed: #{inspect(error)}; retrying")
        Process.send_after(self(), {:retry_block, switch.id, reason}, @retry_ms)
    end

    end_op(state)
  end

  defp block(state, _switch, _reason), do: end_op(state)

  defp retry_block(state, id, reason) do
    case switch(state, id) do
      %ModelProfileSwitch{status: :pending} = switch ->
        block(state, switch, reason)

      %ModelProfileSwitch{} ->
        publish(state)

      nil ->
        Process.send_after(self(), {:retry_block, id, reason}, @retry_ms)
        publish(state)
    end
  end

  # No server is running and none is switching: a held replacement is
  # retried (a server can die even before its init returns).
  defp retry_replacement(%{server: nil, op: nil} = state) do
    Process.send_after(self(), :replace, @replace_retry_ms)
    state
  end

  defp retry_replacement(state), do: state

  # An unexpected server death outside a switch: a held replacement.
  defp server_down(%{op: nil} = state) do
    state = publish(%{state | server: nil, server_ref: nil, hold: nil, hold_state: :pending})

    case start_new(state, :replacement, state.start.profile_id, nil) do
      {:ok, state} -> reconcile(state, :boot)
      {_error, state} -> retry_replacement(state)
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

  # The tenant's open (pending or blocked) switch: `{:ok, switch | nil}`,
  # or `:error` when unreadable (unknown, never "none").
  defp open_switch(state) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id and status in [:pending, :blocked])
    |> Ash.read_one()
    |> case do
      {:ok, switch} -> {:ok, switch}
      _error -> :error
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
