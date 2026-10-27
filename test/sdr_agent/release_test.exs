defmodule SdrAgent.ReleaseTest do
  @moduledoc """
  The hosted release seed (`SdrAgent.Release.seed_hosted/0`, run by
  `scripts/deploy.sh` after the migrations): with the dev/test seeding flag
  off, as in production, it bootstraps the tenant, creates exactly one
  operator — the owner named by `SDR_OWNER_EMAIL`, an active admin with no
  usable password — and the synthetic demo content through the domain APIs;
  it never creates the fixture operators, refuses without `SDR_OWNER_EMAIL`
  and is idempotent.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Release

  @owner "Hosted.Owner@Example.test"

  @resources [
    SdrAgent.Accounts.User,
    SdrAgent.Sales.IcpDefinition,
    SdrAgent.Sales.Sequence,
    SdrAgent.Sales.SequenceStep,
    SdrAgent.Sales.Campaign,
    SdrAgent.Sales.Account,
    SdrAgent.Sales.Contact,
    SdrAgent.Sales.Lead,
    SdrAgent.Outreach.Suppression,
    SdrAgent.Agents.SettingsRevision
  ]

  setup do
    previous_owner = System.get_env("SDR_OWNER_EMAIL")
    previous_seeding = Application.fetch_env(:sdr_agent, :seeding_allowed?)

    on_exit(fn ->
      if previous_owner,
        do: System.put_env("SDR_OWNER_EMAIL", previous_owner),
        else: System.delete_env("SDR_OWNER_EMAIL")

      case previous_seeding do
        {:ok, value} -> Application.put_env(:sdr_agent, :seeding_allowed?, value)
        :error -> Application.delete_env(:sdr_agent, :seeding_allowed?)
      end
    end)

    # Production has no seeding flag: the dev/test seed (and its fixture
    # operators) is refused there.
    Application.put_env(:sdr_agent, :seeding_allowed?, false)
    System.put_env("SDR_OWNER_EMAIL", @owner)
    :ok
  end

  defp tenant_id do
    {:ok, id} = Kernel.singleton_tenant_id()
    id
  end

  defp rows(resource) do
    resource
    |> Ash.read!(Kernel.opts(tenant_id()))
    |> Enum.sort_by(& &1.id)
  end

  defp snapshot,
    do: Map.new(@resources, &{&1, Enum.map(rows(&1), fn r -> RecordHash.canonical_map(r) end)})

  test "refuses without SDR_OWNER_EMAIL (or with a blank one) before writing anything" do
    for value <- [nil, "", "   "] do
      if value,
        do: System.put_env("SDR_OWNER_EMAIL", value),
        else: System.delete_env("SDR_OWNER_EMAIL")

      assert_raise RuntimeError, ~r/SDR_OWNER_EMAIL/, &Release.seed_hosted/0
    end

    assert {:error, :tenant_not_bootstrapped} = Kernel.singleton_tenant_id()
  end

  test "creates exactly one operator: the owner, an active admin with no usable password" do
    assert {:ok, %{created: created}} = Release.seed_hosted()
    assert created > 0

    assert [owner] = rows(User)
    assert to_string(owner.email) == String.downcase(@owner)
    assert {owner.role, owner.status} == {:admin, :active}

    fixture_ids = MapSet.new(Fixtures.users(), & &1.id)
    fixture_emails = MapSet.new(Fixtures.users(), & &1.email)
    refute MapSet.member?(fixture_ids, owner.id)
    refute MapSet.member?(fixture_emails, to_string(owner.email))

    # No password signs the owner in, the fixture ones included.
    for password <- ["", @owner | Enum.map(Fixtures.users(), & &1.password)] do
      assert {:error, _} = Accounts.sign_in(@owner, password)
    end

    for fixture <- Fixtures.users() do
      assert {:error, _} = Accounts.sign_in(fixture.email, fixture.password)
    end
  end

  test "seeds the synthetic demo content on reserved domains, written by the owner" do
    assert {:ok, _summary} = Release.seed_hosted()
    [owner] = rows(User)

    assert [icp] = rows(SdrAgent.Sales.IcpDefinition)
    assert {icp.name, icp.status} == {Fixtures.icp().name, :active}
    assert [sequence] = rows(SdrAgent.Sales.Sequence)
    assert sequence.status == :active
    assert length(rows(SdrAgent.Sales.SequenceStep)) == 2

    assert [campaign] = rows(SdrAgent.Sales.Campaign)

    assert {campaign.status, campaign.icp_definition_id, campaign.sequence_id} ==
             {:active, icp.id, sequence.id}

    assert {campaign.timezone, campaign.quiet_hours_start, campaign.quiet_hours_end} ==
             {"America/Denver", ~T[18:00:00], ~T[08:00:00]}

    accounts = rows(SdrAgent.Sales.Account)
    contacts = rows(SdrAgent.Sales.Contact)
    leads = rows(SdrAgent.Sales.Lead)

    assert Enum.sort(Enum.map(accounts, &to_string(&1.domain))) ==
             Enum.sort(Enum.map(Fixtures.accounts(), & &1.domain))

    # The fixture research sources key on these (FakeCRM, FixtureWeb).
    assert Enum.sort(Enum.map(accounts, &{&1.crm_external_id, &1.website_url})) ==
             Enum.sort(Enum.map(Fixtures.accounts(), &{&1.crm_external_id, &1.website_url}))

    assert Enum.sort(Enum.map(contacts, &{to_string(&1.email), &1.crm_external_id})) ==
             Enum.sort(Enum.map(Fixtures.contacts(), &{&1.email, &1.crm_external_id}))

    assert length(leads) == 10
    assert Enum.all?(contacts, &String.match?(to_string(&1.email), ~r/@[a-z0-9.-]+\.test$/))

    # The suppressed contact's lead is stopped by its Suppression; the rest are new.
    suppressed = MapSet.new(Fixtures.suppressed_contact_emails())

    assert Enum.map(rows(SdrAgent.Outreach.Suppression), &to_string(&1.value)) ==
             MapSet.to_list(suppressed)

    stopped = for c <- contacts, MapSet.member?(suppressed, to_string(c.email)), do: c.id
    {stopped_leads, new_leads} = Enum.split_with(leads, &(&1.contact_id in stopped))
    assert [_] = stopped_leads
    assert Enum.all?(stopped_leads, &(&1.status == :stopped))
    assert Enum.all?(new_leads, &(&1.status == :new))

    # An assignment needs a saved offering profile (C4-R8): the synthetic one.
    agent = system_actor(:agent_runtime, %{id: tenant_id()})
    assert :ok = Agents.settings_complete(:assignment, actor: agent)

    written =
      Enum.filter(events(%{id: tenant_id()}), &(&1.event_type =~ ~r/^(sales|outreach)\./))

    assert length(written) > 30
    assert Enum.all?(written, &(&1.actor_type != :user or &1.actor_id == owner.id))
    assert Enum.count(written, &(&1.actor_id == owner.id)) > 30
    refute Enum.any?(events(%{id: tenant_id()}), &(&1.actor_type == :seeder))

    assert {:ok, %{valid?: true}} =
             Audit.verify_chain(actor: system_actor(:auditor_cli, %{id: tenant_id()}))
  end

  test "is idempotent: a second run creates nothing and appends no event" do
    assert {:ok, _} = Release.seed_hosted()
    first = snapshot()
    count = length(events(%{id: tenant_id()}))

    assert {:ok, %{created: 0}} = Release.seed_hosted()
    assert snapshot() == first
    assert length(events(%{id: tenant_id()})) == count
  end

  test "creates no operator where the tenant already has a different one" do
    tenant = bootstrap!()
    Application.put_env(:sdr_agent, :seeding_allowed?, true)
    other = human(:admin, tenant)
    Application.put_env(:sdr_agent, :seeding_allowed?, false)

    assert_raise RuntimeError, ~r/owner/, &Release.seed_hosted/0
    assert Enum.map(rows(User), & &1.id) == [other.id]
  end
end
