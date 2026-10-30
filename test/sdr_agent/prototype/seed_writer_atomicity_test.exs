defmodule SdrAgent.Prototype.SeedWriterAtomicityTest do
  @moduledoc """
  Synthetic whole-writer rollback and replay checks for D-268 M4. A real
  uniqueness conflict at the sequence create occurs after the provenance,
  two revisions and ICP writes; no invented fault hook or raw resource
  mutation is used. The caller's database remains usable after rollback.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Sales

  @seed SdrAgent.Prototype.Seed
  @tables ~w(settings_revisions payloads icp_definitions sequences sequence_steps campaigns audit_events oban_jobs model_invocations drafts delivery_operations)

  setup do
    fixture = bound!()
    %{actor: fixture.actor, tenant: fixture.tenant}
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
end
