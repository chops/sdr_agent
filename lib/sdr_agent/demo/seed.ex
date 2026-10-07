defmodule SdrAgent.Demo.Seed do
  @moduledoc """
  Writes `SdrAgent.Demo.Fixtures` through the domain APIs as the seeder
  (SEED) actor — the only writer allowed to supply fixture ids, and only
  where seeding is allowed (`config :sdr_agent, seeding_allowed?: true`,
  dev/test). Used by `mix sdr.demo.seed` (and `bin/demo seed` later).

    * **Idempotent:** each fixture row is created only if its id is absent;
      setup transitions (ICP, sequence, campaign activation) run only from
      draft. A second run writes nothing and appends no event.
    * **Deterministic:** the clock is frozen at `Fixtures.epoch/0` plus a
      fixed offset per row while it is written, so ids, timestamps and every
      non-volatile column are identical across runs on empty databases (the
      tenant id, trace ids and bcrypt salts differ by construction).
    * **Audited:** every write appends its usual event, attributed to the
      seeder; the singleton tenant is bootstrapped by the kernel if absent.

  Returns `{:ok, %{created: n, existing: m}}` or
  `{:error, :seeding_not_allowed}` without writing anything.
  """

  alias SdrAgent.Accounts
  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Checks.SeedingAllowed
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Sales

  @doc "Seeds the demo data set (see the moduledoc)."
  @spec run() ::
          {:ok, %{created: non_neg_integer(), existing: non_neg_integer()}} | {:error, term()}
  def run do
    if SeedingAllowed.allowed?(),
      do: with_fixed_clock(&seed/0),
      else: {:error, :seeding_not_allowed}
  end

  defp seed do
    at(0)
    {:ok, tenant} = Audit.bootstrap(Fixtures.tenant())
    seeder = Actor.system(:seeder, tenant.id, "sdr.demo.seed")

    results =
      [
        users(seeder),
        icp(seeder),
        sequence(seeder),
        campaign(seeder),
        rows(seeder, Fixtures.accounts(), 100, Sales.Account, &Sales.seed_account/2),
        rows(seeder, Fixtures.contacts(), 200, Sales.Contact, &Sales.seed_contact/2),
        rows(seeder, Fixtures.leads(), 300, Sales.Lead, &Sales.seed_lead/2)
      ]
      |> List.flatten()

    {:ok,
     %{
       created: Enum.count(results, &(&1 == :created)),
       existing: Enum.count(results, &(&1 == :existing))
     }}
  end

  defp users(seeder) do
    for {user, n} <- Enum.with_index(Fixtures.users()) do
      at(n)

      ensure(fn -> Accounts.get_user(user.id, actor: seeder) end, fn ->
        user
        |> Map.put(:password_confirmation, user.password)
        |> Accounts.seed_user(actor: seeder)
      end)
    end
  end

  defp icp(seeder) do
    fixture = Fixtures.icp()
    at(10)
    created = ensure_sales(seeder, Sales.IcpDefinition, fixture, &Sales.seed_icp_definition/2)
    at(11)
    [created | activate(seeder, Sales.IcpDefinition, fixture.id)]
  end

  defp sequence(seeder) do
    fixture = Fixtures.sequence()
    at(20)
    created = ensure_sales(seeder, Sales.Sequence, fixture, &Sales.seed_sequence/2)

    steps =
      for {step, n} <- Enum.with_index(Fixtures.sequence_steps(), 21) do
        at(n)

        ensure_sales(
          seeder,
          Sales.SequenceStep,
          Map.put(step, :sequence_id, fixture.id),
          &Sales.seed_sequence_step/2
        )
      end

    at(29)
    [created, steps | activate(seeder, Sales.Sequence, fixture.id)]
  end

  defp campaign(seeder) do
    fixture = Fixtures.campaign()
    at(30)
    created = ensure_sales(seeder, Sales.Campaign, fixture, &Sales.seed_campaign/2)
    at(31)
    [created | activate(seeder, Sales.Campaign, fixture.id)]
  end

  defp rows(seeder, fixtures, offset, resource, seed_fun) do
    for {fixture, n} <- Enum.with_index(fixtures, offset) do
      at(n)
      ensure_sales(seeder, resource, Map.delete(fixture, :expected_outcome), seed_fun)
    end
  end

  defp ensure_sales(seeder, resource, fixture, seed_fun) do
    ensure(fn -> Sales.fetch(resource, fixture.id, actor: seeder) end, fn ->
      seed_fun.(fixture, actor: seeder)
    end)
  end

  defp activate(seeder, resource, id) do
    case Sales.fetch(resource, id, actor: seeder) do
      {:ok, %{status: :draft} = record} ->
        {:ok, _} = Sales.update(record, :activate, %{}, actor: seeder)
        [:created]

      {:ok, _active} ->
        [:existing]
    end
  end

  defp ensure(fetch, create) do
    case fetch.() do
      {:ok, _existing} ->
        :existing

      {:error, _not_found} ->
        {:ok, _created} = create.()
        :created
    end
  end

  defp at(offset), do: Clock.freeze(DateTime.add(Fixtures.epoch(), offset, :second))

  # Freezes the clock for the seed and restores the caller's clock after.
  defp with_fixed_clock(fun) do
    previous = if Clock.source() == :test_fixed, do: Clock.utc_now()

    try do
      fun.()
    after
      if previous, do: Clock.freeze(previous), else: Clock.unfreeze()
    end
  end
end
