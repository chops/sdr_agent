defmodule SdrAgentWeb.LiveRefreshTest do
  @moduledoc """
  S13 live refresh (ADR-0012): console views re-read through the domain APIs
  when a committed audit event of their tenant arrives. The sandbox never
  commits, so these tests deliver the relay's broadcast themselves
  (`SdrAgent.LiveEvents.broadcast/1`, exactly what `SdrAgent.LiveEvents.Relay`
  sends after a commit); `SdrAgent.LiveEventsTest` proves the commit-time
  delivery on a real connection.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.LiveEvents
  alias SdrAgent.Outreach

  defp committed(ctx, category \\ "domain_change") do
    LiveEvents.broadcast(%{
      tenant_id: ctx.tenant.id,
      sequence: 0,
      event_type: "test.committed",
      category: category,
      subject_resource: nil,
      subject_id: nil,
      agent_run_id: nil
    })
  end

  test "the dashboard counts a draft the agent produced after the page loaded",
       %{conn: conn} = ctx do
    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/")
    assert has_element?(view, "#stat-pending-review [data-value]", "0")

    drafted!(ctx)
    committed(ctx)

    assert has_element?(view, "#stat-pending-review [data-value]", "1")
  end

  test "the review queue shows a new draft without a reload", %{conn: conn} = ctx do
    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/review")
    assert has_element?(view, "#review-count", "0")

    %{draft: draft, revision: revision} = drafted!(ctx)
    committed(ctx)

    assert has_element?(view, "#review-queue-#{draft.id}", revision.subject)
    assert has_element?(view, "#review-count", "1")
  end

  test "lead detail follows the agent: its run and draft appear", %{conn: conn} = ctx do
    lead = fixture_lead!(ctx, "01")
    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/leads/#{lead.id}")
    refute has_element?(view, "#lead-drafts a[href^='/drafts/']")

    %{draft: draft, run: run} = drafted!(ctx)
    committed(ctx)

    assert has_element?(view, "#lead-runs a[href='/runs/#{run.id}']")
    assert has_element?(view, "#lead-drafts a[href='/drafts/#{draft.id}']")
  end

  describe "draft page" do
    setup ctx, do: Map.merge(ctx, drafted!(ctx))

    test "shows another reviewer's approval of the displayed revision", %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/drafts/#{ctx.draft.id}")
      assert has_element?(view, "#draft-header [data-status='pending_review']")

      approve!(ctx, ctx.draft, ctx.admin)
      committed(ctx)

      assert has_element?(view, "#draft-header [data-status='queued']")
      refute has_element?(view, "#newer-revision")
    end

    test "never swaps a newer revision under the reviewer; a verdict stays stale-checked",
         %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/drafts/#{ctx.draft.id}")
      edit_elsewhere!(ctx)

      assert has_element?(view, "#newer-revision")
      assert has_element?(view, "#binding-revision", "#1")
      assert has_element?(view, "#revision-subject", ctx.revision.subject)

      view |> form("#approve-form") |> render_submit()

      assert has_element?(view, "#review-error", "stale review")
      assert approvals!(ctx, ctx.draft) == []
      assert has_element?(view, "#binding-revision", "#2")
      refute has_element?(view, "#newer-revision")
    end

    test "with the revision frozen, later lifecycle changes still show", %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/drafts/#{ctx.draft.id}")
      edit_elsewhere!(ctx)
      assert has_element?(view, "#newer-revision")

      latest = draft!(ctx, ctx.draft)
      approve!(ctx, latest, ctx.admin)
      committed(ctx)

      assert has_element?(view, "#draft-header [data-status='queued']")
      assert has_element?(view, "#newer-revision")
      assert has_element?(view, "#binding-revision", "#1")
      assert has_element?(view, "#revision-subject", ctx.revision.subject)
      assert [%{status: :granted}] = approvals!(ctx, ctx.draft)
      assert has_element?(view, "[id^='approval-'] [data-status='granted']")
    end

    test "the notice shows the latest revision on request", %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/drafts/#{ctx.draft.id}")
      edit_elsewhere!(ctx)

      view |> element("#show-latest-revision") |> render_click()

      refute has_element?(view, "#newer-revision")
      assert has_element?(view, "#binding-revision", "#2")
      assert has_element?(view, "#revision-subject", "Changed elsewhere")
    end
  end

  defp edit_elsewhere!(ctx) do
    elsewhere = %{subject: "Changed elsewhere", body_text: ctx.revision.body_text}
    {:ok, _edited} = Outreach.edit_draft(ctx.draft, elsewhere, actor: ctx.admin)
    committed(ctx)
  end

  describe "auditor views" do
    test "a refresh is recorded like any view; access and auth events cause none",
         %{conn: conn} = ctx do
      auditor = user!(ctx, :auditor)
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/")
      assert [_load] = accesses_of(ctx, auditor)

      committed(ctx, "access")
      committed(ctx, "auth")
      _ = render(view)
      assert [_load] = accesses_of(ctx, auditor)

      committed(ctx)
      _ = render(view)
      assert [_load, _refresh] = accesses_of(ctx, auditor)
    end

    test "a burst of events is coalesced into one reload", %{conn: conn} = ctx do
      previous = Application.get_env(:sdr_agent, SdrAgentWeb.LiveRefresh)
      Application.put_env(:sdr_agent, SdrAgentWeb.LiveRefresh, debounce_ms: 50)
      on_exit(fn -> Application.put_env(:sdr_agent, SdrAgentWeb.LiveRefresh, previous) end)

      auditor = user!(ctx, :auditor)
      {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/")

      for _ <- 1..5, do: committed(ctx)
      Process.sleep(200)
      _ = render(view)

      assert [_load, _one_refresh] = accesses_of(ctx, auditor)
    end
  end

  test "an event of another tenant reaches no view of this one", %{conn: conn} = ctx do
    auditor = user!(ctx, :auditor)
    {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/")

    committed(%{tenant: %{id: Ecto.UUID.generate()}})
    _ = render(view)

    assert [_load] = accesses_of(ctx, auditor)
  end
end
