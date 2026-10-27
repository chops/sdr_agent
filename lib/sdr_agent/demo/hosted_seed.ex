defmodule SdrAgent.Demo.HostedSeed do
  @moduledoc """
  Seeds the hosted test copy (sdr.a-z.bot, `SdrAgent.Release.seed_hosted/0`)
  in production, where the dev/test seed is refused: the singleton tenant
  and its audit chain, exactly ONE operator — the owner — and the same
  synthetic demo content as `SdrAgent.Demo.Seed` (`SdrAgent.Demo.Fixtures`,
  every domain and email under `.test`), except that the sequence has its
  first touch only.

    * **Identity, checked before any content write.** The tenant must be the
      fixture tenant (slug `demo`). With no operator yet, the owner is created
      by the kernel's first-admin bootstrap (`Accounts.bootstrap_admin/2`,
      any environment, only while the tenant has no user): an active admin
      with the given email and a random 64-byte password that is hashed and
      never stored, returned or printed, so a NEW owner signs in only by
      magic link. Otherwise the database must hold exactly one operator, the
      owner, as an active admin; it is reused unchanged — the seed neither
      knows nor changes its password, role or status. Anything else (another
      or a second operator, a disabled or non-admin owner, another tenant)
      raises before any content write; no user is deleted, promoted or reset.
    * **No fixture operator** is ever created: this module never uses the
      seeder or its `:seed` actions, which stay refused outside dev/test
      (`SdrAgent.Audit.Checks.SeedingAllowed`); the fixture passwords are
      public.
    * **No follow-up** (Codex M4; D-218 item 9 defers the D-206 suppression
      fix of the follow-up worker only under this containment): the hosted
      sequence ("Demo first-touch email") has only the fixtures' first
      step, so a delivered first touch completes its enrollment and nothing
      is scheduled. A follow-up step an earlier hosted seed activated (the
      two-step fixture sequence, e8f041b9) is contained first, by the owner
      through the ordinary audited admin actions: each open campaign of the
      fixture campaign name on a sequence with a step after the first is
      archived, then each such active seeded sequence is retired. Nothing is
      deleted. Production also disables follow-ups outright
      (`SdrAgent.Outreach.FollowUps`), and the deploy checks the store
      afterwards (`SdrAgent.Demo.HostedContainment`).
    * **Content** is written by the owner through the ordinary admin
      actions (generated ids, real timestamps, each write audited with the
      owner as actor): the ICP, the sequence and its step, and the campaign
      (each activated), the ten accounts, contacts and leads, the one
      Suppression (which stops its contact's lead), and the synthetic
      offering profile an assignment needs (C4-R8).
    * **Idempotent:** rows are matched by natural key (owner email, ICP
      name and version, the newest first-touch-only sequence version, the
      campaign on it, account domain, contact email, the contact's lead,
      suppression value, a saved offering profile); a second run creates and
      contains nothing and appends no event.

  Returns `{:ok, %{created: n, existing: m, contained: k}}`; raises on any
  failure (it runs only from the release task). Error messages carry kinds
  and counts, never row values.
  """

  alias SdrAgent.Accounts
  alias SdrAgent.Accounts.User
  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Sales

  @sequence_name "Demo first-touch email"
  @open_campaign [:draft, :active, :paused]

  @doc "The hosted sequence's name (its only step is the fixtures' first touch)."
  def sequence_name, do: @sequence_name

  @doc "Seeds the hosted copy for `owner_email` (see the moduledoc)."
  @spec run(String.t()) ::
          {:ok,
           %{
             created: non_neg_integer(),
             existing: non_neg_integer(),
             contained: non_neg_integer()
           }}
  def run(owner_email) when is_binary(owner_email) do
    email = owner_email |> String.trim() |> String.downcase()
    if email == "", do: raise(ArgumentError, "the owner email is blank")

    {:ok, tenant} = Audit.bootstrap(Fixtures.tenant())
    expected_tenant!(tenant)
    {owner_result, owner} = owner(email, tenant.id)
    opts = [actor: owner]

    contained = contain_follow_ups(opts)
    {icp_results, icp} = icp(opts)
    {sequence_results, sequence} = sequence(opts)
    {campaign_results, _campaign} = campaign(icp, sequence, opts)
    {account_results, account_ids} = accounts(opts)
    {contact_results, contact_ids} = contacts(account_ids, opts)

    results =
      List.flatten([
        owner_result,
        icp_results,
        sequence_results,
        campaign_results,
        account_results,
        contact_results,
        leads(account_ids, contact_ids, opts),
        suppressions(opts),
        offering(tenant.id, opts)
      ])

    {:ok,
     %{
       created: Enum.count(results, &(&1 == :created)),
       existing: Enum.count(results, &(&1 == :existing)),
       contained: contained
     }}
  end

  ## Identity (before any content write)

  defp expected_tenant!(tenant) do
    if tenant.slug != Keyword.fetch!(Fixtures.tenant(), :slug),
      do: refuse!("the database's tenant is not the hosted demo tenant")
  end

  # The owner: the database's only operator, an active admin with the owner's
  # email; or, with no operator at all, the tenant's first admin.
  defp owner(email, tenant_id) do
    case operators(tenant_id) do
      [] ->
        bootstrap_owner(email, tenant_id)

      [%User{} = user] ->
        existing_owner(user, email, tenant_id)

      users ->
        refuse!(
          "the database holds #{length(users)} operators; the hosted copy has exactly " <>
            "one, the owner"
        )
    end
  end

  # The only operator, reused unchanged when it is the owner as an active admin
  # of this tenant; refused otherwise (kinds only, never its email).
  defp existing_owner(user, email, tenant_id) do
    owner? = String.downcase(to_string(user.email)) == email

    if owner? and user.tenant_id == tenant_id and user.role == :admin and user.status == :active do
      {:existing, user}
    else
      refuse!(
        "the database's only operator is not the owner as an active admin of this " <>
          "tenant (owner email: #{if owner?, do: "matches", else: "differs"}, " <>
          "role: #{user.role}, status: #{user.status})"
      )
    end
  end

  # Every user in the database (any tenant), read by the kernel.
  defp operators(tenant_id) do
    case Ash.read(User, Kernel.opts(tenant_id)) do
      {:ok, users} -> users
      {:error, error} -> raise "seed_hosted: reading the operators failed: #{error_kind(error)}"
    end
  end

  defp bootstrap_owner(email, tenant_id) do
    password = Base.encode64(:crypto.strong_rand_bytes(64))

    %{
      email: email,
      display_name: "Owner",
      password: password,
      password_confirmation: password
    }
    |> Accounts.bootstrap_admin(tenant_id: tenant_id)
    |> case do
      {:ok, user} ->
        {:created, user}

      {:error, error} ->
        raise "seed_hosted: the owner could not be created as the tenant's first " <>
                "operator (does the tenant already have another operator?): " <>
                error_kind(error)
    end
  end

  defp refuse!(reason) do
    raise "seed_hosted: refused before any content write: #{reason} " <>
            "(SDR_OWNER_EMAIL names the owner; nothing was written, no user was changed)"
  end

  ## Follow-up containment (Codex M4)

  # Archives each open campaign of the fixture campaign name whose sequence
  # has a follow-up step, then retires each such active seeded sequence; both
  # are ordinary audited admin actions by the owner. Returns how many rows it
  # closed (0 on a contained database).
  defp contain_follow_ups(opts) do
    sequences =
      Enum.flat_map([Fixtures.sequence().name, @sequence_name], fn name ->
        list!(Sales.Sequence, [name: name], opts)
      end)

    with_follow_up =
      for sequence <- sequences, follow_up?(sequence, opts), into: MapSet.new(), do: sequence.id

    archived =
      for campaign <- list!(Sales.Campaign, [name: Fixtures.campaign().name], opts),
          campaign.status in @open_campaign,
          MapSet.member?(with_follow_up, campaign.sequence_id) do
        transition!(campaign, :archive, opts)
      end

    retired =
      for sequence <- sequences,
          sequence.status == :active,
          MapSet.member?(with_follow_up, sequence.id) do
        transition!(sequence, :retire, opts)
      end

    length(archived) + length(retired)
  end

  defp follow_up?(sequence, opts),
    do: Enum.any?(steps(sequence, opts), &(&1.position > 1))

  defp steps(sequence, opts), do: list!(Sales.SequenceStep, [sequence_id: sequence.id], opts)

  defp transition!(record, action, opts) do
    record |> Sales.update(action, %{}, opts) |> created!("#{action} for containment")
  end

  ## Content

  defp icp(opts) do
    fixture = Fixtures.icp()

    {created, icp} =
      ensure(Sales, Sales.IcpDefinition, [name: fixture.name, version: 1], opts, fn ->
        Sales.create_icp_definition(Map.take(fixture, [:name, :description, :criteria]), opts)
      end)

    {[created, activate(icp, opts)], icp}
  end

  # The newest draft or active version of the hosted sequence with no step
  # after the first; else a new version holding only the first touch.
  defp sequence(opts) do
    versions = list!(Sales.Sequence, [name: @sequence_name], opts)

    reusable =
      versions
      |> Enum.filter(&(&1.status in [:draft, :active]))
      |> Enum.sort_by(& &1.version, :desc)
      |> Enum.find(fn sequence -> Enum.all?(steps(sequence, opts), &(&1.position == 1)) end)

    {created, sequence} =
      case reusable do
        nil ->
          version = 1 + (versions |> Enum.map(& &1.version) |> Enum.max(fn -> 0 end))
          attrs = %{name: @sequence_name, version: version}
          {:created, created!(Sales.create_sequence(attrs, opts), "the hosted sequence")}

        sequence ->
          {:existing, sequence}
      end

    {step_result, _step} =
      ensure(Sales, Sales.SequenceStep, [sequence_id: sequence.id, position: 1], opts, fn ->
        Sales.add_sequence_step(sequence, Map.delete(first_touch(), :id), opts)
      end)

    {[created, step_result, activate(sequence, opts)], sequence}
  end

  defp first_touch, do: Enum.find(Fixtures.sequence_steps(), &(&1.position == 1))

  # An open campaign of the fixture name on the hosted sequence; else a new one.
  defp campaign(icp, sequence, opts) do
    fixture =
      Fixtures.campaign()
      |> Map.delete(:id)
      |> Map.merge(%{icp_definition_id: icp.id, sequence_id: sequence.id})

    open =
      Sales.Campaign
      |> list!([name: fixture.name, sequence_id: sequence.id], opts)
      |> Enum.filter(&(&1.status in @open_campaign))

    {created, campaign} =
      case open do
        [campaign | _] -> {:existing, campaign}
        [] -> {:created, created!(Sales.create_campaign(fixture, opts), "the campaign")}
      end

    {[created, activate(campaign, opts)], campaign}
  end

  # Returns the results and a map from each fixture account id to the row id.
  defp accounts(opts) do
    Fixtures.accounts()
    |> Enum.map(fn fixture ->
      {result, account} =
        ensure(Sales, Sales.Account, [domain: fixture.domain], opts, fn ->
          Sales.create_account(Map.drop(fixture, [:id, :expected_outcome]), opts)
        end)

      {result, {fixture.id, account.id}}
    end)
    |> unzip_ids()
  end

  defp contacts(account_ids, opts) do
    Fixtures.contacts()
    |> Enum.map(fn fixture ->
      attrs =
        fixture
        |> Map.delete(:id)
        |> Map.put(:account_id, Map.fetch!(account_ids, fixture.account_id))

      {result, contact} =
        ensure(Sales, Sales.Contact, [email: fixture.email], opts, fn ->
          Sales.create_contact(attrs, opts)
        end)

      {result, {fixture.id, contact.id}}
    end)
    |> unzip_ids()
  end

  # Any lead of the contact counts (the suppressed contact's is stopped).
  defp leads(account_ids, contact_ids, opts) do
    for fixture <- Fixtures.leads() do
      contact_id = Map.fetch!(contact_ids, fixture.contact_id)

      {result, _lead} =
        ensure(Sales, Sales.Lead, [contact_id: contact_id], opts, fn ->
          Sales.create_lead(
            %{
              contact_id: contact_id,
              account_id: Map.fetch!(account_ids, fixture.account_id),
              source: fixture.source
            },
            opts
          )
        end)

      result
    end
  end

  # Written after the leads, so its side effect stops the contact's lead.
  defp suppressions(opts) do
    for fixture <- Fixtures.suppressions() do
      {result, _suppression} =
        ensure(
          Outreach,
          Outreach.Suppression,
          [scope: fixture.scope, value: fixture.value],
          opts,
          fn ->
            Outreach.suppress(Map.take(fixture, [:scope, :value]), opts)
          end
        )

      result
    end
  end

  # C4-R8: an assignment needs a saved offering profile; saved once.
  defp offering(tenant_id, opts) do
    agent = Actor.system(:agent_runtime, tenant_id)

    case Agents.settings_complete(:assignment, actor: agent) do
      :ok ->
        :existing

      {:error, {:settings_incomplete, _kinds}} ->
        %{
          kind: :offering_profile,
          content: Fixtures.offering_profile(),
          expected_number: 0,
          note: "Synthetic demo offering (hosted seed).",
          confirm_raised: []
        }
        |> Agents.create_settings_revision(opts)
        |> created!("the offering profile")

        :created
    end
  end

  defp activate(%{status: :draft} = record, opts) do
    record |> Sales.update(:activate, %{}, opts) |> created!("activation")
    :created
  end

  defp activate(_active, _opts), do: :existing

  # The row matching `filter` in the actor's tenant (read through `domain`'s
  # public list API), else the one `create` makes.
  defp ensure(domain, resource, filter, opts, create) do
    case domain.list_records(resource, Keyword.put(opts, :filter, filter)) do
      {:ok, [record | _]} ->
        {:existing, record}

      {:ok, []} ->
        {:created, created!(create.(), inspect(resource))}

      {:error, error} ->
        raise "seed_hosted: reading #{inspect(resource)} failed: #{error_kind(error)}"
    end
  end

  # Every Sales row of `resource` matching `filter` in the actor's tenant.
  defp list!(resource, filter, opts) do
    case Sales.list_records(resource, Keyword.put(opts, :filter, filter)) do
      {:ok, records} ->
        records

      {:error, error} ->
        raise "seed_hosted: reading #{inspect(resource)} failed: #{error_kind(error)}"
    end
  end

  defp created!({:ok, record}, _what), do: record

  defp created!({:error, error}, what),
    do: raise("seed_hosted: #{what} failed: #{error_kind(error)}")

  defp unzip_ids(pairs) do
    {results, ids} = Enum.unzip(pairs)
    {results, Map.new(ids)}
  end

  # The error's kind, never its values (they may carry row content).
  defp error_kind(%{__struct__: module, errors: errors}) when is_list(errors),
    do: "#{inspect(module)} #{inspect(Enum.map(errors, & &1.__struct__))}"

  defp error_kind(%{__struct__: module}), do: inspect(module)
  defp error_kind(other) when is_atom(other), do: inspect(other)
  defp error_kind(_other), do: "error"
end
