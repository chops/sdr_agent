defmodule SdrAgent.Demo.SeedTest do
  @moduledoc """
  The demo seed (`mix sdr.demo.seed`): the fixture data set with fixture ids
  and fixed timestamps, idempotent and deterministic, written only by the
  seeder and only where seeding is allowed.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Accounts
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Demo.Seed

  @resources [
    SdrAgent.Accounts.User,
    SdrAgent.Sales.IcpDefinition,
    SdrAgent.Sales.Sequence,
    SdrAgent.Sales.SequenceStep,
    SdrAgent.Sales.Campaign,
    SdrAgent.Sales.Account,
    SdrAgent.Sales.Contact,
    SdrAgent.Sales.Lead,
    SdrAgent.Outreach.Suppression
  ]

  # Differ by construction between runs: the tenant is bootstrapped with a
  # fresh id, rows carry their span ids, and bcrypt salts every hash.
  @volatile [:tenant_id, :trace_id, :span_id, :hashed_password]

  defp tenant_id do
    {:ok, id} = Kernel.singleton_tenant_id()
    id
  end

  defp rows(resource) do
    resource
    |> Ash.read!(Kernel.opts(tenant_id()))
    |> Enum.sort_by(& &1.id)
  end

  defp snapshot do
    Map.new(@resources, fn resource ->
      {resource,
       Enum.map(rows(resource), &(&1 |> RecordHash.canonical_map() |> Map.drop(@volatile)))}
    end)
  end

  defp tenant, do: %{id: tenant_id()}

  test "seeds the demo data set with fixture ids, fixed timestamps and compliance defaults" do
    assert {:ok, _summary} = Seed.run()

    users = rows(SdrAgent.Accounts.User)
    assert Enum.map(users, & &1.id) == Enum.sort(Enum.map(Fixtures.users(), & &1.id))
    assert Enum.sort(Enum.map(users, & &1.role)) == [:admin, :auditor, :reviewer]

    assert [icp] = rows(SdrAgent.Sales.IcpDefinition)
    assert {icp.id, icp.status} == {Fixtures.icp().id, :active}
    assert [sequence] = rows(SdrAgent.Sales.Sequence)
    assert sequence.status == :active
    assert length(rows(SdrAgent.Sales.SequenceStep)) == 2

    assert [campaign] = rows(SdrAgent.Sales.Campaign)
    assert campaign.status == :active
    assert campaign.timezone == "America/Denver"
    assert {campaign.quiet_hours_start, campaign.quiet_hours_end} == {~T[18:00:00], ~T[08:00:00]}

    assert {campaign.sender_name, to_string(campaign.sender_email)} ==
             {"Demo SDR", "sdr@example.test"}

    accounts = rows(SdrAgent.Sales.Account)
    contacts = rows(SdrAgent.Sales.Contact)
    leads = rows(SdrAgent.Sales.Lead)
    assert length(accounts) == 10 and length(contacts) == 10 and length(leads) == 10
    # Every lead is new except the suppressed contact's, which its seeded
    # Suppression stopped (S8: suppression side effects).
    suppressed = MapSet.new(Fixtures.suppressed_contact_emails())
    stopped = for c <- contacts, MapSet.member?(suppressed, to_string(c.email)), do: c.id
    {stopped_leads, new_leads} = Enum.split_with(leads, &(&1.contact_id in stopped))
    assert Enum.all?(new_leads, &(&1.status == :new))
    assert [_ | _] = stopped_leads
    assert Enum.all?(stopped_leads, &(&1.status == :stopped))
    assert Enum.all?(accounts, &String.ends_with?(to_string(&1.domain), ".test"))

    assert Enum.all?(
             contacts ++ users,
             &String.match?(to_string(&1.email), ~r/@[a-z0-9.-]+\.test$/)
           )

    epoch = Fixtures.epoch()

    for row <- users ++ accounts ++ contacts ++ leads ++ [icp, sequence, campaign] do
      assert DateTime.compare(row.inserted_at, epoch) in [:eq, :gt]
      assert DateTime.diff(row.inserted_at, epoch, :second) < 3600
    end

    assert SdrAgent.Clock.source() == :system_utc
  end

  test "designates qualified, disqualified and suppressed outcomes for later slices" do
    {:ok, _} = Seed.run()
    outcomes = Enum.frequencies_by(Fixtures.accounts(), & &1.expected_outcome)
    assert outcomes[:qualify] >= 1
    assert outcomes[:disqualify] >= 1

    contact_emails = MapSet.new(rows(SdrAgent.Sales.Contact), &to_string(&1.email))
    assert [_ | _] = suppressed = Fixtures.suppressed_contact_emails()
    assert Enum.all?(suppressed, &MapSet.member?(contact_emails, &1))
  end

  test "seeds one email Suppression per designated contact (S8)" do
    {:ok, _} = Seed.run()
    suppressions = rows(SdrAgent.Outreach.Suppression)

    assert Enum.sort(Enum.map(suppressions, &to_string(&1.value))) ==
             Enum.sort(Fixtures.suppressed_contact_emails())

    assert Enum.all?(suppressions, &(&1.scope == :email and &1.reason == :manual))
    assert Enum.map(suppressions, & &1.id) == Enum.sort(Enum.map(Fixtures.suppressions(), & &1.id))
  end

  test "every seeded write is audited as the seeder and the chain verifies" do
    {:ok, _} = Seed.run()

    seeded =
      Enum.filter(events(tenant()), &(&1.event_type =~ ~r/^(user|sales|outreach)\./))

    assert length(seeded) > 30
    assert Enum.all?(seeded, &(&1.actor_type == :seeder))

    assert {:ok, %{valid?: true}} =
             Audit.verify_chain(actor: system_actor(:auditor_cli, tenant()))
  end

  test "is idempotent: a second run writes nothing" do
    {:ok, _} = Seed.run()
    first = snapshot()
    count = length(events(tenant()))

    assert {:ok, _} = Seed.run()
    assert snapshot() == first
    assert length(events(tenant())) == count
  end

  test "is deterministic: two runs on empty databases produce the same rows" do
    assert {:error, {:snapshot, first}} =
             Audit.transaction(fn ->
               {:ok, _} = Seed.run()
               SdrAgent.Repo.rollback({:snapshot, snapshot()})
             end)

    assert {:error, :tenant_not_bootstrapped} = Kernel.singleton_tenant_id()
    {:ok, _} = Seed.run()
    assert snapshot() == first
  end

  test "refuses where seeding is not allowed" do
    previous = Application.get_env(:sdr_agent, :seeding_allowed?)
    Application.put_env(:sdr_agent, :seeding_allowed?, false)

    try do
      assert {:error, :seeding_not_allowed} = Seed.run()
    after
      Application.put_env(:sdr_agent, :seeding_allowed?, previous)
    end

    assert {:error, :tenant_not_bootstrapped} = Kernel.singleton_tenant_id()
  end

  test "the mix task runs only in dev and test" do
    assert Mix.Tasks.Sdr.Demo.Seed.allowed_env?(:dev)
    assert Mix.Tasks.Sdr.Demo.Seed.allowed_env?(:test)
    refute Mix.Tasks.Sdr.Demo.Seed.allowed_env?(:prod)
  end

  test "seeded operators sign in with their fixture passwords" do
    {:ok, _} = Seed.run()

    for user <- Fixtures.users() do
      assert {:ok, signed_in} = Accounts.sign_in(user.email, user.password)
      assert signed_in.id == user.id
    end
  end
end
