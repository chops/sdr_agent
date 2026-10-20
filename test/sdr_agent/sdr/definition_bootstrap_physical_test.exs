defmodule SdrAgent.SDR.DefinitionBootstrapPhysicalTest do
  @moduledoc """
  C3-02 RED-2, plan r8 section 11 N [P] (T-N10, T-N11): the definition
  bootstrap on independent physical connections with committed synthetic
  rows (sections 7.2 and 7.3). Kept apart from
  `definition_bootstrap_test.exs` because these tests commit.

  - T-N10: a retained committed tenant gets its definition from
    `DefinitionBootstrap.run/1`; a tenant created after boot (boot saw no
    tenant) gets it from `SDR.bootstrap_definitions/1`; a deadline gives
    `{:error, {:definition_bootstrap_failed, :timeout}}`, then a second run
    converges (idempotent). The test does not assert that nothing
    committed: the kill can race the commit (section 7.3).
  - T-N11: a different-hash winner committed while the bootstrap's INSERT
    waits on the unique index makes the post-violation re-read (outside a
    transaction) return `{:error, :definition_conflict}`.

  Connections: the module runs in sandbox `:auto` mode (the pattern of
  `test/sdr_agent/inbox/count_pool_test.exs:20-21` and
  `agents/profile_switch_resolve_race_test.exs:57-61`), restored to
  `:manual` on exit, because `start_link/1` runs its work in a process it
  spawns (`spawn_monitor`), which a `Sandbox.checkout(Repo, sandbox:
  false)` owner could not share; every process checks out its own physical
  connection.

  Committed-row safety (`InboxConcurrencyFixtures.assert_test_database!/0`
  and the tenant-scoped cleanup pattern of
  `test/support/inbox_concurrency_fixtures.ex:48-81`): every subject is
  guarded and the database name checked before anything commits; the
  database must hold no tenant before the test bootstraps its own, and the
  cleanup deletes only rows whose `tenant_id` is that tenant, then the
  tenant row. Provenance snapshots are global and are not touched.

  RED form: structural (every subject is new); interface names as in
  `SdrAgent.SDR.DefinitionBootstrapTest` (`run/1`, `start_link/1` with
  `deadline_ms:`, `disposition/1`, `bootstrap_definitions/1`,
  `fetch_definition/1`).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Agents.AgentDefinition
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Repo
  alias SdrAgent.SDR.SDRAgent

  @sdr SdrAgent.SDR
  @bootstrap SdrAgent.SDR.DefinitionBootstrap
  @lookup SdrAgent.SDR.SDRAgent
  @wait_ms 10_000

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)
    :ok
  end

  describe "T-N10" do
    test "T-N10 a retained committed tenant gets its committed definition from run/1, once" do
      preflight!()
      tenant = commit_tenant!()
      first = run_bootstrap([])

      assert match?({:ok, [%AgentDefinition{}]}, first),
             "C3-02: run/1 registers for the retained tenant: #{short(first)}"

      {:ok, [definition]} = first
      assert_valid!(definition, tenant.id)
      assert elsewhere(fn -> ids(definitions(tenant.id)) end) == [definition.id]
      assert {:ok, [again]} = run_bootstrap([])
      assert again.id == definition.id
      assert registered_events(tenant.id) == 1, "C3-02: a second run writes nothing"
    end

    test "T-N10 a tenant created after boot gets its committed definition" do
      preflight!()
      assert run_bootstrap([]) == :no_tenant, "C3-02: boot with no tenant"
      assert start_child([]) == :ignore
      tenant = commit_tenant!()
      result = bootstrap_definitions(tenant.id)
      assert match?({:ok, %AgentDefinition{}}, result), "C3-02: got #{short(result)}"
      {:ok, definition} = result
      assert_valid!(definition, tenant.id)
      assert elsewhere(fn -> ids(definitions(tenant.id)) end) == [definition.id]
    end

    test "T-N10 a deadline is :timeout, then a second run converges" do
      preflight!()
      tenant = commit_tenant!()

      assert start_child(deadline_ms: 0) == {:error, {:definition_bootstrap_failed, :timeout}},
             "C3-02: the deadline gives the sanitized :timeout class"

      # Not asserted: that nothing committed (`:timeout` means "not confirmed").
      converged = run_bootstrap([])

      assert match?({:ok, [%AgentDefinition{}]}, converged),
             "C3-02: the next run converges: #{short(converged)}"

      {:ok, [definition]} = converged
      assert_valid!(definition, tenant.id)
      assert {:ok, [again]} = run_bootstrap([])
      assert again.id == definition.id
      assert elsewhere(fn -> ids(definitions(tenant.id)) end) == [definition.id]
      assert registered_events(tenant.id) == 1
    end
  end

  describe "T-N11" do
    test "T-N11 the post-violation re-read rejects a different-hash winner" do
      preflight!()
      tenant = commit_tenant!()
      holder = hold_winner!(tenant)
      loser = Task.async(fn -> bootstrap_definitions(tenant.id) end)
      await_waiter!(holder.backend)
      send(holder.task.pid, {holder.tag, :release})
      assert Task.await(holder.task, @wait_ms) == {:ok, holder.winner_id}

      assert Task.await(loser, @wait_ms) == {:error, :definition_conflict},
             "C3-02: a different-hash winner is rejected after the unique violation"

      assert [winner] = definitions(tenant.id)
      assert winner.id == holder.winner_id
      refute winner.definition_sha256 == code_sha()
      assert fetch_definition(tenant.id) == {:error, :agent_definition_unavailable}
      assert registered_events(tenant.id) == 1, "C3-02: the loser appended no event"
    end
  end

  ## Committed rows

  # Guards every subject, then the database, before anything commits.
  defp preflight! do
    present!(@sdr, :bootstrap_definitions, 1)
    present!(@lookup, :fetch_definition, 1)
    present!(@bootstrap, :run, 1)
    present!(@bootstrap, :start_link, 1)
    present!(@bootstrap, :disposition, 1)
    InboxConcurrencyFixtures.assert_test_database!()

    assert match?(%{rows: [[0]]}, Repo.query!("SELECT count(*) FROM tenants")),
           "precondition: the test database holds no committed tenant"
  end

  defp commit_tenant! do
    assert {:ok, tenant} = Audit.bootstrap(slug: "c302-bootstrap", name: "Synthetic C3-02")
    on_exit(fn -> cleanup!(tenant.id) end)
    tenant
  end

  defp cleanup!(tenant_id) do
    InboxConcurrencyFixtures.assert_test_database!()
    raw = Ecto.UUID.dump!(tenant_id)

    assert {:ok, _} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL session_replication_role = replica")
               Enum.each(tenant_tables(), &delete_tenant_rows!(&1, raw))

               assert %{num_rows: 1} =
                        Repo.query!("DELETE FROM tenants WHERE id = $1", [raw])
             end)

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM tenants WHERE id = $1", [raw])
  end

  defp tenant_tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.table_name
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name
      WHERE c.table_schema = 'public' AND c.column_name = 'tenant_id'
        AND t.table_type = 'BASE TABLE' AND c.table_name <> 'tenants'
      """)

    List.flatten(rows)
  end

  defp delete_tenant_rows!(table, raw),
    do: Repo.query!(~s(DELETE FROM "#{table}" WHERE tenant_id = $1), [raw])

  # Registers a different-hash SDRAgent row of the code's version inside an
  # open transaction on its own connection, holding the unique index entry.
  defp hold_winner!(tenant) do
    parent = self()
    tag = make_ref()

    task =
      Task.async(fn ->
        Audit.transaction(fn ->
          {:ok, winner} = Agents.register_definition(different(), actor: kernel(tenant))
          send(parent, {tag, :held, backend(), winner.id})
          await_release(tag, winner.id)
        end)
      end)

    assert_receive {^tag, :held, backend, winner_id}, @wait_ms
    %{task: task, tag: tag, backend: backend, winner_id: winner_id}
  end

  defp await_release(tag, winner_id) do
    receive do
      {^tag, :release} -> winner_id
    after
      @wait_ms -> Repo.rollback(:holder_not_released)
    end
  end

  defp different do
    %{
      name: "SDRAgent",
      version: SDRAgent.version(),
      module: inspect(SDRAgent),
      definition: %{"c302" => "different-hash-winner"}
    }
  end

  defp kernel(tenant), do: Actor.system(:kernel, tenant.id)

  ## Waits

  defp await_waiter!(holder_backend) do
    poll_waiter(holder_backend, System.monotonic_time(:millisecond) + @wait_ms)
  end

  defp poll_waiter(holder_backend, deadline) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pid FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
          AND $1 = ANY(pg_blocking_pids(pid))
        """,
        [holder_backend]
      )

    cond do
      rows != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("C3-02: the bootstrap never waited on the winner's uncommitted row")

      true ->
        Process.sleep(20)
        poll_waiter(holder_backend, deadline)
    end
  end

  defp backend do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp elsewhere(fun), do: fun |> Task.async() |> Task.await(@wait_ms)

  ## Reads and assertions

  defp definitions(tenant_id) do
    code_version = SDRAgent.version()

    AgentDefinition
    |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and name == "SDRAgent" and version == ^code_version
    )
    |> Ash.read!()
    |> Enum.sort_by(& &1.id)
  end

  defp ids(definitions), do: Enum.map(definitions, & &1.id)

  defp registered_events(tenant_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM audit_events
        WHERE tenant_id = $1 AND event_type = 'agents.definition.registered'
        """,
        [Ecto.UUID.dump!(tenant_id)]
      )

    count
  end

  defp assert_valid!(definition, tenant_id) do
    assert {definition.tenant_id, definition.name, definition.version, definition.status} ==
             {tenant_id, "SDRAgent", SDRAgent.version(), :active}

    assert definition.definition_sha256 == code_sha(), "C3-02: the hash of current code"
  end

  defp code_sha, do: Canonical.sha256(SDRAgent.definition_body())

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp bootstrap_definitions(tenant_id), do: call(@sdr, :bootstrap_definitions, [tenant_id])
  defp fetch_definition(tenant_id), do: call(@lookup, :fetch_definition, [tenant_id])
  defp run_bootstrap(opts), do: call(@bootstrap, :run, [opts])

  # start_link/1 links the child to the caller: trap exits around it so a
  # refused start reaches the assertion as a value.
  defp start_child(opts) do
    previous = Process.flag(:trap_exit, true)

    try do
      call(@bootstrap, :start_link, [opts])
    after
      Process.flag(:trap_exit, previous)
      flush_exits()
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp short(term), do: inspect(term, limit: 12, printable_limit: 300)
end
