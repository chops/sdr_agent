defmodule SdrAgent.Inbox.ModelContextTest do
  @moduledoc "A broken referenced model/baseline cannot bypass release withholding or reduce integrity."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [drafted!: 1, drafted!: 2]

  for field <- [:model_invocation_id, :ai_baseline_revision_id] do
    test "a missing referenced #{field} is producer_error in both source list and exact count",
         ctx do
      %{revision: revision} = drafted!(ctx)

      tamper!("UPDATE draft_revisions SET #{unquote(field)} = $1 WHERE id = $2", [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(revision.id)
      ])

      assert {:error, :producer_error} = SdrAgent.Outreach.list_inbox_drafts(ctx.admin, nil)
      assert {:error, :producer_error} = SdrAgent.Outreach.count_inbox_drafts(actor: ctx.admin)
      assert {:ok, page} = refresh(session!(ctx.admin))
      assert page.items == []
      assert page.completeness == :partial
      assert %{status: :unavailable, reason: :producer_error} = page.totals.pending_email_drafts
    end
  end

  test "a baseline belonging to another draft is not substituted as its review context", ctx do
    %{revision: revision} = drafted!(ctx)
    %{revision: foreign} = drafted!(ctx, "02")

    tamper!("UPDATE draft_revisions SET ai_baseline_revision_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(foreign.id),
      Ecto.UUID.dump!(revision.id)
    ])

    assert {:error, :producer_error} = SdrAgent.Outreach.list_inbox_drafts(ctx.admin, nil)
    assert {:error, :producer_error} = SdrAgent.Outreach.count_inbox_drafts(actor: ctx.admin)
  end
end
