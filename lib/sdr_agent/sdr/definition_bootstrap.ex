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

  **Inside `run/1`:** one tenant enumeration (KRN; at most the singleton
  tenant), then per tenant one registration plus at most one
  post-violation re-read; a `:connection` failure is retried up to 3 times
  with a 2 s backoff while time remains. Each registration transaction's
  `lock_timeout` and `statement_timeout` are `min(remaining, 5 s)`.

  Test-seam builds only (`:claude_cli_test_seams`, compile time; absent from
  dev and prod): `start_link/1` takes `test_barrier: pid`. The worker, once
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
  `deadline_ms:` (from now; default from config).
  """
  def run(opts) do
    deadline =
      Keyword.get_lazy(opts, :deadline, fn ->
        now() + Keyword.get(opts, :deadline_ms, configured_deadline_ms())
      end)

    with_retries(deadline, @connection_retries, fn -> run_once(deadline, opts) end)
  end

  defp with_retries(deadline, retries, fun) do
    case fun.() do
      {:error, :connection} when retries > 0 ->
        if remaining(deadline) > @backoff_ms do
          Process.sleep(@backoff_ms)
          with_retries(deadline, retries - 1, fun)
        else
          {:error, :connection}
        end

      outcome ->
        outcome
    end
  end

  defp run_once(deadline, opts) do
    case tenant() do
      :no_tenant ->
        :no_tenant

      {:ok, tenant_id} ->
        barrier(opts)

        case register(tenant_id, step_ms: min(remaining(deadline), @step_ms)) do
          {:ok, definition} -> {:ok, [definition]}
          {:error, :bootstrap_in_transaction} -> {:error, :crash}
          {:error, class} -> {:error, class}
        end

      {:error, class} ->
        {:error, class}
    end
  end

  defp tenant do
    case Kernel.singleton_tenant_id() do
      {:ok, tenant_id} -> {:ok, tenant_id}
      {:error, :tenant_not_bootstrapped} -> :no_tenant
      {:error, error} -> {:error, classify(error)}
    end
  rescue
    error -> {:error, classify(error)}
  end

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
  else
    defp barrier(_opts), do: :ok
  end

  ## Registration

  @doc """
  Registers the tenant's `SDRAgent` definition (see the moduledoc, steps
  1-4): `{:ok, definition}`, `{:error, :bootstrap_in_transaction}`,
  `{:error, :definition_conflict}` or `{:error, class}`. Options:
  `step_ms:` bounds the registration transaction's lock and statement
  waits (the boot run); without it no timeout is set.
  """
  def register(tenant_id, opts \\ []) do
    if Repo.in_transaction?(),
      do: {:error, :bootstrap_in_transaction},
      else: registered(tenant_id, registration(tenant_id, Keyword.get(opts, :step_ms)))
  rescue
    error -> {:error, classify(error)}
  end

  defp registered(_tenant_id, {:ok, definition}), do: validate(definition)

  defp registered(tenant_id, {:error, error}) do
    if winner_possible?(error),
      do: reread(tenant_id, error),
      else: {:error, classify(error)}
  end

  defp registration(tenant_id, step_ms) do
    Audit.transaction(fn ->
      bound(step_ms)

      case SDRAgent.register(tenant_id) do
        {:ok, definition} -> definition
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp bound(nil), do: :ok

  defp bound(step_ms) do
    value = "#{max(step_ms, 1)}ms"
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", [value])
    Repo.query!("SELECT set_config('statement_timeout', $1, true)", [value])
    :ok
  end

  # A concurrent winner (the unique index) or an existing row of another
  # hash (`Agents.register_definition/2`'s refusal on `:definition`).
  defp winner_possible?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &winner_error?/1)

  defp winner_possible?(_error), do: false

  defp winner_error?(%InvalidAttribute{private_vars: vars}) when is_list(vars) and vars != [],
    do: Keyword.get(vars, :constraint) == @unique_index

  defp winner_error?(%InvalidAttribute{field: :definition}), do: true
  defp winner_error?(_error), do: false

  # Outside any transaction (the registration's has ended): the row once.
  defp reread(tenant_id, error) do
    version = SDRAgent.version()

    AgentDefinition
    |> Ash.Query.for_read(:read, %{}, actor: SdrAgent.Actor.system(:kernel, tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and name == "SDRAgent" and version == ^version)
    |> Ash.read_one()
    |> case do
      {:ok, %AgentDefinition{} = definition} -> validate(definition)
      {:ok, nil} -> {:error, classify(error)}
      {:error, read_error} -> {:error, classify(read_error)}
    end
  end

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

  defp classify(%DBConnection.ConnectionError{}), do: :connection

  defp classify(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: :schema_not_migrated

  defp classify(%Postgrex.Error{postgres: %{code: code}})
       when code in [:query_canceled, :lock_not_available],
       do: :timeout

  defp classify(%{errors: errors}) when is_list(errors), do: first_class(errors)
  defp classify(%{error: error}) when is_map(error), do: classify(error)
  defp classify(_error), do: :crash

  defp first_class(errors) do
    Enum.find_value(errors, :crash, fn error ->
      case classify(error) do
        :crash -> nil
        class -> class
      end
    end)
  end

  ## Time

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
