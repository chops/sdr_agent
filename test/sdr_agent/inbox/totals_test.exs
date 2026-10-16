defmodule SdrAgent.Inbox.TotalsTest do
  @moduledoc "C1-02 exact authorized scalar totals and local capture history."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [approved!: 1, deliver!: 0, outreach!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Clock
  alias SdrAgent.Operations

  test "one logical committed capture counts once even if its job is replayed", ctx do
    %{delivery: delivery} = approved!(ctx)
    assert %{success: 1} = deliver!()
    accepted = outreach!(ctx, delivery)
    assert accepted.accepted_at

    assert {:ok, _} =
             %{"delivery_operation_id" => delivery.id, "tenant_id" => ctx.tenant.id}
             |> SdrAgent.Outreach.DeliveryWorker.new()
             |> Oban.insert()

    assert %{success: 1} = deliver!()
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert total!(page, :local_captures_this_week) == 1
    assert total!(page, :pending_email_drafts) == 0
    assert total!(page, :live_failures) == 0
    assert page.items == []
    total = page.totals.local_captures_this_week
    assert total.timezone == "America/Denver"
    assert total.week_start_utc == ~U[2026-01-05 07:00:00.000000Z]
    assert total.next_week_start_utc == ~U[2026-01-12 07:00:00.000000Z]
  end

  test "requested but unaccepted capture is not history or a pending inbox item", ctx do
    %{delivery: delivery} = approved!(ctx)
    assert delivery.accepted_at == nil
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert total!(page, :local_captures_this_week) == 0
    assert page.items == []
  end

  test "history includes an acceptance up to but not at the next local Monday boundary", ctx do
    approved!(ctx)
    assert %{success: 1} = deliver!()
    session = session!(ctx.admin)
    Clock.freeze(~U[2026-01-12 06:59:59.999999Z])

    assert {:ok, sunday} = refresh(session)
    assert total!(sunday, :local_captures_this_week) == 1
    Clock.freeze(~U[2026-01-12 07:00:00.000000Z])
    assert {:ok, monday} = refresh(session)
    assert total!(monday, :local_captures_this_week) == 0

    assert monday.totals.local_captures_this_week.week_start_utc ==
             ~U[2026-01-12 07:00:00.000000Z]
  end

  for {label, now, start_at, end_at, hours} <- [
        {"spring", ~U[2026-03-08 18:00:00.000000Z], ~U[2026-03-02 07:00:00.000000Z],
         ~U[2026-03-09 06:00:00.000000Z], 167},
        {"fall", ~U[2026-11-01 18:00:00.000000Z], ~U[2026-10-26 06:00:00.000000Z],
         ~U[2026-11-02 07:00:00.000000Z], 169}
      ] do
    test "#{label} DST history uses local Monday boundaries, not fixed 168 hours", ctx do
      session = session!(ctx.admin)
      Clock.freeze(unquote(Macro.escape(now)))

      assert {:ok, page} = refresh(session)
      total = page.totals.local_captures_this_week
      assert total.week_start_utc == unquote(Macro.escape(start_at))
      assert total.next_week_start_utc == unquote(Macro.escape(end_at))

      assert DateTime.diff(total.next_week_start_utc, total.week_start_utc, :hour) ==
               unquote(hours)

      assert total!(page, :local_captures_this_week) == 0
    end
  end

  test "resolved historical run cause is excluded; a distinct live Operation cause remains",
       ctx do
    %{run: run, operation: operation, agent: agent} = AgentsFixtures.operated_run(ctx.tenant)

    assert {:ok, stopped} =
             Agents.fail_run(
               run,
               %{status_reason: :provider_error, failure_reason: "Synthetic stop"},
               actor: agent
             )

    assert {:ok, cause} = Operations.get_failure(stopped.attention_failure_id, actor: ctx.admin)

    assert {:ok, _} =
             Operations.resolve_failure(cause, %{resolution_note: "Original cause resolved"},
               actor: ctx.admin
             )

    assert {:ok, _} =
             Operations.fail_operation(
               operation,
               %{
                 failure: %{
                   class: :budget_exhausted,
                   severity: :critical,
                   message: "Operation still needs repair; original cause #{cause.id}",
                   retryable: false
                 }
               },
               actor: agent
             )

    assert {:ok, [live]} = Operations.list_attention(actor: ctx.admin)
    refute live.id == cause.id
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert total!(page, :live_failures) == 1
    assert Enum.map(page.items, & &1.subject_ref.id) == [live.id]
  end

  test "each metric uses one aggregate query with no cursor, limit or counted-member loads",
       ctx do
    failure!(ctx)
    session = session!(ctx.admin)

    {{:ok, _}, queries} = trace_queries(fn -> refresh(session, limit: 1) end)
    counts = Enum.filter(queries, fn {sql, _} -> String.downcase(sql) =~ "count(" end)
    assert length(counts) == 3

    for {sql, _params} <- counts do
      refute sql =~ "LIMIT"
      refute sql =~ "OFFSET"
      refute sql =~ ~r/\ASELECT\s+\w+\."id"\s*,/i
      refute sql =~ ~r/"(body_text|content|parsed_output|stderr)"/
    end

    history = Enum.filter(queries, fn {sql, _} -> sql =~ ~s(FROM "delivery_operations") end)
    assert length(history) == 1
    assert Enum.all?(history, fn {sql, _} -> String.downcase(sql) =~ "count(" end)
  end
end
