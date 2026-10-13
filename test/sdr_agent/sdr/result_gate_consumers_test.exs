defmodule SdrAgent.SDR.ResultGateConsumersTest do
  @moduledoc """
  R0-07 slice A read gate at the business consumers of a model output
  (entity PASS at 1da747a; ADR-0005 R0 amendment item 4, "No bypass"): the
  OutreachProposal replay (`SDR.proposal/2`) and the agent ReplyAssessment
  (`Outreach.Changes.AssessmentRules`) refuse a generation-2 ClaudeCLI
  output that has no `:released` release with `:result_not_released`.

  The flows run on the Fake (ungated, unchanged); the cited invocation is
  then rewritten behind the application's back into a generation-2
  ClaudeCLI row with no release, as a row completed before its gate step
  (or after a crash) would be.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Errors.ResultNotReleased
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Outreach
  alias SdrAgent.SDR

  defp gate!(ctx, invocation_id) do
    grant = AgentsFixtures.grant!(ctx.tenant)
    [allocation | _] = grant.allocations

    tamper!(
      "UPDATE model_invocations SET provider = 'claude_cli', ledger_generation = 2, " <>
        "profile_id = 'claude_cli_opus', grant_id = $2, allocation_id = $3 WHERE id = $1",
      [Ecto.UUID.dump!(invocation_id), Ecto.UUID.dump!(grant.id), Ecto.UUID.dump!(allocation.id)]
    )
  end

  test "SDR.proposal/2 refuses an unreleased output with :result_not_released", ctx do
    %{run: run} = assign!(ctx, "01")
    assert %{success: 1} = drain!()
    assert {:ok, proposal} = SDR.proposal(run.id, actor: ctx.agent)

    gate!(ctx, proposal.model_invocation_id)
    assert {:error, :result_not_released} = SDR.proposal(run.id, actor: ctx.agent)
  end

  test "an agent ReplyAssessment refuses an unreleased output with :result_not_released", ctx do
    approved = approved!(ctx, "01")
    assert %{success: 1} = deliver!()
    delivery = outreach!(ctx, approved.delivery)
    reply = reply_body(delivery, "Thanks, this sounds interesting. Could we talk next week?")
    assert {:ok, %{status: :accepted}} = ingest!("reply", reply)
    assert %{success: 1} = process!()
    assert %{success: 1} = Oban.drain_queue(queue: :agent, with_safety: false)

    {:ok, [assessment]} = Outreach.list_records(Outreach.ReplyAssessment, actor: ctx.admin)

    attrs =
      assessment
      |> Map.take([
        :reply_id,
        :classification,
        :sentiment,
        :intent,
        :suggested_next_action,
        :confidence,
        :reason,
        :agent_run_id,
        :decision_id,
        :model_invocation_id
      ])
      |> Map.put(:supersedes_id, assessment.id)

    # Ungated (Fake): the same assessment may be re-recorded as a successor.
    assert {:ok, successor} = Outreach.record_assessment(attrs, actor: ctx.agent)

    gate!(ctx, assessment.model_invocation_id)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Outreach.record_assessment(%{attrs | supersedes_id: successor.id}, actor: ctx.agent)

    assert Enum.any?(errors, &match?(%ResultNotReleased{}, &1)), inspect(errors)

    assert {:error, :result_not_released} =
             Agents.released_output(assessment.model_invocation_id, actor: ctx.agent)
  end
end
