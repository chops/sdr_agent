defmodule SdrAgentWeb.DashboardLiveTest do
  @moduledoc """
  S10a Dashboard: pipeline counts, the drafts awaiting review and the
  operator-attention list (`Operations.list_attention/1`); an auditor's view
  is recorded as an AuditAccess naming what was shown.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Operations

  test "shows lead, review and delivery counts", %{conn: conn} = ctx do
    drafted!(ctx)

    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/")

    assert has_element?(view, "#stat-leads [data-value]", "10")
    assert has_element?(view, "#stat-pending-review [data-value]", "1")
    assert has_element?(view, "#stat-attention [data-value]", "0")
    assert has_element?(view, "#dashboard-review-queue a[href^='/drafts/']")
  end

  test "lists open attention failures newest first", %{conn: conn} = ctx do
    lead = fixture_lead!(ctx, "02")

    {:ok, failure} =
      Operations.open_failure(
        %{
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: lead.id,
          class: :provider_error,
          severity: :critical,
          message: "fixture provider unavailable"
        },
        actor: ctx.agent
      )

    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/")

    assert has_element?(view, "#attention-#{failure.id}", "fixture provider unavailable")
    assert has_element?(view, "#attention-#{failure.id} [data-severity='critical']")
    assert has_element?(view, "#attention-#{failure.id} a[href='/leads/#{lead.id}']")
    assert has_element?(view, "#stat-attention [data-value]", "1")
  end

  test "an auditor's dashboard view is recorded before it is served", %{conn: conn} = ctx do
    auditor = user!(ctx, :auditor)
    before = length(accesses_of(ctx, auditor))

    {:ok, view, _html} = conn |> sign_in(:auditor) |> live(~p"/")

    assert has_element?(view, "#stat-leads")
    accesses = accesses_of(ctx, auditor)
    assert length(accesses) == before + 1
    assert %{access_kind: :record_view, target_resource: "Dashboard"} = List.last(accesses)
  end
end
