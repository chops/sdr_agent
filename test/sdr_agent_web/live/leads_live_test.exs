defmodule SdrAgentWeb.LeadsLiveTest do
  @moduledoc """
  S10a Leads list and Lead detail: the seeded leads with company, contact
  and status; the research evidence drill-down (artifact → claims, the
  qualification and the claims it cites, the full source through the
  audited payload read); assigning a lead to the agent (ADM, REV only).
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Research

  describe "leads list" do
    test "lists every seeded lead with company, contact and status", %{conn: conn} do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads")

      for lead <- Fixtures.leads() do
        assert has_element?(view, "#leads-#{lead.id} a[href='/leads/#{lead.id}']")
      end

      [first | _] = Fixtures.leads()
      assert has_element?(view, "#leads-#{first.id} [data-status='new']")
    end

    test "filters by status through the URL", %{conn: conn} = ctx do
      drafted!(ctx)
      lead = fixture_lead!(ctx, "01")
      other = fixture_lead!(ctx, "03")

      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/leads?status=in_outreach")

      assert has_element?(view, "#leads-#{lead.id}")
      refute has_element?(view, "#leads-#{other.id}")

      view |> element("#status-filter-all") |> render_click()
      assert_patch(view, ~p"/leads")
      assert has_element?(view, "#leads-#{other.id}")
    end

    test "an auditor's list view names the leads shown", %{conn: conn} = ctx do
      auditor = user!(ctx, :auditor)
      {:ok, _view, _html} = conn |> sign_in(:auditor) |> live(~p"/leads")

      [access] = accesses_of(ctx, auditor)
      assert access.access_kind == :record_view
      assert access.target_resource == "SdrAgent.Sales.Lead"

      for lead <- Fixtures.leads(), do: assert(access.target_ref =~ lead.id)
    end
  end

  describe "lead detail" do
    setup ctx do
      Map.merge(ctx, drafted!(ctx))
    end

    test "shows the contact, account and qualification with its evidence links",
         %{conn: conn, lead: lead} = ctx do
      {:ok, qualification} = Research.current_qualification(lead.id, actor: ctx.admin)

      {:ok, links} =
        Research.list_records(Research.QualificationEvidence,
          filter: [qualification_id: qualification.id],
          actor: ctx.admin
        )

      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}")

      assert has_element?(view, "#lead-header [data-status='in_outreach']")
      assert has_element?(view, "#qualification [data-qualified='true']")
      assert has_element?(view, "#qualification-score", to_string(qualification.score))
      assert links != []

      for link <- links do
        assert has_element?(
                 view,
                 "#qualification-evidence a[href='/leads/#{lead.id}?claim=#{link.evidence_claim_id}']"
               )
      end
    end

    test "drills from an artifact to its claims and the claim's quoted source",
         %{conn: conn, lead: lead} = ctx do
      {:ok, [artifact | _]} =
        Research.list_records(Research.ResearchArtifact,
          filter: [lead_id: lead.id],
          actor: ctx.admin
        )

      {:ok, [claim | _]} =
        Research.list_records(Research.EvidenceClaim,
          filter: [research_artifact_id: artifact.id],
          actor: ctx.admin
        )

      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}")

      assert has_element?(view, "#artifact-#{artifact.id}")
      assert has_element?(view, "#claim-#{claim.id}")

      view |> element("#claim-#{claim.id} a") |> render_click()
      assert_patch(view, ~p"/leads/#{lead.id}?claim=#{claim.id}")

      assert has_element?(view, "#evidence-panel [data-claim-id='#{claim.id}']")
      assert has_element?(view, "#evidence-panel blockquote", claim.quote)
      assert has_element?(view, "#evidence-panel a[href='#{artifact.source_url}']")
    end

    test "the full source content is served only through the audited read",
         %{conn: conn, lead: lead} = ctx do
      reviewer = user!(ctx, :reviewer)

      {:ok, [claim | _]} =
        Research.list_records(Research.EvidenceClaim,
          filter: [lead_id: lead.id],
          actor: ctx.admin
        )

      {:ok, view, _html} =
        conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}?claim=#{claim.id}")

      refute has_element?(view, "#source-content")
      before = length(accesses_of(ctx, reviewer))

      view |> element("#show-source") |> render_click()

      assert has_element?(view, "#source-content mark", claim.quote)
      accesses = accesses_of(ctx, reviewer)
      assert length(accesses) == before + 1
      assert List.last(accesses).access_kind == :payload_view
    end

    test "lists the lead's drafts with a link to review", %{conn: conn, lead: lead} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}")
      assert has_element?(view, "#lead-drafts a[href='/drafts/#{ctx.draft.id}']")
    end

    test "links the lead's agent runs and, for admins and auditors, its audit trail",
         %{conn: conn, lead: lead, run: run} do
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/leads/#{lead.id}")
      assert has_element?(view, "#lead-runs a[href='/runs/#{run.id}']")
      assert has_element?(view, "#lead-audit-link[href='/audit?lead=#{lead.id}']")

      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}")
      refute has_element?(view, "#lead-audit-link")
    end

    test "an auditor's detail view is recorded with the lead id",
         %{conn: conn, lead: lead} = ctx do
      auditor = user!(ctx, :auditor)
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/leads/#{lead.id}")

      assert has_element?(view, "#lead-header")

      assert [%{target_resource: "SdrAgent.Sales.Lead", target_ref: ref}] =
               accesses_of(ctx, auditor)

      assert ref == lead.id
    end

    test "navigating from a lead to a missing one shows nothing of the first",
         %{conn: conn, lead: lead} do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}")
      assert has_element?(view, "#lead-header")

      render_patch(view, ~p"/leads/#{Ecto.UUID.generate()}")

      assert has_element?(view, "#not-found")
      refute has_element?(view, "#lead-header")
      refute has_element?(view, "#research")
    end

    test "an unknown lead shows not found", %{conn: conn} do
      {:ok, view, _html} =
        conn |> sign_in(:reviewer) |> live(~p"/leads/#{Ecto.UUID.generate()}")

      assert has_element?(view, "#not-found")
    end
  end

  describe "assigning a lead to the agent" do
    test "a reviewer assigns a new lead; the agent run is queued", %{conn: conn} = ctx do
      lead = fixture_lead!(ctx, "01")
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}")

      view |> element("#assign-lead") |> render_click()

      assert has_element?(view, "#lead-header [data-status='assigned']")
      assert reload!(ctx, lead).status == :assigned
    end

    test "the auditor sees no assign control and a forged event is refused and audited",
         %{conn: conn} = ctx do
      lead = fixture_lead!(ctx, "01")
      auditor = user!(ctx, :auditor)
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/leads/#{lead.id}")

      refute has_element?(view, "#assign-lead")
      render_click(view, "assign", %{})

      assert has_element?(view, "#flash-error")
      assert reload!(ctx, lead).status == :new
      assert [_denied] = denials_of(ctx, auditor)
    end
  end
end
