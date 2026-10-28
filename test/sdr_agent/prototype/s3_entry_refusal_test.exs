defmodule SdrAgent.Prototype.S3EntryRefusalTest do
  @moduledoc """
  The D-237 S3 write entries refuse before any write unless the caller is
  the live operator of the live binding in prototype runtime (interfaces r6
  IF-6 and IF-7; supplement 1 r2 §3-§5, Codex R5-R9):
  `SdrAgent.Prototype.Seed.run/2`, `SdrAgent.Prototype.DossierImport.import/2`
  and `import_row/2` each re-check the actor through
  `SdrAgent.Prototype.operator_actor/1` and the binding through
  `SdrAgent.Prototype.check_live/0`. A forged delegation, a foreign tenant
  or a non-operator actor is `:forbidden`; a live binding mismatch is
  `:binding_mismatch`; ordinary runtime is `:not_prototype_runtime`. Codes
  only, never values.

  The dossier adapters `SdrAgent.Integrations.DossierWeb` and
  `DossierSearch` refuse every caller with
  `:prototype_scoped_read_required`: dossier content is read only through
  the scoped `SdrAgent.Research.read_dossier_sources/4`.

  The write paths themselves are in the seed and import tests. Synthetic
  `.test` fixtures in a sandboxed prototype binding.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.DossierFixtures, as: F

  @seed SdrAgent.Prototype.Seed
  @import SdrAgent.Prototype.DossierImport
  @writes ~w(settings_revisions icp_definitions sequences campaigns accounts contacts leads dossier_entries dossier_sources)

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  defp counts do
    Map.new(@writes, fn table ->
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
      {table, n}
    end)
  end

  defp outsiders(ctx) do
    [
      forged_delegation: %{ctx.actor | id: Ecto.UUID.generate()},
      foreign_tenant: %{ctx.actor | tenant_id: Ecto.UUID.generate()},
      seeder: SdrAgent.Actor.system(:seeder, ctx.tenant.id),
      agent_runtime: SdrAgent.Actor.system(:agent_runtime, ctx.tenant.id)
    ]
  end

  # Every entry, called with `actor`, and the exact refusal it must return
  # for `code`.
  defp entries(actor, code) do
    [
      {"Seed.run/2", fn -> call(@seed, :run, [F.seed_read(), actor]) end, {:error, code}},
      {"DossierImport.import/2", fn -> call(@import, :import, [[], actor]) end,
       {:error, %{code: code, failed_row: nil, imported: [], replayed: []}}},
      {"DossierImport.import_row/2", fn -> call(@import, :import_row, [%{}, actor]) end,
       {:error, code}}
    ]
  end

  describe "the live operator and binding" do
    test "a forged delegation, a foreign tenant or a non-operator actor is :forbidden", ctx do
      before = counts()

      for {label, actor} <- outsiders(ctx),
          {entry, run, expected} <- entries(actor, :forbidden) do
        result = run.()
        assert result == expected, "#{entry} as #{label} returned #{inspect(result)}"
      end

      assert counts() == before
    end

    test "a live binding mismatch is :binding_mismatch", ctx do
      before = counts()
      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{database_oid: 1})

      for {entry, run, expected} <- entries(ctx.actor, :binding_mismatch) do
        result = run.()
        assert result == expected, "#{entry} returned #{inspect(result)}"
      end

      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{})
      assert counts() == before
    end

    test "ordinary runtime is :not_prototype_runtime, for the operator too", ctx do
      before = counts()
      :ok = SdrAgent.PrototypeFixtures.leave_runtime()

      for {entry, run, expected} <- entries(ctx.actor, :not_prototype_runtime) do
        result = run.()
        assert result == expected, "#{entry} returned #{inspect(result)}"
      end

      assert counts() == before
    end
  end

  # Seed design D3 (Codex 718e0c98 and the ed0a67b5 ranking, item 1):
  # Seed.run/2 owns its one transaction, so a call inside an already-open
  # caller transaction, Repo or Audit, is :seed_failed before ANY query (no
  # live check, read or write), and that caller's transaction stays usable
  # and commits. The query count is checked first: it does not depend on
  # the write stub.
  describe "a call inside an open transaction" do
    test "Seed.run/2 is :seed_failed before any query; the caller's transaction stays usable",
         ctx do
      seed = F.seed_read()
      before = seed_counts()

      observed =
        for {owner, open} <- [repo: &Repo.transaction/1, audit: &SdrAgent.Audit.transaction/1],
            {label, actor} <- [
              operator: ctx.actor,
              forged_delegation: %{ctx.actor | id: Ecto.UUID.generate()}
            ] do
          {:ok, {queries, result}} =
            open.(fn ->
              {queries, result} = queries_during(fn -> call(@seed, :run, [seed, actor]) end)
              assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
              {queries, result}
            end)

          {owner, label, queries, result}
        end

      for {owner, label, queries, _result} <- observed do
        assert queries == 0,
               "#{owner}/#{label}: Seed.run/2 ran #{queries} queries inside the caller's " <>
                 "transaction; all: #{inspect(observed)}"
      end

      for {owner, label, _queries, result} <- observed do
        assert result == {:error, :seed_failed},
               "#{owner}/#{label}: Seed.run/2 returned #{inspect(result)}"
      end

      assert seed_counts() == before
    end
  end

  # The write tables plus the provenance Payloads and every audit event.
  defp seed_counts do
    Map.merge(
      counts(),
      Map.new(~w(payloads audit_events), fn table ->
        %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
        {table, n}
      end)
    )
  end

  # The number of repo queries `fun` issues from this process (counted, never
  # recorded), and its result.
  defp queries_during(fun) do
    parent = self()
    handler = "s3-seed-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, :s3_seed_query)
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {drain(0), result}
  end

  defp drain(n) do
    receive do
      :s3_seed_query -> drain(n + 1)
    after
      0 -> n
    end
  end

  describe "the dossier adapters refuse every caller" do
    test "DossierWeb and DossierSearch never return content" do
      assert SdrAgent.Integrations.DossierWeb.fetch("https://www.acme1.test/about") ==
               {:error, :prototype_scoped_read_required}

      assert SdrAgent.Integrations.DossierSearch.search("Acme 1", domain: "acme1.test") ==
               {:error, :prototype_scoped_read_required}
    end
  end
end
