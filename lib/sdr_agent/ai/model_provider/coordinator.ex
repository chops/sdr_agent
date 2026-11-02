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
  server stays held; otherwise the reconciled read releases it. The block
  also follows a first start of this boot that ends held (a failed
  preflight), never started, or was only a fence behind a dead lease (the
  b2α boot-gap correction, C2-02b2β): only once this boot has allocated a
  start of its own, never for an unmanaged named process before that, and
  without the rest of the boot (no release).

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

  **No server** (a death outside a switch, the post-resolution path, the
  tick): a fresh held `:replacement` only once no lease is held; a live
  holder is waited for on the tick. A lease held by a **dead** process
  blocks every new server's admission, so nothing is started behind it:
  the **hard conflict** (C2-02b2β), held, `stage: :cleanup_unprovable`,
  re-observed on the tick. Its exit is the existing operator path (the
  operator checks the machine and runs `Reaper.release/1` from a console);
  this module never calls `Reaper.release/1`. Once there is no lease and
  no live named server, the tick runs the cold-boot path again (a fresh
  held allocation, the no-call preflight, `:ready`, the reconciled
  release); that absence proves nothing about who removed the lease and is
  never cleanup evidence. At boot the same dead lease allocates only this
  boot's fence (marked failed, never started).

  **The attended resolution** (C2-02b2β, `docs/product/r0/c2-02b2b-interface.md`;
  `resolve_blocked/2`, from `SdrAgent.Agents.resolve_blocked_switch/3`, and
  the read-only `resolution_facts/2`), in this order: a request dequeued
  after its caller's deadline is refused (`:resolve_timeout`) and nothing
  else happens, and every later step re-checks the budget; the admin
  (re-read) and the attestation's shape; the second replay read, before
  any mutable check (an exact match is the replay, another row
  `:attestation_conflict`, an unreadable read `:observation_unknown`); the
  switch blocked, else `:switch_not_blocked`; not busy (a switch worker, a
  reconciliation in flight or an unsettled outcome: `:coordinator_busy`,
  nothing queued); the binding (this boot allocated, and its latest start
  is the attested one, else `:stale_attestation`); the acknowledged hold
  (any live named server is this coordinator's exact child, held, else
  `:observation_unknown`); the observed lease kind (`:survivor` — the bound
  held server, open admission, its own live reaper's lease; `:none` — no
  server, no lease; `:dead_holder` — no server, a dead holder; anything
  else `:live_work_observed`; another kind than attested
  `:stale_attestation`). Then one bounded write (`min(time left, 2 s)`,
  `SdrAgent.Agents.ProfileSwitches.commit_resolution/2`). A commit is
  replied first, then b2α's no-open-switch reconciliation runs on the
  **current** runtime facts (adopt the survivor, or stop it with a fresh
  receipt and replace it; a fresh start for none; the hard conflict for a
  dead lease); it releases the hold only through b2α's reconciled read and
  never releases a lease. An unknown outcome (an exception, a lost reply)
  is settled first, by the barrier and exact re-read
  (`SdrAgent.Agents.ProfileSwitches.settle_resolution/2`, as
  `model_runtime`); unproven, the coordinator stays held, replies
  `:resolve_uncertain`, takes no other action and retries the settlement
  on its tick.

  **Status** (`status/0`) is published in a protected ETS table and never
  waits on this process: `%{boot_id, generation, profile_id, hold: :held |
  :released | :pending, stage, switch_id, desired, switch, published_at}`;
  it never holds a raw pid or ref. The stage is the switch's, or
  `:cleanup_unprovable` in the hard conflict. C2-02c
  (`docs/product/r0/c2-02c-interface.md` section 2): `desired`
  (`%{profile_id, source: :setting | :default, confirmed_at}`) and `switch`
  (`%{state: :none, confirmed_at}`, or `%{state: :open, id,
  from_profile_id, to_profile_id, status: :pending | :blocked,
  failure_reason, confirmed_at}`) are this process's **last confirmed
  observations**, each taken from the outcome of its own bounded reads and
  writes (the boot reads of the switch and the setting, the request's
  read, `block`, `complete`, `fail`, the reconciled reads and `resolve`);
  a failed read, or an uncertain finalization or resolution until it is
  settled, is `:unknown`, never a stale value presented as current. Its
  own acknowledged write establishes the switch's outcome; an exact read of
  one switch changes the observations only for the switch they concern (an
  older switch's history never replaces a newer desired profile or erases
  an observed open switch). The stage stays published until an outcome is
  definite: `:finalizing` for an uncertain finalization until its
  reconciled read, `:settling` while a resolution's settlement is pending.
  A caller's committed request shows the previous observation until this
  process handles its cast. `publish/1` makes no database read. The same
  row carries a **private** binding (this pid, the bound server pid or
  `:none`, the start id, the boot id, a publication counter), read only by
  `sample/0` for `SdrAgent.AI.ModelProvider.Runtime.status/0`'s bracket and
  never returned by `status/0`.

  **Stages** are observed through `[:sdr_agent, :model_coordinator,
  :stage]` telemetry (`%{stage:, switch_id:}`): the worker emits `:drained`
  and `:preflighted`, the coordinator `:old_stopping` and `:finalizing`.

  Options: `server:` (`fn profile_id -> ClaudeCLI options end`),
  `cleanup_wait_ms:`; test builds only: `manual: true` (allocates and
  starts nothing), `faults:` (`lose_reply: [:complete | :resolve_blocked]`,
  `reconcile:`, and for C2-02b2β `observe:` (the hold and lease
  observation), `replay_read:` (the coordinator's stored replay read) and
  `locked_replay_read:` (the replay read after the locks), each `fn -> :read
  | :unavailable end`, `resolve_budget_ms:` (a smaller write budget) and
  `client_slack_ms:` (the write's client-side slack, forwarded to
  `SdrAgent.Agents.LedgerCall`; #230)) and the `test_run/2` seam. Other
  builds refuse `manual:` and `faults:`.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias Ash.Error.Query.NotFound
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.CurrentAdmin
  alias SdrAgent.Agents.ModelProfileSetting
  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Agents.ModelServerStart
  alias SdrAgent.Agents.ProfileSwitches
  alias SdrAgent.Agents.SwitchResolution
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
  @ledger_max_ms 2_000
  @reply_slack_ms 500
  @facts_timeout_ms 10_000

  ## API

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The published status (its public part only), read from the coordinator's
  ETS table without waiting on it; nil when no coordinator runs.
  """
  def status do
    case :ets.lookup(@table, :status) do
      [{:status, public, _private}] -> public
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  C2-02c: one read of the published row with its private binding, for
  `SdrAgent.AI.ModelProvider.Runtime.status/0`'s bracket only (C1 and C2).
  `{:ok, %{public, private}}` only when the table's owner is the registered
  coordinator and the row's own coordinator pid is that owner; otherwise
  `:error`. Read-only: no message to this process, no database read. The
  private part (`coordinator`, `server` (a pid or `:none`), `start_id`,
  `boot_id`, `publication`) must never reach a caller's status.
  """
  def sample do
    with tid when tid != :undefined <- :ets.whereis(@table),
         owner when is_pid(owner) <- :ets.info(tid, :owner),
         ^owner <- Process.whereis(__MODULE__),
         [{:status, public, %{coordinator: ^owner} = private}] <- :ets.lookup(tid, :status) do
      {:ok, %{public: public, private: private}}
    else
      _invalid -> :error
    end
  rescue
    ArgumentError -> :error
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

  @doc """
  ADM (C2-02b2β): the facts a blocked switch's resolution is attested on,
  read-only (no write, no runtime change): `{:ok, %{switch, boot_id,
  latest_start, hold, covered_starts, lease_kind}}` — this boot, the
  stored latest start, the published hold, every start of the tenant with
  a generation in `[switch.server_generation, latest.generation]` with its
  recorded identity, and the observed lease kind (`:none | :survivor |
  :dead_holder`, or `:live_work_observed`, which no attestation can name).
  `{:error, :observation_unknown}` when the observation fails or no
  coordinator answers. `opts`: `actor:` (an active human admin).
  """
  def resolution_facts(switch, opts) do
    id = if is_map(switch), do: Map.get(switch, :id), else: switch

    GenServer.call(
      __MODULE__,
      {:resolution_facts, id, Keyword.get(opts, :actor)},
      @facts_timeout_ms
    )
  catch
    :exit, _no_answer -> {:error, :observation_unknown}
  end

  @doc """
  ADM (C2-02b2β): executes a validated resolution `request` (`%{switch_id,
  attestation, actor}`, from `SdrAgent.Agents.resolve_blocked_switch/3`)
  stamped with the caller's monotonic `deadline`; the call's timeout is the
  time left plus 500 ms, and its exit is the caller's to settle. See the
  moduledoc for the checks and results.
  """
  def resolve_blocked(request, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0) + @reply_slack_ms
    GenServer.call(__MODULE__, {:resolve_blocked, request, deadline}, timeout)
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
      reconcile: nil,
      # C2-02b2β: an unknown resolution still to settle, and the hard
      # conflict (`:cleanup_unprovable`).
      settling: nil,
      deferred: [],
      conflict: nil,
      # C2-02c: the last confirmed ledger observations (`publish/1`), and
      # the desired profile an uncertain outcome masks until it settles.
      desired: :unknown,
      switch_obs: :unknown,
      desired_stash: nil,
      # The switch the switch observation concerns (only its own exact
      # reads may change it), and the stage of an outcome not yet definite.
      ledger_subject: nil,
      unsettled: nil
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
  def handle_continue(:resolved, state), do: {:noreply, after_resolution(state)}

  # No maintenance work while a resolution's outcome is unproven (C2-02b2β):
  # the boot waits for the settlement.
  def handle_continue(:boot, %{settling: %{}} = state), do: {:noreply, defer(state, :boot)}

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
    case open_switch(state) do
      {:ok, open} ->
        case desired_profile(observe_open(state, {:ok, open})) do
          {:ok, desired, state} -> state |> first_start(desired) |> booted(open)
          {:error, state} -> retry_boot(state)
        end

      :error ->
        retry_boot(observe_open(state, :error))
    end
  end

  defp booted({:ok, state}, open), do: after_boot(state, open)

  # The b2α boot gap (C2-02b2β prerequisite correction): a first start of
  # this boot that does not end ready still blocks a pending switch, through
  # the registered coordinator's own `block` under its stored latest-start
  # fence (`block_at_boot/2`), and the runtime stays held. Nothing else of
  # `after_boot/2` runs: no release, and blocked or terminal histories are
  # left as they are.
  #
  # Fail closed, no retry: this boot's own server failed its preflight, or
  # a named server runs outside the supervisor.
  defp booted({:held, %{boot_id: _} = state}, open),
    do: state |> block_at_boot(open) |> publish()

  # Allocated, but its server never started: retried as a boot.
  defp booted({:not_started, %{boot_id: _} = state}, open),
    do: state |> block_at_boot(open) |> retry_boot()

  # A retained lease with no server (the fence only, nothing started): the
  # no-server path observes it (C2-02b2β, the hard conflict).
  defp booted({:conflict, %{boot_id: _} = state}, open),
    do: state |> block_at_boot(open) |> no_server(state.start.profile_id)

  # A failed or unreadable allocation: no fence of this boot, so no block.
  defp booted({:error, %{boot_id: _} = state}, _open), do: retry_boot(state)

  # Only once this boot holds a start of its own (an unmanaged named
  # process before any allocation gives the same held tuple, and grants
  # nothing); the domain re-checks the stored fence and the pending state.
  defp block_at_boot(
         %{start: %ModelServerStart{boot_id: boot}, boot_id: boot} = state,
         %ModelProfileSwitch{status: :pending} = switch
       ),
       do: block(state, switch, "coordinator_restarted")

  defp block_at_boot(state, _open), do: state

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

  # No server: a lease left by a dead reaper blocks any new server's
  # admission, so only this boot's fence is allocated (and failed, never
  # started); nothing runs behind it (C2-02b2β, the hard conflict).
  defp first_start(state, desired) do
    case lease_holder() do
      :dead -> fence_only(state, :boot, desired)
      _none_or_live -> start_new(state, :boot, desired, nil)
    end
  end

  defp fence_only(state, reason, profile) do
    with {:ok, start} <- allocate(state, reason, profile, nil),
         state = bind(state, start),
         {:ok, start} <- mark(state, start, :failed, %{}) do
      {:conflict, publish(bind(state, start))}
    else
      _error -> {:error, publish(state)}
    end
  end

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
        # stays held and failed until an operator acts. A lease found absent
        # here is uncertified, never a reason to start.
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
  # unreadable answer is unknown, never the default. Either outcome is the
  # published desired observation (C2-02c): `{:ok, profile, state}` or
  # `{:error, state}`.
  defp desired_profile(state) do
    ModelProfileSetting
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id)
    |> Ash.read_one()
    |> case do
      {:ok, %ModelProfileSetting{desired_profile_id: profile}} ->
        {:ok, profile, observe_desired(state, profile, :setting)}

      {:ok, nil} ->
        profile = ModelProfiles.default_real()
        {:ok, profile, observe_desired(state, profile, :default)}

      _error ->
        {:error, %{state | desired: :unknown, desired_stash: nil}}
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

  # C2-02b2β: the post-commit no-open-switch reconciliation, retried.
  defp reconcile(state, :resolution), do: after_resolution(%{state | reconcile: nil})

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
    case switch_result(state, id) do
      {:ok, %ModelProfileSwitch{status: :pending} = switch} ->
        block(state, switch, "finalization_uncertain")

      read ->
        release_if_reconciled(ledger_read(state, id, read), expected)
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
         {true, state} <- outcome_stored(state, expected) do
      release(state, expected)
    else
      # Not yet reconciled (a failed read or observation): held, retried.
      {false, state} -> retry_reconcile(state, expected)
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

  # The reconciled read, recorded as the published switch observation.
  defp outcome_stored(state, :boot) do
    read = open_switch(state)
    {read == {:ok, nil}, observe_open(state, read)}
  end

  defp outcome_stored(state, {:switch, id, status}) do
    read = switch_result(state, id)
    {match?({:ok, %ModelProfileSwitch{status: ^status}}, read), ledger_read(state, id, read)}
  end

  defp release(%{server: pid, hold: ref} = state, expected)
       when is_pid(pid) and is_reference(ref) do
    case ClaudeCLI.release_hold(pid, ref) do
      :ok -> publish(%{state | hold: nil, hold_state: :released, reconcile: nil, unsettled: nil})
      _error -> retry_reconcile(state, expected)
    end
  end

  defp release(state, _expected), do: publish(%{state | reconcile: nil})

  ## The switch

  @impl true
  def handle_cast({:switch_requested, switch_id}, %{op: nil, settling: nil, start: %{}} = state) do
    case switch_result(state, switch_id) do
      {:ok, %ModelProfileSwitch{status: :pending} = switch} ->
        {:noreply, begin_switch(observe_open(state, {:ok, switch}), switch)}

      {:ok, _other} ->
        {:noreply, state}

      # An unreadable request: the switch observation is unknown (C2-02c).
      _unreadable ->
        {:noreply, publish(%{state | switch_obs: :unknown, ledger_subject: switch_id})}
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

  # C2-02b2β: while a resolution's outcome is unproven, every maintenance
  # message (a boot retry, a replacement or conflict tick, a block retry, a
  # reconciliation retry) is deferred, never acted on: it is replayed only
  # once the settlement is definite (`resettle/1`). A server DOWN still
  # updates the facts (`server_down/1`), and starts nothing.
  @impl true
  def handle_info(message, %{settling: %{}} = state)
      when message in [:boot, :replace] or
             (is_tuple(message) and tuple_size(message) >= 2 and
                elem(message, 0) in [:retry_block, :reconcile]),
      do: {:noreply, defer(state, message)}

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

  def handle_info(:replace, %{server: nil, op: nil, settling: nil, start: %{}} = state),
    do: {:noreply, no_server(state, state.start.profile_id)}

  # C2-02b2β: the settlement of an unknown resolution, retried on the tick.
  def handle_info(:settle, %{settling: %{}} = state), do: {:noreply, resettle(state)}

  def handle_info(:replace, %{server: nil, op: nil, start: nil} = state),
    do: {:noreply, state, {:continue, :boot}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:resolution_facts, switch_id, actor}, _from, state),
    do: {:reply, resolution_facts(state, switch_id, actor), state}

  def handle_call({:resolve_blocked, request, deadline}, _from, state) do
    case resolve(state, request, deadline) do
      # Committed (or proven committed): b2α's no-open-switch
      # reconciliation follows the reply, never the other way round.
      {:committed, reply, state} -> {:reply, reply, state, {:continue, :resolved}}
      {:reply, reply, state} -> {:reply, reply, state}
    end
  end

  if @test_seams do
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
      {{:ok, stored}, false} ->
        finish(ledger_written(state, stored), expected)

      _uncertain ->
        uncertain(%{mask_ledger(state, switch.id) | unsettled: :finalizing}, switch, expected)
    end
  end

  defp finalizer(:complete), do: &Agents.complete_profile_switch/3
  defp finalizer(:fail), do: &Agents.fail_profile_switch/3

  # No other action before the reconciled read (section 1a).
  defp uncertain(state, switch, expected) do
    case readable(state, expected) do
      :read ->
        case switch_result(state, switch.id) do
          {:ok, %ModelProfileSwitch{status: :pending}} ->
            block(state, switch, "finalization_uncertain")

          read ->
            finish(ledger_read(state, switch.id, read), expected)
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

    state =
      case Agents.block_profile_switch(switch, attrs, actor: actor(state)) do
        {:ok, blocked} ->
          ledger_written(state, blocked)

        error ->
          Logger.error("model profile switch block failed: #{inspect(error)}; retrying")
          Process.send_after(self(), {:retry_block, switch.id, reason}, @retry_ms)
          %{state | switch_obs: :unknown, ledger_subject: switch.id}
      end

    state |> end_op() |> publish()
  end

  defp block(state, _switch, _reason), do: end_op(state)

  defp retry_block(state, id, reason) do
    case switch_result(state, id) do
      {:ok, %ModelProfileSwitch{status: :pending} = switch} ->
        block(state, switch, reason)

      {:ok, %ModelProfileSwitch{}} = read ->
        publish(ledger_read(state, id, read))

      read ->
        Process.send_after(self(), {:retry_block, id, reason}, @retry_ms)
        publish(ledger_read(state, id, read))
    end
  end

  # No server is running and none is switching: a held replacement is
  # retried (a server can die even before its init returns).
  defp retry_replacement(%{server: nil, op: nil} = state) do
    Process.send_after(self(), :replace, @replace_retry_ms)
    state
  end

  defp retry_replacement(state), do: state

  # An unexpected server death outside a switch: a held replacement, once
  # no lease is held (`no_server/2`); none while a resolution's outcome is
  # unproven.
  defp server_down(%{op: nil, settling: %{}} = state),
    do: defer(publish(%{state | server: nil, server_ref: nil, hold: nil}), :replace)

  defp server_down(%{op: nil} = state) do
    state = publish(%{state | server: nil, server_ref: nil, hold: nil, hold_state: :pending})
    no_server(state, state.start.profile_id)
  end

  defp server_down(state), do: %{state | server: nil, server_ref: nil}

  ## No server (b2α's cold-boot precondition; C2-02b2β, the hard conflict)

  # No live server and no switch at work: a fresh held start of `profile`
  # only once no lease is held. A lease held by a live process (a reaper
  # still cleaning up) is waited for on the tick; one held by a dead
  # process blocks every new server's admission, so nothing is started
  # behind it: the hard conflict (`stage: :cleanup_unprovable`), held,
  # re-observed on the tick. Its exit is the operator's `Reaper.release/1`,
  # never this code's; a lease found absent later proves nothing about who
  # removed it, and is not cleanup evidence.
  defp no_server(state, profile) do
    case lease_holder() do
      :none ->
        case start_new(%{state | conflict: nil}, :replacement, profile, nil) do
          {:ok, state} -> after_start(state)
          {:held, state} -> publish(state)
          {_not_started_or_error, state} -> retry_replacement(state)
        end

      :live ->
        retry_replacement(publish(%{state | conflict: nil}))

      :dead ->
        retry_replacement(publish(%{state | conflict: :cleanup_unprovable, hold_state: :held}))
    end
  end

  # A fresh start with a blocked switch open stays held (b2α: b2β owns that
  # exit); otherwise the reconciled read decides the release.
  defp after_start(state) do
    read = open_switch(state)
    state = observe_open(state, read)

    case read do
      {:ok, %ModelProfileSwitch{status: :blocked}} -> publish(state)
      _none_pending_or_unknown -> reconcile(state, :boot)
    end
  end

  # Who holds the named server's lease: nobody, a live or a dead process.
  defp lease_holder do
    case Reaper.lease(ClaudeCLI.server()) do
      nil -> :none
      {:held, holder} -> if Process.alive?(holder), do: :live, else: :dead
    end
  end

  ## The attended resolution (C2-02b2β)

  defp resolution_facts(state, switch_id, actor) do
    with :ok <- requester(state, actor),
         {:ok, switch} <- stored_switch(state, switch_id),
         :ok <- blocked_only(switch),
         {:ok, latest} <- latest_start(state),
         {:ok, covered} <- covered_starts(state, switch, latest),
         {:ok, kind} <- observed_kind(state) do
      {:ok,
       %{
         switch: switch,
         boot_id: state.boot_id,
         latest_start: latest,
         hold: state.hold_state,
         covered_starts: covered,
         lease_kind: kind
       }}
    end
  end

  # Section 2, steps 1–6, in this order: the expiry on dequeue (and the
  # budget before every later step), the actor and the shape, the second
  # replay read (before any mutable check), the state, busy, the binding,
  # the acknowledged hold, the lease kind, then the write.
  defp resolve(state, %{switch_id: id, attestation: attestation, actor: actor}, deadline) do
    with :ok <- before_deadline(deadline),
         :ok <- requester(state, actor),
         {:ok, attestation} <- SwitchResolution.checked_attestation(id, attestation),
         {:ok, nil} <- coordinator_replay(state, attestation),
         :ok <- before_deadline(deadline),
         {:ok, switch} <- stored_switch(state, id),
         :ok <- blocked_only(switch),
         :ok <- not_busy(state),
         :ok <- bound(state, attestation),
         :ok <- acknowledged_hold(state),
         :ok <- attested_kind(state, attestation),
         :ok <- before_deadline(deadline) do
      write(state, %{switch_id: id, attestation: attestation, actor: actor}, deadline)
    else
      {:ok, %ModelProfileSwitch{} = stored} ->
        {:reply, SwitchResolution.resolution_result(stored, attestation, actor.id), state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp before_deadline(deadline) do
    if deadline - System.monotonic_time(:millisecond) > 0,
      do: :ok,
      else: {:error, :resolve_timeout}
  end

  # An active human admin of this coordinator's tenant, re-read now.
  defp requester(%{tenant_id: tenant_id}, %SdrAgent.Accounts.User{tenant_id: tenant_id} = actor)
       when is_binary(tenant_id) do
    if CurrentAdmin.match?(actor, %{}, []), do: :ok, else: forbidden()
  end

  # Before this boot has its tenant, it has allocated nothing to bind.
  defp requester(%{tenant_id: nil}, _actor), do: {:error, :stale_attestation}
  defp requester(_state, _actor), do: forbidden()

  defp forbidden, do: {:error, Ash.Error.Forbidden.exception([])}

  defp coordinator_replay(state, attestation) do
    case fault(state, :replay_read) do
      :unavailable ->
        {:error, :observation_unknown}

      :read ->
        SwitchResolution.replay_lookup(
          state.tenant_id,
          attestation.attestation_id,
          Kernel.opts(state.tenant_id)
        )
    end
  end

  defp stored_switch(state, id) do
    case is_binary(id) && switch_result(state, id) do
      {:ok, %ModelProfileSwitch{} = switch} ->
        {:ok, switch}

      {:ok, nil} ->
        {:error, Ash.Error.to_error_class(NotFound.exception(resource: ModelProfileSwitch))}

      _unreadable ->
        {:error, :observation_unknown}
    end
  end

  defp blocked_only(%ModelProfileSwitch{status: :blocked, resolution: nil}), do: :ok
  defp blocked_only(_switch), do: {:error, :switch_not_blocked}

  # Nothing is queued: a switch worker, a reconciliation in flight (a
  # block retry ends on a stored blocked switch) or an unsettled outcome.
  defp not_busy(%{op: nil, reconcile: nil, settling: nil}), do: :ok
  defp not_busy(_state), do: {:error, :coordinator_busy}

  # This boot has allocated, and its latest start is the attested one.
  defp bound(%{start: %ModelServerStart{boot_id: boot} = start, boot_id: boot}, attestation) do
    if start.id == attestation.attested_start_id and
         start.generation == attestation.attested_generation,
       do: :ok,
       else: {:error, :stale_attestation}
  end

  defp bound(_state, _attestation), do: {:error, :stale_attestation}

  # Any live named server is this coordinator's exact supervised child,
  # with an acknowledged hold; with none, the published hold is acknowledged.
  defp acknowledged_hold(state) do
    case fault(state, :observe) do
      :read -> if held?(state, named_server()), do: :ok, else: {:error, :observation_unknown}
      _unavailable -> {:error, :observation_unknown}
    end
  end

  defp held?(state, pid) when is_pid(pid) do
    pid == state.server and state.hold_state == :held and is_reference(state.hold) and
      child?(pid) and ClaudeCLI.held?(pid)
  end

  defp held?(state, nil), do: state.hold_state == :held

  # An observation only refuses: live work, or a kind other than the
  # attested one. It is never proof of absence, and it grants nothing.
  defp attested_kind(state, %{attested_lease_kind: attested}) do
    case observed_kind(state) do
      {:ok, :live_work_observed} -> {:error, :live_work_observed}
      {:ok, ^attested} -> :ok
      {:ok, _other} -> {:error, :stale_attestation}
      error -> error
    end
  end

  # `:survivor`: the live, held server is the bound pid, its admission is
  # open, and its own published reaper, alive, holds the lease. `:none`: no
  # live named server and no lease. `:dead_holder`: no live named server,
  # and the lease is held by a dead process. Anything else is live work.
  defp observed_kind(state) do
    case fault(state, :observe) do
      :read -> {:ok, kind(state, named_server())}
      _unavailable -> {:error, :observation_unknown}
    end
  end

  defp kind(state, pid) when is_pid(pid) do
    reaper = ClaudeCLI.reaper(pid)

    if pid == state.server and is_pid(reaper) and Process.alive?(reaper) and
         Reaper.lease(ClaudeCLI.server()) == {:held, reaper} and
         ClaudeCLI.admission(pid).admission == :open,
       do: :survivor,
       else: :live_work_observed
  end

  defp kind(_state, nil) do
    case lease_holder() do
      :none -> :none
      :dead -> :dead_holder
      :live -> :live_work_observed
    end
  end

  # The write: one bounded ledger call, `min(time left, 2 s)`.
  defp write(state, request, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    budget = Enum.min([remaining, @ledger_max_ms, resolve_budget(state)])
    request = Map.merge(request, %{boot_id: state.boot_id, start_id: state.start.id})

    case ProfileSwitches.commit_resolution(request, [budget_ms: budget] ++ write_faults(state)) do
      {:ok, {:resolved, switch}} ->
        if lost?(state),
          do: unknown(state, request),
          else: {:committed, {:ok, %{switch: switch}}, ledger_written(state, switch)}

      {:ok, {:replay, switch}} ->
        {:reply, {:ok, %{switch: switch, replay: true}}, state}

      {:rolled_back, reason} ->
        {:reply, SwitchResolution.rolled_back_result(reason), state}

      {:unknown, _reason} ->
        unknown(state, request)
    end
  end

  # An unknown commit is settled before any other action; unproven, the
  # coordinator stays held and retries the same settlement on its tick.
  defp unknown(state, request) do
    settlement = %{
      switch_id: request.switch_id,
      attestation: request.attestation,
      resolver_id: request.actor.id
    }

    case settle(state, settlement) do
      {:proven, reply} ->
        {:committed, reply, resolved_ledger(state)}

      # Unsettled: the ledger observations are unknown until it settles.
      {:unproven, reply} ->
        {:reply, reply,
         schedule_settle(%{mask_ledger(state, request.switch_id) | settling: settlement})}

      {:settled, reply} ->
        {:reply, reply, state}
    end
  end

  # Proven committed: the reconciliation; definitely not committed: back to
  # b2α's rules (a server lost meanwhile gets its held replacement).
  # A proven commit takes the reconciliation, which re-observes the runtime
  # itself (a deferred boot retry or replacement tick is superseded by it);
  # a definite non-commit replays the deferred work in its order.
  defp resettle(state) do
    case settle(state, state.settling) do
      # C2-02c: a proven commit closes the switch (terminal); a definite
      # non-commit restores the masked desired profile. `resume/2` publishes.
      {:proven, _reply} ->
        state
        |> resolved_ledger()
        |> resume(&(&1 not in [:boot, :replace]))
        |> after_resolution()

      {:unproven, _reply} ->
        schedule_settle(state)

      {:settled, _reply} ->
        state |> unmask_desired() |> resume(fn _message -> true end) |> retry_replacement()
    end
  end

  defp defer(state, message) do
    if message in state.deferred,
      do: state,
      else: %{state | deferred: state.deferred ++ [message]}
  end

  # The settlement is definite: the deferred messages `keep?` keeps are
  # delivered again, in order.
  defp resume(state, keep?) do
    for message <- state.deferred, keep?.(message), do: send(self(), message)
    publish(%{state | settling: nil, deferred: []})
  end

  # The barrier and exact re-read, as `model_runtime` in this process. A
  # switch no longer blocked (the replay, or resolved under another id) is
  # terminal: b2α's no-open-switch reconciliation follows.
  defp settle(state, settlement) do
    case ProfileSwitches.settle_resolution(settlement, actor(state)) do
      {:ok, %{replay: true}} = replay -> {:proven, replay}
      {:error, :switch_not_blocked} = reply -> {:proven, reply}
      {:error, :resolve_uncertain} = reply -> {:unproven, reply}
      reply -> {:settled, reply}
    end
  end

  defp schedule_settle(state) do
    Process.send_after(self(), :settle, @retry_ms)
    publish(state)
  end

  # After a committed resolution: b2α's no-open-switch reconciliation
  # (section 2a) on the current runtime facts, never the attested kind.
  defp after_resolution(state) do
    read = open_switch(state)
    state = observe_open(%{state | conflict: nil}, read)

    case read do
      {:ok, nil} ->
        no_open_switch(state)

      # A new switch keeps b2α's own rules; one requested while the outcome
      # was unsettled (its request was not taken then) begins now.
      {:ok, %ModelProfileSwitch{status: :pending} = switch} when is_nil(state.op) ->
        begin_switch(state, switch)

      {:ok, _open} ->
        publish(state)

      :error ->
        retry_reconcile(state, :resolution)
    end
  end

  defp no_open_switch(state) do
    case desired_profile(state) do
      {:ok, desired, state} -> no_open_switch(state, named_server(), desired)
      {:error, state} -> retry_reconcile(state, :resolution)
    end
  end

  defp no_open_switch(%{server: pid} = state, pid, desired) when is_pid(pid),
    do: held_server(state, pid, desired)

  defp no_open_switch(state, pid, _desired) when is_pid(pid) do
    Logger.error("a named ClaudeCLI server runs outside this coordinator; held")
    publish(state)
  end

  defp no_open_switch(state, nil, desired), do: state |> forget_server() |> no_server(desired)

  # The survivor: adopted if b2α's conditions hold (the exact child, the
  # desired profile, its own live reaper's lease), released by the
  # reconciled read; otherwise the bound stop protocol (a fresh receipt),
  # then the no-server path.
  defp held_server(state, pid, desired) do
    cond do
      not child?(pid) ->
        Logger.error("a named ClaudeCLI server runs outside the model server supervisor; held")
        publish(state)

      # b2α's own-boot failed-start exclusion (as `first_start/2`): this
      # boot's own server, not ready on its start (its no-call preflight
      # failed), is never adopted, never given `:adopted` evidence and never
      # released; it stays held.
      pid == state.spawned and not ready_on?(state, pid) ->
        Logger.error("this boot's own server failed its readiness; held after the resolution")
        publish(%{state | hold_state: :held})

      adoptable?(pid, desired) ->
        adopted_server(state, pid, desired)

      true ->
        case stop_and_confirm(state, pid, nil) do
          :confirmed -> state |> forget_server() |> no_server(desired)
          :unconfirmed -> state |> forget_server() |> unconfirmed_stop(desired)
        end
    end
  end

  # Already this boot's ready start on that pid (adopted at boot, say), or
  # adopted now under a new `:replacement` start; then the reconciled read.
  defp adopted_server(state, pid, desired) do
    if ready_on?(state, pid) do
      reconcile(state, :boot)
    else
      case adopt(state, pid, desired) do
        {:ok, state} -> reconcile(state, :boot)
        {:error, state} -> retry_reconcile(state, :resolution)
      end
    end
  end

  # An unconfirmed stop starts nothing: a dead holder is the hard conflict
  # (re-observed on the tick); an absent or live lease is uncertified and
  # stays held, as b2α keeps it.
  defp unconfirmed_stop(state, desired) do
    case lease_holder() do
      :dead -> no_server(state, desired)
      _uncertified -> publish(%{state | hold_state: :held})
    end
  end

  defp ready_on?(%{start: %ModelServerStart{} = start, boot_id: boot}, pid),
    do: start.boot_id == boot and start.status == :ready and start.pid == inspect(pid)

  defp ready_on?(_state, _pid), do: false

  defp forget_server(%{server_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | server: nil, server_ref: nil, hold: nil}
  end

  # Test builds only: the coordinator's `faults:` (see the moduledoc).
  defp fault(state, key) do
    case Keyword.get(state.faults, key) do
      fun when is_function(fun, 0) -> fun.()
      nil -> :read
    end
  end

  defp lost?(state), do: :resolve_blocked in Keyword.get(state.faults, :lose_reply, [])

  defp resolve_budget(state), do: Keyword.get(state.faults, :resolve_budget_ms, @ledger_max_ms)

  if @test_seams do
    defp write_faults(%{faults: faults}),
      do: [faults: Keyword.take(faults, [:locked_replay_read, :client_slack_ms])]
  else
    defp write_faults(_state), do: []
  end

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

  # The tenant's switch `id`: `{:ok, switch | nil}`, or an error when unreadable.
  defp switch_result(state, id) do
    ModelProfileSwitch
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(tenant_id == ^state.tenant_id and id == ^id)
    |> Ash.read_one()
  end

  # The tenant's starts in the covered range `[switch.server_generation,
  # latest.generation]`, by generation, with their recorded identity.
  defp covered_starts(state, switch, %ModelServerStart{generation: last}) do
    ModelServerStart
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(state.tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^state.tenant_id and generation >= ^switch.server_generation and
        generation <= ^last
    )
    |> Ash.Query.sort(generation: :asc)
    |> Ash.read()
    |> case do
      {:ok, starts} -> {:ok, starts}
      _error -> {:error, :observation_unknown}
    end
  end

  defp covered_starts(_state, _switch, _latest), do: {:error, :observation_unknown}

  ## Status and stages

  # One row: the public status and the private binding (C2-02c 2a), from
  # this process's state only (no database read).
  defp publish(state) do
    public = %{
      boot_id: state.boot_id,
      generation: state.start && state.start.generation,
      profile_id: state.start && state.start.profile_id,
      hold: state.hold_state,
      stage: stage(state),
      switch_id: state.op && state.op.switch.id,
      desired: state.desired,
      switch: state.switch_obs,
      published_at: DateTime.utc_now()
    }

    private = %{
      coordinator: self(),
      server: if(is_pid(state.server), do: state.server, else: :none),
      start_id: state.start && state.start.id,
      boot_id: state.boot_id,
      publication: System.unique_integer([:monotonic])
    }

    :ets.insert(@table, {:status, public, private})
    state
  end

  # The switch's stage; else an outcome not yet definite (an uncertain
  # finalization until its reconciled read, `:settling` while a
  # resolution's settlement is pending); else the hard conflict.
  defp stage(%{op: %{stage: stage}}), do: stage
  defp stage(%{unsettled: unsettled}) when not is_nil(unsettled), do: unsettled
  defp stage(%{settling: %{}}), do: :settling
  defp stage(state), do: state.conflict

  ## The ledger observations (C2-02c section 2)

  # A desired profile this process just read (`:setting` or `:default`).
  defp observe_desired(state, profile, source),
    do: %{
      state
      | desired: %{profile_id: profile, source: source, confirmed_at: DateTime.utc_now()},
        desired_stash: nil
    }

  # This process's read of the open switch: none, the open one, or unknown.
  defp observe_open(state, {:ok, nil}),
    do: %{
      state
      | switch_obs: %{state: :none, confirmed_at: DateTime.utc_now()},
        ledger_subject: nil
    }

  defp observe_open(state, {:ok, %ModelProfileSwitch{status: status} = switch})
       when status in [:pending, :blocked],
       do: %{state | switch_obs: open_observation(switch), ledger_subject: switch.id}

  defp observe_open(state, _unreadable), do: %{state | switch_obs: :unknown, ledger_subject: nil}

  defp open_observation(switch) do
    %{
      state: :open,
      id: switch.id,
      from_profile_id: switch.from_profile_id,
      to_profile_id: switch.to_profile_id,
      status: switch.status,
      failure_reason: switch.failure_reason,
      confirmed_at: DateTime.utc_now()
    }
  end

  # This process's own acknowledged write on `switch` (block, complete,
  # fail, resolve): the switch was the tenant's one open switch when it
  # committed, so its outcome is the current one, and the switch becomes
  # the subject of the observations.
  defp ledger_written(state, %ModelProfileSwitch{} = switch),
    do: %{ledger_after(state, switch) | ledger_subject: switch.id, unsettled: nil}

  # This process's exact read of switch `id` (`switch_result/2`). Only the
  # subject's own read changes the observations: a stored row establishes
  # its outcome; a failed read, or the subject's row known absent, makes the
  # switch observation unknown (never a retained none or open). A read of
  # any other switch is history: it never replaces a newer desired profile
  # or erases an observed open switch.
  defp ledger_read(%{ledger_subject: id} = state, id, {:ok, %ModelProfileSwitch{} = stored}),
    do: ledger_written(state, stored)

  defp ledger_read(%{ledger_subject: id} = state, id, _failed_or_known_absent),
    do: %{state | switch_obs: :unknown}

  defp ledger_read(state, _history_id, _read), do: state

  # The stored state of one switch (`ledger_written/2`). A terminal switch
  # was the tenant's one open switch, so none is open as of that outcome; a
  # completed one applied its profile to the setting, while fail, block and
  # resolve leave the setting unchanged.
  defp ledger_after(state, %ModelProfileSwitch{status: :completed, to_profile_id: to}),
    do: observe_open(observe_desired(state, to, :setting), {:ok, nil})

  defp ledger_after(state, %ModelProfileSwitch{status: :failed}),
    do: state |> unmask_desired() |> observe_open({:ok, nil})

  defp ledger_after(state, %ModelProfileSwitch{} = open),
    do: state |> unmask_desired() |> observe_open({:ok, open})

  # A committed resolution: the switch is terminal (`:failed`).
  defp resolved_ledger(state), do: state |> unmask_desired() |> observe_open({:ok, nil})

  # An uncertain finalization or resolution: both observations are unknown
  # until it is settled; the desired profile is kept to be restored by an
  # outcome that leaves the setting unchanged.
  defp mask_ledger(%{desired_stash: nil} = state, id),
    do: %{
      state
      | desired: :unknown,
        switch_obs: :unknown,
        desired_stash: {:stashed, state.desired},
        ledger_subject: id
    }

  defp mask_ledger(state, id),
    do: %{state | desired: :unknown, switch_obs: :unknown, ledger_subject: id}

  defp unmask_desired(%{desired_stash: {:stashed, desired}} = state),
    do: %{state | desired: desired, desired_stash: nil}

  defp unmask_desired(state), do: state

  defp emit(stage, %{op: %{switch: switch}}), do: emit(stage, switch.id)

  defp emit(stage, switch_id),
    do: :telemetry.execute(@stage, %{}, %{stage: stage, switch_id: switch_id})
end
