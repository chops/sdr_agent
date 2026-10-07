defmodule SdrAgent.Sales.CatalogTest do
  @moduledoc """
  S2 rows IcpDefinition, Account, Contact, Sequence, SequenceStep and
  Campaign: who may write them, the synthetic-data guard, immutability once
  active, and their lifecycle tables.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Sales
  alias SdrAgent.SalesFixtures, as: F

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      reviewer: human(:reviewer, tenant),
      agent: system_actor(:agent_runtime, tenant),
      seeder: system_actor(:seeder, tenant)
    }
  end

  describe "IcpDefinition" do
    test "ADM creates a draft with a canonical criteria hash; audited", ctx do
      {:ok, icp} = Sales.create_icp_definition(F.icp_attrs(), actor: ctx.admin)

      assert icp.status == :draft
      assert icp.version == 1
      assert icp.tenant_id == ctx.tenant.id
      assert byte_size(icp.criteria_sha256) == 32
      assert icp.trace_id =~ ~r/^[0-9a-f]{32}$/
      assert [event] = events_of_type(ctx.tenant, "sales.icp_definition.created")
      assert event.subject_id == icp.id

      {:ok, same} = Sales.create_icp_definition(F.icp_attrs(), actor: ctx.admin)
      assert same.criteria_sha256 == icp.criteria_sha256

      {:ok, other} =
        Sales.create_icp_definition(
          F.icp_attrs(%{criteria: %{employee_count_min: 10, industries: ["retail"]}}),
          actor: ctx.admin
        )

      refute other.criteria_sha256 == icp.criteria_sha256
    end

    test "criteria counts are non-negative and max ≥ min", ctx do
      for criteria <- [
            %{employee_count_min: -1},
            %{employee_count_min: 100, employee_count_max: 50}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Sales.create_icp_definition(F.icp_attrs(%{criteria: criteria}),
                   actor: ctx.admin
                 )
      end
    end

    test "draft edits; activation freezes criteria; new_version starts a new draft", ctx do
      {:ok, icp} = Sales.create_icp_definition(F.icp_attrs(), actor: ctx.admin)

      {:ok, icp} =
        Sales.update(icp, :update, %{description: "edited", criteria: %{industries: ["x"]}},
          actor: ctx.admin
        )

      assert icp.description == "edited"
      {:ok, active} = Sales.update(icp, :activate, %{}, actor: ctx.admin)
      assert active.status == :active

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(active, :update, %{description: "too late"}, actor: ctx.admin)

      {:ok, v2} =
        Sales.new_icp_version(active, %{criteria: %{industries: ["y"]}}, actor: ctx.admin)

      assert {v2.name, v2.version, v2.status} == {active.name, 2, :draft}
      assert [_] = events_of_type(ctx.tenant, "sales.icp_definition.version_created")

      {:ok, retired} = Sales.update(active, :retire, %{}, actor: ctx.admin)
      assert retired.status == :retired

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(retired, :activate, %{}, actor: ctx.admin)
    end

    test "transition table" do
      assert F.declared(SdrAgent.Sales.IcpDefinition) ==
               F.transition_actions(SdrAgent.Sales.IcpDefinition)

      assert F.declared(SdrAgent.Sales.IcpDefinition) ==
               Enum.sort([{:activate, [:draft], :active}, {:retire, [:active], :retired}])
    end

    test "REV and AGT read but cannot write", ctx do
      icp = F.active_icp!(ctx.tenant)

      for actor <- [ctx.reviewer, ctx.agent] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.create_icp_definition(F.icp_attrs(), actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} = Sales.update(icp, :retire, %{}, actor: actor)
        assert {:ok, [_]} = Sales.list_records(SdrAgent.Sales.IcpDefinition, actor: actor)
      end
    end
  end

  describe "Account" do
    test "ADM creates an account; the domain is normalised; audited", ctx do
      {:ok, account} =
        Sales.create_account(F.account_attrs(%{domain: "  Acme-Rail.TEST "}), actor: ctx.admin)

      assert to_string(account.domain) == "acme-rail.test"
      assert account.status == :active
      assert account.tenant_id == ctx.tenant.id
      assert [_] = events_of_type(ctx.tenant, "sales.account.created")

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.create_account(F.account_attrs(%{domain: "acme-rail.test"}),
                 actor: ctx.admin
               )
    end

    test "the synthetic-data guard admits only reserved domains", ctx do
      for domain <- ~w(acme.test acme.example acme.invalid example.com example.net
                       example.org sales.example.com) do
        assert {:ok, _} =
                 Sales.create_account(F.account_attrs(%{domain: domain}), actor: ctx.admin),
               domain
      end

      for domain <- ~w(acme.com acme.io test example notexample.com https://acme.test
                       acme.test/path example.com.evil.io) do
        assert {:error, %Ash.Error.Invalid{}} =
                 Sales.create_account(F.account_attrs(%{domain: domain}), actor: ctx.admin),
               domain
      end

      account = F.account!(ctx.tenant)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(account, :update, %{domain: "acme.com"}, actor: ctx.admin)
    end

    test "a CRM id is unique per provider when present", ctx do
      attrs = %{crm_provider: :fake_crm, crm_external_id: "crm-1"}
      {:ok, _} = Sales.create_account(F.account_attrs(attrs), actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.create_account(F.account_attrs(attrs), actor: ctx.admin)

      assert {:ok, _} = Sales.create_account(F.account_attrs(), actor: ctx.admin)
      assert {:ok, _} = Sales.create_account(F.account_attrs(), actor: ctx.admin)
    end

    test "archive is terminal; REV and AGT cannot write", ctx do
      account = F.account!(ctx.tenant)

      for actor <- [ctx.reviewer, ctx.agent] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.create_account(F.account_attrs(), actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.update(account, :archive, %{}, actor: actor)
      end

      {:ok, archived} = Sales.update(account, :archive, %{}, actor: ctx.admin)
      assert archived.status == :archived

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(archived, :update, %{name: "x"}, actor: ctx.admin)

      assert F.declared(SdrAgent.Sales.Account) == F.transition_actions(SdrAgent.Sales.Account)
      assert F.declared(SdrAgent.Sales.Account) == [{:archive, [:active], :archived}]
    end
  end

  describe "Contact" do
    test "ADM creates a contact with a reserved email; unique per tenant", ctx do
      account = F.account!(ctx.tenant)
      {:ok, contact} = Sales.create_contact(F.contact_attrs(account), actor: ctx.admin)
      assert contact.status == :active
      assert contact.account_id == account.id
      assert [_] = events_of_type(ctx.tenant, "sales.contact.created")

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.create_contact(F.contact_attrs(account, %{email: contact.email}),
                 actor: ctx.admin
               )

      for email <- ["jo@acme.com", "not-an-email", "jo@test"] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Sales.create_contact(F.contact_attrs(account, %{email: email}),
                   actor: ctx.admin
                 ),
               email
      end

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.create_contact(F.contact_attrs(account, %{timezone: "not a zone"}),
                 actor: ctx.admin
               )
    end

    test "the email changes only through change_email, which records old and new", ctx do
      contact = F.contact!(ctx.tenant)
      old = to_string(contact.email)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(contact, :update, %{email: "new@acme.test"}, actor: ctx.admin)

      {:ok, contact} =
        Sales.update(contact, :change_email, %{email: "new@acme.test"}, actor: ctx.admin)

      assert to_string(contact.email) == "new@acme.test"
      assert [event] = events_of_type(ctx.tenant, "sales.contact.email_changed")
      assert event.payload["previous"]["email"] == old
      assert event.payload["changes"]["email"] == "new@acme.test"

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(contact, :change_email, %{email: "new@acme.com"}, actor: ctx.admin)
    end

    test "archive is terminal; REV and AGT cannot write", ctx do
      contact = F.contact!(ctx.tenant)

      for actor <- [ctx.reviewer, ctx.agent] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.update(contact, :change_email, %{email: "x@acme.test"}, actor: actor)
      end

      {:ok, archived} = Sales.update(contact, :archive, %{}, actor: ctx.admin)
      assert archived.status == :archived

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(archived, :update, %{title: "CEO"}, actor: ctx.admin)

      assert F.declared(SdrAgent.Sales.Contact) == F.transition_actions(SdrAgent.Sales.Contact)
      assert F.declared(SdrAgent.Sales.Contact) == [{:archive, [:active], :archived}]
    end
  end

  describe "Sequence and SequenceStep" do
    test "steps: position 1 has no delay, positions are unique, Tier 0 flags stay true", ctx do
      {:ok, sequence} = Sales.create_sequence(%{name: "Seq"}, actor: ctx.admin)
      assert {sequence.version, sequence.status} == {1, :draft}

      step = fn attrs ->
        Sales.add_sequence_step(
          sequence,
          Map.merge(%{position: 1, channel: :email, delay_days: 0, instructions: "Hi"}, attrs),
          actor: ctx.admin
        )
      end

      assert {:error, %Ash.Error.Invalid{}} = step.(%{delay_days: 2})
      assert {:ok, first} = step.(%{})
      assert first.requires_approval and first.stop_on_reply
      assert {:error, %Ash.Error.Invalid{}} = step.(%{})
      assert {:error, %Ash.Error.Invalid{}} = step.(%{position: 2, requires_approval: false})
      assert {:error, %Ash.Error.Invalid{}} = step.(%{position: 2, stop_on_reply: false})
      assert {:error, %Ash.Error.Invalid{}} = step.(%{position: 2, channel: :sms})
      assert {:error, %Ash.Error.Invalid{}} = step.(%{position: 0})
      assert {:ok, _} = step.(%{position: 2, delay_days: 3})
      assert length(events_of_type(ctx.tenant, "sales.sequence_step.created")) == 2
    end

    test "activation needs a step and freezes the steps", ctx do
      {:ok, empty} = Sales.create_sequence(%{name: "Empty"}, actor: ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(empty, :activate, %{}, actor: ctx.admin)

      sequence = F.sequence_with_steps!(ctx.tenant)
      {:ok, [first | _]} = Sales.list_records(SdrAgent.Sales.SequenceStep, actor: ctx.admin)

      {:ok, first} =
        Sales.update(first, :update, %{instructions: "Edited while draft"}, actor: ctx.admin)

      {:ok, active} = Sales.update(sequence, :activate, %{}, actor: ctx.admin)
      assert active.status == :active

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.add_sequence_step(
                 active,
                 %{position: 3, channel: :email, delay_days: 1, instructions: "late"},
                 actor: ctx.admin
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(first, :update, %{instructions: "late"}, actor: ctx.admin)

      {:ok, retired} = Sales.update(active, :retire, %{}, actor: ctx.admin)
      assert retired.status == :retired

      assert F.declared(SdrAgent.Sales.Sequence) == F.transition_actions(SdrAgent.Sales.Sequence)

      assert F.declared(SdrAgent.Sales.Sequence) ==
               Enum.sort([{:activate, [:draft], :active}, {:retire, [:active], :retired}])
    end

    test "REV and AGT cannot write sequences or steps", ctx do
      sequence = F.sequence_with_steps!(ctx.tenant)

      for actor <- [ctx.reviewer, ctx.agent] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.create_sequence(%{name: "x"}, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.add_sequence_step(
                   sequence,
                   %{position: 3, channel: :email, delay_days: 1, instructions: "x"},
                   actor: actor
                 )

        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.update(sequence, :activate, %{}, actor: actor)
      end
    end
  end

  describe "Campaign" do
    test "compliance defaults, Tier 0 and the sender guard", ctx do
      icp = F.active_icp!(ctx.tenant)
      sequence = F.active_sequence!(ctx.tenant)
      {:ok, campaign} = Sales.create_campaign(F.campaign_attrs(icp, sequence), actor: ctx.admin)

      assert campaign.status == :draft
      assert campaign.sender_name == "Demo SDR"
      assert to_string(campaign.sender_email) == "sdr@example.test"
      assert campaign.timezone == "America/Denver"
      assert campaign.quiet_hours_start == ~T[18:00:00]
      assert campaign.quiet_hours_end == ~T[08:00:00]
      assert campaign.autonomy_tier == 0
      assert [_] = events_of_type(ctx.tenant, "sales.campaign.created")

      for attrs <- [%{sender_email: "sdr@acme.com"}, %{autonomy_tier: 1}, %{timezone: "nowhere"}] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Sales.create_campaign(F.campaign_attrs(icp, sequence, attrs), actor: ctx.admin),
               inspect(attrs)
      end
    end

    test "activation needs an active ICP and an active sequence", ctx do
      {:ok, draft_icp} = Sales.create_icp_definition(F.icp_attrs(), actor: ctx.admin)
      icp = F.active_icp!(ctx.tenant)
      draft_sequence = F.sequence_with_steps!(ctx.tenant)
      sequence = F.active_sequence!(ctx.tenant)

      for {i, s} <- [{draft_icp, sequence}, {icp, draft_sequence}, {icp, nil}] do
        {:ok, campaign} = Sales.create_campaign(F.campaign_attrs(i, s), actor: ctx.admin)

        assert {:error, %Ash.Error.Invalid{}} =
                 Sales.update(campaign, :activate, %{}, actor: ctx.admin)
      end

      {:ok, campaign} = Sales.create_campaign(F.campaign_attrs(icp, nil), actor: ctx.admin)

      {:ok, campaign} =
        Sales.update(campaign, :update, %{sequence_id: sequence.id}, actor: ctx.admin)

      assert {:ok, %{status: :active}} = Sales.update(campaign, :activate, %{}, actor: ctx.admin)
    end

    test "REV may pause and resume; only ADM activates, completes and archives", ctx do
      campaign = F.active_campaign!(ctx.tenant)

      {:ok, paused} = Sales.update(campaign, :pause, %{}, actor: ctx.reviewer)
      assert paused.status == :paused
      assert [_] = events_of_type(ctx.tenant, "sales.campaign.paused")
      {:ok, resumed} = Sales.update(paused, :resume, %{}, actor: ctx.reviewer)
      assert resumed.status == :active

      for action <- [:complete, :archive] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.update(resumed, action, %{}, actor: ctx.reviewer)
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.update(resumed, :pause, %{}, actor: ctx.agent)

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(resumed, :update, %{name: "renamed"}, actor: ctx.admin)

      {:ok, completed} = Sales.update(resumed, :complete, %{}, actor: ctx.admin)
      assert completed.status == :completed

      assert {:error, %Ash.Error.Invalid{}} =
               Sales.update(completed, :archive, %{}, actor: ctx.admin)
    end

    test "transition table" do
      assert F.declared(SdrAgent.Sales.Campaign) == F.transition_actions(SdrAgent.Sales.Campaign)

      assert F.declared(SdrAgent.Sales.Campaign) ==
               Enum.sort([
                 {:activate, [:draft], :active},
                 {:pause, [:active], :paused},
                 {:resume, [:paused], :active},
                 {:complete, [:active, :paused], :completed},
                 {:archive, [:active, :draft, :paused], :archived}
               ])
    end
  end

  describe "seeder" do
    test "SEED creates with fixture ids and activates setup rows only where seeding is allowed",
         ctx do
      id = Ecto.UUID.generate()

      assert {:ok, %{id: ^id}} =
               Sales.seed_icp_definition(Map.put(F.icp_attrs(), :id, id), actor: ctx.seeder)

      {:ok, icp} = Sales.fetch(SdrAgent.Sales.IcpDefinition, id, actor: ctx.seeder)
      assert {:ok, %{status: :active}} = Sales.update(icp, :activate, %{}, actor: ctx.seeder)

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.create_account(F.account_attrs(), actor: ctx.seeder)

      previous = Application.get_env(:sdr_agent, :seeding_allowed?)
      Application.put_env(:sdr_agent, :seeding_allowed?, false)

      try do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Sales.seed_account(Map.put(F.account_attrs(), :id, Ecto.UUID.generate()),
                   actor: ctx.seeder
                 )
      after
        Application.put_env(:sdr_agent, :seeding_allowed?, previous)
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Sales.seed_account(Map.put(F.account_attrs(), :id, Ecto.UUID.generate()),
                 actor: ctx.admin
               )
    end
  end
end
