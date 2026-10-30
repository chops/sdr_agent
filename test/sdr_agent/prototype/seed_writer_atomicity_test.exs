defmodule SdrAgent.Prototype.SeedWriterAtomicityTest do
  @moduledoc """
  Synthetic whole-writer rollback and replay checks for D-268 M4. A real
  uniqueness conflict at the sequence create occurs after the provenance,
  two revisions and ICP writes; no invented fault hook or raw resource
  mutation is used. The caller's database remains usable after rollback.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Agents
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

  test "the domain history API returns only exact empty or matching metadata", ctx do
    seed = F.seed_read()

    assert {:ok, {:ok, empty}} =
             SdrAgent.Audit.transaction(fn ->
               call(Agents, :prototype_seed_settings_history, [seed.sha256.provenance, ctx.actor])
             end)

    assert empty == %{
             empty?: true,
             matches?: false,
             ids: [],
             subject_resource: "SdrAgent.Agents.SettingsRevision"
           }

    assert {:ok, %{result: :created}} = call(@seed, :run, [seed, ctx.actor])

    assert {:ok, {:ok, facts}} =
             SdrAgent.Audit.transaction(fn ->
               call(Agents, :prototype_seed_settings_history, [seed.sha256.provenance, ctx.actor])
             end)

    assert Map.keys(facts) |> Enum.sort() == [:empty?, :ids, :matches?, :subject_resource]
    assert facts.matches? and not facts.empty?
    assert length(facts.ids) == 2 and facts.ids == Enum.sort(facts.ids)
    assert facts.subject_resource == empty.subject_resource

    assert {:ok, {:ok, mismatch}} =
             SdrAgent.Audit.transaction(fn ->
               call(Agents, :prototype_seed_settings_history, [
                 String.duplicate("a", 64),
                 ctx.actor
               ])
             end)

    assert mismatch == %{facts | empty?: false, matches?: false}

    assert {:ok, {:error, :seed_invalid}} =
             SdrAgent.Audit.transaction(fn ->
               call(Agents, :prototype_seed_settings_history, ["bad", ctx.actor])
             end)
  end

  test "the domain APIs refuse missing transactions before any action", ctx do
    assert call(Agents, :prototype_seed_settings_history, [
             F.seed_read().sha256.provenance,
             ctx.actor
           ]) == {:error, :seed_failed}

    assert call(Agents, :seed_prototype_settings_revision, [
             %{},
             ctx.actor,
             %{sdr_seed_run_id: Ecto.UUID.generate()}
           ]) == {:error, :seed_failed}
  end

  test "domain history refuses ordinary runtime and stale or foreign actors", ctx do
    digest = F.seed_read().sha256.provenance

    for actor <- [
          %{ctx.actor | id: Ecto.UUID.generate()},
          %{ctx.actor | tenant_id: Ecto.UUID.generate()}
        ] do
      assert {:ok, {:error, :forbidden}} =
               SdrAgent.Audit.transaction(fn ->
                 call(Agents, :prototype_seed_settings_history, [digest, actor])
               end)
    end

    :ok = PrototypeFixtures.leave_runtime()

    assert {:ok, {:error, :not_prototype_runtime}} =
             SdrAgent.Audit.transaction(fn ->
               call(Agents, :prototype_seed_settings_history, [digest, ctx.actor])
             end)
  end

  test "the domain write accepts no context except one canonical run UUID", ctx do
    uuid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    before = counts()

    for context <- [
          %{},
          %{sdr_seed_run_id: "bad"},
          %{sdr_seed_run_id: uuid, kernel: true},
          %{"sdr_seed_run_id" => uuid},
          %{sdr_seed_run_id: String.upcase(uuid)}
        ] do
      assert {:ok, {:error, :seed_invalid}} =
               SdrAgent.Audit.transaction(fn ->
                 call(Agents, :seed_prototype_settings_revision, [%{}, ctx.actor, context])
               end)
    end

    assert counts() == before
  end
end
