defmodule SdrAgentWeb.OwnerCitedDraftTest do
  @moduledoc """
  T3 (owner intake; Codex 321e0207): the positive end-to-end control for
  the owner-supplied evidence labels. A prospect the hosted owner saves
  goes through the real prototype research path (op assign, ClaudeCLI on
  the hermetic journey CLI, `read_lead_sources/4`), so its accepted claims
  sit on `:owner_intake` / `:unverified` artifacts and its draft cites
  them. The draft page shows the owner-supplied banner and the citation
  label, and the review queue marks the row.

  Synthetic `.test` data only; no real model, network or outreach.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import SdrAgent.PrototypeOutreachFixtures, only: [enter_window!: 1, exclusive_root!: 1]

  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Outreach

  @endpoint SdrAgentWeb.Endpoint
  @op Mix.Tasks.Sdr.Prototype.Op
  @cli Path.expand("../../support/d237_journey_cli.exs", __DIR__)
  @site_excerpt "Acme Intake builds warehouse robots for regional distributors."
  @team_excerpt "Avery Intake leads operations at Acme Intake."

  defp start_cli!(variant) do
    SdrAgent.OutreachFixtures.put_env!(:model_provider, ClaudeCLI)
    test_pid = self()

    admit = fn invocation_id, profile, opts ->
      :ok = SdrAgent.SDR.SeamCallers.adopt(%{sdr_seam_callers: [test_pid]})
      Agents.admit_launch(invocation_id, profile, opts)
    end

    start_supervised!(
      {ClaudeCLI,
       [
         name: ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         test_launcher: true,
         launch_admission: admit,
         command_args: [@cli, variant]
       ]}
    )
  end

  defp params do
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
    }
  end

  defp op!(parsed, actor) do
    result = call(@op, :execute, [parsed, actor])
    assert match?({:ok, _}, result), "op #{parsed.command}: #{inspect(result)}"
    {:ok, value} = result
    value
  end

  setup do
    ctx = H.activated!()
    # A human admin (arranged outside prototype runtime) edits the draft
    # elsewhere in the frozen-revision test.
    admin = SdrAgent.AuditCase.human(:admin, ctx.fx.tenant)
    enrolled = H.enrol!(ctx)
    owner = H.consume!(enrolled.enrollment_token)
    :ok = enter_window!(ctx.fx)
    actor = ctx.fx.actor

    {:ok, %{campaign_id: campaign_id}} =
      call(SdrAgent.Prototype.Seed, :run, [SdrAgent.DossierFixtures.seed_read(), actor])

    root = exclusive_root!("owner-cited-worksheet")
    worksheet = root |> SdrAgent.OwnerAllowanceFixtures.worksheet() |> Jason.encode!()
    path = Path.join(root, "worksheet.json")
    File.write!(path, worksheet)
    File.chmod!(path, 0o600)
    sha = Base.encode16(:crypto.hash(:sha256, worksheet), case: :lower)

    {:ok, _grant} =
      Agents.provision_prototype_grant(%{worksheet: worksheet, worksheet_sha256: sha},
        actor: actor,
        evidence_root: root
      )

    {:ok, preview} = SdrAgent.Prototype.OwnerIntake.preview(params(), owner)
    {:ok, :created, ids} = SdrAgent.Prototype.OwnerIntake.commit(params(), preview, owner)

    Map.merge(ctx, %{
      owner: owner,
      admin: admin,
      enrolled: enrolled,
      actor: actor,
      ids: ids,
      campaign_id: campaign_id,
      token: owner.__metadata__.token
    })
  end

  # Research the owner lead through the real path and return its draft.
  defp researched!(ctx) do
    start_cli!("qualified")

    %{id: run_id} =
      op!(
        %{
          command: :assign,
          agent: :claude_code,
          lead: ctx.ids.lead_id,
          campaign: ctx.campaign_id
        },
        ctx.actor
      )

    assert %{success: 1} = Oban.drain_queue(queue: :research, with_safety: false)
    {:ok, run} = Agents.get_run(run_id, actor: ctx.actor)
    assert run.status == :succeeded, inspect({run.status, run.status_reason})

    {:ok, claims} =
      SdrAgent.Research.EvidenceClaim
      |> Ash.Query.filter(lead_id == ^ctx.ids.lead_id and quality == :accepted)
      |> Ash.read(H.kernel(ctx))

    assert claims != [], "no accepted claim on the owner lead"

    for claim <- claims do
      {:ok, artifact} =
        Ash.get(SdrAgent.Research.ResearchArtifact, claim.research_artifact_id, H.kernel(ctx))

      assert {artifact.provider, artifact.trust_level} == {:owner_intake, :unverified}
    end

    {:ok, [draft]} =
      Outreach.list_records(Outreach.Draft,
        filter: [lead_id: ctx.ids.lead_id],
        actor: ctx.actor
      )

    draft
  end

  defp owner_conn!(ctx) do
    H.enter!(ctx)
    init_test_session(build_conn(), %{"user_token" => ctx.token})
  end

  test "an owner lead's draft cites owner_intake evidence and both pages mark it", ctx do
    draft = researched!(ctx)
    conn = owner_conn!(ctx)

    {:ok, view, _html} = live(conn, "/drafts/#{draft.id}")
    assert has_element?(view, "#owner-supplied-evidence")

    {:ok, [citation | _]} =
      Outreach.list_records(Outreach.RevisionCitation,
        filter: [draft_revision_id: draft.current_revision_id],
        actor: ctx.actor
      )

    view |> element("#revision-body [data-citation-id='#{citation.id}']") |> render_click()
    assert has_element?(view, "#citation-panel [data-provenance='owner_intake']")

    {:ok, queue, _html} = live(conn, "/review")
    assert has_element?(queue, "#review-queue-#{draft.id}[data-owner-supplied='true']")
  end

  # Codex m_1793686926846936125_724f1216 / follow-up: SequenceStep has no
  # hosted-owner review_read; the step is display-only metadata, so the
  # page shows it as unavailable instead of withholding the whole draft.
  test "the hosted owner's draft page shows the step as unavailable, not withheld", ctx do
    draft = researched!(ctx)
    {:ok, view, _html} = live(owner_conn!(ctx), "/drafts/#{draft.id}")

    refute has_element?(view, "#withheld"), "the draft page was withheld from the owner"
    assert has_element?(view, "#draft-step-unavailable", "step unavailable")
    assert has_element?(view, "#revision-body")
    # Review verdicts stay reviewer-only: the hosted owner gets no approve form.
    refute has_element?(view, "#approve-form")
  end

  # Codex finding: the owner-supplied banner is frozen with the shown
  # revision and its citations; a newer uncited revision must not clear it
  # until the reviewer asks for the latest.
  test "a newer uncited revision keeps the banner on the shown revision until show_latest",
       ctx do
    draft = researched!(ctx)
    {:ok, view, _html} = live(owner_conn!(ctx), "/drafts/#{draft.id}")
    assert has_element?(view, "#owner-supplied-evidence")

    :ok = SdrAgent.PrototypeFixtures.leave_runtime()

    {:ok, _edited} =
      Outreach.edit_draft(
        draft,
        %{subject: "Edited elsewhere", body_text: "A plain note with no cited claims."},
        actor: ctx.admin
      )

    :ok = enter_window!(ctx.fx)
    H.enter!(ctx)
    send(view.pid, :live_refresh)

    assert has_element?(view, "#newer-revision")

    assert has_element?(view, "#owner-supplied-evidence"),
           "a newer revision cleared the banner of the revision on screen"

    view |> element("#show-latest-revision") |> render_click()
    refute has_element?(view, "#newer-revision")

    refute has_element?(view, "#owner-supplied-evidence"),
           "the latest revision cites no owner evidence but still shows the banner"
  end

  # Codex m_1793687196231506833_cd48f2a2: no policy widening; the boundary
  # around the unavailable step stays as it was.
  describe "boundary around the unavailable step" do
    test "the fresh owner still cannot read the step through the Sales API", ctx do
      draft = researched!(ctx)
      H.enter!(ctx)

      refute match?(
               {:ok, _},
               SdrAgent.Sales.fetch(SdrAgent.Sales.SequenceStep, draft.sequence_step_id,
                 actor: ctx.owner
               )
             ),
             "the hosted owner read a SequenceStep"
    end

    test "a foreign-tenant owner identity cannot read the draft", ctx do
      draft = researched!(ctx)
      H.enter!(ctx)
      forged = %{ctx.owner | tenant_id: Ecto.UUID.generate()}

      refute match?({:ok, _}, Outreach.fetch(Outreach.Draft, draft.id, actor: forged)),
             "a foreign-tenant owner identity read the draft"
    end

    test "a disabled owner cannot read the draft or open its page", ctx do
      draft = researched!(ctx)
      conn = owner_conn!(ctx)

      :ok = SdrAgent.PrototypeFixtures.leave_runtime()
      :ok = SdrAgent.PrototypeFixtures.put_live_identity(ctx.destination)
      assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id)
      H.enter!(ctx)

      refute match?({:ok, _}, Outreach.fetch(Outreach.Draft, draft.id, actor: ctx.owner)),
             "a disabled owner read the draft"

      case live(conn, "/drafts/#{draft.id}") do
        {:ok, view, _html} ->
          refute has_element?(view, "#revision-body"), "a disabled owner saw the draft body"

        {:error, {kind, _}} when kind in [:redirect, :live_redirect] ->
          :ok
      end
    end
  end
end
