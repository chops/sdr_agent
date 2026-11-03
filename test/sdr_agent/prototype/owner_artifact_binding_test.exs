defmodule SdrAgent.Prototype.OwnerArtifactBindingTest do
  @moduledoc "Direct owner-origin artifact binding controls; synthetic data, no model or network."
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.DossierFixtures
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Prototype.OwnerIntake
  alias SdrAgent.Research
  alias SdrAgent.SalesFixtures

  @content "  Avery builds synthetic widgets.\n"
  @url "https://owner-binding.test/"
  @metadata_keys ~w(owner_source_id owner_intake_id source_id submission_sha256
                    final_url source_type retrieved_on retrieved_at_meaning)

  setup do
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    H.enter!(ctx)
    assert {:ok, _} = SdrAgent.Prototype.Seed.run(DossierFixtures.seed_read(), ctx.fx.actor)
    user = enrolled.user
    ids = save!(user, "avery@owner-binding.test", @content)
    agent = SdrAgent.Actor.system(:agent_runtime, ctx.fx.tenant.id)
    attrs = AgentsFixtures.definition!(ctx.fx.tenant) |> AgentsFixtures.run_attrs()
    assert {:ok, run} = Agents.create_run(Map.put(attrs, :lead_id, ids.lead_id), actor: agent)
    assert {:ok, run} = Agents.start_run(run, actor: agent)
    tool = SalesFixtures.tool_invocation!(ctx.fx.tenant, run)

    # Setup reads use the established private fixture kernel, never the
    # subject under test; artifact writes below use the real agent actor.
    assert {:ok, [source]} = Ash.read(Research.OwnerProspectSource, H.kernel(ctx))
    assert {:ok, intake} = Ash.get(Research.OwnerProspectIntake, ids.entry_id, H.kernel(ctx))

    Map.merge(ctx, %{
      user: user,
      ids: ids,
      agent: agent,
      run: run,
      tool: tool,
      source: source,
      intake: intake
    })
  end

  defp save!(user, email, excerpt) do
    input = %{
      "company_name" => "Owner Binding",
      "domain" => "owner-binding.test",
      "website_url" => @url,
      "first_name" => "Avery",
      "last_name" => "Synthetic",
      "title" => "Founder",
      "email" => email,
      "sources" => [
        %{
          "url" => @url,
          "source_type" => "company_site",
          "retrieved_on" => "2026-11-01",
          "excerpt" => excerpt
        }
      ]
    }

    assert {:ok, preview} = OwnerIntake.preview(input, user)
    assert {:ok, :created, ids} = OwnerIntake.commit(input, preview, user)
    ids
  end

  defp attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        lead_id: ctx.ids.lead_id,
        agent_run_id: ctx.run.id,
        tool_invocation_id: ctx.tool.id,
        source_type: :company_website,
        provider: :public_dossier,
        source_url: @url,
        title: "Synthetic page",
        content: @content,
        excerpt: "Avery",
        trust_level: :high,
        freshness: :current,
        retrieved_at: DateTime.utc_now(),
        published_at: DateTime.utc_now(),
        metadata: %{"dossier_source_id" => "forged", "owner_source_id" => "forged"}
      },
      overrides
    )
  end

  defp writes do
    %{rows: [[payloads, artifacts, events]]} =
      Repo.query!("""
      SELECT (SELECT count(*) FROM payloads), (SELECT count(*) FROM research_artifacts),
        (SELECT count(*) FROM audit_events WHERE event_type='research.artifact.recorded')
      """)

    {payloads, artifacts, events}
  end

  defp refused?(result, code),
    do: match?({:error, _}, result) and inspect(result, limit: :infinity) =~ code

  test "all owner provenance and trust fields are server-bound despite dossier impersonation",
       ctx do
    assert {:ok, artifact} = Research.record_artifact(attrs(ctx), actor: ctx.agent)
    assert artifact.provider == :owner_intake
    assert artifact.trust_level == :unverified
    assert artifact.freshness == :unknown
    assert artifact.published_at == nil
    assert artifact.retrieved_at == ctx.source.submitted_at
    assert artifact.content_sha256 == :crypto.hash(:sha256, @content)
    assert Enum.sort(Map.keys(artifact.metadata)) == Enum.sort(@metadata_keys)
    assert artifact.metadata["owner_source_id"] == ctx.source.id
    assert artifact.metadata["owner_intake_id"] == ctx.ids.entry_id
    assert artifact.metadata["source_id"] == "s1"

    assert artifact.metadata["submission_sha256"] ==
             Base.encode16(ctx.intake.submission_sha256, case: :lower)

    assert artifact.metadata["retrieved_at_meaning"] == "owner_submitted"
  end

  test "substituted content is refused before any artifact payload or event write", ctx do
    before = writes()

    result =
      Research.record_artifact(attrs(ctx, %{content: "Substituted bytes"}), actor: ctx.agent)

    assert refused?(result, "content_not_source_bound"), inspect(result)
    assert writes() == before
  end

  test "an unknown owner source URL is refused without partial writes", ctx do
    before = writes()

    result =
      Research.record_artifact(attrs(ctx, %{source_url: "https://other.test/"}),
        actor: ctx.agent
      )

    assert refused?(result, "owner_source_missing"), inspect(result)
    assert writes() == before
  end

  test "exact artifact replay returns the original id without another payload or event", ctx do
    assert {:ok, first} = Research.record_artifact(attrs(ctx), actor: ctx.agent)
    before = writes()
    assert {:ok, again} = Research.record_artifact(attrs(ctx), actor: ctx.agent)
    assert again.id == first.id
    assert writes() == before
  end

  test "same Account and URL do not let one lead use another contact's excerpt", ctx do
    other = save!(ctx.user, "rowan@owner-binding.test", "Rowan has a different exact excerpt.")
    assert other.account_id == ctx.ids.account_id
    before = writes()
    result = Research.record_artifact(attrs(ctx, %{lead_id: other.lead_id}), actor: ctx.agent)
    assert refused?(result, "content_not_source_bound"), inspect(result)
    assert writes() == before
  end
end
