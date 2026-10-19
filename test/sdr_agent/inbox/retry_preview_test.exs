defmodule SdrAgent.Inbox.RetryPreviewTest do
  @moduledoc """
  C1-03 B RED: fixed metadata preview shapes and capability integration.
  Atom errors and missing-id hiding are pinned by Claude's 714c4f69 reply.
  Query telemetry covers the actual public boundary, not a mock reader.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.InboxRetryFixtures, except: [command: 2]

  alias SdrAgent.Accounts

  @blocked [
    :actor_not_permitted,
    :recipient_suppressed,
    :recipient_inactive,
    :campaign_closed,
    :real_data_disabled,
    :model_staged,
    :tuple_not_promoted,
    :grant_unavailable,
    :grant_exhausted,
    :witness_withheld,
    :cleanup_unconfirmed,
    :unknown_outcome,
    :guard_not_available,
    :producer_unavailable
  ]

  test "empty input succeeds without authentication or a database read" do
    {result, queries} = trace_queries(fn -> preview("not-a-session", []) end)
    assert result == {:ok, %{}}
    assert queries == []
  end

  for ids <- [nil, %{}, "all", [nil], ["not-a-uuid"], [1]] do
    test "invalid ids #{inspect(ids)} refuse before authentication/database reads" do
      {result, queries} =
        trace_queries(fn -> preview("not-a-session", unquote(Macro.escape(ids))) end)

      assert result == {:error, :invalid_input}
      assert queries == []
    end
  end

  test "duplicates refuse rather than silently deduplicating" do
    id = Ecto.UUID.generate()
    {result, queries} = trace_queries(fn -> preview("not-a-session", [id, id]) end)
    assert result == {:error, :invalid_input}
    assert queries == []
  end

  test "51 valid ids refuse before any database read" do
    ids = for _ <- 1..51, do: Ecto.UUID.generate()
    {result, queries} = trace_queries(fn -> preview("not-a-session", ids) end)
    assert result == {:error, :invalid_input}
    assert queries == []
  end

  for trigger <- [:assignment, :reply] do
    test "known terminal gen2 Fake #{trigger} is an enabled fixed-shape entry", ctx do
      prior = prior!(ctx, unquote(trigger))
      session = session!(ctx.admin)
      {result, queries} = trace_queries(fn -> preview(session, [prior.attention_failure_id]) end)

      assert result ==
               {:ok, %{prior.attention_failure_id => %{enabled?: true, blocked_reason: nil}}}

      refute Enum.any?(queries, fn {sql, _} ->
               Regex.match?(~r/\b(?:INSERT|UPDATE|DELETE|FOR\s+UPDATE|FOR\s+SHARE)\b/i, sql)
             end)

      refute Enum.any?(queries, fn {sql, _} -> sql =~ ~s("audit_chain_heads") end)
      assert {:ok, page} = refresh(session)
      row = item!(page, %{id: prior.attention_failure_id})
      action = Enum.find(row.actions, &(&1.action_id == :retry_run))
      assert {action.availability, action.blocked_reason} == {:enabled, nil}
    end
  end

  for status <- [:reserved, :sent, :unknown] do
    test "#{status} remains an advisory blocked entry, never an authorization", ctx do
      prior = prior!(ctx, :assignment)
      [invocation | _] = invocations!(ctx, prior)

      tamper!("UPDATE model_invocations SET status = $1 WHERE id = $2", [
        Atom.to_string(unquote(status)),
        Ecto.UUID.dump!(invocation.id)
      ])

      session = session!(ctx.admin)

      assert preview(session, [prior.attention_failure_id]) ==
               {:ok,
                %{
                  prior.attention_failure_id => %{
                    enabled?: false,
                    blocked_reason: :unknown_outcome
                  }
                }}
    end
  end

  for role <- [:reviewer, :auditor] do
    test "#{role} gets no rich preview and Home keeps the readable Failure", ctx do
      prior = prior!(ctx, :assignment)
      session = session!(human(unquote(role), ctx.tenant))
      {result, queries} = trace_queries(fn -> preview(session, [prior.attention_failure_id]) end)
      assert result == {:error, :forbidden}

      refute Enum.any?(queries, fn {sql, _} ->
               Enum.any?(~w(agent_runs model_invocations oban_jobs failures), fn table ->
                 sql =~ ~s("#{table}")
               end)
             end)

      assert {:ok, page} = refresh(session)
      row = item!(page, %{id: prior.attention_failure_id})
      action = Enum.find(row.actions, &(&1.action_id == :retry_run))
      assert {action.availability, action.blocked_reason} == {:blocked, :actor_not_permitted}
    end
  end

  test "nonexistent ids are absent, not per-id disclosure entries", ctx do
    prior = prior!(ctx, :assignment)
    missing = Ecto.UUID.generate()
    assert {:ok, result} = preview(session!(ctx.admin), [prior.attention_failure_id, missing])
    assert Map.keys(result) == [prior.attention_failure_id]
    assert_entry!(result[prior.attention_failure_id])
  end

  test "the 50-id batch never returns an unsupplied id or changes source effects", ctx do
    prior = prior!(ctx, :assignment)
    ids = [prior.attention_failure_id | for(_ <- 1..49, do: Ecto.UUID.generate())]
    session = session!(ctx.admin)
    before = effects!(ctx)
    assert {:ok, result} = preview(session, ids)
    assert Map.keys(result) == [prior.attention_failure_id]
    Enum.each(Map.values(result), &assert_entry!/1)
    assert effects!(ctx) == before
  end

  test "a revoked session yields only the uniform forbidden atom", ctx do
    prior = prior!(ctx, :assignment)
    session = session!(ctx.admin)
    assert :ok = AshAuthentication.TokenResource.Actions.revoke(Accounts.Token, session)
    assert preview(session, [prior.attention_failure_id]) == {:error, :forbidden}
  end

  defp assert_entry!(entry) do
    assert is_map(entry) and not is_struct(entry)
    assert Enum.sort(Map.keys(entry)) == [:blocked_reason, :enabled?]

    case entry do
      %{enabled?: true, blocked_reason: nil} -> :ok
      %{enabled?: false, blocked_reason: reason} -> assert reason in @blocked
      _ -> flunk("preview returned an invalid capability shape")
    end
  end
end
