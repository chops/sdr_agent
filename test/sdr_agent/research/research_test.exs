defmodule SdrAgent.ResearchTest do
  @moduledoc """
  S2 rows ResearchArtifact, EvidenceClaim, Qualification and
  QualificationEvidence: append-only records the agent creates, the
  grounding check, qualification lineage and provenance, the lead
  transition in the same transaction, and human overrides.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      agent: system_actor(:agent_runtime, tenant)
    }
  end

  defp lead_status(ctx, lead) do
    {:ok, lead} = Sales.get(SdrAgent.Sales.Lead, lead.id, actor: ctx.admin)
    lead.status
  end

  describe "ResearchArtifact" do
    test "AGT records an artifact whose full content is a Payload; audited", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      tool = F.tool_invocation!(ctx.tenant, run)

      {:ok, artifact} =
        Research.record_artifact(F.artifact_attrs(lead, run, tool), actor: ctx.agent)

      assert artifact.content_sha256 == :crypto.hash(:sha256, F.content())
      assert artifact.tenant_id == ctx.tenant.id
      assert %DateTime{} = artifact.retrieved_at

      assert {:ok, content} =
               Audit.read_content(artifact.content_sha256, actor: ctx.admin, purpose: "test")

      assert content == F.content()
      assert [event] = events_of_type(ctx.tenant, "research.artifact.recorded")
      assert event.subject_id == artifact.id
      assert event.agent_run_id == run.id
    end

    test "recording the same source again returns the existing artifact without a new event",
         ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      tool = F.tool_invocation!(ctx.tenant, run)
      attrs = F.artifact_attrs(lead, run, tool)

      {:ok, first} = Research.record_artifact(attrs, actor: ctx.agent)
      {:ok, again} = Research.record_artifact(%{attrs | title: "Other title"}, actor: ctx.agent)

      assert again.id == first.id
      assert [_] = events_of_type(ctx.tenant, "research.artifact.recorded")
    end

    test "the excerpt must be a substring of the content, at most 2000 characters", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      tool = F.tool_invocation!(ctx.tenant, run)

      for attrs <- [
            %{excerpt: "Not in the source"},
            %{content: String.duplicate("a", 2500), excerpt: String.duplicate("a", 2001)}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Research.record_artifact(F.artifact_attrs(lead, run, tool, attrs),
                   actor: ctx.agent
                 )
      end
    end

    test "source URLs must be fixture or reserved hosts", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      tool = F.tool_invocation!(ctx.tenant, run)

      for url <- ["https://acme-freight.test/careers", "fixture://search/acme?q=sdr"] do
        assert {:ok, _} =
                 Research.record_artifact(F.artifact_attrs(lead, run, tool, %{source_url: url}),
                   actor: ctx.agent
                 ),
               url
      end

      for url <- ["https://acme.com/careers", "ftp://acme.test/x", "acme.test"] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Research.record_artifact(F.artifact_attrs(lead, run, tool, %{source_url: url}),
                   actor: ctx.agent
                 ),
               url
      end
    end

    test "humans cannot record artifacts", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      tool = F.tool_invocation!(ctx.tenant, run)

      for actor <- [ctx.admin, ctx.reviewer] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Research.record_artifact(F.artifact_attrs(lead, run, tool), actor: actor)
      end
    end
  end

  describe "EvidenceClaim" do
    setup ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{artifact: artifact, run: run} = F.artifact!(ctx.tenant, lead)
      decision = F.extraction_decision!(ctx.tenant, run, artifact)
      %{lead: lead, artifact: artifact, run: run, decision: decision}
    end

    test "a grounded claim is recorded and audited", ctx do
      {:ok, claim} =
        Research.record_claim(F.claim_attrs(ctx.artifact, ctx.decision, "120 employees"),
          actor: ctx.agent
        )

      assert claim.quote == "120 employees"
      assert claim.lead_id == ctx.lead.id
      assert claim.quality == :accepted
      assert [event] = events_of_type(ctx.tenant, "research.claim.recorded")
      assert event.subject_id == claim.id
    end

    test "a quote that does not match the cited span is refused and nothing is stored", ctx do
      attrs = F.claim_attrs(ctx.artifact, ctx.decision, "120 employees")

      for bad <- [
            %{quote: "121 employees"},
            %{source_location: %{char_start: 0, char_end: 5}},
            %{source_location: %{char_start: 5, char_end: 5}},
            %{source_location: %{char_start: 0, char_end: 100_000}},
            %{content: F.content() <> " tampered"},
            %{lead_id: F.lead!(ctx.tenant).id}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Research.record_claim(Map.merge(attrs, bad), actor: ctx.agent),
               inspect(bad)
      end

      assert {:ok, []} = Research.list(SdrAgent.Research.EvidenceClaim, actor: ctx.admin)
      assert events_of_type(ctx.tenant, "research.claim.recorded") == []
    end

    test "offsets count Unicode code points", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      tool = F.tool_invocation!(ctx.tenant, run)
      content = "Café Freight — 3 SDR roles open."

      {:ok, artifact} =
        Research.record_artifact(
          F.artifact_attrs(lead, run, tool, %{
            content: content,
            excerpt: "Café Freight",
            source_url: "fixture://web/cafe"
          }),
          actor: ctx.agent
        )

      decision = F.extraction_decision!(ctx.tenant, run, artifact)

      assert {:ok, _} =
               Research.record_claim(
                 F.claim_attrs(artifact, decision, "3 SDR roles", %{
                   content: content,
                   source_location: %{char_start: 15, char_end: 26}
                 }),
                 actor: ctx.agent
               )
    end

    test "humans cannot record claims", ctx do
      for actor <- [ctx.admin, ctx.reviewer] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Research.record_claim(F.claim_attrs(ctx.artifact, ctx.decision, "120 employees"),
                   actor: actor
                 )
      end
    end
  end

  describe "Qualification by the agent" do
    setup ctx do
      lead = F.lead_in!(ctx.tenant, :qualifying)
      %{artifact: artifact, run: run} = F.artifact!(ctx.tenant, lead)
      accepted = F.claim!(ctx.tenant, artifact, run, :accepted)
      decision = F.qualification_decision!(ctx.tenant, run, lead)
      icp = F.active_icp!(ctx.tenant)

      %{lead: lead, artifact: artifact, run: run, claim: accepted, decision: decision, icp: icp}
    end

    defp attrs(ctx, overrides \\ %{}),
      do: F.qualification_attrs(ctx.lead, ctx.icp, ctx.run, ctx.decision, [ctx.claim], overrides)

    test "records the qualification, its evidence and the lead transition together", ctx do
      {:ok, qualification} = Research.record_qualification(attrs(ctx), actor: ctx.agent)

      assert qualification.source == :agent
      assert qualification.supersedes_id == nil
      assert lead_status(ctx, ctx.lead) == :qualified

      {:ok, [evidence]} =
        Research.list(SdrAgent.Research.QualificationEvidence, actor: ctx.admin)

      assert {evidence.qualification_id, evidence.evidence_claim_id} ==
               {qualification.id, ctx.claim.id}

      assert [event] = events_of_type(ctx.tenant, "research.qualification.recorded")
      assert event.payload["arguments"]["evidence_claim_ids"] == [ctx.claim.id]
      assert [lead_event] = events_of_type(ctx.tenant, "sales.lead.qualified")
      assert lead_event.payload["changes"]["last_decision_id"] == ctx.decision.id

      assert {:ok, current} = Research.current_qualification(ctx.lead.id, actor: ctx.reviewer)
      assert current.id == qualification.id
      assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: ctx.admin)
    end

    test "a negative result disqualifies the lead", ctx do
      {:ok, _} =
        Research.record_qualification(attrs(ctx, %{qualified: false, score: 20}),
          actor: ctx.agent
        )

      assert lead_status(ctx, ctx.lead) == :disqualified
    end

    test "qualified needs at least one cited accepted claim of the same lead", ctx do
      rejected = F.claim!(ctx.tenant, ctx.artifact, ctx.run, :rejected)
      other_lead = F.lead_in!(ctx.tenant, :researching)
      %{artifact: other_artifact, run: other_run} = F.artifact!(ctx.tenant, other_lead)
      foreign = F.claim!(ctx.tenant, other_artifact, other_run)

      for claims <- [[], [rejected], [ctx.claim, foreign]] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Research.record_qualification(
                   attrs(ctx, %{evidence_claim_ids: Enum.map(claims, & &1.id)}),
                   actor: ctx.agent
                 )
      end

      assert lead_status(ctx, ctx.lead) == :qualifying
      assert {:ok, nil} = Research.current_qualification(ctx.lead.id, actor: ctx.admin)
    end

    test "agent provenance: an LLM qualification decision of the same run", ctx do
      deterministic = F.decision!(ctx.tenant, ctx.run, ctx.lead, "qualified")
      %{run: other_run} = F.run!(ctx.tenant)

      for overrides <- [
            %{decision_id: deterministic.id},
            %{agent_run_id: other_run.id},
            %{agent_run_id: nil}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Research.record_qualification(attrs(ctx, overrides), actor: ctx.agent),
               inspect(overrides)
      end
    end

    test "the lead must be qualifying; a refused transition stores no qualification", ctx do
      {:ok, _} = Sales.update(ctx.lead, :stop, %{status_reason: "manual"}, actor: ctx.admin)

      assert {:error, _} = Research.record_qualification(attrs(ctx), actor: ctx.agent)
      assert {:ok, nil} = Research.current_qualification(ctx.lead.id, actor: ctx.admin)
      assert events_of_type(ctx.tenant, "research.qualification.recorded") == []
    end

    test "humans cannot record agent qualifications", ctx do
      for actor <- [ctx.admin, ctx.reviewer] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Research.record_qualification(attrs(ctx), actor: actor)
      end
    end
  end

  describe "Qualification lineage and human override" do
    setup ctx do
      %{lead: lead, qualification: qualification, claim: claim} =
        F.qualified_lead!(ctx.tenant)

      %{lead: lead, qualification: qualification, claim: claim}
    end

    defp override(ctx, overrides \\ %{}) do
      Map.merge(
        %{
          lead_id: ctx.lead.id,
          icp_definition_id: ctx.qualification.icp_definition_id,
          supersedes_id: ctx.qualification.id,
          qualified: false,
          score: 30,
          criteria: %{
            company_size: :pass,
            industry: :fail,
            geography: :pass,
            persona: :unknown,
            trigger: :pass
          },
          confidence: 0.9,
          reason: "Industry does not fit after manual review.",
          output_schema_version: "qualification_result/1",
          evidence_claim_ids: [ctx.claim.id]
        },
        overrides
      )
    end

    test "REV overrides the current qualification; the lead does not move", ctx do
      {:ok, overridden} = Research.override_qualification(override(ctx), actor: ctx.reviewer)

      assert overridden.source == :human_override
      assert overridden.created_by_user_id == ctx.reviewer.id
      assert overridden.supersedes_id == ctx.qualification.id
      assert overridden.decision_id == ctx.qualification.decision_id
      assert overridden.agent_run_id == nil
      assert lead_status(ctx, ctx.lead) == :qualified

      assert {:ok, current} = Research.current_qualification(ctx.lead.id, actor: ctx.admin)
      assert current.id == overridden.id
      assert length(events_of_type(ctx.tenant, "research.qualification.recorded")) == 2
    end

    test "an override must supersede the current row, and has a reason", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Research.override_qualification(override(ctx, %{supersedes_id: nil}),
                 actor: ctx.admin
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Research.override_qualification(override(ctx, %{reason: nil}), actor: ctx.admin)

      {:ok, _} = Research.override_qualification(override(ctx), actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Research.override_qualification(override(ctx), actor: ctx.admin)
    end

    test "AGT cannot override", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Research.override_qualification(override(ctx), actor: ctx.agent)
    end

    test "evidence rows exist only through their qualification", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               SdrAgent.Research.QualificationEvidence
               |> Ash.Changeset.for_create(
                 :link,
                 %{qualification_id: ctx.qualification.id, evidence_claim_id: ctx.claim.id},
                 actor: ctx.agent
               )
               |> Ash.create()
    end
  end

  describe "agent re-qualification after a reopen" do
    test "a new agent qualification must supersede the current one", ctx do
      %{lead: lead, qualification: first} = F.qualified_lead!(ctx.tenant, false)
      {:ok, lead} = Sales.update(lead, :reopen, %{}, actor: ctx.admin)
      %{run: run} = F.run!(ctx.tenant)

      {:ok, lead} =
        Sales.update(
          lead,
          :start_research,
          %{decision_id: F.decision!(ctx.tenant, run, lead, "r").id}, actor: ctx.agent)

      {:ok, lead} =
        Sales.update(
          lead,
          :start_qualifying,
          %{decision_id: F.decision!(ctx.tenant, run, lead, "q").id}, actor: ctx.agent)

      %{artifact: artifact, run: run} = F.artifact!(ctx.tenant, lead)
      claim = F.claim!(ctx.tenant, artifact, run)
      decision = F.qualification_decision!(ctx.tenant, run, lead)
      icp = %{id: first.icp_definition_id}
      attrs = F.qualification_attrs(lead, icp, run, decision, [claim])

      assert {:error, %Ash.Error.Invalid{}} =
               Research.record_qualification(attrs, actor: ctx.agent)

      assert lead_status(ctx, lead) == :qualifying

      {:ok, second} =
        Research.record_qualification(Map.put(attrs, :supersedes_id, first.id), actor: ctx.agent)

      assert second.supersedes_id == first.id
      assert lead_status(ctx, lead) == :qualified
    end
  end
end
