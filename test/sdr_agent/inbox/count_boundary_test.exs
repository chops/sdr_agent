defmodule SdrAgent.Inbox.CountBoundaryTest do
  @moduledoc """
  C1-02 public source-owned count boundaries: human read policies, scalar
  outputs, server-only lowerable deadlines, and a validated capture window.
  Pool/lock cancellation is exercised separately on independent connections.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [drafted!: 1, operator!: 2]

  alias SdrAgent.Actor
  alias SdrAgent.Operations
  alias SdrAgent.Outreach

  @window %{
    week_start_utc: ~U[2026-01-05 07:00:00.000000Z],
    next_week_start_utc: ~U[2026-01-12 07:00:00.000000Z]
  }

  for role <- [:admin, :reviewer, :auditor] do
    test "#{role} source counts equal authorized membership and return only scalars", ctx do
      drafted!(ctx)
      failure!(ctx)
      actor = if unquote(role) == :admin, do: ctx.admin, else: operator!(ctx, unquote(role))
      assert {:ok, drafts} = Outreach.list_review_queue(actor: actor)
      assert {:ok, failures} = Operations.list_attention(actor: actor)

      assert {:ok, draft_total} = source_count(:pending_email_drafts, actor: actor)
      assert {:ok, failure_total} = source_count(:live_failures, actor: actor)
      assert {:ok, capture_total} = source_count(:local_captures_this_week, actor: actor)
      assert draft_total == length(drafts)
      assert failure_total == length(failures)
      assert capture_total == 0
      assert Enum.all?([draft_total, failure_total, capture_total], &is_integer/1)
    end
  end

  test "missing and system actors cannot use Home's count-only source boundary", ctx do
    failure!(ctx)
    actors = [nil | Enum.map(Actor.types(), &Actor.system(&1, ctx.tenant.id))]

    for actor <- actors,
        metric <- [:pending_email_drafts, :live_failures, :local_captures_this_week] do
      assert {:error, :forbidden} = source_count(metric, actor: actor)
    end
  end

  test "valid server limits can lower both ceilings without changing exact membership", ctx do
    failure!(ctx)

    assert {:ok, 1} =
             source_count(:live_failures,
               actor: ctx.admin,
               count_timeout_ms: 500,
               statement_timeout_ms: 250
             )
  end

  test "invalid or above-ceiling server limits fail closed rather than disabling a deadline",
       ctx do
    failure!(ctx)

    for overrides <- [
          [count_timeout_ms: 0],
          [count_timeout_ms: -1],
          [count_timeout_ms: :infinity],
          [count_timeout_ms: "2500"],
          [count_timeout_ms: 2501],
          [statement_timeout_ms: 0],
          [statement_timeout_ms: -1],
          [statement_timeout_ms: :infinity],
          [statement_timeout_ms: "2000"],
          [statement_timeout_ms: 2001],
          [count_timeout_ms: 100, statement_timeout_ms: 100],
          [count_timeout_ms: 100, statement_timeout_ms: 101]
        ] do
      assert {{:error, :invalid_input}, queries} =
               trace_queries(fn ->
                 source_count(:live_failures, Keyword.put(overrides, :actor, ctx.admin))
               end)

      refute Enum.any?(queries, fn {sql, _} -> String.downcase(sql) =~ "count(" end)
    end
  end

  test "capture count refuses malformed, non-UTC, reversed or implausible windows", ctx do
    start_at = @window.week_start_utc
    end_at = @window.next_week_start_utc

    for window <- [
          nil,
          %{},
          %{week_start_utc: start_at},
          %{week_start_utc: "2026-01-05", next_week_start_utc: end_at},
          %{week_start_utc: end_at, next_week_start_utc: start_at},
          %{week_start_utc: start_at, next_week_start_utc: start_at},
          %{week_start_utc: start_at, next_week_start_utc: DateTime.add(start_at, 166, :hour)},
          %{week_start_utc: start_at, next_week_start_utc: DateTime.add(start_at, 170, :hour)},
          %{
            week_start_utc: DateTime.shift_zone!(start_at, "America/Denver", Tz.TimeZoneDatabase),
            next_week_start_utc: end_at
          }
        ] do
      assert {{:error, :invalid_input}, queries} =
               trace_queries(fn -> capture_count(window, actor: ctx.admin) end)

      refute Enum.any?(queries, fn {sql, _} -> sql =~ ~s(FROM "delivery_operations") end)
    end
  end

  defp source_count(:pending_email_drafts, opts),
    do: invoke(Outreach, :count_inbox_drafts, [opts])

  defp source_count(:live_failures, opts),
    do: invoke(Operations, :count_inbox_failures, [opts])

  defp source_count(:local_captures_this_week, opts), do: capture_count(@window, opts)

  defp capture_count(window, opts), do: invoke(Outreach, :count_inbox_captures, [window, opts])

  defp invoke(module, function, args) do
    assert Code.ensure_loaded?(module) and function_exported?(module, function, length(args)),
           "C1-02 source-owned #{function}/#{length(args)} is not implemented"

    apply(module, function, args)
  end
end
