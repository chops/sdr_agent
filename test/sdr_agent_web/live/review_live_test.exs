defmodule SdrAgentWeb.ReviewLiveTest do
  @moduledoc """
  S10a Review queue: drafts awaiting review (`Outreach.list_review_queue/1`),
  oldest first, with recipient, company and the current revision's subject;
  decided drafts drop out of the queue.
  """
  use SdrAgentWeb.OperatorCase, async: false

  test "lists drafts pending review with recipient and subject", %{conn: conn} = ctx do
    %{draft: draft, revision: revision, lead: lead} = drafted!(ctx)
    contact = contact!(ctx, lead)

    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/review")

    assert has_element?(view, "#review-queue-#{draft.id} a[href='/drafts/#{draft.id}']")
    assert has_element?(view, "#review-queue-#{draft.id}", revision.subject)
    assert has_element?(view, "#review-queue-#{draft.id}", to_string(contact.email))
    assert has_element?(view, "#review-count", "1")
  end

  test "an approved draft leaves the queue and appears under recent decisions",
       %{conn: conn} = ctx do
    %{draft: draft} = approved!(ctx)

    {:ok, view, _html} = conn |> sign_in(:reviewer) |> live(~p"/review")

    refute has_element?(view, "#review-queue-#{draft.id}")
    assert has_element?(view, "#recent-drafts-#{draft.id} [data-status='queued']")
    assert has_element?(view, "#review-count", "0")
  end

  test "an auditor's queue view is recorded", %{conn: conn} = ctx do
    %{draft: draft} = drafted!(ctx)
    auditor = user!(ctx, :auditor)

    {:ok, _view, _html} = conn |> sign_in(:auditor) |> live(~p"/review")

    assert [%{target_resource: "SdrAgent.Outreach.Draft", target_ref: ref}] =
             accesses_of(ctx, auditor)

    assert ref =~ draft.id
  end
end
