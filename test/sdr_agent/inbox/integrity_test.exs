defmodule SdrAgent.Inbox.IntegrityTest do
  @moduledoc """
  C1-02 fail-closed source integrity. Tampering is sandbox-local and models
  legacy/corrupt rows; it never substitutes raw writes for application fixture
  creation. A malformed required context cannot disappear behind a zero total.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [drafted!: 1, drafted!: 2]

  test "a dangling current revision reports producer_error, not an empty ready queue", ctx do
    %{draft: draft} = drafted!(ctx)
    failure = failure!(ctx)

    tamper!("UPDATE drafts SET current_revision_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(draft.id)
    ])

    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert page.completeness == :partial
    assert Enum.map(page.items, & &1.subject_ref.id) == [failure.id]

    assert %{status: :unavailable, value: nil, reason: :producer_error} =
             page.totals.pending_email_drafts

    assert total!(page, :live_failures) == 1
  end

  test "a current revision from another draft is never substituted as reviewable context", ctx do
    %{draft: draft} = drafted!(ctx)
    %{revision: foreign} = drafted!(ctx, "02")

    tamper!("UPDATE drafts SET current_revision_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(foreign.id),
      Ecto.UUID.dump!(draft.id)
    ])

    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert page.completeness == :partial
    refute Enum.any?(page.items, &(&1.subject_ref.id == draft.id))

    assert %{status: :unavailable, value: nil, reason: :producer_error} =
             page.totals.pending_email_drafts
  end

  test "foreign-tenant pending failures are excluded by SQL, not counted or loaded", ctx do
    own = failure!(ctx)
    hidden = for _ <- 1..53, do: failure!(ctx)
    foreign_tenant = Ecto.UUID.generate()
    ids = Enum.map(hidden, &Ecto.UUID.dump!(&1.id))

    tamper!("UPDATE failures SET tenant_id = $1 WHERE id = ANY($2::uuid[])", [
      Ecto.UUID.dump!(foreign_tenant),
      ids
    ])

    session = session!(ctx.admin)

    {{:ok, page}, queries} = trace_queries(fn -> refresh(session) end)
    assert Enum.map(page.items, & &1.subject_ref.id) == [own.id]
    assert total!(page, :live_failures) == 1
    assert page.next_cursor == nil

    for {sql, params} <- queries, sql =~ ~s(FROM "failures") do
      assert sql =~ ~s("tenant_id")
      refute Enum.any?(ids, &(&1 in params))
    end
  end

  test "persisted non-synthetic recipient is withheld while real data is disabled", ctx do
    %{draft: draft} = drafted!(ctx)

    tamper!("UPDATE contacts SET email = $1 WHERE id = $2", [
      "private-recipient@unapproved-company.com",
      Ecto.UUID.dump!(draft.recipient_contact_id)
    ])

    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert page.completeness == :partial
    refute Enum.any?(page.items, &(&1.subject_ref.id == draft.id))

    assert %{status: :unavailable, value: nil, reason: :withheld} =
             page.totals.pending_email_drafts

    refute inspect(page) =~ "private-recipient"
  end

  test "an unreleased generation-2 model result cannot become a reviewable draft", ctx do
    %{draft: draft, revision: revision} = drafted!(ctx)
    grant = SdrAgent.AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)

    assert {:ok, %{allocations: [allocation]}} =
             SdrAgent.Agents.get_grant(grant.id, actor: ctx.admin)

    tamper!(
      "UPDATE model_invocations SET provider = 'claude_cli', ledger_generation = 2, profile_id = 'claude_cli_opus', grant_id = $1, allocation_id = $2 WHERE id = $3",
      [
        Ecto.UUID.dump!(grant.id),
        Ecto.UUID.dump!(allocation.id),
        Ecto.UUID.dump!(revision.model_invocation_id)
      ]
    )

    session = session!(ctx.admin)

    assert {:ok, page} = refresh(session)
    assert page.completeness == :partial
    refute Enum.any?(page.items, &(&1.subject_ref.id == draft.id))

    assert %{status: :unavailable, value: nil, reason: :withheld} =
             page.totals.pending_email_drafts

    refute inspect(page) =~ revision.subject
    refute inspect(page) =~ revision.body_text
  end
end
