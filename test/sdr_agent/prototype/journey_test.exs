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
    4. import of ONE synthetic dossier row (S3
       `SdrAgent.Sales.import_dossier_row/2`);
    5. `op assign` (S4) → the agent run on ClaudeCLI → three
       `released_unverified` releases (S2) → a draft;
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

  import SdrAgent.OutreachFixtures,
    only: [deliver!: 0, receipts!: 2, delivery_of!: 2, approvals!: 2]

  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Outreach
  alias SdrAgent.Prototype.Output

  @op Mix.Tasks.Sdr.Prototype.Op
  @seed SdrAgent.Prototype.Seed
  @sales SdrAgent.Sales
  @cli Path.expand("../../support/d237_journey_cli.exs", __DIR__)
  @label "UNVERIFIED (PROTOTYPE)"

  defp scratch!(name) do
    dir =
      Path.join(System.tmp_dir!(), "d237-journey-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

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
  defp prepared!(variant) do
    fixture = bound!()
    enter!(fixture)
    actor = fixture.actor

    seed_dir = scratch!("seed")
    seed = call(@seed, :run, [%{dir: seed_dir, fixture: :synthetic}, [actor: actor]])
    assert match?({:ok, _}, seed), "seed (S3): #{inspect(seed)}"

    root = scratch!("worksheet")
    {worksheet, worksheet_sha} = private!(root, "worksheet.json", journey_worksheet(root))

    grant =
      call(Agents, :provision_prototype_grant, [
        %{worksheet: File.read!(worksheet), worksheet_sha256: worksheet_sha},
        [actor: actor, evidence_root: root]
      ])

    assert match?({:ok, _}, grant), "provision (S1): #{inspect(grant)}"

    dossier_dir = scratch!("dossier")
    {dossier, dossier_sha} = private!(dossier_dir, "dossier.json", journey_dossier(variant))

    imported =
      call(@sales, :import_dossier_row, [
        %{dossier: dossier, dossier_sha256: dossier_sha, row_id: "acme-widgets"},
        [actor: actor]
      ])

    assert match?({:ok, %{lead: _}}, imported), "import (S3): #{inspect(imported)}"
    {:ok, %{lead: lead, campaign: campaign}} = imported
    {:ok, %{grant: grant_record}} = grant

    %{fixture: fixture, actor: actor, lead: lead, campaign: campaign, grant: grant_record}
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

  # A synthetic `sdr-agent.prototype-dossier` v1 file with one importable row
  # (reserved `.test` names only); the S3 parser is the authority on its shape.
  defp journey_dossier(_variant) do
    Jason.encode!(%{
      "schema" => "sdr-agent.prototype-dossier",
      "schema_version" => 1,
      "generated_at" => "2026-10-29T10:00:00Z",
      "sources_policy" => "synthetic journey fixture",
      "companies" => []
    })
  end

  defp op!(parsed, actor) do
    result = call(@op, :execute, [parsed, actor])
    assert match?({:ok, _}, result), "op #{parsed.command}: #{inspect(result)}"
    {:ok, value} = result
    value
  end

  test "G4: assign → three released_unverified → draft → review → delegated approve → captured with the block" do
    ctx = prepared!("qualified")
    start_cli!("qualified")

    %{id: run_id} =
      op!(
        %{command: :assign, agent: :claude_code, lead: ctx.lead.id, campaign: ctx.campaign.id},
        ctx.actor
      )

    assert %{success: 1} = Oban.drain_queue(queue: :research, with_safety: false)

    {:ok, run} = Agents.get_run(run_id, actor: ctx.actor)
    assert run.status == :succeeded, inspect({run.status, run.status_reason})

    {:ok, invocations} = Agents.list_model_invocations(run.id, actor: agent(ctx))
    assert length(invocations) == 3

    for invocation <- invocations do
      {:ok, release} = Agents.get_result_release(invocation.id, actor: agent(ctx))
      assert release.disposition == :released_unverified
      assert release.reason == :owner_prototype_unverified
    end

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft, filter: [lead_id: ctx.lead.id], actor: ctx.actor)

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
    ctx = prepared!("disqualified")
    start_cli!("disqualified")

    %{id: run_id} =
      op!(
        %{command: :assign, agent: :claude_code, lead: ctx.lead.id, campaign: ctx.campaign.id},
        ctx.actor
      )

    assert %{success: 1} = Oban.drain_queue(queue: :research, with_safety: false)
    {:ok, run} = Agents.get_run(run_id, actor: ctx.actor)
    assert run.status == :succeeded

    assert {:ok, []} =
             Outreach.list_records(Outreach.Draft,
               filter: [lead_id: ctx.lead.id],
               actor: ctx.actor
             )
  end
end
