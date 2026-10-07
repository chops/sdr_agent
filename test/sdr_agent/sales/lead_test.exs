defmodule SdrAgent.Sales.LeadTest do
  @moduledoc """
  S2 rows Lead and CampaignEnrollment: creation invariants, the lead
  lifecycle (who may move it, decisions on agent transitions, from/to in
  every event), the hand-off queue, and enrollment preconditions and
  transitions.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Sales
  alias SdrAgent.Sales.Lead
  alias SdrAgent.SalesFixtures, as: F

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      agent: system_actor(:agent_runtime, tenant),
      webhook: system_actor(:webhook_ingestor, tenant),
      delivery: system_actor(:delivery_worker, tenant)
    }
  end

  defp lead_attrs(contact),
    do: %{contact_id: contact.id, account_id: contact.account_id, source: :manual}

  describe "creating leads" do
    test "ADM creates a new lead for a contact; audited", ctx do
      contact = F.contact!(ctx.tenant)
      {:ok, lead} = Sales.create_lead(lead_attrs(contact), actor: ctx.admin)

      assert lead.status == :new
      assert lead.tenant_id == ctx.tenant.id
      assert [event] = events_of_type(ctx.tenant, "sales.lead.created")
      assert event.subject_id == lead.id
    end

    test "the account must be the contact's, and active", ctx do
      contact = F.contact!(ctx.tenant)
      other = F.account!(ctx.tenant)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.create_lead(%{lead_attrs(contact) | account_id: other.id}, actor: ctx.admin)

      {:ok, account} =
        Sales.get(SdrAgent.Sales.Account, contact.account_id, actor: ctx.admin)

      {:ok, _} = Sales.update(account, :archive, %{}, actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.create_lead(lead_attrs(contact), actor: ctx.admin)
    end

    test "a contact has at most one open lead", ctx do
      contact = F.contact!(ctx.tenant)
      {:ok, lead} = Sales.create_lead(lead_attrs(contact), actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.create_lead(lead_attrs(contact), actor: ctx.admin)

      {:ok, _} = Sales.update(lead, :stop, %{status_reason: "manual stop"}, actor: ctx.admin)
      assert {:ok, _} = Sales.create_lead(lead_attrs(contact), actor: ctx.admin)
    end

    test "REV, AGT and DLV cannot create leads", ctx do
      contact = F.contact!(ctx.tenant)

      for actor <- [ctx.reviewer, ctx.agent, ctx.delivery] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.create_lead(lead_attrs(contact), actor: actor)
      end
    end
  end

  describe "lead lifecycle" do
    test "the declared transition table matches the transition actions" do
      assert F.declared(Lead) == F.transition_actions(Lead)

      non_terminal = [
        :assigned,
        :blocked,
        :in_outreach,
        :new,
        :qualified,
        :qualifying,
        :replied,
        :researching
      ]

      assert F.declared(Lead) ==
               Enum.sort([
                 {:assign, [:new], :assigned},
                 {:start_research, [:assigned], :researching},
                 {:start_qualifying, [:researching], :qualifying},
                 {:qualify, [:qualifying], :qualified},
                 {:disqualify, [:qualifying], :disqualified},
                 {:start_outreach, [:qualified], :in_outreach},
                 {:mark_replied, [:in_outreach], :replied},
                 {:convert, [:replied], :converted},
                 {:nurture, [:replied], :nurture},
                 {:stop, non_terminal, :stopped},
                 {:block, [:qualifying, :researching], :blocked},
                 {:retry, [:blocked], :assigned},
                 {:reopen, [:disqualified], :assigned}
               ])
    end

    test "REV assigns; AGT moves the lead with a decision; events carry from, to and decision",
         ctx do
      lead = F.lead!(ctx.tenant)
      %{run: run} = F.run!(ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} = Sales.update(lead, :assign, %{}, actor: ctx.agent)

      {:ok, lead} =
        Sales.update(lead, :assign, %{owner_user_id: ctx.reviewer.id}, actor: ctx.reviewer)

      assert lead.status == :assigned
      assert lead.owner_user_id == ctx.reviewer.id
      assert %DateTime{} = lead.assigned_at

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(lead, :start_research, %{}, actor: ctx.agent)

      decision = F.decision!(ctx.tenant, run, lead, "research")

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(lead, :start_research, %{decision_id: decision.id},
                 actor: ctx.reviewer
               )

      {:ok, lead} =
        Sales.update(lead, :start_research, %{decision_id: decision.id}, actor: ctx.agent)

      assert lead.status == :researching
      assert lead.last_decision_id == decision.id

      assert [event] = events_of_type(ctx.tenant, "sales.lead.research_started")
      assert event.payload["previous"]["status"] == "assigned"
      assert event.payload["changes"]["status"] == "researching"
      assert event.payload["changes"]["last_decision_id"] == decision.id
      assert event.actor_type == :agent_runtime
    end

    test "a transition from the wrong state is refused and changes nothing", ctx do
      lead = F.lead!(ctx.tenant)
      %{run: run} = F.run!(ctx.tenant)
      decision = F.decision!(ctx.tenant, run, lead, "research")

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(lead, :start_research, %{decision_id: decision.id}, actor: ctx.agent)

      {:ok, stopped} = Sales.update(lead, :stop, %{status_reason: "manual"}, actor: ctx.reviewer)
      assert %DateTime{} = stopped.closed_at

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(stopped, :assign, %{}, actor: ctx.reviewer)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(stopped, :stop, %{status_reason: "again"}, actor: ctx.reviewer)

      # A stale struct cannot move a row that has already moved on.
      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(lead, :assign, %{}, actor: ctx.reviewer)
    end

    test "qualified and disqualified are reachable only through a Qualification", ctx do
      lead = F.lead_in!(ctx.tenant, :qualifying)
      %{run: run} = F.run!(ctx.tenant)
      decision = F.decision!(ctx.tenant, run, lead, "qualified")

      for action <- [:qualify, :disqualify] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.update(lead, action, %{decision_id: decision.id}, actor: ctx.agent)
      end
    end

    test "AGT blocks a lead with a reason; only ADM retries it", ctx do
      lead = F.lead_in!(ctx.tenant, :researching)
      %{run: run} = F.run!(ctx.tenant)
      decision = F.decision!(ctx.tenant, run, lead, "blocked")

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(lead, :block, %{decision_id: decision.id}, actor: ctx.agent)

      {:ok, blocked} =
        Sales.update(lead, :block, %{decision_id: decision.id, status_reason: "provider down"},
          actor: ctx.agent
        )

      assert blocked.status == :blocked
      assert blocked.status_reason == "provider down"

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(blocked, :retry, %{}, actor: ctx.reviewer)

      {:ok, retried} = Sales.update(blocked, :retry, %{}, actor: ctx.admin)
      assert retried.status == :assigned
    end

    test "REV and WHK stop a lead with a reason; DLV cannot", ctx do
      lead = F.lead_in!(ctx.tenant, :assigned)

      assert {:error, %Ash.Error.Invalid{}} = Sales.update(lead, :stop, %{}, actor: ctx.reviewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(lead, :stop, %{status_reason: "x"}, actor: ctx.delivery)

      {:ok, stopped} =
        Sales.update(lead, :stop, %{status_reason: "unsubscribe"}, actor: ctx.webhook)

      assert stopped.status == :stopped
      assert [event] = events_of_type(ctx.tenant, "sales.lead.stopped")
      assert event.payload["previous"]["status"] == "assigned"
      assert event.payload["changes"]["status_reason"] == "unsubscribe"
    end

    test "replied leads form the hand-off queue; REV converts or nurtures them", ctx do
      [first, second] =
        for _ <- 1..2 do
          %{lead: lead} = F.qualified_lead!(ctx.tenant)
          %{run: run} = F.run!(ctx.tenant)
          decision = F.decision!(ctx.tenant, run, lead, "outreach")

          {:ok, lead} =
            Sales.update(lead, :start_outreach, %{decision_id: decision.id}, actor: ctx.agent)

          assert {:error, %Ash.Error.Forbidden{}} =
                   Sales.update(lead, :mark_replied, %{}, actor: ctx.agent)

          {:ok, lead} = Sales.update(lead, :mark_replied, %{}, actor: ctx.webhook)
          assert %DateTime{} = lead.handed_off_at
          lead
        end

      assert {:ok, queue} = Sales.list_handoff_queue(actor: ctx.reviewer)
      assert Enum.map(queue, & &1.id) == [first.id, second.id]

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(first, :convert, %{}, actor: ctx.agent)

      {:ok, converted} = Sales.update(first, :convert, %{}, actor: ctx.reviewer)
      assert converted.status == :converted
      {:ok, nurtured} = Sales.update(second, :nurture, %{}, actor: ctx.admin)
      assert nurtured.status == :nurture
      assert {:ok, []} = Sales.list_handoff_queue(actor: ctx.reviewer)
    end

    test "ADM reopens a disqualified lead", ctx do
      %{lead: lead} = F.qualified_lead!(ctx.tenant, false)
      assert lead.status == :disqualified

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(lead, :reopen, %{}, actor: ctx.reviewer)

      {:ok, reopened} = Sales.update(lead, :reopen, %{}, actor: ctx.admin)
      assert reopened.status == :assigned
      assert reopened.closed_at == nil
    end
  end

  describe "CampaignEnrollment" do
    test "AGT enrolls a qualified lead in an active campaign once", ctx do
      campaign = F.active_campaign!(ctx.tenant)
      %{lead: lead} = F.qualified_lead!(ctx.tenant)

      for actor <- [ctx.reviewer, ctx.admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: lead.id}, actor: actor)
      end

      {:ok, enrollment} =
        Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: lead.id}, actor: ctx.agent)

      assert enrollment.status == :active
      assert enrollment.current_step_position == 0
      assert %DateTime{} = enrollment.enrolled_at
      assert [_] = events_of_type(ctx.tenant, "sales.enrollment.created")

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: lead.id}, actor: ctx.agent)
    end

    test "unqualified leads and inactive campaigns are refused", ctx do
      campaign = F.active_campaign!(ctx.tenant)
      unqualified = F.lead_in!(ctx.tenant, :assigned)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: unqualified.id},
                 actor: ctx.agent
               )

      %{lead: lead} = F.qualified_lead!(ctx.tenant)
      {:ok, paused} = Sales.update(campaign, :pause, %{}, actor: ctx.reviewer)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.enroll_lead(%{campaign_id: paused.id, lead_id: lead.id}, actor: ctx.agent)
    end

    test "REV pauses, resumes and stops; WHK marks replied; transition table", ctx do
      campaign = F.active_campaign!(ctx.tenant)
      %{lead: lead} = F.qualified_lead!(ctx.tenant)

      {:ok, enrollment} =
        Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: lead.id}, actor: ctx.agent)

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(enrollment, :pause, %{}, actor: ctx.agent)

      {:ok, paused} = Sales.update(enrollment, :pause, %{}, actor: ctx.reviewer)
      {:ok, active} = Sales.update(paused, :resume, %{}, actor: ctx.reviewer)
      assert active.status == :active

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(active, :stop, %{}, actor: ctx.reviewer)

      {:ok, replied} = Sales.update(active, :mark_replied, %{}, actor: ctx.webhook)
      assert replied.status == :replied

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(replied, :stop, %{stop_reason: :manual}, actor: ctx.reviewer)

      enrollment_module = SdrAgent.Sales.CampaignEnrollment
      assert F.declared(enrollment_module) == F.transition_actions(enrollment_module)

      assert F.declared(enrollment_module) ==
               Enum.sort([
                 {:pause, [:active], :paused},
                 {:resume, [:paused], :active},
                 {:mark_replied, [:active, :paused], :replied},
                 {:stop, [:active, :paused], :stopped}
               ])
    end

    test "WHK stops an enrollment with a reason", ctx do
      campaign = F.active_campaign!(ctx.tenant)
      %{lead: lead} = F.qualified_lead!(ctx.tenant)

      {:ok, enrollment} =
        Sales.enroll_lead(%{campaign_id: campaign.id, lead_id: lead.id}, actor: ctx.agent)

      {:ok, stopped} =
        Sales.update(enrollment, :stop, %{stop_reason: :unsubscribe}, actor: ctx.webhook)

      assert {stopped.status, stopped.stop_reason} == {:stopped, :unsubscribe}
    end
  end
end
