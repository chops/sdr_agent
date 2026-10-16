defmodule SdrAgent.InboxConcurrencyFixtures do
  @moduledoc """
  Committed synthetic fixtures for C1 read contention tests. Callers use
  independent non-sandboxed connections, except the dedicated pool-wait
  module's reviewed automatic-checkout interval. Cleanup targets only the
  fixture's tenant id and its users' token subjects in a verified test DB.
  """

  import ExUnit.Assertions

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.InboxFixtures
  alias SdrAgent.Repo

  @doc "Create a new owned tenant, three operators and one live Failure."
  def seed! do
    assert_test_database!()
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM tenants")
    assert {:ok, tenant} = Audit.bootstrap(slug: "inbox-contention", name: "Synthetic Inbox")
    admin = AuditCase.new_human(:admin, tenant)
    reviewer = AuditCase.new_human(:reviewer, tenant)
    auditor = AuditCase.new_human(:auditor, tenant)

    ctx = %{
      tenant: tenant,
      admin: admin,
      reviewer: reviewer,
      auditor: auditor,
      agent: AuditCase.system_actor(:agent_runtime, tenant)
    }

    Map.put(ctx, :failure, InboxFixtures.failure!(ctx))
  end

  @doc "Check out one real connection, always returning it on exit."
  def connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  @doc "Delete only this fixture's committed rows; never another tenant's data."
  def cleanup!(ctx) do
    assert_test_database!()
    tenant_id = Ecto.UUID.dump!(ctx.tenant.id)

    subjects =
      Enum.map([ctx.admin, ctx.reviewer, ctx.auditor], &AshAuthentication.user_to_subject/1)

    assert {:ok, _} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL session_replication_role = replica")
               Repo.query!("DELETE FROM tokens WHERE subject = ANY($1::text[])", [subjects])

               # Provenance snapshots are global, content-addressed metadata;
               # they have no tenant_id and are not owned by this fixture.
               for table <- ~w(audit_accesses failures audit_events audit_chain_heads users) do
                 Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1", [tenant_id])
               end

               assert %{num_rows: 1} =
                        Repo.query!("DELETE FROM tenants WHERE id = $1", [tenant_id])
             end)

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM tenants WHERE id = $1", [tenant_id])
  end

  @doc "Guard every committed fixture/cleanup operation by the actual DB name."
  def assert_test_database! do
    expected = "sdr_agent_test" <> (System.get_env("MIX_TEST_PARTITION") || "")
    assert Mix.env() == :test
    assert Repo.config()[:database] == expected
    assert %{rows: [[^expected]]} = Repo.query!("SELECT current_database()")
    :ok
  end

  @doc "Assert the absent count API before starting contenders or taking locks."
  def require_count! do
    assert function_exported?(SdrAgent.Operations, :count_inbox_failures, 1),
           "C1-02 source-owned count_inbox_failures/1 is not implemented"
  end

  @doc "Call the fixed Failure count boundary, never caller-selected dispatch."
  def count(opts), do: apply(SdrAgent.Operations, :count_inbox_failures, [opts])

  @doc "Hold a connection/transaction until explicitly released (bounded fallback)."
  def hold!(sql, params, checkout? \\ true) do
    parent = self()
    tag = make_ref()

    work = fn ->
      Repo.transaction(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        Repo.query!(sql, params)
        send(parent, {tag, :held, backend})

        receive do
          {^tag, :release} -> :released
        after
          5_000 -> Repo.rollback(:holder_not_released)
        end
      end)
    end

    task = Task.async(fn -> if checkout?, do: connection(work), else: work.() end)
    assert_receive {^tag, :held, backend}, 2_000
    %{task: task, tag: tag, backend: backend}
  end

  @doc "Release holders and join them before cleanup or mode restoration."
  def release!(holders) do
    for holder <- holders, do: send(holder.task.pid, {holder.tag, :release})

    for holder <- holders do
      assert {:ok, :released} = Task.await(holder.task, 2_000)
    end
  end

  @doc "Measure the API call, excluding fixture and holder setup."
  def timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  @doc "A separate diagnostic connection, outside the exhausted Repo pool."
  def observer(fun) do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    {:ok, pid} = Postgrex.start_link(opts)

    try do
      fun.(pid)
    after
      GenServer.stop(pid)
    end
  end

  @doc "Count only this isolated DB's active Failure aggregates, including lock waiters."
  def count_queries(observer \\ Repo) do
    sql = """
       SELECT count(*) FROM pg_stat_activity
       WHERE datname = current_database() AND pid <> pg_backend_pid()
         AND state = 'active'
         AND query ILIKE '%count(%' AND query ILIKE '%"failures"%'
    """

    result =
      if observer == Repo, do: Repo.query!(sql), else: Postgrex.query!(observer, sql, [])

    assert %{rows: [[n]]} = result
    n
  end

  @doc "Cancel may be asynchronous, but a query must disappear within 250 ms."
  def assert_no_count_query!(observer \\ Repo) do
    assert poll(fn -> count_queries(observer) == 0 end, 250),
           "a Failure aggregate remained active after its API returned"
  end

  @doc "Prove the table-lock oracle sees the query, not just the holder."
  def blocked_count(fun) do
    assert count_queries() == 0

    task =
      Task.async(fn ->
        connection(fn ->
          before_timeout = timeout_setting!()
          result = timed(fun)
          {result, before_timeout, timeout_setting!()}
        end)
      end)

    try do
      assert poll(fn -> count_queries() == 1 end, 1_000),
             "the aggregate never became visible while blocked on the held table"

      Task.await(task, 3_500)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp timeout_setting! do
    assert %{rows: [[timeout]]} = Repo.query!("SELECT current_setting('statement_timeout')")
    timeout
  end

  defp poll(check, timeout) do
    poll_until(check, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll_until(check, deadline) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        poll_until(check, deadline)
    end
  end
end
