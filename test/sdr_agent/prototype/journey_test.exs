defmodule SdrAgent.Prototype.JourneyTest do
  @moduledoc """
  G4: the first integrated hermetic Fake journey of the D-237 prototype
  (plan r7 section 5 row G4 and section 6 row "Journey"; interfaces r6
  IF-1..IF-8). No real model call, no network, no owner database:
  ClaudeCLI runs against the hermetic fake CLI, the witness store is
  absent, and all data is synthetic (`.test` names).

  The chain, each link owned by its slice:

    1. setup phase 2 in the sandbox (S1 `PrototypeFixtures.bind/1`);
    2. the GTM seed from a synthetic four-file seed directory (S3
       `SdrAgent.Prototype.Seed.run/2`);
    3. the budget worksheet and provisioning (S1
       `SdrAgent.Agents.provision_prototype_grant/2`);
    4. import of ONE synthetic dossier row through the real route (S3
       `SdrAgent.Prototype.DossierImport.import_row/2`, supplement 1 r2
       section 5; the row from S3's synthetic fixtures);
    5. `op assign` (S4) → the agent run in prototype runtime on the
       ClaudeCLI provider with a FAKE CLI executable (the
       `:claude_cli_test_seams` harness; never the Fake provider: the policy
       entry pins `:claude_cli` with `:claude_cli_opus`) → the bound dossier
       excerpts become accepted claims on `:company_website` / `:web_page`
       artifacts of provider `:public_dossier` (S3) → three
       `released_unverified` releases (S2) → a draft, absent from Home
       (R10: Home keeps requiring `:released`);
    6. `op review` (S4): the bundle with the pending-revision view;
    7. `op approve` (S4) with the reviewed revision, digest and address →
       the delegated machine approval;
    8. capture (S4 validation) → one captured receipt carrying the block;
    9. exact charges: three attempts consumed on the one grant.

  The disqualified variant ends truthfully with no draft.

  It runs once S1, S2 and S3 land on the integration branch; before that it
  fails at the first missing link (an assertion, never a crash).
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  import SdrAgent.OutreachFixtures,
    only: [deliver!: 0, receipts!: 2, delivery_of!: 2, approvals!: 2]

  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Outreach
  alias SdrAgent.Prototype.Output

  @op Mix.Tasks.Sdr.Prototype.Op
  @seed SdrAgent.Prototype.Seed
  @import SdrAgent.Prototype.DossierImport
  # S3's fixtures (test/support/dossier_fixtures.ex; S3 RED-2): company/1,2
  # builds a valid synthetic row (reserved names; size, location and industry
  # facts verified), route_rows/2 takes it through DossierParser.parse,
  # SpotcheckManifest.parse and DossierImport.prepare in its own exclusive
  # scratch dir, and seed_read/0 gives the SeedDir.read/2 map. Until S3 lands
  # these links fail as assertions (call/3 guards).
  @s3_fixtures SdrAgent.DossierFixtures
  @cli Path.expand("../../support/d237_journey_cli.exs", __DIR__)
  @label "UNVERIFIED (PROTOTYPE)"

  defp scratch!(name), do: exclusive_root!("d237-journey-#{name}")

  defp private!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    {path, hex(:crypto.hash(:sha256, bytes))}
  end

  defp start_cli!(variant) do
    assert File.regular?(@cli), "the journey's fake CLI #{@cli} does not exist"
    put_env!(:model_provider, ClaudeCLI)

    start_supervised!(
      {ClaudeCLI,
       [
         name: ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         test_launcher: true,
         command_args: [@cli, variant]
       ]}
    )
  end

  defp put_env!(key, value), do: SdrAgent.OutreachFixtures.put_env!(key, value)

  defp agent(ctx), do: SdrAgent.Actor.system(:agent_runtime, ctx.fixture.tenant.id)

  # Steps 1–4: a bound prototype with the seed, a provisioned grant and one imported row.
  defp prepared! do
    fixture = bound!(auditor: true)
    enter_window!(fixture)
    actor = fixture.actor

    seed = call(@seed, :run, [call(@s3_fixtures, :seed_read, []), actor])
    assert match?({:ok, %{campaign_id: _}}, seed), "seed (S3): #{inspect(seed)}"
    {:ok, %{campaign_id: campaign_id}} = seed

    root = scratch!("worksheet")
    {worksheet, worksheet_sha} = private!(root, "worksheet.json", journey_worksheet(root))

    grant =
      call(Agents, :provision_prototype_grant, [
        %{worksheet: File.read!(worksheet), worksheet_sha256: worksheet_sha},
        [actor: actor, evidence_root: root]
      ])

    # S1 contract (IF-2): the grant itself, never a wrapper.
    assert match?({:ok, %SdrAgent.Agents.ModelCallGrant{}}, grant),
           "provision (S1): #{inspect(grant)}"

    {:ok, grant_record} = grant

    # One row prepared through the real route by S3's route_rows/2 (never a
    # bespoke row). The variant is decided by the ICP and the fake CLI's
    # answer, not by the row.
    company = call(@s3_fixtures, :company, [1])
    routed = call(@s3_fixtures, :route_rows, [[company], ["row-1"]])
    assert match?({:ok, [_ | _]}, routed), "route_rows (S3): #{inspect(routed, limit: 5)}"
    {:ok, [row | _]} = routed
    imported = call(@import, :import_row, [row, actor])

    assert match?({:ok, :imported, %{lead_id: _, entry_id: _}}, imported),
           "import (S3): #{inspect(imported)}"

    {:ok, :imported, %{lead_id: lead_id, entry_id: entry_id}} = imported
    {:ok, lead} = SdrAgent.Sales.fetch(SdrAgent.Sales.Lead, lead_id, actor: actor)
    {:ok, campaign} = SdrAgent.Sales.fetch(SdrAgent.Sales.Campaign, campaign_id, actor: actor)

    %{
      fixture: fixture,
      actor: actor,
      lead: lead,
      entry_id: entry_id,
      campaign: campaign,
      grant: grant_record
    }
  end

  # The bound dossier excerpts became accepted claims on public_dossier
  # website or page artifacts, each artifact bound to one of the entry's
  # DossierSource digests (supplement 1 r2 sections 6 and 6a).
  defp assert_dossier_evidence!(ctx) do
    {:ok, sources} =
      Ash.read(SdrAgent.Research.DossierSource, actor: ctx.actor)

    source_digests =
      for source <- sources,
          source.entry_id == ctx.entry_id,
          into: MapSet.new(),
          do: source.content_sha256

    assert MapSet.size(source_digests) > 0, "the imported entry has no dossier sources"

    {:ok, claims} =
      SdrAgent.Research.EvidenceClaim
      |> Ash.Query.filter(lead_id == ^ctx.lead.id and quality == :accepted)
      |> Ash.read(actor: ctx.actor)

    assert claims != [], "no accepted claim on the imported lead"

    for claim <- claims do
      {:ok, artifact} =
        Ash.get(SdrAgent.Research.ResearchArtifact, claim.research_artifact_id, actor: ctx.actor)

      assert artifact.provider == :public_dossier
      assert artifact.source_type in [:company_website, :web_page]
      assert artifact.trust_level == :unverified
      assert MapSet.member?(source_digests, artifact.content_sha256)
    end
  end

  # R10: Home keeps requiring `:released`, so a released_unverified draft
  # never appears there.
  defp refute_on_home!(ctx, draft) do
    auditor = ctx.fixture.auditor
    result = SdrAgent.Outreach.Inbox.list(auditor, nil)
    assert match?({:ok, _}, result), "Home refused the auditor: #{inspect(result, limit: 5)}"
    refute inspect(result, limit: :infinity) =~ draft.id, "a released_unverified draft is on Home"
  end

  defp journey_worksheet(root) do
    routes =
      for route <- ~w(prototype_binding owner_dev owner_calibration hosted other_owner) do
        {_path, sha} = private!(root, "#{route}.receipt", "counts-only receipt #{route}\n")

        %{
          "route" => route,
          "basis" =>
            if(route == "prototype_binding", do: "agent_receipt", else: "owner_attestation"),
          "consumed" => 0,
          "evidence" => %{"path" => "#{route}.receipt", "sha256" => sha}
        }
      end

    {_path, previous} = private!(root, "previous.receipt", "counts-only receipt previous\n")

    Jason.encode!(%{
      "schema" => "d237-budget-worksheet/1",
      "shared_total" => 60,
      "window_starts_at" => "2026-10-28T02:38:32.000000Z",
      "as_of" => "2026-10-29T12:00:00Z",
      "routes" => routes,
      "previous_bindings" => %{
        "consumed" => 0,
        "evidence" => %{"path" => "previous.receipt", "sha256" => previous}
      }
    })
  end

  defp op!(parsed, actor) do
    result = call(@op, :execute, [parsed, actor])
    assert match?({:ok, _}, result), "op #{parsed.command}: #{inspect(result)}"
    {:ok, value} = result
    value
  end

  test "G4: assign → three released_unverified → draft → review → delegated approve → captured with the block" do
    ctx = prepared!()
    start_cli!("qualified")

    %{id: run_id} =
      op!(
        %{command: :assign, agent: :claude_code, lead: ctx.lead.id, campaign: ctx.campaign.id},
        ctx.actor
      )

    assert %{success: 1} = Oban.drain_queue(queue: :research, with_safety: false)

    {:ok, run} = Agents.get_run(run_id, actor: ctx.actor)
    assert run.status == :succeeded, inspect({run.status, run.status_reason})
    assert_dossier_evidence!(ctx)

    {:ok, invocations} = Agents.list_model_invocations(run.id, actor: agent(ctx))
    assert length(invocations) == 3

    for invocation <- invocations do
      {:ok, release} = Agents.get_result_release(invocation.id, actor: agent(ctx))
      assert release.disposition == :released_unverified
      assert release.reason == :owner_prototype_unverified
    end

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: ctx.lead.id], actor: ctx.actor)

    refute_on_home!(ctx, draft)

    bundle_id =
      op!(%{command: :review, agent: :claude_code, draft: draft.id}, ctx.actor).bundle_id

    assert is_binary(bundle_id)

    {:ok, view} = Output.view(:pending_revision, draft.id, ctx.actor)
    fields = view["fields"]

    op!(
      %{
        command: :approve,
        agent: :claude_code,
        revision: fields["revision_id"],
        revision_sha256: fields["revision_content_sha256"],
        recipient_email: fields["recipient_email"]
      },
      ctx.actor
    )

    [approval] = approvals!(%{admin: ctx.actor}, draft)
    assert approval.approver_id == ctx.fixture.anchor.id
    deliver!()

    [receipt] =
      Enum.filter(
        receipts!(%{admin: ctx.actor}, delivery_of!(%{admin: ctx.actor}, approval)),
        &(&1.kind == :captured)
      )

    {:ok, receipt_view} = Output.view(:receipt, receipt.id, ctx.actor)
    assert receipt_view["prototype"]["label"] == @label
    refute receipt_view["fields"]["rendered_bytes"] =~ @label

    [granted] = events_of(ctx.fixture.tenant, "outreach.approval.granted")
    assert granted.payload["arguments"]["approval_mode"] == "delegated_machine"
  end

  test "G4 disqualified variant: a truthful disqualification, no draft and no approval" do
    ctx = prepared!()
    start_cli!("disqualified")

    %{id: run_id} =
      op!(
        %{command: :assign, agent: :claude_code, lead: ctx.lead.id, campaign: ctx.campaign.id},
        ctx.actor
      )

    assert %{success: 1} = Oban.drain_queue(queue: :research, with_safety: false)
    {:ok, run} = Agents.get_run(run_id, actor: ctx.actor)
    assert run.status == :succeeded
    assert_dossier_evidence!(ctx)

    assert {:ok, []} =
             Outreach.list_records(Outreach.Draft,
               filter: [lead_id: ctx.lead.id],
               actor: ctx.actor
             )
  end
end
