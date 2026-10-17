defmodule SdrAgent.Inbox.QueryPlanTest do
  @moduledoc """
  Execute EXPLAIN against the aggregate SQL actually emitted by Home, never
  a hand-written substitute. Failure cardinality includes many foreign rows;
  Draft/capture plans use smaller end-to-end domain fixtures. No planner
  switches influence the default-plan check. A separate diagnostic with
  seq scans discouraged proves a tenant/status index is usable; this is
  not a production-scale benchmark.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures

  alias SdrAgent.OutreachFixtures

  @tag timeout: 120_000
  test "large authorized and foreign Failure sets stay scalar, exact and tenant-filtered", ctx do
    own = for _ <- 1..128, do: failure!(ctx)
    foreign = for _ <- 1..1_920, do: failure!(ctx)
    ids = Enum.map(foreign, &Ecto.UUID.dump!(&1.id))

    # API-created fixtures only. Model a legacy foreign tenant in this
    # rollback-only sandbox: the application must filter it in SQL.
    Repo.query!("SET LOCAL session_replication_role = replica")

    assert %{num_rows: 1_920} =
             Repo.query!("UPDATE failures SET tenant_id = $1 WHERE id = ANY($2::uuid[])", [
               Ecto.UUID.dump!(Ecto.UUID.generate()),
               ids
             ])

    Repo.query!("SET LOCAL session_replication_role = origin")
    Repo.query!("ANALYZE failures")
    session = session!(ctx.admin)

    {{:ok, page}, queries} = trace_queries(fn -> refresh(session, limit: 3) end)
    assert total!(page, :live_failures) == 128
    own_ids = MapSet.new(own, & &1.id)
    assert length(page.items) == 3
    assert Enum.all?(page.items, &MapSet.member?(own_ids, &1.subject_ref.id))
    {sql, params} = aggregate!(queries, "failures")
    plan = explain!(sql, params)
    encoded = Jason.encode!(plan["Plan"])
    assert encoded =~ "tenant_id"
    assert encoded =~ "status"
    assert encoded =~ ctx.tenant.id
    scans = scan_nodes(plan["Plan"])
    predicates = Enum.map_join(scans, " ", &scan_predicates/1)
    assert predicates =~ "tenant_id"
    assert predicates =~ "status"

    # Do not require the default planner to pick an index at 2k rows.
    # Separately prove the required tenant/status index can serve this SQL.
    Repo.query!("SET LOCAL enable_seqscan = off")

    try do
      indexed = explain!(sql, params)
      names = indexed["Plan"] |> scan_nodes() |> Enum.map(& &1["Index Name"])

      assert %{rows: indexes} =
               Repo.query!("""
               SELECT indexname FROM pg_indexes
               WHERE schemaname = 'public' AND tablename = 'failures'
                 AND indexdef ~ '\\(tenant_id, status[,)]'
               """)

      assert indexes != []
      assert Enum.any?(indexes, fn [name] -> name in names end)
    after
      Repo.query!("SET LOCAL enable_seqscan = on")
    end
  end

  test "all three actual metric plans return one scalar without body or counted-id loads", ctx do
    %{delivery: delivery} = OutreachFixtures.approved!(ctx)
    assert %{success: 1} = OutreachFixtures.deliver!()
    assert OutreachFixtures.outreach!(ctx, delivery).accepted_at
    OutreachFixtures.drafted!(ctx, "02")
    failure!(ctx)
    session = session!(ctx.admin)

    {{:ok, page}, queries} = trace_queries(fn -> refresh(session) end)
    assert total!(page, :live_failures) == 1
    assert total!(page, :pending_email_drafts) == 1
    assert total!(page, :local_captures_this_week) == 1

    for table <- ~w(failures drafts delivery_operations) do
      {sql, params} = aggregate!(queries, table)
      refute sql =~ ~r/\b(LIMIT|OFFSET)\b/i
      refute sql =~ ~r/"(body_text|content|parsed_output|stderr)"/
      plan = explain!(sql, params)
      assert Jason.encode!(plan["Plan"]) =~ "tenant_id"
    end
  end

  defp aggregate!(queries, table) do
    assert [query] =
             Enum.filter(queries, fn {sql, _} ->
               sql =~ ~s(FROM "#{table}") and String.downcase(sql) =~ "count("
             end)

    query
  end

  defp explain!(sql, params) do
    assert %{rows: [[[plan]]]} =
             Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)

    assert plan["Plan"]["Actual Rows"] == 1
    assert plan["Execution Time"] < 2_000
    refute Jason.encode!(plan["Plan"]) =~ ~r/\b(body_text|parsed_output|stderr)\b/
    plan
  end

  defp scan_nodes(node) do
    own = if node["Relation Name"] == "failures" or node["Index Name"], do: [node], else: []
    own ++ Enum.flat_map(node["Plans"] || [], &scan_nodes/1)
  end

  defp scan_predicates(node) do
    Enum.map_join(["Index Cond", "Recheck Cond", "Filter"], " ", &(node[&1] || ""))
  end
end
