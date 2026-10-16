defmodule SdrAgent.Inbox.CountLockTest do
  @moduledoc """
  C1 counts under real PostgreSQL table/head contention. Every process has
  its own sandbox:false connection; no shared sandbox serializes the race.
  Presence assertions precede contenders, so initial RED is assertion-only.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit
  alias SdrAgent.InboxConcurrencyFixtures, as: F
  alias SdrAgent.InboxFixtures
  alias SdrAgent.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    ctx = F.seed!()
    on_exit(fn -> F.connection(fn -> F.cleanup!(ctx) end) end)
    ctx
  end

  for role <- [:admin, :reviewer] do
    test "#{role} refresh does not wait for or append behind a held audit head", ctx do
      token = InboxFixtures.session!(Map.fetch!(ctx, unquote(role)))
      require_refresh!()
      F.require_count!()
      head = hold_head!(ctx)

      try do
        assert {{:ok, page}, elapsed} = F.timed(fn -> InboxFixtures.refresh(token) end)
        assert elapsed < 2_500
        assert page.completeness == :complete
        assert InboxFixtures.total!(page, :live_failures) == 1
        assert InboxFixtures.total!(page, :pending_email_drafts) == 0
        assert InboxFixtures.total!(page, :local_captures_this_week) == 0
        assert {:ok, []} = Audit.list_accesses(actor: ctx.admin)
      after
        F.release!([head])
      end
    end
  end

  test "auditor counts finish before its separate bounded append fails closed", ctx do
    token = InboxFixtures.session!(ctx.auditor)
    require_refresh!()
    F.require_count!()
    head = hold_head!(ctx)

    try do
      assert {{{:error, :audit_unavailable}, elapsed}, queries} =
               InboxFixtures.trace_queries(fn ->
                 F.timed(fn -> InboxFixtures.refresh(token) end)
               end)

      # 250 ms is scheduler/measurement tolerance, not an extended API budget.
      assert elapsed <= 2_750
      counts = Enum.filter(queries, &metric_aggregate?/1)
      assert length(counts) == 3
      F.assert_no_count_query!()

      assert %{rows: [[0]]} =
               Repo.query!("""
               SELECT count(*) FROM pg_stat_activity
               WHERE datname = current_database() AND pid <> pg_backend_pid()
                 AND wait_event_type = 'Lock'
               """)
    after
      F.release!([head])
    end

    assert {:ok, []} = Audit.list_accesses(actor: ctx.admin)
  end

  test "statement timeout cancels a blocked aggregate once and restores connection settings",
       ctx do
    F.require_count!()
    holder = F.hold!("LOCK TABLE failures IN ACCESS EXCLUSIVE MODE", [])

    try do
      assert {{{{:error, :timeout}, elapsed}, before_setting, after_setting}, queries} =
               InboxFixtures.trace_queries(fn ->
                 F.blocked_count(fn ->
                   F.count(actor: ctx.admin, count_timeout_ms: 750, statement_timeout_ms: 250)
                 end)
               end)

      assert elapsed <= 1_000
      counts = Enum.filter(queries, &metric_aggregate?/1)
      assert length(counts) == 1
      F.assert_no_count_query!()
      # The connection actually used for the timed-out query is reusable and
      # has its original setting; backend replacement is permitted.
      assert after_setting == before_setting
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    after
      F.release!([holder])
    end
  end

  test "default statement and total deadlines remain bounded without caller overrides", ctx do
    F.require_count!()
    holder = F.hold!("LOCK TABLE failures IN ACCESS EXCLUSIVE MODE", [])

    try do
      assert {{{:error, :timeout}, elapsed}, before_setting, after_setting} =
               F.blocked_count(fn -> F.count(actor: ctx.admin) end)

      assert elapsed <= 2_750
      assert after_setting == before_setting
      F.assert_no_count_query!()
    after
      F.release!([holder])
    end
  end

  defp hold_head!(ctx) do
    F.hold!(
      "SELECT tenant_id FROM audit_chain_heads WHERE tenant_id = $1 FOR UPDATE",
      [Ecto.UUID.dump!(ctx.tenant.id)]
    )
  end

  defp metric_aggregate?({sql, _}) do
    String.downcase(sql) =~ "count(" and
      Enum.any?(~w(failures drafts delivery_operations), &(sql =~ ~s(FROM "#{&1}")))
  end

  defp require_refresh! do
    assert Code.ensure_loaded?(SdrAgent.Inbox) and
             function_exported?(SdrAgent.Inbox, :refresh, 2),
           "C1-02 Inbox.refresh/2 authorized bounded projection is not implemented"
  end
end
