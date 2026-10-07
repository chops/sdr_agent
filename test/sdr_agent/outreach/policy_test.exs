defmodule SdrAgent.Outreach.PolicyTest do
  @moduledoc """
  Auditor (AUR) contract and denial audit for the S8a Outreach actions:
  every Outreach mutation attempted by an auditor is denied with exactly one
  committed `authz.denied`, and the auditor reads every Outreach record a
  timeline links to.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Outreach

  test "every S8a Outreach mutation is denied for AUR and audited once", ctx do
    %{draft: draft, revision: rev} = drafted!(ctx)
    approval = approve!(ctx, draft, operator!(ctx, :reviewer))
    aur = operator!(ctx, :auditor)

    attempts = [
      {"propose_draft", fn -> Outreach.propose_draft(%{lead_id: draft.lead_id}, actor: aur) end},
      {"edit_draft",
       fn -> Outreach.edit_draft(draft, %{subject: "x", body_text: "y"}, actor: aur) end},
      {"approve", fn -> Outreach.approve(draft, approval_input(rev), actor: aur) end},
      {"reject",
       fn -> Outreach.reject(draft, Map.put(approval_input(rev), :reason, "x"), actor: aur) end},
      {"revoke", fn -> Outreach.revoke(approval, actor: aur) end},
      {"suppress", fn -> Outreach.suppress(%{scope: :domain, value: "x.test"}, actor: aur) end},
      {"seed_suppression",
       fn -> Outreach.seed_suppression(%{scope: :domain, value: "x.test"}, actor: aur) end}
    ]

    before = length(events(ctx.tenant))
    denied = length(events_of_type(ctx.tenant, "authz.denied"))

    for {{label, attempt}, index} <- Enum.with_index(attempts, 1) do
      assert {:error, %Ash.Error.Forbidden{}} = attempt.(), label
      assert length(events_of_type(ctx.tenant, "authz.denied")) == denied + index, label
    end

    assert length(events(ctx.tenant)) == before + length(attempts)
  end

  test "AUR reads the Outreach records a timeline links to", ctx do
    %{draft: draft} = drafted!(ctx)
    approve!(ctx, draft, operator!(ctx, :reviewer))
    aur = operator!(ctx, :auditor)

    for resource <- [
          Outreach.Draft,
          Outreach.DraftRevision,
          Outreach.RevisionCitation,
          Outreach.Approval,
          Outreach.Suppression
        ] do
      assert {:ok, [_ | _]} = Outreach.list_records(resource, actor: aur), inspect(resource)
    end
  end

  test "the review queue lists drafts awaiting review, oldest first", ctx do
    %{draft: first} = drafted!(ctx)
    %{draft: second} = drafted!(ctx, "02")
    reviewer = operator!(ctx, :reviewer)

    assert {:ok, queue} = Outreach.list_review_queue(actor: reviewer)
    assert Enum.map(queue, & &1.id) == [first.id, second.id]

    approve!(ctx, first, reviewer)
    assert {:ok, [only]} = Outreach.list_review_queue(actor: reviewer)
    assert only.id == second.id
    assert {:ok, []} = Outreach.list_review_queue(actor: nil)
  end
end
