defmodule SdrAgent.Inbox.PageTest do
  @moduledoc "C1-02 merged metadata projection and global continuation contract."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [drafted!: 1, revision!: 2, contact!: 2]

  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Outreach
  alias SdrAgent.Sales

  test "a complete empty refresh has three successful zero totals and no cursor", ctx do
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert page.items == []
    assert page.completeness == :complete
    assert page.errors == []
    assert page.next_cursor == nil
    assert %DateTime{} = page.observed_at

    for metric <- [:pending_email_drafts, :live_failures, :local_captures_this_week] do
      assert total!(page, metric) == 0
    end
  end

  test "a draft row binds exact revision hash, email and channel without its body", ctx do
    %{draft: draft, lead: lead, revision: revision} = drafted!(ctx)
    contact = contact!(ctx, lead)
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    row = item!(page, draft)
    assert row.kind == :draft_review
    assert row.producer == :outreach_drafts
    assert row.channel == :email
    assert row.revision_ref.id == revision.id
    assert row.revision_ref.content_sha256 == Base.encode16(revision.content_sha256, case: :lower)
    assert row.recipient_binding.id == contact.id
    assert row.recipient_binding.email == to_string(contact.email)
    assert is_binary(row.id) and is_binary(row.freshness_token)
    assert is_binary(row.summary)
    refute inspect(row) =~ revision.body_text
    assert total!(page, :pending_email_drafts) == 1
    assert Enum.any?(row.actions, &(&1.action_id == :inspect))
  end

  test "critical failures precede an older draft; remaining rows use oldest source time", ctx do
    warning = failure!(ctx)
    Clock.freeze(DateTime.add(Clock.utc_now(), 1, :second))
    %{draft: draft} = drafted!(ctx)
    Clock.freeze(DateTime.add(Clock.utc_now(), 1, :second))
    critical = failure!(ctx, %{severity: :critical})
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert Enum.map(page.items, & &1.subject_ref.id) == [critical.id, warning.id, draft.id]
  end

  test "tied timestamps use producer then source id and continue from the last returned row",
       ctx do
    %{draft: draft} = drafted!(ctx)
    failures = for _ <- 1..4, do: failure!(ctx)
    session = session!(ctx.admin)
    expected = Enum.sort(Enum.map(failures, & &1.id)) ++ [draft.id]

    assert {:ok, first} = refresh(session, limit: 2)
    assert length(first.items) == 2
    assert is_binary(first.next_cursor)
    assert {:ok, second} = refresh(session, limit: 2, cursor: first.next_cursor)
    assert {:ok, third} = refresh(session, limit: 2, cursor: second.next_cursor)
    assert Enum.map(first.items ++ second.items ++ third.items, & &1.subject_ref.id) == expected
    assert third.next_cursor == nil
  end

  test "53 live rows yield 50 plus continuation, not a capped total", ctx do
    failures = for _ <- 1..53, do: failure!(ctx)
    session = session!(ctx.admin)

    assert {:ok, first} = refresh(session)
    assert length(first.items) == 50
    assert total!(first, :live_failures) == 53
    assert {:ok, second} = refresh(session, cursor: first.next_cursor)
    assert length(second.items) == 3
    assert total!(second, :live_failures) == 53
    assert second.next_cursor == nil

    assert Enum.sort(Enum.map(first.items ++ second.items, & &1.subject_ref.id)) ==
             Enum.sort(Enum.map(failures, & &1.id))
  end

  test "acknowledgment stays pending and changes freshness; resolution removes only that failure",
       ctx do
    failure = failure!(ctx)
    other = failure!(ctx)
    session = session!(ctx.admin)

    assert {:ok, first} = refresh(session)
    before = item!(first, failure)
    assert {:ok, acknowledged} = Operations.acknowledge_failure(failure, actor: ctx.admin)
    assert {:ok, second} = refresh(session)
    after_ack = item!(second, failure)
    assert before.id == after_ack.id
    refute before.freshness_token == after_ack.freshness_token
    assert total!(second, :live_failures) == 2

    assert {:ok, _} =
             Operations.resolve_failure(acknowledged, %{resolution_note: "Synthetic repair"},
               actor: ctx.admin
             )

    assert {:ok, third} = refresh(session)
    assert Enum.map(third.items, & &1.subject_ref.id) == [other.id]
    assert total!(third, :live_failures) == 1
  end

  test "time passing changes observation but not stable identity or freshness", ctx do
    failure = failure!(ctx)
    session = session!(ctx.admin)

    assert {:ok, first} = refresh(session)
    Clock.freeze(DateTime.add(Clock.utc_now(), 60, :second))
    assert {:ok, second} = refresh(session)
    a = item!(first, failure)
    b = item!(second, failure)
    assert {a.id, a.freshness_token} == {b.id, b.freshness_token}
    refute first.observed_at == second.observed_at
  end

  test "editing keeps draft identity but changes exact revision and token", ctx do
    %{draft: draft, revision: revision} = drafted!(ctx)
    session = session!(ctx.admin)

    assert {:ok, first} = refresh(session)

    assert {:ok, edited} =
             Outreach.edit_draft(
               draft,
               %{subject: "Updated synthetic subject", body_text: revision.body_text},
               actor: ctx.admin
             )

    current = revision!(ctx, edited.current_revision_id)
    assert {:ok, second} = refresh(session)
    a = item!(first, draft)
    b = item!(second, draft)
    assert a.id == b.id
    refute a.freshness_token == b.freshness_token
    assert b.revision_ref.id == current.id
  end

  test "recipient changes invalidate freshness even for rejection", ctx do
    %{draft: draft, lead: lead} = drafted!(ctx)
    contact = contact!(ctx, lead)
    session = session!(ctx.admin)

    assert {:ok, first} = refresh(session)

    assert {:ok, _} =
             Sales.update(contact, :change_email, %{email: "new-recipient@example.test"},
               actor: ctx.admin
             )

    assert {:ok, second} = refresh(session)
    a = item!(first, draft)
    b = item!(second, draft)
    assert a.id == b.id
    refute a.freshness_token == b.freshness_token
    assert b.recipient_binding.email == "new-recipient@example.test"
  end

  test "an unknown source string never dispatches a resource or enables retry", ctx do
    failure = failure!(ctx, %{subject_resource: "Kernel.system", retryable: true})
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    row = item!(page, failure)
    assert row.kind == :failure_attention
    refute Enum.any?(row.actions, &(&1.action_id == :retry_run and &1.availability == :enabled))
    assert Enum.any?(row.actions, &(&1.action_id == :inspect))
  end

  for limit <- [0, 51, -1, "50", nil] do
    test "invalid page limit #{inspect(limit)} is refused", ctx do
      session = session!(ctx.admin)
      assert {:error, :invalid_input} = refresh(session, limit: unquote(limit))
    end
  end

  test "malformed and tampered continuation cannot select a producer or change scope", ctx do
    for _ <- 1..3, do: failure!(ctx)
    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session, limit: 1)

    for cursor <- [
          "not-a-cursor",
          page.next_cursor <> "x",
          Base.url_encode64(~s({"version":999,"producer":"Elixir.System"}))
        ] do
      assert {:error, :invalid_input} = refresh(session, cursor: cursor)
    end
  end

  test "metadata reads bound candidates in SQL and never select body, payload or stderr", ctx do
    %{revision: _} = drafted!(ctx)
    for _ <- 1..53, do: failure!(ctx)
    session = session!(ctx.admin)

    {{:ok, page}, queries} = trace_queries(fn -> refresh(session, limit: 3) end)
    assert length(page.items) == 3
    reads = Enum.filter(queries, fn {sql, _} -> String.starts_with?(sql, "SELECT") end)

    source_lists =
      Enum.filter(reads, fn {sql, _} ->
        (sql =~ ~s(FROM "drafts") or sql =~ ~s(FROM "failures")) and
          not (String.downcase(sql) =~ "count(")
      end)

    assert length(source_lists) == 2

    assert Enum.all?(source_lists, fn {sql, params} ->
             limit = query_limit(sql, params)
             is_integer(limit) and limit in 1..51
           end)

    for {sql, _params} <- reads do
      refute sql =~ ~r/"(body_text|content|stderr|parsed_output|response_sha256)"/
      refute sql =~ ~s(FROM "payloads")
    end
  end

  defp query_limit(sql, params) do
    case Regex.run(~r/\bLIMIT\s+\$(\d+)/, sql) do
      [_, index] ->
        Enum.at(params, String.to_integer(index) - 1)

      nil ->
        case Regex.run(~r/\bLIMIT\s+(\d+)/, sql) do
          [_, literal] -> String.to_integer(literal)
          nil -> nil
        end
    end
  end
end
