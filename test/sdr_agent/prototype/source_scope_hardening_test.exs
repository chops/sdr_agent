defmodule SdrAgent.Prototype.SourceScopeHardeningTest do
  @moduledoc """
  RED (owner intake T2, Codex 321e0207; review 63939789):
  `SdrAgent.Audit.Checks.DossierSourceScope` must not trust its context
  map. At policy consumption it re-reads, in the actor's tenant:
  - the scope's run, which must be running for the scope's lead;
  - the scope's entry, which must be that lead's entry in the live binding;
  - the requested hash, which must be one of that entry's DossierSource
    content hashes.
  A context built by hand with another lead's hash, entry or run is
  refused. Genuine reads through `read_dossier_sources/4` stay unchanged
  (see DossierSourceReadTest).

  Synthetic `.test` fixtures in a sandboxed prototype binding.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.PrototypeOutreachFixtures, only: [enter_window!: 1]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.Checks.DossierSourceScope
  alias SdrAgent.DossierFixtures, as: F

  @seed SdrAgent.Prototype.Seed
  @import SdrAgent.Prototype.DossierImport

  setup do
    fixture = bound!()
    enter_window!(fixture)
    actor = fixture.actor
    assert match?({:ok, _}, call(@seed, :run, [F.seed_read(), actor]))
    rows = F.route_rows!([F.company(1), F.company(2)], ["row-1", "row-2"])
    agent = SdrAgent.Actor.system(:agent_runtime, fixture.tenant.id)

    [a, b] =
      for row <- rows do
        {:ok, :imported, %{lead_id: lead_id, entry_id: entry_id}} =
          call(@import, :import_row, [row, actor])

        %{
          lead_id: lead_id,
          entry_id: entry_id,
          run: running_run!(fixture.tenant, agent, lead_id),
          sources: sources!(entry_id)
        }
      end

    %{fixture: fixture, agent: agent, a: a, b: b}
  end

  defp running_run!(tenant, agent, lead_id) do
    definition = AgentsFixtures.definition!(tenant)
    attrs = definition |> AgentsFixtures.run_attrs() |> Map.put(:lead_id, lead_id)
    {:ok, run} = Agents.create_run(attrs, actor: agent)
    {:ok, run} = Agents.start_run(run, actor: agent)
    run
  end

  defp sources!(entry_id) do
    # Setup read only; never the subject.
    {:ok, sources} = Ash.read(SdrAgent.Research.DossierSource, authorize?: false)
    sources |> Enum.filter(&(&1.entry_id == entry_id)) |> Enum.sort_by(& &1.source_id)
  end

  defp scope(ctx, run, lead, entry, sha256s) do
    DossierSourceScope.context(%{
      tenant_id: ctx.fixture.tenant.id,
      agent_run_id: run.id,
      lead_id: lead.lead_id,
      entry_id: entry.entry_id,
      sha256s: sha256s
    })
  end

  defp scoped_read(ctx, sha256, context) do
    SdrAgent.Audit.Payload
    |> Ash.ActionInput.for_action(:read_dossier_source_content, %{sha256: sha256},
      actor: ctx.agent,
      context: context
    )
    |> Ash.run_action()
  end

  defp sha(item), do: hd(item.sources).content_sha256

  test "control: a scope matching the authoritative rows reads", ctx do
    %{a: a} = ctx
    assert {:ok, bytes} = scoped_read(ctx, sha(a), scope(ctx, a.run, a, a, [sha(a)]))
    assert :crypto.hash(:sha256, bytes) == sha(a)
  end

  test "another entry's hash under a real run, lead and entry is refused", ctx do
    %{a: a, b: b} = ctx
    result = scoped_read(ctx, sha(b), scope(ctx, a.run, a, a, [sha(b)]))
    assert match?({:error, _}, result), "read another entry's source: #{inspect(result, limit: 4)}"
  end

  test "another lead's entry named with this lead's run is refused", ctx do
    %{a: a, b: b} = ctx
    result = scoped_read(ctx, sha(b), scope(ctx, a.run, a, b, [sha(b)]))
    assert match?({:error, _}, result), "read via a foreign entry: #{inspect(result, limit: 4)}"
  end

  test "a run of another lead is refused", ctx do
    %{a: a, b: b} = ctx
    result = scoped_read(ctx, sha(b), scope(ctx, a.run, b, b, [sha(b)]))
    assert match?({:error, _}, result), "read via a foreign run: #{inspect(result, limit: 4)}"
  end

  test "a run that is no longer running is refused", ctx do
    %{a: a} = ctx

    {:ok, _} =
      Agents.fail_run(a.run, %{status_reason: :crash, failure_reason: "test"}, actor: ctx.agent)

    result = scoped_read(ctx, sha(a), scope(ctx, a.run, a, a, [sha(a)]))
    assert match?({:error, _}, result), "read under a failed run: #{inspect(result, limit: 4)}"
  end

  test "an arbitrary payload hash listed in the scope is refused", ctx do
    %{a: a} = ctx
    other = :crypto.hash(:sha256, "seed or other payload bytes")
    result = scoped_read(ctx, other, scope(ctx, a.run, a, a, [other]))
    assert match?({:error, _}, result), inspect(result, limit: 4)
  end
end
