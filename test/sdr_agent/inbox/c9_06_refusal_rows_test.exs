defmodule SdrAgent.Inbox.C906RefusalRowsTest do
  @moduledoc """
  C9-06 (#46) part B3, CHARACTERIZATION (not RED): these tests pass on the
  merged code. A model-call reservation refusal made through the real
  admission path (`Agents.reserve_model_invocation/3`) opens a
  `budget_exhausted` Failure, and Home (`Inbox.refresh/2`, read with an
  admin's stored session token) shows it as one `operations_failures`
  `failure_attention` row bound to that exact Failure.

  Covered: an unavailable refusal (no eligible grant), an exhausted refusal
  (allocation cap), dedupe of a repeated refusal with a matching live
  count, and the row leaving Home after an admin resolves it. Out of scope:
  authorization and the blocked-retry metadata, which C1-02's own tests
  cover; the retry commands (C1-03) and the Home LiveView, which are not
  built yet. Synthetic data only.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Operations

  @run_resource "SdrAgent.Agents.AgentRun"
  @failure_resource "SdrAgent.Operations.Failure"

  setup do
    # R0-07 slice B: real reservations are judged only with a promoted tuple
    # and a trusted store, so the refusal is the grant's, not admission's.
    SdrAgent.AdmissionFixtures.admit_tuples!()
    :ok
  end

  defp reserve(%{run: run, agent: agent}, key) do
    Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs(key), actor: agent)
  end

  defp failure_rows(page), do: Enum.filter(page.items, &(&1.producer == :operations_failures))

  # The one Home row of a refusal: bound to the Failure the refusal receipt
  # names, which is the run's own budget Failure and the refused event's.
  defp assert_refusal_row(ctx, page, %Refused{} = refused, run, reason) do
    assert {:ok, failure} = Operations.get_failure(refused.failure_id, actor: ctx.admin)
    assert failure.class == :budget_exhausted
    assert failure.status == :open
    assert {failure.subject_resource, failure.subject_id} == {@run_resource, run.id}
    assert failure.message =~ "model call reservation refused: #{reason}"

    event =
      ctx.tenant
      |> events_of_type("model.reservation.refused")
      |> Enum.find(&(&1.id == refused.event_id))

    assert event.payload["failure_id"] == failure.id

    assert [row] = Enum.filter(page.items, &(&1.subject_ref.id == failure.id))
    assert row.producer == :operations_failures
    assert row.kind == :failure_attention
    assert row.subject_ref == %{resource: @failure_resource, id: failure.id}
    assert row.summary == String.slice(failure.message, 0, 240)

    assert %{target_ref: %{resource: @failure_resource, id: target}} =
             Enum.find(row.actions, &(&1.action_id == :inspect))

    assert target == failure.id
    row
  end

  test "an unavailable refusal (no eligible grant) is one Home row bound to its Failure", ctx do
    session = session!(ctx.admin)
    assert {:ok, before} = refresh(session)
    assert failure_rows(before) == []

    %{run: run} = refused_run = AgentsFixtures.running_run(ctx.tenant)

    assert {:error, %Refused{reason: :no_eligible_grant} = refused} =
             reserve(refused_run, "c906-unavailable")

    assert {:ok, page} = refresh(session)
    assert page.completeness == :complete
    assert_refusal_row(ctx, page, refused, run, "no_eligible_grant")
    assert [_] = failure_rows(page)
    assert total!(page, :live_failures) == 1
  end

  test "an exhausted refusal (allocation cap) is one Home row bound to its Failure", ctx do
    AgentsFixtures.grant!(
      ctx.tenant,
      %{total_attempts: 10, allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]},
      ctx.admin
    )

    %{run: run} = refused_run = AgentsFixtures.running_run(ctx.tenant)
    assert {:ok, _spent} = reserve(refused_run, "c906-spent")

    assert {:error, %Refused{reason: {:budget_exhausted, :allocation}} = refused} =
             reserve(refused_run, "c906-exhausted")

    session = session!(ctx.admin)
    assert {:ok, page} = refresh(session)
    assert page.completeness == :complete
    assert_refusal_row(ctx, page, refused, run, "allocation_exhausted")
    assert [_] = failure_rows(page)
    assert total!(page, :live_failures) == 1
  end

  test "both refusals show as two distinct rows, each bound to its own Failure", ctx do
    %{run: unavailable_run} = unavailable = AgentsFixtures.running_run(ctx.tenant)

    assert {:error, %Refused{reason: :no_eligible_grant} = no_grant} =
             reserve(unavailable, "c906-both-unavailable")

    AgentsFixtures.grant!(
      ctx.tenant,
      %{total_attempts: 10, allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]},
      ctx.admin
    )

    %{run: exhausted_run} = exhausted = AgentsFixtures.running_run(ctx.tenant)
    assert {:ok, _spent} = reserve(exhausted, "c906-both-spent")

    assert {:error, %Refused{reason: {:budget_exhausted, :allocation}} = capped} =
             reserve(exhausted, "c906-both-exhausted")

    refute no_grant.failure_id == capped.failure_id

    assert {:ok, page} = refresh(session!(ctx.admin))
    a = assert_refusal_row(ctx, page, no_grant, unavailable_run, "no_eligible_grant")
    b = assert_refusal_row(ctx, page, capped, exhausted_run, "allocation_exhausted")
    refute a.id == b.id

    assert Enum.sort(Enum.map(failure_rows(page), & &1.subject_ref.id)) ==
             Enum.sort([no_grant.failure_id, capped.failure_id])

    assert total!(page, :live_failures) == 2
  end

  test "a repeated refusal adds no second row, and the live count matches the rows", ctx do
    %{run: run} = refused_run = AgentsFixtures.running_run(ctx.tenant)
    session = session!(ctx.admin)

    assert {:error, %Refused{reason: :no_eligible_grant} = first} =
             reserve(refused_run, "c906-again-1")

    assert {:ok, once} = refresh(session)

    assert {:error, %Refused{reason: :no_eligible_grant} = second} =
             reserve(refused_run, "c906-again-2")

    # The second refusal is its own event, deduplicated onto the first Failure.
    refute second.event_id == first.event_id
    assert second.failure_id == first.failure_id

    assert {:ok, twice} = refresh(session)
    row = assert_refusal_row(ctx, twice, second, run, "no_eligible_grant")
    assert row.id == item!(once, %{id: first.failure_id}).id
    assert [_] = failure_rows(twice)
    assert total!(twice, :live_failures) == 1
    assert total!(twice, :live_failures) == length(failure_rows(twice))
  end

  test "after an admin resolves the refusal Failure, its row is gone from Home", ctx do
    %{run: run} = refused_run = AgentsFixtures.running_run(ctx.tenant)
    session = session!(ctx.admin)

    assert {:error, %Refused{reason: :no_eligible_grant} = refused} =
             reserve(refused_run, "c906-resolve")

    assert {:ok, open} = refresh(session)
    assert_refusal_row(ctx, open, refused, run, "no_eligible_grant")
    assert total!(open, :live_failures) == 1

    {:ok, failure} = Operations.get_failure(refused.failure_id, actor: ctx.admin)

    assert {:ok, %{status: :resolved}} =
             Operations.resolve_failure(failure, %{resolution_note: "Synthetic grant created"},
               actor: ctx.admin
             )

    assert {:ok, resolved} = refresh(session)
    assert resolved.completeness == :complete
    refute Enum.any?(resolved.items, &(&1.subject_ref.id == refused.failure_id))
    assert failure_rows(resolved) == []
    assert total!(resolved, :live_failures) == 0
  end
end
