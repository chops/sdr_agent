defmodule SdrAgent.DomainPolicyTest do
  @moduledoc """
  Auditor (AUR) contract for the S5 domains: every Accounts, Sales and
  Research mutation attempted by an auditor is denied with exactly one
  committed `authz.denied` event and changes nothing, while the auditor can
  still read the records a timeline links to.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F

  setup do
    tenant = bootstrap!()

    %{lead: qualified, qualification: qualification, claim: claim, run: run} =
      F.qualified_lead!(tenant)

    %{
      tenant: tenant,
      auditor: human(:auditor, tenant),
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      qualified: qualified,
      qualification: qualification,
      claim: claim,
      run: run,
      campaign: F.active_campaign!(tenant),
      lead: F.lead!(tenant)
    }
  end

  defp denials(tenant), do: events_of_type(tenant, "authz.denied")

  test "every S5 mutation is denied for AUR and audited once", ctx do
    aur = ctx.auditor
    icp = F.active_icp!(ctx.tenant)
    sequence = F.sequence_with_steps!(ctx.tenant)
    {:ok, [step | _]} = Sales.list_records(SdrAgent.Sales.SequenceStep, actor: ctx.admin)
    {:ok, contact} = Sales.fetch(SdrAgent.Sales.Contact, ctx.lead.contact_id, actor: ctx.admin)
    {:ok, account} = Sales.fetch(SdrAgent.Sales.Account, ctx.lead.account_id, actor: ctx.admin)
    password = %{password: "aur-password-99", password_confirmation: "aur-password-99"}
    tool = F.tool_invocation!(ctx.tenant, ctx.run)

    attempts = [
      {"create_user",
       fn ->
         Accounts.create_user(
           Map.merge(password, %{email: "aur-made@example.test", display_name: "X", role: :admin}),
           actor: aur
         )
       end},
      {"change_role", fn -> Accounts.change_role(aur, :admin, actor: aur) end},
      {"change_status", fn -> Accounts.change_status(ctx.admin, :disabled, actor: aur) end},
      {"change_password",
       fn ->
         Accounts.change_password(aur, Map.put(password, :current_password, test_password()),
           actor: aur
         )
       end},
      {"set_password", fn -> Accounts.set_password(ctx.reviewer, password, actor: aur) end},
      {"create_icp_definition", fn -> Sales.create_icp_definition(F.icp_attrs(), actor: aur) end},
      {"new_icp_version", fn -> Sales.new_icp_version(icp, %{}, actor: aur) end},
      {"retire_icp", fn -> Sales.update(icp, :retire, %{}, actor: aur) end},
      {"create_account", fn -> Sales.create_account(F.account_attrs(), actor: aur) end},
      {"update_account", fn -> Sales.update(account, :update, %{name: "x"}, actor: aur) end},
      {"archive_account", fn -> Sales.update(account, :archive, %{}, actor: aur) end},
      {"create_contact", fn -> Sales.create_contact(F.contact_attrs(account), actor: aur) end},
      {"change_email",
       fn -> Sales.update(contact, :change_email, %{email: "x@acme.test"}, actor: aur) end},
      {"create_sequence", fn -> Sales.create_sequence(%{name: "x"}, actor: aur) end},
      {"add_sequence_step",
       fn ->
         Sales.add_sequence_step(
           sequence,
           %{position: 9, channel: :email, delay_days: 1, instructions: "x"},
           actor: aur
         )
       end},
      {"update_sequence_step",
       fn -> Sales.update(step, :update, %{instructions: "x"}, actor: aur) end},
      {"activate_sequence", fn -> Sales.update(sequence, :activate, %{}, actor: aur) end},
      {"create_campaign",
       fn -> Sales.create_campaign(F.campaign_attrs(icp, nil), actor: aur) end},
      {"pause_campaign", fn -> Sales.update(ctx.campaign, :pause, %{}, actor: aur) end},
      {"create_lead",
       fn ->
         Sales.create_lead(
           %{contact_id: contact.id, account_id: account.id, source: :manual},
           actor: aur
         )
       end},
      {"assign_lead", fn -> Sales.update(ctx.lead, :assign, %{}, actor: aur) end},
      {"stop_lead", fn -> Sales.update(ctx.lead, :stop, %{status_reason: "aur"}, actor: aur) end},
      {"enroll_lead",
       fn ->
         Sales.enroll_lead(%{campaign_id: ctx.campaign.id, lead_id: ctx.qualified.id},
           actor: aur
         )
       end},
      {"record_artifact",
       fn ->
         Research.record_artifact(F.artifact_attrs(ctx.lead, ctx.run, tool), actor: aur)
       end},
      {"record_claim",
       fn ->
         Research.record_claim(
           %{research_artifact_id: ctx.claim.research_artifact_id, lead_id: ctx.claim.lead_id},
           actor: aur
         )
       end},
      {"record_qualification",
       fn -> Research.record_qualification(%{lead_id: ctx.qualified.id}, actor: aur) end},
      {"override_qualification",
       fn ->
         Research.override_qualification(
           %{lead_id: ctx.qualified.id, supersedes_id: ctx.qualification.id},
           actor: aur
         )
       end}
    ]

    before = length(events(ctx.tenant))

    for {{label, attempt}, index} <- Enum.with_index(attempts, 1) do
      assert {:error, %Ash.Error.Forbidden{}} = attempt.(), label

      assert length(denials(ctx.tenant)) == index,
             "#{label} must append exactly one authz.denied"
    end

    # Nothing but the denials was appended.
    assert length(events(ctx.tenant)) == before + length(attempts)

    for denied <- denials(ctx.tenant) do
      assert {denied.actor_type, denied.actor_role, denied.actor_id} ==
               {:user, :auditor, aur.id}
    end
  end

  test "AUR reads the Sales and Research records a timeline links to", ctx do
    for resource <- [
          SdrAgent.Sales.Lead,
          SdrAgent.Sales.Account,
          SdrAgent.Sales.Contact,
          SdrAgent.Sales.Campaign,
          SdrAgent.Sales.IcpDefinition
        ] do
      assert {:ok, [_ | _]} = Sales.list_records(resource, actor: ctx.auditor), inspect(resource)
    end

    for resource <- [
          SdrAgent.Research.ResearchArtifact,
          SdrAgent.Research.EvidenceClaim,
          SdrAgent.Research.Qualification,
          SdrAgent.Research.QualificationEvidence
        ] do
      assert {:ok, [_ | _]} = Research.list_records(resource, actor: ctx.auditor),
             inspect(resource)
    end

    assert denials(ctx.tenant) == []
  end

  test "anonymous callers read nothing", ctx do
    assert {:ok, []} = Sales.list_records(SdrAgent.Sales.Lead, actor: nil)
    assert {:ok, []} = Research.list_records(SdrAgent.Research.Qualification, actor: nil)
    assert {:ok, %{valid?: true}} = SdrAgent.Audit.verify_chain(actor: ctx.admin)
  end
end
