defmodule SdrAgent.Inbox.AggregatePrivacyTest do
  @moduledoc "C1 aggregate expressions inspect metadata only, never R0 protected output fields."
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures, only: [drafted!: 1, operator!: 2]

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.Inbox

  test "actual invalid/withheld expression references exclude protected ModelInvocation output",
       ctx do
    assert function_exported?(Inbox, :count_guards, 1), "source metadata guard inspection missing"

    for actor <- [ctx.admin, operator!(ctx, :reviewer), operator!(ctx, :auditor)] do
      guards = apply(Inbox, :count_guards, [actor])
      assert Enum.sort(Map.keys(guards)) == [:invalid, :withheld]

      for {kind, expression} <- guards do
        assert {:ok, filter} = Ash.Filter.parse(Draft, expression)
        refs = Ash.Filter.list_refs(filter)
        assert refs != []
        names = Enum.map(refs, &Ash.Query.Ref.name/1)
        # Reviewer withholding deliberately has no release subquery, hence
        # no tenant ref in that expression. Check each actual metadata shape
        # rather than requiring an unrelated ref; protection stays universal.
        required =
          if kind == :invalid,
            do: [:tenant_id, :model_invocation_id],
            else: [:email, :ledger_generation, :provider]

        assert Enum.all?(required, &(&1 in names))
        assert Enum.any?(refs, &(&1.resource == ModelInvocation))
        refute Enum.any?(names, &(&1 in ModelInvocation.output_fields()))
      end
    end
  end

  test "differing unreleased gen-2 output never changes a withheld count into an output-derived value",
       ctx do
    %{revision: revision} = drafted!(ctx)
    grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    assert {:ok, %{allocations: [allocation]}} = Agents.get_grant(grant.id, actor: ctx.admin)

    tamper!(
      "UPDATE model_invocations SET provider='claude_cli', ledger_generation=2, profile_id='claude_cli_opus', grant_id=$1, allocation_id=$2 WHERE id=$3",
      [
        Ecto.UUID.dump!(grant.id),
        Ecto.UUID.dump!(allocation.id),
        Ecto.UUID.dump!(revision.model_invocation_id)
      ]
    )

    for output <- [%{"secret" => "alpha"}, %{"secret" => "omega", "n" => 9000}, nil] do
      tamper!("UPDATE model_invocations SET parsed_output=$1 WHERE id=$2", [
        output,
        Ecto.UUID.dump!(revision.model_invocation_id)
      ])

      assert {:error, :withheld} = Outreach.count_inbox_drafts(actor: ctx.admin)
    end
  end
end
