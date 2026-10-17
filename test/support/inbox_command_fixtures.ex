defmodule SdrAgent.InboxCommandFixtures do
  @moduledoc """
  C1-03 synthetic commands built from the real authorized projection.
  Assertions guard the absent API in RED; fixture writes and subject calls
  use domain APIs, never a permissive command implementation.
  """

  import ExUnit.Assertions
  import SdrAgent.InboxFixtures

  alias SdrAgent.Outreach

  @doc "Assert the missing API before invoking it, so RED is not an undefined-function crash."
  def require_command! do
    assert Code.ensure_loaded?(SdrAgent.Inbox) and
             function_exported?(SdrAgent.Inbox, :command, 2),
           "C1-03 Inbox.command/2 strict source-owned command boundary is not implemented"
  end

  @doc "Call the single fixed public command boundary."
  def command(session, request) do
    require_command!()
    apply(SdrAgent.Inbox, :command, [session, request])
  end

  @doc "Build exactly the displayed draft binding; no latest-source fallback at dispatch."
  def displayed!(session, draft, action, extra \\ %{}) do
    assert {:ok, page} = refresh(session)
    row = item!(page, draft)

    request = %{
      action_id: action,
      source_id: draft.id,
      item_id: row.id,
      expected_freshness_token: row.freshness_token,
      args:
        Map.merge(
          %{
            draft_revision_id: row.revision_ref.id,
            content_sha256: row.revision_ref.content_sha256,
            recipient_email: row.recipient_binding.email,
            channel: row.channel
          },
          extra
        )
    }

    {row, request}
  end

  @doc "Safe closed failures, with no unreviewed error payload or source content."
  def error!(result, reason, details \\ %{}) do
    assert {:error, error} = result
    assert is_map(error) and not is_struct(error)
    assert error.reason == reason
    assert Map.take(error, Map.keys(details)) == details
    assert Map.keys(error) -- [:reason, :change, :blocked_reason] == []

    if Map.has_key?(error, :change) do
      assert reason == :stale
      assert error.change in [:revision, :recipient, :lifecycle, :recovery_guard]
    end

    if Map.has_key?(error, :blocked_reason) do
      assert reason == :blocked

      assert error.blocked_reason in [
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
    end

    error
  end

  @doc "Read durable source effects without depending on gateway implementation details."
  def effects!(ctx, draft) do
    assert {:ok, current} = Outreach.fetch(Outreach.Draft, draft.id, actor: ctx.admin)

    records =
      for resource <- [Outreach.DraftRevision, Outreach.Approval, Outreach.DeliveryOperation],
          into: %{} do
        assert {:ok, rows} =
                 Outreach.list_records(resource, filter: [draft_id: draft.id], actor: ctx.admin)

        {resource, Enum.sort_by(rows, & &1.id)}
      end

    Map.put(records, :draft, current)
  end
end
