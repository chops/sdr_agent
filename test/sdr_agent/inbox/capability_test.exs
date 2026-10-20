defmodule SdrAgent.Inbox.CapabilityTest do
  @moduledoc "Metadata-only capability guards stay truthful without enabling C1-03 commands."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [drafted!: 1, contact!: 2]

  alias SdrAgent.Outreach
  alias SdrAgent.Sales

  test "suppression metadata binds freshness and blocks approval, not safe rejection", ctx do
    %{draft: draft, lead: lead} = drafted!(ctx)
    contact = contact!(ctx, lead)
    email = "blocked-recipient@example.invalid"
    assert {:ok, _} = Outreach.suppress(%{scope: :email, value: email}, actor: ctx.admin)

    # C3-02 G2 (D-174 Q-O2, OQ6 (ii)) -- SANDBOX LEGACY/CORRUPTION FIXTURE,
    # for the metadata-read defense only. `:change_email` now refuses a
    # suppressed address, so no valid application path produces this
    # contact: it stands for a pre-C3-02 legacy row (or a corrupted one)
    # whose email is already suppressed. The raw write sets only the email,
    # bypassing the action, its policy and its audit event; it is neither a
    # valid `:change_email` nor auditable history, and it is no precedent for
    # production writes. What this test checks is that the Inbox read still
    # binds freshness and blocks approval for such a row.
    tamper!("UPDATE contacts SET email = $1 WHERE id = $2", [
      email,
      Ecto.UUID.dump!(contact.id)
    ])

    session = session!(ctx.admin)

    {{:ok, page}, queries} = trace_queries(fn -> refresh(session) end)
    row = item!(page, draft)
    assert action(row, :approve_capture).blocked_reason == :recipient_suppressed
    assert action(row, :reject_draft).availability == :enabled
    assert action(row, :inspect).target_ref == row.subject_ref
    assert total!(page, :pending_email_drafts) == 1

    suppression_reads = Enum.filter(queries, fn {sql, _} -> sql =~ ~s(FROM "suppressions") end)
    assert [{sql, _}] = suppression_reads
    assert sql =~ "LIMIT"

    # The source's applicable guard facts are carried in its selected
    # metadata result; no Suppression content/reason is copied into Home.
    assert {:ok, [source]} = Outreach.list_inbox_drafts(ctx.admin, nil)
    assert [_] = source.suppression_refs
  end

  test "edit is enabled through the atomic C1-03 freshness adapter", ctx do
    %{draft: draft} = drafted!(ctx)
    assert {:ok, page} = refresh(session!(ctx.admin))
    row = item!(page, draft)
    assert action(row, :edit_draft).availability == :enabled
    assert action(row, :edit_draft).blocked_reason == nil
    assert action(row, :approve_capture).availability == :enabled
    assert action(row, :reject_draft).availability == :enabled
  end

  test "a new applicable suppression changes freshness even for a legacy pending row", ctx do
    %{draft: draft, lead: lead} = drafted!(ctx)
    contact = contact!(ctx, lead)
    session = session!(ctx.admin)
    assert {:ok, before} = refresh(session)

    assert {:ok, _} =
             Outreach.suppress(%{scope: :email, value: to_string(contact.email)},
               actor: ctx.admin
             )

    # The real API cancels pending drafts atomically. Restore only the status
    # in this sandbox to model a legacy pending row, not an application path.
    tamper!("UPDATE drafts SET status = 'pending_review' WHERE id = $1", [
      Ecto.UUID.dump!(draft.id)
    ])

    assert {:ok, after_suppression} = refresh(session)
    a = item!(before, draft)
    b = item!(after_suppression, draft)
    assert a.id == b.id
    assert a.revision_ref == b.revision_ref
    assert a.recipient_binding == b.recipient_binding
    refute a.freshness_token == b.freshness_token
    assert action(b, :approve_capture).blocked_reason == :recipient_suppressed
  end

  test "a full 51-candidate producer uses one bounded tenant-scoped suppression join", ctx do
    sequence = SdrAgent.SalesFixtures.sequence_with_steps!(ctx.tenant, 51)
    assert {:ok, sequence} = Sales.update(sequence, :activate, %{}, actor: ctx.admin)

    attrs =
      SdrAgent.Demo.Fixtures.campaign()
      |> Map.take([
        :icp_definition_id,
        :sender_name,
        :sender_email,
        :timezone,
        :footer_template_version
      ])
      |> Map.merge(%{name: "Synthetic 51-step inbox", sequence_id: sequence.id})

    assert {:ok, campaign} = Sales.create_campaign(attrs, actor: ctx.admin)
    assert {:ok, campaign} = Sales.update(campaign, :activate, %{}, actor: ctx.admin)
    %{draft: first, revision: revision} = drafted!(%{ctx | campaign_id: campaign.id})

    assert {:ok, steps} =
             Sales.list_records(Sales.SequenceStep,
               filter: [sequence_id: sequence.id],
               actor: ctx.admin
             )

    for step <- steps, step.id != first.sequence_step_id do
      attrs =
        first
        |> Map.take([
          :lead_id,
          :enrollment_id,
          :campaign_id,
          :recipient_contact_id,
          :origin_agent_run_id
        ])
        |> Map.merge(%{
          sequence_step_id: step.id,
          subject: revision.subject,
          body_text: revision.body_text,
          decision_id: revision.decision_id,
          model_invocation_id: revision.model_invocation_id
        })

      assert {:ok, _} = Outreach.propose_draft(attrs, actor: ctx.agent)
    end

    session = session!(ctx.admin)

    {{:ok, page}, queries} = trace_queries(fn -> refresh(session) end)
    assert length(page.items) == 50
    assert is_binary(page.next_cursor)
    assert total!(page, :pending_email_drafts) == 51

    assert [{sql, params}] =
             Enum.filter(queries, fn {sql, _} -> sql =~ ~s(FROM "suppressions") end)

    assert sql =~ ~s("tenant_id")
    assert 102 in params
    assert sql =~ "LIMIT"
    assert length(params) <= 104
  end

  defp action(row, name), do: Enum.find(row.actions, &(&1.action_id == name))
end
