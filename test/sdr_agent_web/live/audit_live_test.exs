defmodule SdrAgentWeb.AuditLiveTest do
  @moduledoc """
  S10b auditor views (ADM, AUR): the audit timeline filtered by lead, run or
  draft (a `timeline_view` AuditAccess recorded before it is served), Tempo
  trace links from `trace_id` (configurable Grafana URL), chain verification
  (`Audit.verify_chain/1`), the payload viewer (audited `read_content`, fail
  closed) and the export list. Reviewers are sent back to the dashboard.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Research

  setup ctx do
    one = assign!(ctx, "01")
    two = assign!(ctx, "02")
    Map.merge(ctx, %{one: one, two: two})
  end

  describe "timeline" do
    test "an auditor filters the timeline by lead; the view is recorded", %{conn: conn} = ctx do
      auditor = user!(ctx, :auditor)
      lead = ctx.one.lead
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/audit?lead=#{lead.id}")

      [assigned | _] =
        ctx.tenant
        |> events_of_type("sales.lead.assigned")
        |> Enum.filter(&(&1.subject_id == lead.id))

      [other | _] =
        ctx.tenant
        |> events_of_type("sales.lead.assigned")
        |> Enum.filter(&(&1.subject_id == ctx.two.lead.id))

      assert has_element?(view, "#events-#{assigned.id}")
      refute has_element?(view, "#events-#{other.id}")

      assert [%{access_kind: :timeline_view, target_ref: ref}] = accesses_of(ctx, auditor)
      assert ref =~ lead.id
    end

    test "filters by run", %{conn: conn} = ctx do
      run = ctx.one.run
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/audit?run=#{run.id}")

      run_events = Enum.filter(events(ctx.tenant), &(&1.agent_run_id == run.id))
      assert run_events != []
      for event <- run_events, do: assert(has_element?(view, "#events-#{event.id}"))

      other = Enum.find(events(ctx.tenant), &(&1.agent_run_id == ctx.two.run.id))
      refute has_element?(view, "#events-#{other.id}")
    end

    test "events link to their Tempo trace through the configured Grafana URL",
         %{conn: conn} = ctx do
      put_env!(SdrAgentWeb.Trace, grafana_url: "http://grafana.example.test")
      event = Enum.find(events(ctx.tenant), &(&1.agent_run_id == ctx.one.run.id))

      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/audit?run=#{ctx.one.run.id}")

      assert has_element?(
               view,
               "#events-#{event.id} a[data-trace-id='#{event.trace_id}'][href^='http://grafana.example.test/explore']"
             )
    end

    test "reviewers cannot open the audit views", %{conn: conn} do
      for path <- ["/audit", "/audit/exports"] do
        assert {:error, {:redirect, %{to: "/"}}} = conn |> sign_in(:reviewer) |> live(path)
      end
    end

    test "the audit link is shown to admins and auditors only", %{conn: conn} do
      for role <- [:admin, :auditor] do
        {:ok, view, _html} = conn |> sign_in(role) |> live(~p"/")
        assert has_element?(view, "#nav-audit[href='/audit']")
      end

      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/")
      refute has_element?(view, "#nav-audit")
    end
  end

  describe "chain verification" do
    test "an auditor verifies the chain; the verification is recorded", %{conn: conn} = ctx do
      auditor = user!(ctx, :auditor)
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/audit")

      view |> element("#verify-chain") |> render_click()

      assert has_element?(view, "#chain-result[data-valid='true']")
      assert has_element?(view, "#chain-result [data-events-checked]")
      assert Enum.any?(accesses_of(ctx, auditor), &(&1.access_kind == :chain_verify))
    end
  end

  describe "payload viewer" do
    setup ctx do
      %{success: 2} = drain!()

      {:ok, [artifact | _]} =
        Research.list_records(Research.ResearchArtifact,
          filter: [lead_id: ctx.one.lead.id],
          actor: ctx.admin
        )

      Map.put(ctx, :artifact, artifact)
    end

    test "an auditor reads a payload through the audited read", %{conn: conn} = ctx do
      auditor = user!(ctx, :auditor)
      sha = hex(ctx.artifact.content_sha256)
      {:ok, content} = SdrAgent.Audit.read_content(ctx.artifact.content_sha256, actor: ctx.admin)

      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/audit/payloads/#{sha}")

      assert has_element?(view, "#payload-content", String.slice(content, 0, 40))
      assert has_element?(view, "#payload-sha", sha)
      assert [%{access_kind: :payload_view, target_ref: ^sha}] = accesses_of(ctx, auditor)
    end

    test "an unknown payload serves nothing", %{conn: conn} do
      missing = String.duplicate("ab", 32)
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/audit/payloads/#{missing}")

      refute has_element?(view, "#payload-content")
      assert has_element?(view, "#withheld")
    end
  end

  describe "exports" do
    test "lists audit exports with the CLI that creates them", %{conn: conn} = ctx do
      {:ok, export} =
        SdrAgent.Audit.AuditExport
        |> Ash.Changeset.for_create(
          :request,
          %{
            requested_by_type: :auditor_cli,
            requested_by_id: "audit-live-test",
            scope: :lead,
            scope_ref: ctx.one.lead.id
          },
          actor: ctx.aud
        )
        |> Ash.create()

      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/audit/exports")

      assert has_element?(view, "#exports-#{export.id} [data-status='building']")
      assert has_element?(view, "#export-command", "mix sdr.audit.export")
    end
  end
end
