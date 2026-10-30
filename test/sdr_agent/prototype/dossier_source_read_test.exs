defmodule SdrAgent.Prototype.DossierSourceReadTest do
  @moduledoc """
  The scoped, audited dossier source read path (supplement 1 r2 §6a, Q2;
  D-268 M8 research link): `SdrAgent.Research.read_dossier_sources/4`
  re-reads the running run, its lead's dossier entry and that entry's
  sources in the agent's tenant, builds the `DossierSourceScope` from those
  sources' hashes only, and reads each verified excerpt through
  `Payload :read_dossier_source_content` (a `payload_view` under AGT).
  In prototype runtime `ReadCompanyPage` and `SearchCompany` use it; the
  refusing adapters stay refusing.

  Synthetic `.test` fixtures in a sandboxed prototype binding.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.PrototypeOutreachFixtures, only: [enter_window!: 1]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.DossierFixtures, as: F

  @research SdrAgent.Research
  @seed SdrAgent.Prototype.Seed
  @import SdrAgent.Prototype.DossierImport

  setup do
    fixture = bound!()
    enter_window!(fixture)
    actor = fixture.actor
    assert match?({:ok, _}, call(@seed, :run, [F.seed_read(), actor]))

    [row] = F.route_rows!([F.company(1)], ["row-1"])

    {:ok, :imported, %{lead_id: lead_id, entry_id: entry_id}} =
      call(@import, :import_row, [row, actor])

    agent = SdrAgent.Actor.system(:agent_runtime, fixture.tenant.id)

    %{
      fixture: fixture,
      actor: actor,
      agent: agent,
      lead_id: lead_id,
      entry_id: entry_id,
      run: running_run!(fixture.tenant, agent, lead_id),
      sources: sources!(entry_id)
    }
  end

  defp running_run!(tenant, agent, lead_id) do
    definition = AgentsFixtures.definition!(tenant)
    attrs = definition |> AgentsFixtures.run_attrs() |> Map.put(:lead_id, lead_id)
    {:ok, run} = Agents.create_run(attrs, actor: agent)
    {:ok, run} = Agents.start_run(run, actor: agent)
    run
  end

  defp sources!(entry_id) do
    # Setup read only (the operator has no DossierSource read); never the subject.
    {:ok, sources} = Ash.read(SdrAgent.Research.DossierSource, authorize?: false)
    sources |> Enum.filter(&(&1.entry_id == entry_id)) |> Enum.sort_by(& &1.source_id)
  end

  defp payload!(sha256) do
    %{rows: [[content]]} = Repo.query!("SELECT content FROM payloads WHERE sha256 = $1", [sha256])
    content
  end

  defp views do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_accesses WHERE purpose = 'd237_dossier_source' AND actor_type = 'agent_runtime'",
        []
      )

    n
  end

  defp scoped_read(ctx, sha256, context) do
    SdrAgent.Audit.Payload
    |> Ash.ActionInput.for_action(:read_dossier_source_content, %{sha256: sha256},
      actor: ctx.agent,
      context: context
    )
    |> Ash.run_action()
  end

  defp read(ctx, selector, actor \\ nil),
    do:
      call(@research, :read_dossier_sources, [
        ctx.run.id,
        ctx.lead_id,
        selector,
        actor || ctx.agent
      ])

  describe "allow" do
    test ":all returns every source of the run's lead entry with its verified bytes, each read audited",
         ctx do
      assert ctx.sources != []
      before = views()

      assert {:ok, read} = read(ctx, :all)

      assert Enum.map(read, & &1.dossier_source_id) |> Enum.sort() ==
               Enum.map(ctx.sources, & &1.id) |> Enum.sort()

      for item <- read do
        source = Enum.find(ctx.sources, &(&1.id == item.dossier_source_id))
        assert item.content == payload!(source.content_sha256)
        assert :crypto.hash(:sha256, item.content) == source.content_sha256
        assert item.final_url == source.final_url
        assert item.source_type == source.source_type
        assert item.retrieved_on == source.retrieved_on
        assert item.checked_at == source.checked_at
      end

      assert views() == before + length(ctx.sources)
    end

    test "{:final_url, url} returns exactly that one source", ctx do
      [source | _] = ctx.sources
      assert {:ok, [item]} = read(ctx, {:final_url, source.final_url})
      assert item.dossier_source_id == source.id
    end
  end

  describe "deny" do
    test "an unknown final URL is :dossier_source_missing, with no payload view", ctx do
      before = views()

      assert read(ctx, {:final_url, "https://nowhere.test/none"}) ==
               {:error, :dossier_source_missing}

      assert views() == before
    end

    test "a run of another lead is refused, with no payload view", ctx do
      other = running_run!(ctx.fixture.tenant, ctx.agent, Ecto.UUID.generate())
      before = views()
      result = call(@research, :read_dossier_sources, [other.id, ctx.lead_id, :all, ctx.agent])
      assert match?({:error, code} when is_atom(code), result), inspect(result)
      assert views() == before
    end

    test "a run that is not running is refused", ctx do
      {:ok, _} =
        Agents.fail_run(ctx.run, %{status_reason: :crash, failure_reason: "test"},
          actor: ctx.agent
        )

      result = read(ctx, :all)
      assert match?({:error, code} when is_atom(code), result), inspect(result)
    end

    test "a non-AGT actor (the operator) is refused, with no payload view", ctx do
      before = views()
      result = read(ctx, :all, ctx.actor)
      assert match?({:error, code} when is_atom(code), result), inspect(result)
      assert views() == before
    end

    test "AGT has no plain :read_content of a source hash", ctx do
      [source | _] = ctx.sources

      result =
        SdrAgent.Audit.Payload
        |> Ash.ActionInput.for_action(
          :read_content,
          %{sha256: source.content_sha256, purpose: "d237_dossier_source"},
          actor: ctx.agent
        )
        |> Ash.run_action()

      assert match?({:error, _}, result)
    end

    test "ordinary runtime is :not_prototype_runtime", ctx do
      SdrAgent.PrototypeFixtures.leave_runtime()
      assert read(ctx, :all) == {:error, :not_prototype_runtime}
    end
  end

  describe "deny: tenant and scope" do
    test "an AGT actor of another tenant is :forbidden, with no payload view", ctx do
      before = views()
      foreign = SdrAgent.Actor.system(:agent_runtime, Ecto.UUID.generate())
      assert read(ctx, :all, foreign) == {:error, :forbidden}
      assert views() == before
    end

    test "the scoped payload action refuses AGT with no scope", ctx do
      [source | _] = ctx.sources
      assert match?({:error, _}, scoped_read(ctx, source.content_sha256, %{}))
    end

    test "the scoped payload action refuses AGT with a forged scope", ctx do
      [source | _] = ctx.sources

      forged =
        SdrAgent.Audit.Checks.DossierSourceScope.context(%{
          tenant_id: ctx.fixture.tenant.id,
          agent_run_id: ctx.run.id,
          lead_id: ctx.lead_id,
          entry_id: ctx.entry_id,
          sha256s: [:crypto.hash(:sha256, "another source")]
        })

      assert match?({:error, _}, scoped_read(ctx, source.content_sha256, forged))

      malformed = %{
        sdr_dossier_source_scope: %{
          tenant_id: ctx.fixture.tenant.id,
          sha256s: [source.content_sha256]
        }
      }

      assert match?({:error, _}, scoped_read(ctx, source.content_sha256, malformed))
    end
  end

  describe "adapters and SDR routing" do
    test "the dossier adapters still refuse" do
      assert SdrAgent.Integrations.DossierWeb.fetch("https://www.acme1.test/about") ==
               {:error, :prototype_scoped_read_required}
    end

    test "ReadCompanyPage.read/3 in prototype runtime records the bound source as a public_dossier page",
         ctx do
      [source | _] = ctx.sources
      tool = SdrAgent.SalesFixtures.tool_invocation!(ctx.fixture.tenant, ctx.run)

      sdr_ctx = %SdrAgent.SDR.Context{
        actor: ctx.agent,
        tenant_id: ctx.fixture.tenant.id,
        run_id: ctx.run.id,
        correlation_id: ctx.run.correlation_id,
        tool_invocation: tool
      }

      assert {:ok, artifact, _ref} =
               SdrAgent.SDR.Actions.ReadCompanyPage.read(sdr_ctx, ctx.lead_id, source.final_url)

      assert artifact.content == payload!(source.content_sha256)
      assert artifact.source_url == source.final_url
      assert artifact.trust_level == :unverified

      expected = if source.source_type == :company_site, do: :company_website, else: :web_page
      assert artifact.source_type == expected
    end

    test "SearchCompany in prototype runtime records every source but the website once and returns no URLs (C1)",
         ctx do
      # A website URL that is no source: every source counts as "other".
      website_url = "https://elsewhere.test/"
      others = ctx.sources
      assert others != []
      tool = SdrAgent.SalesFixtures.tool_invocation!(ctx.fixture.tenant, ctx.run)

      sdr_ctx = %SdrAgent.SDR.Context{
        actor: ctx.agent,
        tenant_id: ctx.fixture.tenant.id,
        run_id: ctx.run.id,
        correlation_id: ctx.run.correlation_id,
        tool_invocation: tool
      }

      assert {:ok, %{artifacts: artifacts, urls: []}, [], _refs} =
               SdrAgent.SDR.Actions.SearchCompany.perform(
                 %{lead_id: ctx.lead_id, website_url: website_url},
                 sdr_ctx
               )

      assert Enum.map(artifacts, & &1.source_url) |> Enum.sort() ==
               Enum.map(others, & &1.final_url) |> Enum.sort()

      assert Enum.all?(artifacts, &(&1.trust_level == :unverified))
    end

    test "SearchCompany in prototype runtime excludes the already recorded website source (C1)",
         ctx do
      [website | _] = ctx.sources
      tool = SdrAgent.SalesFixtures.tool_invocation!(ctx.fixture.tenant, ctx.run)

      sdr_ctx = %SdrAgent.SDR.Context{
        actor: ctx.agent,
        tenant_id: ctx.fixture.tenant.id,
        run_id: ctx.run.id,
        correlation_id: ctx.run.correlation_id,
        tool_invocation: tool
      }

      assert {:ok, %{artifacts: artifacts, urls: []}, [], _refs} =
               SdrAgent.SDR.Actions.SearchCompany.perform(
                 %{lead_id: ctx.lead_id, website_url: website.final_url},
                 sdr_ctx
               )

      refute Enum.any?(artifacts, &(&1.source_url == website.final_url))
    end
  end
end
