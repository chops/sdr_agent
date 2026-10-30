defmodule SdrAgent.Prototype.ArtifactSourceBindingTest do
  @moduledoc """
  `ResearchArtifact :record` binds a prototype artifact to its dossier source
  and bytes (supplement 1 r2 §6, R8; D-268 M8 research link): in prototype
  runtime `SdrAgent.Research.Validations.SourceUrl` and
  `SdrAgent.Research.Changes.DossierSourceBinding` resolve exactly one
  source of the artifact's lead entry by `final_url`, require
  `sha256(content)` to be that source's `content_sha256`, and force
  `provider: :public_dossier`, `trust_level: :unverified`, the spot-check
  time, `published_at: nil`, `freshness: :unknown` and the fixed metadata.
  Ordinary runtime keeps today's `Reserved` check exactly.

  Synthetic `.test` fixtures in a sandboxed prototype binding.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.PrototypeOutreachFixtures, only: [enter_window!: 1]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Research
  alias SdrAgent.SalesFixtures

  @seed SdrAgent.Prototype.Seed
  @import SdrAgent.Prototype.DossierImport
  @metadata_keys ~w(dossier_source_id dossier_entry_id source_id dossier_sha256 spotcheck_sha256
                    original_url final_url source_type retrieved_on retrieved_at_meaning)

  setup do
    fixture = bound!()
    enter_window!(fixture)
    actor = fixture.actor
    assert match?({:ok, _}, call(@seed, :run, [F.seed_read(), actor]))

    [one, two] = F.route_rows!([F.company(1), F.company(2)], ["row-1", "row-2"])

    {:ok, :imported, %{lead_id: lead_id, entry_id: entry_id}} =
      call(@import, :import_row, [one, actor])

    {:ok, :imported, %{lead_id: other_lead_id}} = call(@import, :import_row, [two, actor])

    agent = SdrAgent.Actor.system(:agent_runtime, fixture.tenant.id)
    definition = AgentsFixtures.definition!(fixture.tenant)
    attrs = definition |> AgentsFixtures.run_attrs() |> Map.put(:lead_id, lead_id)
    {:ok, run} = Agents.create_run(attrs, actor: agent)
    {:ok, run} = Agents.start_run(run, actor: agent)
    tool = SalesFixtures.tool_invocation!(fixture.tenant, run)

    # Setup read only (the operator has no DossierSource read); never the subject.
    {:ok, sources} = Ash.read(Research.DossierSource, authorize?: false)
    mine = sources |> Enum.filter(&(&1.entry_id == entry_id)) |> Enum.sort_by(& &1.source_id)

    %{
      fixture: fixture,
      agent: agent,
      lead_id: lead_id,
      other_lead_id: other_lead_id,
      entry_id: entry_id,
      run: run,
      tool: tool,
      source: hd(mine)
    }
  end

  defp payload!(sha256) do
    %{rows: [[content]]} = Repo.query!("SELECT content FROM payloads WHERE sha256 = $1", [sha256])
    content
  end

  defp count(sql) do
    %{rows: [[n]]} = Repo.query!(sql, [])
    n
  end

  defp writes,
    do:
      {count("SELECT count(*) FROM payloads"), count("SELECT count(*) FROM research_artifacts"),
       count("SELECT count(*) FROM audit_events WHERE event_type = 'research.artifact.recorded'")}

  # What Support.record_artifact/3 sends, with a caller trying to set the
  # server-owned fields.
  defp attrs(ctx, overrides \\ %{}) do
    content = Map.get(overrides, :content, payload!(ctx.source.content_sha256))

    Map.merge(
      %{
        lead_id: ctx.lead_id,
        agent_run_id: ctx.run.id,
        tool_invocation_id: ctx.tool.id,
        source_type: :company_website,
        provider: :fixture_web,
        source_url: ctx.source.final_url,
        title: "page",
        content: content,
        excerpt: String.slice(content, 0, 20),
        trust_level: :high,
        freshness: :current,
        retrieved_at: DateTime.utc_now(),
        published_at: DateTime.utc_now(),
        metadata: %{"dossier_source_id" => "forged", "extra" => "x"}
      },
      overrides
    )
  end

  defp refused?(result, code),
    do: match?({:error, _}, result) and inspect(result, limit: :infinity) =~ Atom.to_string(code)

  test "the correct source and bytes are accepted with every server-owned field forced", ctx do
    assert {:ok, artifact} = Research.record_artifact(attrs(ctx), actor: ctx.agent)
    source = ctx.source

    assert artifact.provider == :public_dossier
    assert artifact.trust_level == :unverified
    assert artifact.retrieved_at == source.checked_at
    assert artifact.published_at == nil
    assert artifact.freshness == :unknown
    assert artifact.content_sha256 == source.content_sha256

    assert Map.keys(artifact.metadata) |> Enum.map(&to_string/1) |> Enum.sort() ==
             Enum.sort(@metadata_keys)

    assert artifact.metadata["dossier_source_id"] == source.id
    assert artifact.metadata["dossier_entry_id"] == ctx.entry_id
    assert artifact.metadata["final_url"] == source.final_url
    assert artifact.metadata["retrieved_at_meaning"] == "spot_check"
  end

  test "a genuine URL with substituted bytes is :content_not_source_bound, nothing written",
       ctx do
    before = writes()

    result =
      Research.record_artifact(attrs(ctx, %{content: "substituted bytes"}), actor: ctx.agent)

    assert refused?(result, :content_not_source_bound), inspect(result)
    assert writes() == before
  end

  test "another lead's artifact for this source's URL is :dossier_source_missing", ctx do
    before = writes()
    result = Research.record_artifact(attrs(ctx, %{lead_id: ctx.other_lead_id}), actor: ctx.agent)
    assert refused?(result, :dossier_source_missing), inspect(result)
    assert writes() == before
  end

  test "a URL with no source is :dossier_source_missing before any Payload or event write", ctx do
    before = writes()

    result =
      Research.record_artifact(attrs(ctx, %{source_url: "https://nowhere.test/x"}),
        actor: ctx.agent
      )

    assert refused?(result, :dossier_source_missing), inspect(result)
    assert writes() == before
  end

  # Two sources of one lead entry sharing a final_url (s1 also carries a
  # verified fact, so both become DossierSources): no first-row-wins.
  test "two sources of the lead sharing a final_url are :dossier_source_ambiguous", ctx do
    url = "https://www.acme3.test/about"

    row =
      F.company(3)
      |> Map.update!("sources", fn [s1, s2] ->
        [%{s1 | "original_url" => url, "final_url" => url}, s2]
      end)
      |> Map.update!("facts", fn [f1 | rest] -> [%{f1 | "source_id" => "s1"} | rest] end)

    [routed] = F.route_rows!([row], ["row-3"])

    {:ok, :imported, %{lead_id: lead_id, entry_id: entry_id}} =
      call(@import, :import_row, [routed, ctx.fixture.actor])

    {:ok, all} = Ash.read(Research.DossierSource, authorize?: false)
    shared = Enum.filter(all, &(&1.entry_id == entry_id and &1.final_url == url))
    assert length(shared) == 2, "the fixture must store two sources at one URL"

    content = payload!(hd(shared).content_sha256)
    before = writes()

    result =
      Research.record_artifact(
        attrs(ctx, %{lead_id: lead_id, source_url: url, content: content}),
        actor: ctx.agent
      )

    assert refused?(result, :dossier_source_ambiguous), inspect(result)
    assert writes() == before
  end

  test "a replay returns the same artifact", ctx do
    {:ok, first} = Research.record_artifact(attrs(ctx), actor: ctx.agent)
    {:ok, again} = Research.record_artifact(attrs(ctx, %{title: "other"}), actor: ctx.agent)
    assert again.id == first.id
  end

  test "ordinary runtime keeps the Reserved check exactly", ctx do
    SdrAgent.PrototypeFixtures.leave_runtime()
    real = attrs(ctx, %{source_url: "https://www.unreserved-domain.com/about"})
    assert match?({:error, _}, Research.record_artifact(real, actor: ctx.agent))

    # A reserved .test URL is recorded as the caller sent it: no binding.
    assert {:ok, artifact} = Research.record_artifact(attrs(ctx), actor: ctx.agent)
    assert artifact.provider == :fixture_web
    assert artifact.trust_level == :high
    assert artifact.freshness == :current
  end
end
