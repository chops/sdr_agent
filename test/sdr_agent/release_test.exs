defmodule SdrAgent.ReleaseTest do
  @moduledoc """
  The hosted release seed (`SdrAgent.Release.seed_hosted/0`, run by
  `scripts/deploy.sh` after the migrations): with the dev/test seeding flag
  off, as in production, it bootstraps the tenant, creates exactly one
  operator — the owner named by `SDR_OWNER_EMAIL`, an active admin with no
  usable password — and the synthetic demo content through the domain APIs;
  it never creates the fixture operators, refuses without `SDR_OWNER_EMAIL`
  and is idempotent.

  Reuse (Codex M1): an existing database is accepted only when its one
  operator is the owner as an active admin of the expected tenant; any other
  identity state fails before any content write, and no user is deleted,
  promoted or reset. Follow-ups (Codex M4, D-218 item 9): the seeded
  sequence has only its first touch, and a rerun contains a follow-up step an
  earlier seed activated (its campaign archived, its sequence retired, by the
  owner through the ordinary audited actions).
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
  alias SdrAgent.Sales

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

  # The seed's outcome without letting a raise end the test: {:ok, result}
  # or {:raised, exception}.
  defp seed_outcome do
    {:ok, Release.seed_hosted()}
  rescue
    error -> {:raised, error}
  end

  defp refusal_message({:raised, error}), do: Exception.message(error)
  defp refusal_message(other), do: inspect(other, limit: 5)

  # Every row and event as they are now, to prove a refusal wrote nothing.
  defp state, do: {snapshot(), length(events(%{id: tenant_id()}))}

  defp owner_password, do: "hosted-owner-test-" <> Base.encode16(:crypto.strong_rand_bytes(8))

  # The owner as the e8f041b9 seed made it: the tenant's first admin.
  defp bootstrap_owner!(tenant) do
    password = owner_password()

    {:ok, owner} =
      Accounts.bootstrap_admin(
        %{
          email: String.downcase(@owner),
          display_name: "Owner",
          password: password,
          password_confirmation: password
        },
        tenant_id: tenant.id
      )

    owner
  end

  # What the e8f041b9 hosted seed left on sdr.a-z.bot: an active ICP, the
  # active two-step fixture sequence (step 2 a three-day follow-up) and an
  # active campaign on it, each written by the owner through the admin actions.
  defp legacy_hosted_state! do
    tenant = bootstrap!()
    owner = bootstrap_owner!(tenant)
    opts = [actor: owner]

    {:ok, icp} =
      Sales.create_icp_definition(
        Map.take(Fixtures.icp(), [:name, :description, :criteria]),
        opts
      )

    {:ok, icp} = Sales.update(icp, :activate, %{}, opts)

    {:ok, sequence} =
      Sales.create_sequence(Map.take(Fixtures.sequence(), [:name, :version]), opts)

    for step <- Fixtures.sequence_steps() do
      {:ok, _step} = Sales.add_sequence_step(sequence, Map.delete(step, :id), opts)
    end

    {:ok, sequence} = Sales.update(sequence, :activate, %{}, opts)

    {:ok, campaign} =
      Fixtures.campaign()
      |> Map.delete(:id)
      |> Map.merge(%{icp_definition_id: icp.id, sequence_id: sequence.id})
      |> Sales.create_campaign(opts)

    {:ok, campaign} = Sales.update(campaign, :activate, %{}, opts)
    %{owner: owner, sequence: sequence, campaign: campaign}
  end

  defp reload!(%resource{id: id}, owner) do
    {:ok, record} = Sales.fetch(resource, id, actor: owner)
    record
  end

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

    # Follow-ups stay off on the hosted copy (Codex M4, D-218 item 9): the
    # sequence has its first touch only, no follow-up step.
    assert Enum.map(
             rows(SdrAgent.Sales.SequenceStep),
             &{&1.sequence_id, &1.position, &1.delay_days}
           ) ==
             [{sequence.id, 1, 0}]

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

  describe "reuse of an existing database (Codex M1)" do
    test "the owner beside a second operator fails before any write; nobody is removed" do
      assert {:ok, _} = Release.seed_hosted()
      [owner] = rows(User)
      password = owner_password()

      {:ok, second} =
        Accounts.create_user(
          %{
            email: "second.operator@example.test",
            display_name: "Second operator",
            role: :reviewer,
            password: password,
            password_confirmation: password
          },
          actor: owner
        )

      before = state()
      outcome = seed_outcome()

      assert match?({:raised, %RuntimeError{}}, outcome),
             "expected a refusal, got #{inspect(outcome, limit: 5)}"

      assert refusal_message(outcome) =~ "before any content write"

      assert state() == before
      assert Enum.sort(Enum.map(rows(User), & &1.id)) == Enum.sort([owner.id, second.id])
    end

    test "a matching but disabled user fails before any write and stays disabled" do
      tenant = bootstrap!()
      owner = bootstrap_owner!(tenant)

      # No action disables the last active admin: this state is reachable only
      # by a database administrator, which the seed must still refuse.
      tamper!("UPDATE users SET status = 'disabled' WHERE id = $1", [Ecto.UUID.dump!(owner.id)])

      before = state()
      outcome = seed_outcome()

      assert match?({:raised, %RuntimeError{}}, outcome),
             "expected a refusal, got #{inspect(outcome, limit: 5)}"

      assert refusal_message(outcome) =~ "before any content write"

      assert state() == before
      assert Enum.map(rows(User), &{&1.id, &1.role, &1.status}) == [{owner.id, :admin, :disabled}]
    end

    test "a matching non-admin user fails before any write and is not promoted" do
      tenant = bootstrap!()
      Application.put_env(:sdr_agent, :seeding_allowed?, true)
      reviewer = new_human(:reviewer, tenant, %{email: String.downcase(@owner)})
      Application.put_env(:sdr_agent, :seeding_allowed?, false)

      before = state()
      outcome = seed_outcome()

      assert match?({:raised, %RuntimeError{}}, outcome),
             "expected a refusal, got #{inspect(outcome, limit: 5)}"

      assert refusal_message(outcome) =~ "before any content write"

      assert state() == before

      assert Enum.map(rows(User), &{&1.id, &1.role, &1.status}) == [
               {reviewer.id, :reviewer, :active}
             ]
    end

    test "an unexpected tenant fails before any operator or content is written" do
      {:ok, tenant} = Audit.bootstrap(slug: "elsewhere", name: "Another Tenant")
      before = state()
      outcome = seed_outcome()

      assert match?({:raised, %RuntimeError{}}, outcome),
             "expected a refusal, got #{inspect(outcome, limit: 5)}"

      assert refusal_message(outcome) =~ "before any content write"

      assert state() == before
      assert {:ok, tenant.id} == Kernel.singleton_tenant_id()
    end

    test "the valid owner's rerun creates nothing, contains nothing and appends no event" do
      assert {:ok, _} = Release.seed_hosted()
      before = state()

      assert Release.seed_hosted() |> elem(1) |> Map.take([:created, :contained]) ==
               %{created: 0, contained: 0}

      assert state() == before
    end
  end

  describe "follow-up containment (Codex M4, D-218 item 9)" do
    test "a rerun contains the follow-up step an earlier seed activated" do
      %{owner: owner, sequence: legacy, campaign: legacy_campaign} = legacy_hosted_state!()
      count = length(events(%{id: tenant_id()}))

      assert {:ok, _} = Release.seed_hosted()

      # The legacy rows stay (nothing is deleted); they are closed by the owner.
      assert {reload!(legacy, owner).status, reload!(legacy_campaign, owner).status} ==
               {:retired, :archived}

      contained =
        events(%{id: tenant_id()})
        |> Enum.drop(count)
        |> Enum.filter(&(&1.event_type in ["sales.campaign.archived", "sales.sequence.retired"]))
        |> Enum.map(&{&1.event_type, &1.subject_id, &1.actor_id})

      assert contained == [
               {"sales.campaign.archived", legacy_campaign.id, owner.id},
               {"sales.sequence.retired", legacy.id, owner.id}
             ]

      # The demo runs on a first-touch-only sequence and an active campaign on it.
      active = Enum.filter(rows(Sales.Sequence), &(&1.status == :active))
      assert length(active) == 1
      [sequence] = active

      assert Enum.map(
               Enum.filter(rows(Sales.SequenceStep), &(&1.sequence_id == sequence.id)),
               & &1.position
             ) ==
               [1]

      open = Enum.filter(rows(Sales.Campaign), &(&1.status in [:draft, :active, :paused]))
      assert Enum.map(open, &{&1.status, &1.sequence_id}) == [{:active, sequence.id}]
      assert length(rows(Sales.SequenceStep)) == 3

      before = state()

      assert Release.seed_hosted() |> elem(1) |> Map.take([:created, :contained]) ==
               %{created: 0, contained: 0}

      assert state() == before
    end
  end
end
