defmodule SdrAgent.Inbox.ReviewerReleaseTest do
  @moduledoc """
  Named C1-02 qualification (#152): reviewer Home cannot read release
  metadata under the existing policy. Even a released gen-2 Draft is
  withheld, not silently excluded from a ready total. The draft-page source
  policy is unchanged. No real provider is launched by this fixture.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures, only: [drafted!: 1, operator!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Outreach

  test "admin sees a released gen-2 draft; reviewer Home fails closed with unavailable total",
       ctx do
    %{draft: draft, revision: revision} = drafted!(ctx)
    grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    assert {:ok, %{allocations: [allocation]}} = Agents.get_grant(grant.id, actor: ctx.admin)
    provenance = ClaudeCLI.provenance()

    # API-created synthetic Draft; sandbox-local legacy generation tagging,
    # as in IntegrityTest. Its actual release is then decided via Agents.
    tamper!(
      "UPDATE model_invocations SET provider = 'claude_cli', ledger_generation = 2, profile_id = 'claude_cli_opus', provider_version = $1, model_id = $2, grant_id = $3, allocation_id = $4 WHERE id = $5",
      [
        provenance.provider_version,
        provenance.model_id,
        Ecto.UUID.dump!(grant.id),
        Ecto.UUID.dump!(allocation.id),
        Ecto.UUID.dump!(revision.model_invocation_id)
      ]
    )

    assert {:ok, invocation} =
             Agents.get_model_invocation(revision.model_invocation_id, actor: ctx.agent)

    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, Agents.Witness, previous) end)
    rec = system_actor(:reconciler, ctx.tenant)
    link = AgentsFixtures.reconciled_link!(invocation, rec)

    assert {:ok, release} =
             Agents.decide_result_release(
               %{
                 model_invocation_id: invocation.id,
                 disposition: :released,
                 reason: :reconciled,
                 wire_witness_link_id: link.id
               },
               actor: ctx.agent
             )

    assert release.disposition == :released
    reviewer = operator!(ctx, :reviewer)
    assert {:ok, [source]} = Outreach.list_review_queue(actor: reviewer)
    assert source.id == draft.id

    assert {:ok, admin} = refresh(session!(ctx.admin))
    assert item!(admin, draft)
    assert total!(admin, :pending_email_drafts) == 1
    assert admin.completeness == :complete

    assert {:ok, limited} = refresh(session!(reviewer))
    assert limited.items == []
    assert limited.completeness == :partial

    assert %{status: :unavailable, value: nil, reason: :withheld} =
             limited.totals.pending_email_drafts

    assert Enum.any?(limited.errors, &(&1.source == :draft_list and &1.reason == :withheld))
    refute inspect(limited) =~ revision.subject
  end
end
