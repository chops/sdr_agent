defmodule SdrAgent.Prototype.LeadSourceReadTest do
  @moduledoc """
  RED (notes/features/owner-prospect-intake.org; ADR-0026; Claude contract
  913d5607, accepted by Codex 434a4c1c): `SdrAgent.Research.read_lead_sources/4`
  resolves a lead's ONE input origin by lead id (legacy dossier entry or
  owner intake). For an owner intake it reads each exact excerpt through
  `Payload :read_owner_intake_source_content` under
  `SdrAgent.Audit.Checks.OwnerIntakeSourceScope`. A dossier lead keeps the
  unchanged `read_dossier_sources/4` bytes. In prototype runtime,
  `ReadCompanyPage` and `SearchCompany` record owner sources as provider
  `:owner_intake`, trust `:unverified`.

  Synthetic `.test` fixtures in a sandboxed hosted binding; no model, CLI
  or network.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.PrototypeOutreachFixtures, only: [enter_window!: 1]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.DossierFixtures, as: D
  alias SdrAgent.HostedOwnerFixtures, as: H

  @research SdrAgent.Research
  @intake SdrAgent.Prototype.OwnerIntake
  @scope SdrAgent.Audit.Checks.OwnerIntakeSourceScope
  @seed SdrAgent.Prototype.Seed
  @import SdrAgent.Prototype.DossierImport

  # Exact bytes: an inner double space and a trailing newline must survive.
  @site_excerpt "Acme Intake builds  warehouse robots.\n"
  @team_excerpt "Avery Intake leads operations at Acme Intake."

  setup do
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    user = H.consume!(enrolled.enrollment_token)
    :ok = enter_window!(ctx.fx)
    agent = SdrAgent.Actor.system(:agent_runtime, ctx.fx.tenant.id)
    Map.merge(ctx, %{user: user, agent: agent})
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "company_name" => "Acme Intake",
        "domain" => "acme-intake.test",
        "website_url" => "https://www.acme-intake.test/",
        "first_name" => "Avery",
        "last_name" => "Intake",
        "title" => "VP Operations",
        "email" => "avery@acme-intake.test",
        "sources" => [
          %{
            "url" => "https://www.acme-intake.test/",
            "source_type" => "company_site",
            "retrieved_on" => "2026-10-30",
            "excerpt" => @site_excerpt
          },
          %{
            "url" => "https://www.acme-intake.test/team",
            "source_type" => "company_site",
            "retrieved_on" => "2026-10-30",
            "excerpt" => @team_excerpt
          }
        ]
      },
      overrides
    )
  end

  defp intake!(ctx, params) do
    assert {:ok, preview} = call(@intake, :preview, [params, ctx.user])
    result = call(@intake, :commit, [params, preview, ctx.user])

    assert match?({:ok, :created, %{lead_id: _, entry_id: _}}, result),
           "prerequisite: owner intake commit #{inspect(result)}"

    {:ok, :created, ids} = result
    ids
  end

  defp running_run!(ctx, lead_id) do
    definition = AgentsFixtures.definition!(ctx.fx.tenant)
    attrs = definition |> AgentsFixtures.run_attrs() |> Map.put(:lead_id, lead_id)
    {:ok, run} = Agents.create_run(attrs, actor: ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)
    run
  end

  defp read(ctx, run, lead_id, selector, actor \\ nil),
    do: call(@research, :read_lead_sources, [run.id, lead_id, selector, actor || ctx.agent])

  defp views do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM audit_accesses WHERE purpose = $1 AND actor_type = 'agent_runtime'",
        [call(@scope, :purpose, [])]
      )

    n
  end

  defp scoped_read(ctx, sha256, context) do
    SdrAgent.Audit.Payload
    |> Ash.ActionInput.for_action(:read_owner_intake_source_content, %{sha256: sha256},
      actor: ctx.agent,
      context: context
    )
    |> Ash.run_action()
  end

  # The action returns the model-facing summary; provider and trust are
  # read from the stored artifact row.
  defp stored!(ctx, summary) do
    {:ok, artifact} = Ash.get(SdrAgent.Research.ResearchArtifact, summary.id, H.kernel(ctx))
    artifact
  end

  defp sdr_ctx(ctx, run) do
    %SdrAgent.SDR.Context{
      actor: ctx.agent,
      tenant_id: ctx.fx.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      tool_invocation: SdrAgent.SalesFixtures.tool_invocation!(ctx.fx.tenant, run)
    }
  end

  describe "owner intake origin" do
    setup ctx do
      # Agent runs need the seeded settings (offering profile).
      assert match?({:ok, _}, call(@seed, :run, [D.seed_read(), ctx.fx.actor]))
      ids = intake!(ctx, params())
      Map.merge(ctx, %{ids: ids, run: running_run!(ctx, ids.lead_id)})
    end

    test ":all returns each owner source with its exact bytes and origin, each read audited",
         ctx do
      before = views()
      assert {:ok, items} = read(ctx, ctx.run, ctx.ids.lead_id, :all)
      assert Enum.map(items, & &1.source_id) == ["s1", "s2"]
      assert Enum.map(items, & &1.content) == [@site_excerpt, @team_excerpt]
      assert Enum.all?(items, &(&1.origin == :owner_intake))
      assert Enum.all?(items, &(is_binary(&1.owner_source_id) and is_nil(&1.checked_at)))
      assert Enum.map(items, & &1.final_url) == Enum.map(params()["sources"], & &1["url"])
      assert Enum.all?(items, &(&1.source_type == :company_site))
      assert Enum.all?(items, &(&1.retrieved_on == ~D[2026-10-30]))
      assert views() == before + 2
    end

    test "{:final_url, url} returns exactly that source; an unknown URL reads nothing", ctx do
      url = "https://www.acme-intake.test/team"
      assert {:ok, [item]} = read(ctx, ctx.run, ctx.ids.lead_id, {:final_url, url})
      assert item.content == @team_excerpt
      before = views()

      assert read(ctx, ctx.run, ctx.ids.lead_id, {:final_url, "https://nowhere.test/"}) ==
               {:error, :owner_source_missing}

      assert views() == before
    end

    test "the legacy dossier reader does not serve an owner lead", ctx do
      result =
        call(@research, :read_dossier_sources, [ctx.run.id, ctx.ids.lead_id, :all, ctx.agent])

      assert result == {:error, :dossier_entry_missing}
    end

    test "a non-AGT actor, a foreign tenant and another lead's run read nothing", ctx do
      before = views()
      operator = read(ctx, ctx.run, ctx.ids.lead_id, :all, ctx.fx.actor)
      assert match?({:error, code} when is_atom(code), operator), inspect(operator)
      foreign = SdrAgent.Actor.system(:agent_runtime, Ecto.UUID.generate())
      assert read(ctx, ctx.run, ctx.ids.lead_id, :all, foreign) == {:error, :forbidden}
      other = running_run!(ctx, Ecto.UUID.generate())
      assert read(ctx, other, ctx.ids.lead_id, :all) == {:error, :forbidden}
      assert views() == before
    end

    test "the owner scope refuses no scope, a forged hash list and a malformed scope", ctx do
      sha = :crypto.hash(:sha256, @site_excerpt)
      assert match?({:error, _}, scoped_read(ctx, sha, %{}))

      forged =
        call(@scope, :context, [
          %{
            tenant_id: ctx.fx.tenant.id,
            agent_run_id: ctx.run.id,
            lead_id: ctx.ids.lead_id,
            intake_id: ctx.ids.entry_id,
            sha256s: [:crypto.hash(:sha256, "another excerpt")]
          }
        ])

      assert match?({:error, _}, scoped_read(ctx, sha, forged))
      malformed = %{sdr_owner_intake_source_scope: %{tenant_id: ctx.fx.tenant.id, sha256s: [sha]}}
      assert match?({:error, _}, scoped_read(ctx, sha, malformed))
    end

    test "the dossier scope cannot read an owner excerpt", ctx do
      sha = :crypto.hash(:sha256, @site_excerpt)

      dossier_scope =
        SdrAgent.Audit.Checks.DossierSourceScope.context(%{
          tenant_id: ctx.fx.tenant.id,
          agent_run_id: ctx.run.id,
          lead_id: ctx.ids.lead_id,
          entry_id: ctx.ids.entry_id,
          sha256s: [sha]
        })

      result =
        SdrAgent.Audit.Payload
        |> Ash.ActionInput.for_action(:read_dossier_source_content, %{sha256: sha},
          actor: ctx.agent,
          context: dossier_scope
        )
        |> Ash.run_action()

      assert match?({:error, _}, result)
    end

    test "ordinary runtime is :not_prototype_runtime", ctx do
      SdrAgent.PrototypeFixtures.leave_runtime()
      assert read(ctx, ctx.run, ctx.ids.lead_id, :all) == {:error, :not_prototype_runtime}
    end

    test "ReadCompanyPage records the website source as an owner_intake unverified page", ctx do
      url = params()["website_url"]

      page = SdrAgent.SDR.Actions.ReadCompanyPage
      assert {:ok, artifact, _ref} = page.read(sdr_ctx(ctx, ctx.run), ctx.ids.lead_id, url)

      stored = stored!(ctx, artifact)

      assert {stored.provider, stored.trust_level, stored.source_type} ==
               {:owner_intake, :unverified, :company_website}

      assert stored.metadata["retrieved_at_meaning"] == "owner_submitted"

      assert {artifact.content, artifact.source_url} == {@site_excerpt, url}
    end

    test "SearchCompany records every other owner source once as owner_intake", ctx do
      assert {:ok, %{artifacts: artifacts, urls: []}, [], _refs} =
               SdrAgent.SDR.Actions.SearchCompany.perform(
                 %{lead_id: ctx.ids.lead_id, website_url: params()["website_url"]},
                 sdr_ctx(ctx, ctx.run)
               )

      recorded =
        Enum.map(artifacts, fn summary ->
          stored = stored!(ctx, summary)
          {summary.source_url, stored.provider, stored.trust_level, summary.content}
        end)

      assert recorded == [
               {"https://www.acme-intake.test/team", :owner_intake, :unverified, @team_excerpt}
             ]
    end
  end

  describe "P1: one Account, two origins" do
    setup ctx do
      assert match?({:ok, _}, call(@seed, :run, [D.seed_read(), ctx.fx.actor]))
      [row] = D.route_rows!([D.company(1)], ["row-1"])

      {:ok, :imported, %{lead_id: dossier_lead, entry_id: entry_id}} =
        call(@import, :import_row, [row, ctx.fx.actor])

      {:ok, lead} = Ash.get(SdrAgent.Sales.Lead, dossier_lead, H.kernel(ctx))
      {:ok, account} = Ash.get(SdrAgent.Sales.Account, lead.account_id, H.kernel(ctx))
      website = to_string(account.website_url)

      owner =
        intake!(
          ctx,
          params(%{
            "company_name" => account.name,
            "domain" => to_string(account.domain),
            "website_url" => website,
            "email" => "riley@#{account.domain}",
            "first_name" => "Riley",
            "sources" => [
              %{
                "url" => website,
                "source_type" => "company_site",
                "retrieved_on" => "2026-10-30",
                "excerpt" => @site_excerpt
              }
            ]
          })
        )

      assert owner.account_id == account.id

      Map.merge(ctx, %{
        dossier_lead: dossier_lead,
        entry_id: entry_id,
        owner: owner,
        dossier_run: running_run!(ctx, dossier_lead),
        owner_run: running_run!(ctx, owner.lead_id)
      })
    end

    test "the owner lead reads only its owner source; the dossier lead only its dossier sources",
         ctx do
      assert {:ok, owner_items} = read(ctx, ctx.owner_run, ctx.owner.lead_id, :all)
      assert Enum.map(owner_items, &{&1.origin, &1.content}) == [{:owner_intake, @site_excerpt}]

      assert {:ok, dossier_items} = read(ctx, ctx.dossier_run, ctx.dossier_lead, :all)
      assert dossier_items != []
      assert Enum.all?(dossier_items, &(&1.origin == :dossier))
      refute Enum.any?(dossier_items, &(&1.content == @site_excerpt))

      assert {:ok, legacy} =
               call(@research, :read_dossier_sources, [
                 ctx.dossier_run.id,
                 ctx.dossier_lead,
                 :all,
                 ctx.agent
               ])

      assert Enum.map(dossier_items, & &1.content) == Enum.map(legacy, & &1.content)
    end

    test "a run of one origin's lead cannot read the other lead", ctx do
      assert read(ctx, ctx.owner_run, ctx.dossier_lead, :all) == {:error, :forbidden}
      assert read(ctx, ctx.dossier_run, ctx.owner.lead_id, :all) == {:error, :forbidden}
    end
  end
end
