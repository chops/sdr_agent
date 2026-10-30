defmodule SdrAgent.Prototype.SeedWriterAtomicityTest do
  @moduledoc """
  Synthetic whole-writer rollback and replay checks for D-268 M4. A real
  uniqueness conflict at the sequence create occurs after the provenance,
  two revisions and ICP writes; no invented fault hook or raw resource
  mutation is used. The caller's database remains usable after rollback.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.PrototypeFixtures
  alias SdrAgent.Sales

  @seed SdrAgent.Prototype.Seed
  @tables ~w(settings_revisions payloads icp_definitions sequences sequence_steps campaigns audit_events oban_jobs model_invocations drafts delivery_operations)

  setup do
    fixture = bound!()
    %{actor: fixture.actor, tenant: fixture.tenant, fixture: fixture}
  end

  defp counts do
    Map.new(@tables, fn table ->
      {table, Repo.query!("SELECT count(*) FROM " <> table, []).rows}
    end)
  end

  test "a late sequence uniqueness failure rolls back every earlier seed write", ctx do
    seeder = SdrAgent.Actor.system(:seeder, ctx.tenant.id, "test")
    name = F.seed_read().campaign["sequence"]["name"]
    assert {:ok, _existing} = Sales.seed_sequence(%{name: name}, actor: seeder)
    before = counts()

    result = call(@seed, :run, [F.seed_read(), ctx.actor])
    assert result == {:error, :seed_invalid}
    assert counts() == before
    assert Repo.query!("SELECT 1", []).rows == [[1]]
  end

  test "an exact replay adds no payload, business row, event, job or model work", ctx do
    assert {:ok, %{result: :created} = first} = call(@seed, :run, [F.seed_read(), ctx.actor])
    before = counts()
    assert {:ok, %{result: :replay} = second} = call(@seed, :run, [F.seed_read(), ctx.actor])
    assert Map.drop(first, [:result]) == Map.drop(second, [:result])
    assert counts() == before
  end

  test "partial settings history is refused without completing or adopting it", ctx do
    provenance = F.stored_provenance!(ctx.actor)

    assert {:ok, _revision} =
             SdrAgent.Agents.SettingsRevision
             |> Ash.Changeset.for_create(
               :seed_prototype,
               %{
                 kind: :writing_guide,
                 content: F.seed_read().writing_guide,
                 note: provenance.note
               },
               actor: ctx.actor
             )
             |> Ash.create()

    before = counts()
    assert call(@seed, :run, [F.seed_read(), ctx.actor]) == {:error, :seed_differs}
    assert counts() == before
  end

  test "an extra historical seed creation event makes replay ambiguous", ctx do
    seed = F.seed_read()
    assert {:ok, %{result: :created}} = call(@seed, :run, [seed, ctx.actor])

    assert {:ok, _extra} =
             SdrAgent.Sales.IcpDefinition
             |> Ash.Changeset.for_create(
               :seed_prototype,
               %{
                 name: "Extra synthetic seed",
                 criteria: %{industries: ["software"]},
                 seed_provenance_sha256: seed.sha256.provenance
               },
               actor: ctx.actor
             )
             |> Ash.create()

    before = counts()
    assert call(@seed, :run, [seed, ctx.actor]) == {:error, :seed_differs}
    assert counts() == before
  end

  test "a complete but inactive seed is not reactivated by replay", ctx do
    assert {:ok, %{icp_id: id}} = call(@seed, :run, [F.seed_read(), ctx.actor])
    :ok = PrototypeFixtures.leave_runtime()
    admin = human(:admin, ctx.tenant)
    assert {:ok, icp} = Sales.fetch(SdrAgent.Sales.IcpDefinition, id, actor: admin)
    assert {:ok, %{status: :retired}} = Sales.update(icp, :retire, %{}, actor: admin)
    :ok = PrototypeFixtures.enter_runtime(ctx.fixture.snapshot)
    before = counts()
    assert call(@seed, :run, [F.seed_read(), ctx.actor]) == {:error, :seed_failed}
    assert counts() == before
  end
end
