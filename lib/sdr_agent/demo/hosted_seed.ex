defmodule SdrAgent.Demo.HostedSeed do
  @moduledoc """
  Seeds the hosted test copy (sdr.a-z.bot, `SdrAgent.Release.seed_hosted/0`)
  in production, where the dev/test seed is refused: the singleton tenant
  and its audit chain, exactly ONE operator — the owner — and the same
  synthetic demo content as `SdrAgent.Demo.Seed` (`SdrAgent.Demo.Fixtures`,
  every domain and email under `.test`).

    * **The owner** is created by the kernel's first-admin bootstrap
      (`Accounts.bootstrap_admin/2`, any environment, only while the tenant
      has no user): an active admin with the given email and a random
      64-byte password that is hashed and never stored, returned or printed,
      so the owner signs in only by magic link. If the tenant already has a
      different operator, nothing is created and the seed fails.
    * **No fixture operator** is ever created: this module never uses the
      seeder or its `:seed` actions, which stay refused outside dev/test
      (`SdrAgent.Audit.Checks.SeedingAllowed`); the fixture passwords are
      public.
    * **Content** is written by the owner through the ordinary admin
      actions (generated ids, real timestamps, each write audited with the
      owner as actor): the ICP, the sequence and its steps, and the campaign
      (each activated), the ten accounts, contacts and leads, the one
      Suppression (which stops its contact's lead), and the synthetic
      offering profile an assignment needs (C4-R8).
    * **Idempotent:** rows are matched by natural key (owner email, ICP,
      sequence and campaign name, account domain, contact email, the
      contact's lead, suppression value, a saved offering profile); a second
      run creates nothing and appends no event.

  Returns `{:ok, %{created: n, existing: m}}`; raises on any failure (it runs
  only from the release task).
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

  require Ash.Query

  @doc "Seeds the hosted copy for `owner_email` (see the moduledoc)."
  @spec run(String.t()) :: {:ok, %{created: non_neg_integer(), existing: non_neg_integer()}}
  def run(owner_email) when is_binary(owner_email) do
    email = owner_email |> String.trim() |> String.downcase()
    if email == "", do: raise(ArgumentError, "the owner email is blank")

    {:ok, tenant} = Audit.bootstrap(Fixtures.tenant())
    {owner_result, owner} = owner(email, tenant.id)
    opts = [actor: owner]

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
       existing: Enum.count(results, &(&1 == :existing))
     }}
  end

  # The owner: found by email, else the tenant's first admin.
  defp owner(email, tenant_id) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(Kernel.opts(tenant_id))
    |> case do
      {:ok, %User{} = user} ->
        {:existing, user}

      {:ok, nil} ->
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
  end

  defp icp(opts) do
    fixture = Fixtures.icp()

    {created, icp} =
      ensure(Sales, Sales.IcpDefinition, [name: fixture.name, version: 1], opts, fn ->
        Sales.create_icp_definition(Map.take(fixture, [:name, :description, :criteria]), opts)
      end)

    {[created, activate(icp, opts)], icp}
  end

  defp sequence(opts) do
    fixture = Fixtures.sequence()

    {created, sequence} =
      ensure(Sales, Sales.Sequence, [name: fixture.name, version: 1], opts, fn ->
        Sales.create_sequence(Map.take(fixture, [:name, :version]), opts)
      end)

    steps =
      for step <- Fixtures.sequence_steps() do
        {result, _step} =
          ensure(
            Sales,
            Sales.SequenceStep,
            [sequence_id: sequence.id, position: step.position],
            opts,
            fn ->
              Sales.add_sequence_step(sequence, Map.delete(step, :id), opts)
            end
          )

        result
      end

    {[created, steps, activate(sequence, opts)], sequence}
  end

  defp campaign(icp, sequence, opts) do
    fixture =
      Fixtures.campaign()
      |> Map.delete(:id)
      |> Map.merge(%{icp_definition_id: icp.id, sequence_id: sequence.id})

    {created, campaign} =
      ensure(Sales, Sales.Campaign, [name: fixture.name], opts, fn ->
        Sales.create_campaign(fixture, opts)
      end)

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
