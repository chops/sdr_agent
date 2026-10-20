defmodule SdrAgent.SDR.DefinitionBootstrap do
  @moduledoc """
  The `SDRAgent` definition bootstrap (C3-02, plan r8 sections 7.2 and 7.3;
  D-174 Q-O4): the only path that registers the `SDRAgent` AgentDefinition,
  and the boot child that runs it.

  **Registration** (`register/2`, behind `SdrAgent.SDR.bootstrap_definitions/1`):

    1. refuses nested entry: inside a transaction it returns
       `{:error, :bootstrap_in_transaction}` and writes nothing, so nothing
       registers under a chain head;
    2. registers through `SdrAgent.SDR.SDRAgent.register/1` (KRN, with its
       `agents.definition.registered` event) in its own outermost
       `SdrAgent.Audit.transaction/1`; the boot run bounds that transaction
       with `SET LOCAL lock_timeout` and `statement_timeout`;
    3. when that registration fails on the unique `(tenant, name, version)`
       index (matched by constraint name), or finds an existing row with
       another hash, its transaction has already rolled back; then, outside
       any transaction, it re-reads the row once;
    4. accepts the registered, existing or re-read row only if it is the
       tenant's `SDRAgent` at the code's version, `active`, with the hash of
       current code (`SDRAgent.definition_sha256/0`); any other row is
       `{:error, :definition_conflict}`. A repeated call returns the
       existing valid row and writes nothing (idempotent).

  Any other failure is reduced to a sanitized class (`:timeout`, `:crash`,
  `:schema_not_migrated` (42P01), `:connection`, `:definition_conflict`);
  no exception message is kept.

  **Boot child.** `SdrAgent.Application` starts it right after
  `SdrAgent.Repo`, before the model provider, Oban, PubSub, the Relay and
  the Endpoint. `start_link/1` is synchronous: it runs `run/1` in a worker
  started with `spawn_monitor` (unlinked) and waits for its result or its
  `:DOWN` until `deadline_ms` (option, else `config :sdr_agent,
  SdrAgent.SDR.DefinitionBootstrap, deadline_ms:`, default 30 000). On the
  deadline it kills the worker and awaits its `:DOWN` before returning.
  Every outcome (`:no_tenant`, `{:ok, definitions}`, `{:error, class}`,
  `{:crash, reason}`, `:timeout`) goes through `disposition/1`:

    * no tenant: `:ignore` (nothing to register for), the only `:ignore`;
    * success: `{:ok, pid}` of an idle process that holds nothing;
    * anything else: `{:error, {:definition_bootstrap_failed, class}}`, so
      the application does not start (D-174 Q-O4); the class is logged,
      never a reason or a value.

  **What the deadline means.** It bounds the wait, not the database state:
  a worker killed at the deadline may already have committed its
  registration (commit can race the deadline); a kill while its
  transaction is open rolls that transaction back. `:timeout` means "not
  confirmed", and the next run or call converges (step 4).

  **Inside `run/1`** (G3-2, Codex 944d822): one tenant enumeration (KRN; at
  most the singleton tenant), then per tenant one registration plus at most
  one post-violation re-read, each a DB call with the client timeout
  `min(remaining, cap)` (cap 5 s, lowered by `step_ms:`); the registration
  transaction also sets its transaction-local `lock_timeout` and
  `statement_timeout` to that value, and the re-read stays outside the
  ended transaction. No call and no attempt starts once the budget is
  spent (`{:error, :timeout}`). A `:connection` failure is retried up to 3
  times with a 2 s backoff while time remains, never after the budget ran
  out during the backoff. `:timeout` means "not confirmed" here as well:
  a client timeout does not prove that the server rolled back.

  Test-seam builds only (`:claude_cli_test_seams`, compile time; absent from
  dev and prod): `run/1` takes `test_hooks:`, which observe and inject but
  decide nothing: `observer: pid` receives `{:c302_bootstrap_attempt, n}`,
  `{:c302_bootstrap_outcome, n, outcome}` and, for each DB call,
  `{:c302_bootstrap_call, step, timeout}` with the client timeout read from
  the options that call actually receives (`:default` when none);
  `connection_faults: n` fails the first n attempts as `:connection` before
  any DB call; `backoff_ms:` and `sleep:` replace the backoff value and its
  sleep; `repo_opts:` adds repo options to the tenant read and the re-read
  (e.g. `prepare: :unnamed`, so a blocked read waits in its retriable
  prepare phase); `after_call: fun` runs `fun.(step)` right after such a
  read returned. And `start_link/1` takes `test_barrier: pid`. The worker, once
  its work started (after the tenant enumeration) and before its first
  database write, monitors `pid`, sends it `{:c302_bootstrap_started,
  worker}` and waits for a release that never comes: it ends when the child
  kills it at the deadline, or on `pid`'s `:DOWN`, by exiting with no
  further database work.
  """
  use GenServer, restart: :temporary

  require Ash.Query
  require Logger

  alias Ash.Error.Changes.InvalidAttribute
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo
  alias SdrAgent.SDR.SDRAgent

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)

  @classes [:timeout, :crash, :schema_not_migrated, :connection, :definition_conflict]
  @default_deadline_ms 30_000
  @step_ms 5_000
  @connection_retries 3
  @backoff_ms 2_000
  @unique_index "agent_definitions_unique_name_version_index"

  ## Boot child

  @doc "Starts the boot child (see the moduledoc). Options: `deadline_ms:`."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    deadline_ms = Keyword.get(opts, :deadline_ms, configured_deadline_ms())

    case opts |> supervise(deadline_ms) |> disposition() do
      :ok ->
        {:ok, :bootstrapped}

      :ignore ->
        :ignore

      {:error, {:definition_bootstrap_failed, class} = reason} ->
        Logger.error("SDRAgent definition bootstrap failed (#{class}); the application stops")
        {:stop, reason}
    end
  end

  @doc """
  The one disposition of every outcome (see the moduledoc): `:ignore` for
  `:no_tenant` only, `:ok` for `{:ok, definitions}`, else
  `{:error, {:definition_bootstrap_failed, class}}` with a sanitized class.
  """
  def disposition(:no_tenant), do: :ignore
  def disposition({:ok, definitions}) when is_list(definitions), do: :ok
  def disposition({:error, class}) when class in @classes, do: failed(class)
  def disposition({:error, error}), do: failed(classify(error))
  def disposition({:crash, _reason}), do: failed(:crash)
  def disposition(:timeout), do: failed(:timeout)
  def disposition(_other), do: failed(:crash)

  defp failed(class), do: {:error, {:definition_bootstrap_failed, class}}

  defp configured_deadline_ms do
    :sdr_agent
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:deadline_ms, @default_deadline_ms)
  end

  # The worker runs unlinked and monitored; its result, its :DOWN or the
  # deadline ends the wait, and the worker is gone before this returns.
  defp supervise(opts, deadline_ms) do
    parent = self()
    tag = make_ref()
    deadline = now() + max(deadline_ms, 0)
    worker_opts = [deadline: deadline] ++ Keyword.take(opts, [:test_barrier])

    {pid, ref} = spawn_monitor(fn -> send(parent, {tag, run(worker_opts)}) end)

    receive do
      {^tag, outcome} ->
        await_down(pid, ref)
        outcome

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:crash, reason}
    after
      max(deadline_ms, 0) ->
        Process.exit(pid, :kill)
        await_down(pid, ref)

        # A result sent between the deadline and the kill is not confirmed.
        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  # The worker's last act is the send, so its :DOWN follows; a kill makes
  # it certain.
  defp await_down(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @step_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
    end
  end

  ## The work

  @doc """
  Runs the bootstrap in the caller: `:no_tenant`, `{:ok, [definition]}` or
  `{:error, class}`. Options: `deadline:` (monotonic milliseconds) or
  `deadline_ms:` (from now; default from config), and `step_ms:`, which
  lowers the per-call cap of 5 000 ms. Every DB call (the tenant
  enumeration, the registration transaction, the post-rollback re-read) is
  given `min(remaining, cap)` as its client timeout, and none starts once
  the budget is spent: that is `{:error, :timeout}`, also when the budget
  ran out during a backoff or in a call that timed out on the client.
  """
  def run(opts) do
    deadline =
      Keyword.get_lazy(opts, :deadline, fn ->
        now() + Keyword.get(opts, :deadline_ms, configured_deadline_ms())
      end)

    budget = %{
      deadline: deadline,
      cap: min(Keyword.get(opts, :step_ms, @step_ms), @step_ms),
      hooks: hooks(opts)
    }

    attempts(budget, opts, 1)
  end

  defp attempts(budget, opts, n) do
    if spent?(budget),
      do: {:error, :timeout},
      else: attempt_outcome(budget, opts, n)
  end

  defp attempt_outcome(budget, opts, n) do
    observe(budget, {:c302_bootstrap_attempt, n})
    outcome = attempt(budget, opts, n)
    observe(budget, {:c302_bootstrap_outcome, n, outcome})

    case outcome do
      {:error, :connection} -> after_connection_failure(budget, opts, n)
      {:error, :crash} -> crash_or_timeout(budget)
      outcome -> outcome
    end
  end

  defp crash_or_timeout(budget),
    do: if(spent?(budget), do: {:error, :timeout}, else: {:error, :crash})

  # A connection failure is retried up to @connection_retries times with a
  # backoff, only while time remains. A failure that arrives with the budget
  # spent is the call's client timeout (each call's timeout ends at the
  # deadline at the latest), so it is `:timeout`, as is a budget spent by the
  # backoff; no attempt starts after that.
  defp after_connection_failure(budget, opts, n) do
    backoff = backoff_ms(budget)

    cond do
      spent?(budget) ->
        {:error, :timeout}

      n > @connection_retries or remaining(budget.deadline) <= backoff ->
        {:error, :connection}

      true ->
        sleep(budget, backoff)
        attempts(budget, opts, n + 1)
    end
  end

  defp run_once(budget, opts) do
    case tenant(budget) do
      :no_tenant ->
        :no_tenant

      {:ok, tenant_id} ->
        barrier(opts)

        case register(tenant_id, budget: budget) do
          {:ok, definition} -> {:ok, [definition]}
          {:error, :bootstrap_in_transaction} -> {:error, :crash}
          {:error, class} -> {:error, class}
        end

      {:error, class} ->
        {:error, class}
    end
  end

  defp tenant(budget) do
    with {:ok, timeout} <- call_timeout(budget) do
      read_opts = [timeout: timeout]
      observe_call(budget, :tenant, read_opts)

      read = with_repo_opts(budget, fn -> Kernel.singleton_tenant_id(read_opts) end)
      after_call(budget, :tenant)

      case read do
        {:ok, tenant_id} -> {:ok, tenant_id}
        {:error, :tenant_not_bootstrapped} -> :no_tenant
        {:error, error} -> {:error, classify(error)}
      end
    end
  rescue
    error -> {:error, classify(error)}
  end

  # The client timeout of the next DB call: min(remaining, cap), or
  # `{:error, :timeout}` without the call once nothing remains. No budget
  # (`SdrAgent.SDR.bootstrap_definitions/1`) sets none.
  defp call_timeout(nil), do: {:ok, nil}

  defp call_timeout(budget) do
    case min(remaining(budget.deadline), budget.cap) do
      ms when ms > 0 -> {:ok, ms}
      _spent -> {:error, :timeout}
    end
  end

  # Reports the client timeout a DB call is actually given, read from the
  # same options the call receives (`:default` when none).
  defp observe_call(budget, step, call_opts),
    do: observe(budget, {:c302_bootstrap_call, step, Keyword.get(call_opts, :timeout, :default)})

  defp spent?(budget), do: remaining(budget.deadline) <= 0

  if @test_seams do
    defp barrier(opts) do
      case Keyword.get(opts, :test_barrier) do
        owner when is_pid(owner) ->
          ref = Process.monitor(owner)
          send(owner, {:c302_bootstrap_started, self()})

          receive do
            {:DOWN, ^ref, :process, ^owner, _reason} -> exit(:normal)
          end

        _none ->
          :ok
      end
    end

    # Test-build hooks of `run/1` (`test_hooks:`, see the moduledoc).
    defp hooks(opts), do: Keyword.get(opts, :test_hooks, [])

    defp observe(nil, _message), do: :ok

    defp observe(%{hooks: hooks}, message) do
      case Keyword.get(hooks, :observer) do
        pid when is_pid(pid) -> send(pid, message)
        _none -> :ok
      end
    end

    # `connection_faults: n` fails the first n attempts before any DB call.
    defp attempt(%{hooks: hooks} = budget, opts, n) do
      if n <= Keyword.get(hooks, :connection_faults, 0),
        do: {:error, :connection},
        else: run_once(budget, opts)
    end

    defp backoff_ms(%{hooks: hooks}), do: Keyword.get(hooks, :backoff_ms, @backoff_ms)

    # `repo_opts:` adds repo options to the tenant read and the re-read
    # (e.g. `prepare: :unnamed`), through `Repo.with_call_options/2`.
    defp with_repo_opts(nil, fun), do: fun.()

    defp with_repo_opts(%{hooks: hooks}, fun) do
      case Keyword.get(hooks, :repo_opts, []) do
        [] -> fun.()
        repo_opts -> Repo.with_call_options(repo_opts, fun)
      end
    end

    # `after_call: fun` runs `fun.(step)` right after a read returned,
    # before its result is used (e.g. to make the result arrive late).
    defp after_call(nil, _step), do: :ok

    defp after_call(%{hooks: hooks}, step) do
      case Keyword.get(hooks, :after_call) do
        fun when is_function(fun, 1) -> fun.(step)
        _none -> :ok
      end
    end

    defp sleep(%{hooks: hooks}, ms), do: Keyword.get(hooks, :sleep, &Process.sleep/1).(ms)
  else
    defp barrier(_opts), do: :ok
    defp hooks(_opts), do: []
    defp observe(_budget, _message), do: :ok
    defp attempt(budget, opts, _n), do: run_once(budget, opts)
    defp backoff_ms(_budget), do: @backoff_ms
    defp with_repo_opts(_budget, fun), do: fun.()
    defp after_call(_budget, _step), do: :ok
    defp sleep(_budget, ms), do: Process.sleep(ms)
  end

  ## Registration

  @doc """
  Registers the tenant's `SDRAgent` definition (see the moduledoc, steps
  1-4): `{:ok, definition}`, `{:error, :bootstrap_in_transaction}`,
  `{:error, :definition_conflict}` or `{:error, class}`. Without a budget
  (`SdrAgent.SDR.bootstrap_definitions/1`) no timeout is set; `run/1`
  passes its budget (`budget:`), which bounds the registration
  transaction (client timeout, transaction-local lock and statement
  timeouts) and the post-rollback re-read.
  """
  def register(tenant_id, opts \\ []) do
    budget = Keyword.get(opts, :budget)

    if Repo.in_transaction?(),
      do: {:error, :bootstrap_in_transaction},
      else: registered(tenant_id, registration(tenant_id, budget), budget)
  rescue
    error -> {:error, classify(error)}
  end

  defp registered(_tenant_id, {:ok, definition}, _budget), do: validate(definition)
  # The budget was spent before the registration could start.
  defp registered(_tenant_id, {:error, :timeout}, _budget), do: {:error, :timeout}

  defp registered(tenant_id, {:error, error}, budget) do
    if winner_possible?(error),
      do: reread(tenant_id, error, budget),
      else: {:error, classify(error)}
  end

  defp registration(tenant_id, budget) do
    with {:ok, timeout} <- call_timeout(budget) do
      transaction_opts = client_timeout(timeout)
      observe_call(budget, :registration, transaction_opts)
      Audit.transaction(fn -> registered_row!(tenant_id, timeout) end, transaction_opts)
    end
  end

  # Inside the registration transaction: its bounds, then the register.
  defp registered_row!(tenant_id, timeout) do
    bound(timeout)

    case SDRAgent.register(tenant_id) do
      {:ok, definition} -> definition
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp bound(nil), do: :ok

  defp bound(timeout) do
    value = "#{timeout}ms"
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", [value], timeout: timeout)
    Repo.query!("SELECT set_config('statement_timeout', $1, true)", [value], timeout: timeout)
    :ok
  end

  defp client_timeout(nil), do: []
  defp client_timeout(timeout), do: [timeout: timeout]

  # A concurrent winner (the unique index) or an existing row of another
  # hash (`Agents.register_definition/2`'s refusal on `:definition`). The
  # error arrives in more than one shape: the hash refusal is our own
  # rollback of an `Ash.Error.Invalid`, but on the unique violation Ash
  # itself rolls the enclosing transaction back (`rollback_on_error?`,
  # default true) with its in-flight error (for example the changeset
  # carrying the `InvalidAttribute`), so every leaf error is inspected.
  defp winner_possible?(error), do: error |> leaves() |> Enum.any?(&winner_error?/1)

  defp winner_error?(%InvalidAttribute{private_vars: vars}) when is_list(vars) and vars != [],
    do: Keyword.get(vars, :constraint) == @unique_index

  defp winner_error?(%InvalidAttribute{field: :definition}), do: true
  defp winner_error?(_error), do: false

  # Outside any transaction (the registration's has ended): the row once,
  # with its own client timeout when there is a budget.
  defp reread(tenant_id, error, budget) do
    version = SDRAgent.version()

    with {:ok, timeout} <- call_timeout(budget) do
      read_opts = client_timeout(timeout)
      observe_call(budget, :reread, read_opts)

      query =
        AgentDefinition
        |> Ash.Query.for_read(:read, %{}, actor: SdrAgent.Actor.system(:kernel, tenant_id))
        |> Ash.Query.filter(
          tenant_id == ^tenant_id and name == "SDRAgent" and version == ^version
        )
        |> with_client_timeout(Keyword.get(read_opts, :timeout))

      read = with_repo_opts(budget, fn -> Ash.read_one(query) end)
      after_call(budget, :reread)

      case read do
        {:ok, %AgentDefinition{} = definition} -> validate(definition)
        {:ok, nil} -> {:error, classify(error)}
        {:error, read_error} -> {:error, classify(read_error)}
      end
    end
  end

  # AshPostgres passes `context.data_layer.timeout` to the repo call.
  defp with_client_timeout(query, nil), do: query

  defp with_client_timeout(query, timeout),
    do: Ash.Query.set_context(query, %{data_layer: %{timeout: timeout}})

  defp validate(%AgentDefinition{} = definition) do
    if valid?(definition),
      do: {:ok, definition},
      else: {:error, :definition_conflict}
  end

  defp valid?(definition) do
    definition.name == "SDRAgent" and definition.version == SDRAgent.version() and
      definition.status == :active and
      definition.definition_sha256 == SDRAgent.definition_sha256()
  end

  ## Sanitized classes

  # The leaf errors of an error class, a changeset or a list of them.
  defp leaves(errors) when is_list(errors), do: Enum.flat_map(errors, &leaves/1)
  defp leaves(%{errors: errors}) when is_list(errors), do: leaves(errors)
  defp leaves(error), do: [error]

  defp classify(error), do: error |> leaves() |> Enum.find_value(:crash, &leaf_class/1)

  defp leaf_class(%DBConnection.ConnectionError{}), do: :connection

  defp leaf_class(%Postgrex.Error{postgres: %{code: :undefined_table}}),
    do: :schema_not_migrated

  defp leaf_class(%Postgrex.Error{postgres: %{code: code}})
       when code in [:query_canceled, :lock_not_available],
       do: :timeout

  defp leaf_class(%{error: error}) when is_map(error),
    do: error |> leaves() |> Enum.find_value(&leaf_class/1)

  defp leaf_class(_error), do: nil

  ## Time

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
