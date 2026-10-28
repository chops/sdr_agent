defmodule SdrAgent.Prototype.SalesImportPolicyTest do
  @moduledoc """
  The three Sales `:import_prototype` actions the D-237 dossier import
  composes (interfaces r6 IF-6 "Tables"; supplement 1 r2 §5, Codex R7/R9),
  through `SdrAgent.Sales.import_prototype_account/2`,
  `import_prototype_contact/2` and `import_prototype_lead/2`:

  - allow: the live operator in prototype runtime creates an account with
    `source: :dossier` and nil size, industry and geography; a person
    contact whose work address is on its account's domain; a new lead with
    `source: :dossier` and no owner; one creation event each, attributed
    to the delegation;
  - deny (`Ash.Error.Forbidden`, nothing written): a human admin, the
    seeder, the agent runtime, no actor, the operator in ordinary runtime,
    and the operator after the live binding drifts;
  - the dataset guard (`SdrAgent.Sales.Validations.DatasetDomain`): in
    prototype runtime a non-host domain and an address off its account's
    domain are refused;
  - tenant-bound relationships (Codex 9a6dba0a R1), through both the raw
    `:import_prototype` actions and the Sales wrappers: a contact on another
    tenant's account, a lead on another tenant's account or with another
    tenant's contact, and a lead whose same-tenant contact and account do
    not match are refused with no row and no creation event; every created
    row is in the operator's tenant.

  Synthetic `.test` data in a sandboxed prototype binding. The database
  admits one tenant (`tenants.singleton` is unique), so a row of another
  tenant exists only by moving a real row's `tenant_id`
  (`SdrAgent.AuditCase.tamper!/2`, one statement with foreign keys and
  triggers off); every other prerequisite is valid.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Sales

  setup do
    fx = bound!(enter_runtime: false)
    admin = human(:admin, fx.tenant)
    enter!(fx)
    %{fx: fx, actor: fx.actor, tenant: fx.tenant, admin: admin}
  end

  @account %{
    name: "Acme 1 Logistics Software",
    domain: "acme1.test",
    website_url: "https://www.acme1.test/about"
  }

  defp account!(ctx, attrs \\ @account) do
    result = Sales.import_prototype_account(attrs, actor: ctx.actor)
    assert match?({:ok, _}, result), "import_prototype_account/2 returned #{inspect(result)}"
    {:ok, account} = result
    account
  end

  defp contact_attrs(account, overrides \\ %{}) do
    Map.merge(
      %{
        account_id: account.id,
        first_name: "Jordan",
        last_name: "Testperson",
        title: "Head of Growth",
        email: "jordan@acme1.test"
      },
      overrides
    )
  end

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  defp forbidden?(result), do: match?({:error, %Ash.Error.Forbidden{}}, result)

  # Both entry paths of each import action: the Sales wrapper and the raw
  # `:import_prototype` action.
  @paths [:wrapper, :raw]

  defp import_contact(:wrapper, attrs, actor),
    do: Sales.import_prototype_contact(attrs, actor: actor)

  defp import_contact(:raw, attrs, actor), do: raw(SdrAgent.Sales.Contact, attrs, actor)

  defp import_lead(:wrapper, attrs, actor), do: Sales.import_prototype_lead(attrs, actor: actor)
  defp import_lead(:raw, attrs, actor), do: raw(SdrAgent.Sales.Lead, attrs, actor)

  defp raw(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:import_prototype, attrs, actor: actor)
    |> Ash.create()
  end

  defp contact!(ctx, account, local) do
    result =
      Sales.import_prototype_contact(
        contact_attrs(account, %{email: "#{local}@#{account.domain}"}),
        actor: ctx.actor
      )

    assert match?({:ok, _}, result), "prerequisite: the contact returned #{inspect(result)}"
    {:ok, contact} = result
    contact
  end

  # Moves a real row to another tenant id (see the moduledoc).
  defp move_to_foreign_tenant!(table, id) do
    tamper!("UPDATE #{table} SET tenant_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(id)
    ])

    :ok
  end

  defp all_refused?(results), do: Enum.all?(results, &match?({_path, {:error, _}}, &1))

  describe "allow: the live operator in prototype runtime" do
    test "an account, its person contact and a new lead, each attributed to the delegation",
         ctx do
      account = account!(ctx)

      assert {account.source, account.industry, account.employee_count, account.geography} ==
               {:dossier, nil, nil, nil}

      assert {to_string(account.domain), account.website_url} ==
               {"acme1.test", "https://www.acme1.test/about"}

      contact_result = Sales.import_prototype_contact(contact_attrs(account), actor: ctx.actor)

      assert match?({:ok, _}, contact_result),
             "import_prototype_contact/2 returned #{inspect(contact_result)}"

      {:ok, contact} = contact_result

      lead_result =
        Sales.import_prototype_lead(%{account_id: account.id, contact_id: contact.id},
          actor: ctx.actor
        )

      assert match?({:ok, _}, lead_result),
             "import_prototype_lead/2 returned #{inspect(lead_result)}"

      {:ok, lead} = lead_result
      assert {lead.source, lead.status, lead.owner_user_id} == {:dossier, :new, nil}

      # Exact row-tenant predicates: every created row is the operator's tenant's.
      assert {account.tenant_id, contact.tenant_id, lead.tenant_id} ==
               {ctx.tenant.id, ctx.tenant.id, ctx.tenant.id}

      assert {contact.account_id, lead.account_id, lead.contact_id} ==
               {account.id, account.id, contact.id}

      for type <- ~w(sales.account.created sales.contact.created sales.lead.created) do
        assert [event] = events_of_type(ctx.tenant, type)
        assert {event.actor_type, event.actor_id} == {:prototype_operator, ctx.actor.id}
      end
    end
  end

  describe "deny" do
    test "a human admin, the seeder, the agent runtime or no actor is Forbidden, writing nothing",
         ctx do
      for {label, actor} <- [
            admin: ctx.admin,
            seeder: system_actor(:seeder, ctx.tenant),
            agent_runtime: system_actor(:agent_runtime, ctx.tenant),
            nil: nil
          ] do
        result = Sales.import_prototype_account(@account, actor: actor)

        assert forbidden?(result),
               "import_prototype_account/2 as #{label} returned #{inspect(result)}"
      end

      assert count("accounts") == 0
    end

    test "the operator outside prototype runtime is Forbidden", ctx do
      :ok = SdrAgent.PrototypeFixtures.leave_runtime()
      result = Sales.import_prototype_account(@account, actor: ctx.actor)
      assert forbidden?(result), "import_prototype_account/2 returned #{inspect(result)}"
      assert count("accounts") == 0
    end

    test "the operator after the live binding drifts is Forbidden, for each action", ctx do
      account = account!(ctx)
      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{database_oid: 1})

      results = [
        Sales.import_prototype_account(%{@account | domain: "acme2.test"}, actor: ctx.actor),
        Sales.import_prototype_contact(contact_attrs(account), actor: ctx.actor),
        Sales.import_prototype_lead(%{account_id: account.id, contact_id: Ecto.UUID.generate()},
          actor: ctx.actor
        )
      ]

      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{})

      for result <- results, do: assert(forbidden?(result), "returned #{inspect(result)}")
      assert {count("accounts"), count("contacts"), count("leads")} == {1, 0, 0}
    end
  end

  describe "the dataset guard in prototype runtime" do
    test "a non-host domain or an address off the account's domain is refused", ctx do
      bad = Sales.import_prototype_account(%{@account | domain: "not a host"}, actor: ctx.actor)
      assert match?({:error, %Ash.Error.Invalid{}}, bad), "returned #{inspect(bad)}"

      account = account!(ctx)

      off =
        Sales.import_prototype_contact(contact_attrs(account, %{email: "jordan@other.test"}),
          actor: ctx.actor
        )

      assert match?({:error, %Ash.Error.Invalid{}}, off), "returned #{inspect(off)}"
      assert {count("accounts"), count("contacts")} == {1, 0}
    end
  end

  # Codex 9a6dba0a R1: every referenced row must be in the new row's (the
  # operator's) tenant. Each path uses its own address or contact, so no
  # uniqueness rule can refuse in place of the tenant rule.
  describe "tenant-bound relationships, through the wrapper and the raw action" do
    test "a contact on another tenant's account is refused, with no row and no event", ctx do
      account = account!(ctx)
      :ok = move_to_foreign_tenant!("accounts", account.id)

      results =
        for path <- @paths do
          attrs = contact_attrs(account, %{email: "#{path}@acme1.test"})
          {path, import_contact(path, attrs, ctx.actor)}
        end

      assert all_refused?(results), "returned #{inspect(results)}"
      assert count("contacts") == 0
      assert events_of_type(ctx.tenant, "sales.contact.created") == []
    end

    test "a lead on another tenant's account is refused, with no row and no event", ctx do
      account = account!(ctx)
      contacts = Map.new(@paths, &{&1, contact!(ctx, account, &1)})
      :ok = move_to_foreign_tenant!("accounts", account.id)

      results =
        for path <- @paths do
          attrs = %{account_id: account.id, contact_id: contacts[path].id}
          {path, import_lead(path, attrs, ctx.actor)}
        end

      assert all_refused?(results), "returned #{inspect(results)}"
      assert count("leads") == 0
      assert events_of_type(ctx.tenant, "sales.lead.created") == []
    end

    test "a lead with another tenant's contact is refused, with no row and no event", ctx do
      account = account!(ctx)
      contacts = Map.new(@paths, &{&1, contact!(ctx, account, &1)})
      for {_path, contact} <- contacts, do: :ok = move_to_foreign_tenant!("contacts", contact.id)

      results =
        for path <- @paths do
          attrs = %{account_id: account.id, contact_id: contacts[path].id}
          {path, import_lead(path, attrs, ctx.actor)}
        end

      assert all_refused?(results), "returned #{inspect(results)}"
      assert count("leads") == 0
      assert events_of_type(ctx.tenant, "sales.lead.created") == []
    end

    test "a lead whose same-tenant contact and account do not match is refused", ctx do
      account = account!(ctx)
      other = account!(ctx, %{@account | domain: "acme2.test"})
      contacts = Map.new(@paths, &{&1, contact!(ctx, account, &1)})

      results =
        for path <- @paths do
          attrs = %{account_id: other.id, contact_id: contacts[path].id}
          {path, import_lead(path, attrs, ctx.actor)}
        end

      assert all_refused?(results), "returned #{inspect(results)}"
      assert count("leads") == 0
      assert events_of_type(ctx.tenant, "sales.lead.created") == []
    end
  end
end
