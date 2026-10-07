defmodule SdrAgent.Outreach.DraftTest do
  @moduledoc """
  S8a Draft, DraftRevision and RevisionCitation: the agent's hand-off
  creates the draft and its immutable first revision in the hand-off
  transaction; reviewers edit by adding human revisions (diffs, carried
  citations); nothing about a revision can be changed afterwards.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Research
  alias SdrAgent.SalesFixtures, as: F

  describe "the hand-off draft" do
    test "the agent's hand-off creates the draft, its agent revision and citations", ctx do
      %{draft: draft, run: run, lead: lead, revision: rev} = drafted!(ctx)
      {:ok, proposal} = SdrAgent.SDR.proposal(run.id, actor: ctx.agent)

      assert draft.status == :pending_review
      assert draft.origin_agent_run_id == run.id
      assert draft.enrollment_id == proposal.enrollment_id
      assert draft.sequence_step_id == proposal.sequence_step_id
      assert draft.campaign_id == ctx.campaign_id
      assert draft.recipient_contact_id == lead.contact_id

      assert rev.draft_id == draft.id
      assert {rev.revision_number, rev.author_type, rev.parent_revision_id} == {1, :agent, nil}
      assert {rev.agent_run_id, rev.decision_id} == {run.id, proposal.decision_id}
      assert rev.model_invocation_id == proposal.model_invocation_id
      assert {rev.subject, rev.body_text} == {proposal.output.subject, proposal.output.body}

      assert rev.content_sha256 ==
               Canonical.sha256(%{subject: rev.subject, body_text: rev.body_text})

      assert rev.canonicalization_version == Canonical.version()

      citations = citations!(ctx, rev)
      assert Enum.sort(Enum.map(citations, & &1.kind)) == [:claim, :personalization]

      for citation <- citations do
        assert String.contains?(rev.body_text, citation.text)

        {:ok, claim} =
          Research.fetch(Research.EvidenceClaim, citation.evidence_claim_id, actor: ctx.admin)

        assert {claim.lead_id, claim.quality} == {lead.id, :accepted}
      end

      types = Enum.map(events(ctx.tenant), & &1.event_type)
      assert "outreach.draft.proposed" in types
      assert "outreach.revision.created" in types
      assert {:ok, %{valid?: true}} = SdrAgent.Audit.verify_chain(actor: ctx.aud)
    end

    test "a disqualified lead gets no draft", ctx do
      %{run: _run} = assign!(ctx, "05")
      assert %{success: 1} = drain!()
      lead = fixture_lead!(ctx, "05")

      assert {:ok, []} =
               Outreach.list_records(Draft, filter: [lead_id: lead.id], actor: ctx.admin)
    end

    test "propose is AGT-only and checks enrollment, step, campaign and recipient", ctx do
      %{draft: draft, revision: rev} = drafted!(ctx)
      other = fixture_lead!(ctx, "02")

      attrs = %{
        lead_id: draft.lead_id,
        enrollment_id: draft.enrollment_id,
        sequence_step_id: draft.sequence_step_id,
        campaign_id: draft.campaign_id,
        recipient_contact_id: other.contact_id,
        origin_agent_run_id: draft.origin_agent_run_id,
        subject: rev.subject,
        body_text: rev.body_text,
        decision_id: rev.decision_id,
        model_invocation_id: rev.model_invocation_id,
        citations: []
      }

      assert {:error, %Ash.Error.Invalid{}} = Outreach.propose_draft(attrs, actor: ctx.agent)

      assert {:error, %Ash.Error.Forbidden{}} =
               Outreach.propose_draft(%{attrs | recipient_contact_id: draft.recipient_contact_id},
                 actor: ctx.admin
               )

      # One open draft per enrollment step.
      assert {:error, %Ash.Error.Invalid{}} =
               Outreach.propose_draft(%{attrs | recipient_contact_id: draft.recipient_contact_id},
                 actor: ctx.agent
               )
    end

    test "a citation must be an accepted claim of the lead, verbatim in the body", ctx do
      %{draft: draft, revision: rev} = drafted!(ctx)
      %{revision: other_rev} = drafted!(ctx, "02")
      [own | _] = citations!(ctx, rev)
      [foreign | _] = citations!(ctx, other_rev)

      base = %{
        lead_id: draft.lead_id,
        enrollment_id: draft.enrollment_id,
        sequence_step_id: draft.sequence_step_id,
        campaign_id: draft.campaign_id,
        recipient_contact_id: draft.recipient_contact_id,
        origin_agent_run_id: draft.origin_agent_run_id,
        subject: "x",
        decision_id: rev.decision_id,
        model_invocation_id: rev.model_invocation_id
      }

      # Another lead's claim, even verbatim in the body.
      assert {:error, %Ash.Error.Invalid{}} =
               Outreach.propose_draft(
                 Map.merge(base, %{
                   body_text: foreign.text,
                   citations: [
                     %{
                       evidence_claim_id: foreign.evidence_claim_id,
                       kind: :claim,
                       text: foreign.text
                     }
                   ]
                 }),
                 actor: ctx.agent
               )

      # The lead's own claim whose text is not in the body.
      assert {:error, %Ash.Error.Invalid{}} =
               Outreach.propose_draft(
                 Map.merge(base, %{
                   body_text: "Nothing cited here.",
                   citations: [
                     %{evidence_claim_id: own.evidence_claim_id, kind: :claim, text: own.text}
                   ]
                 }),
                 actor: ctx.agent
               )
    end
  end

  describe "human revisions" do
    test "an edit adds a human revision with diffs and carried-forward citations", ctx do
      %{draft: draft, revision: rev1} = drafted!(ctx)
      reviewer = operator!(ctx, :reviewer)
      [kept, dropped] = Enum.sort_by(citations!(ctx, rev1), & &1.kind)
      body = String.replace(rev1.body_text, dropped.text, "We help teams like yours.")
      refute String.contains?(body, dropped.text)

      assert {:ok, edited} =
               Outreach.edit_draft(draft, %{subject: "A sharper subject", body_text: body},
                 actor: reviewer
               )

      rev2 = revision!(ctx, edited.current_revision_id)
      assert edited.status == :pending_review

      assert {rev2.revision_number, rev2.author_type, rev2.author_user_id} ==
               {2, :human, reviewer.id}

      assert {rev2.parent_revision_id, rev2.ai_baseline_revision_id} == {rev1.id, rev1.id}

      assert rev2.content_sha256 ==
               Canonical.sha256(%{subject: "A sharper subject", body_text: body})

      assert rev2.diff_from_parent =~ "-Subject: #{rev1.subject}"
      assert rev2.diff_from_parent =~ "+Subject: A sharper subject"
      assert rev2.diff_from_parent =~ dropped.text
      assert rev2.diff_from_ai_baseline == rev2.diff_from_parent

      assert [carried] = citations!(ctx, rev2)

      assert {carried.evidence_claim_id, carried.kind, carried.text} ==
               {kept.evidence_claim_id, kept.kind, kept.text}

      {:ok, again} =
        Outreach.edit_draft(edited, %{subject: "Third", body_text: body}, actor: ctx.admin)

      rev3 = revision!(ctx, again.current_revision_id)

      assert {rev3.revision_number, rev3.parent_revision_id, rev3.ai_baseline_revision_id} ==
               {3, rev2.id, rev1.id}

      assert rev3.diff_from_parent =~ "+Subject: Third"
      assert rev3.diff_from_ai_baseline =~ "-Subject: #{rev1.subject}"
      assert length(events_of_type(ctx.tenant, "outreach.draft.edited")) == 2
    end

    test "only ADM and REV edit, and only while pending review", ctx do
      %{draft: draft, revision: rev} = drafted!(ctx)
      before = length(events_of_type(ctx.tenant, "authz.denied"))
      attrs = %{subject: "x", body_text: rev.body_text}

      for actor <- [operator!(ctx, :auditor), ctx.agent] do
        assert {:error, %Ash.Error.Forbidden{}} = Outreach.edit_draft(draft, attrs, actor: actor)
      end

      assert length(events_of_type(ctx.tenant, "authz.denied")) == before + 2

      approve!(ctx, draft, operator!(ctx, :reviewer))
      queued = draft!(ctx, draft)
      assert queued.status == :queued
      assert {:error, %Ash.Error.Invalid{}} = Outreach.edit_draft(queued, attrs, actor: ctx.admin)
    end
  end

  describe "lifecycle and immutability" do
    test "the declared transition tables match the actions" do
      assert F.declared(Draft) == F.transition_actions(Draft)

      assert F.declared(SdrAgent.Outreach.Approval) ==
               F.transition_actions(SdrAgent.Outreach.Approval)
    end

    test "revisions, citations and suppressions are append-only", ctx do
      %{revision: rev} = drafted!(ctx)

      for {table, column} <- [
            {"draft_revisions", "subject"},
            {"revision_citations", "text"},
            {"suppressions", "value"}
          ] do
        assert {:error, %Postgrex.Error{}} =
                 raw_error("UPDATE #{table} SET #{column} = 'x'"),
               table

        %{rows: rows} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT tgname FROM pg_trigger WHERE tgrelid = $1::text::regclass AND NOT tgisinternal",
            [table]
          )

        assert ["#{table}_guard_row"] -- List.flatten(rows) == [], table
      end

      assert rev.revision_number == 1

      refute Enum.any?(
               Ash.Resource.Info.actions(DraftRevision),
               &(&1.type in [:update, :destroy])
             )
    end

    test "a draft cannot commit without its current revision (deferred FK)", ctx do
      %{draft: draft} = drafted!(ctx)

      result =
        Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])

          case Ecto.Adapters.SQL.query(
                 Repo,
                 "UPDATE drafts SET current_revision_id = gen_random_uuid() WHERE id = $1",
                 [Ecto.UUID.dump!(draft.id)]
               ) do
            {:error, error} -> Repo.rollback(error)
            {:ok, result} -> Repo.rollback({:unexpected, result})
          end
        end)

      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} = result
    end
  end
end
