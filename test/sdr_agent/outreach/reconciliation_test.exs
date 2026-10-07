defmodule SdrAgent.Outreach.ReconciliationTest do
  @moduledoc """
  S8b outcomes other than a clean acceptance (spec §14): retryable failures
  retry with bounded attempts (no new quota unit), permanent failures and
  exhausted retries end the delivery with operator attention, and *unknown*
  outcomes — a timeout or a crash after the hand-off — go to reconciliation,
  which asks the capture adapter what it accepted and never blindly resends.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.Outreach
  alias SdrAgent.Test.CaptureFaults

  setup do
    start_supervised!(CaptureFaults)
    put_env!(:capture_faults, CaptureFaults)
    :ok
  end

  defp captured(ctx, op), do: Enum.filter(receipts!(ctx, op), &(&1.kind == :captured))

  defp attention_for(ctx, op) do
    {:ok, open} = Operations.list_attention(actor: ctx.admin)
    Enum.filter(open, &(&1.subject_id == op.id))
  end

  defp later(seconds), do: Clock.freeze(DateTime.add(Clock.utc_now(), seconds, :second))

  test "a retryable failure retries later without a second quota unit", ctx do
    CaptureFaults.plan(:before_capture, [{:error, {:retryable, :rate_limited}}])
    %{delivery: op} = approved!(ctx)

    assert %{success: 1} = deliver!()
    failed = outreach!(ctx, op)
    assert {failed.state, failed.attempt_count} == {:failed_retryable, 1}
    assert DateTime.compare(failed.not_before, Clock.utc_now()) == :gt

    assert_enqueued(
      worker: SdrAgent.Outreach.DeliveryWorker,
      args: %{"delivery_operation_id" => op.id}
    )

    later(600)
    assert %{success: 1} = deliver!()
    done = outreach!(ctx, op)
    assert {done.state, done.attempt_count} == {:accepted, 2}
    assert length(captured(ctx, op)) == 1
    # Every attempt renders the same bytes.
    assert done.rendered_sha256 == failed.rendered_sha256

    {:ok, [day]} = Outreach.list_records(Outreach.SendQuotaDay, actor: ctx.admin)
    assert day.consumed == 1
  end

  # Review #14 (important): a retry whose rendered bytes would differ from the
  # first attempt's (here: a rotated endpoint secret changes the unsubscribe
  # link) is refused, never sent with different content.
  test "a retry whose message bytes drifted is refused, not re-rendered", ctx do
    CaptureFaults.plan(:before_capture, [{:error, {:retryable, :rate_limited}}])
    %{delivery: op} = approved!(ctx)
    assert %{success: 1} = deliver!()
    first = outreach!(ctx, op)
    assert first.state == :failed_retryable

    endpoint = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint)

    put_env!(
      SdrAgentWeb.Endpoint,
      Keyword.put(endpoint, :secret_key_base, String.duplicate("r", 64))
    )

    later(600)
    assert %{success: 1} = deliver!()
    refused = outreach!(ctx, op)
    assert {refused.state, refused.last_error["reason"]} == {:cancelled, "rendered_drift"}
    assert refused.rendered_sha256 == first.rendered_sha256
    assert captured(ctx, op) == []
  end

  test "a permanent failure ends the delivery, fails the draft and opens attention", ctx do
    CaptureFaults.plan(:before_capture, [{:error, {:permanent, :rejected}}])
    %{delivery: op, draft: draft} = approved!(ctx)

    assert %{success: 1} = deliver!()
    failed = outreach!(ctx, op)
    assert {failed.state, failed.last_error["reason"]} == {:failed_permanent, "rejected"}
    assert draft!(ctx, draft).status == :failed
    assert [failure] = attention_for(ctx, op)
    assert {failure.class, failure.id} == {:delivery_failed, failed.attention_failure_id}
  end

  test "retries are bounded: the third retryable failure is permanent", ctx do
    CaptureFaults.plan(:before_capture, List.duplicate({:error, {:retryable, :rate_limited}}, 3))
    %{delivery: op} = approved!(ctx)

    for _attempt <- 1..3 do
      assert %{success: 1} = deliver!()
      later(3600)
    end

    failed = outreach!(ctx, op)
    assert {failed.state, failed.attempt_count} == {:failed_permanent, 3}
    assert captured(ctx, op) == []
  end

  test "an unknown outcome after the capture reconciles to accepted — never resent", ctx do
    CaptureFaults.plan(:after_capture, [{:error, {:unknown, :timeout}}])
    %{delivery: op, draft: draft, lead: lead} = approved!(ctx)

    assert %{success: 1} = deliver!()
    unknown = outreach!(ctx, op)
    assert unknown.state == :unknown
    assert unknown.unknown_since
    assert [failure] = attention_for(ctx, op)
    assert failure.class == :reconciliation_required

    assert_enqueued(
      worker: SdrAgent.Outreach.ReconcileWorker,
      args: %{"delivery_operation_id" => op.id}
    )

    assert %{success: 1} = reconcile!()

    reconciled = outreach!(ctx, op)
    assert reconciled.state == :accepted
    assert [capture] = captured(ctx, op)
    assert reconciled.provider_message_id == capture.provider_message_id
    assert Enum.map(receipts!(ctx, op), & &1.kind) == [:captured, :reconciled]

    [decision] = decisions_about!(ctx, op.id, :delivery_reconciliation)
    assert {decision.mode, decision.outcome} == {:deterministic, "accepted"}
    assert attention_for(ctx, op) == []
    assert draft!(ctx, draft).status == :sent
    assert enrollment!(ctx, lead).current_step_position == 1
  end

  test "an unknown outcome before the capture reconciles to a retry, then one capture", ctx do
    CaptureFaults.plan(:before_capture, [{:error, {:unknown, :timeout}}])
    %{delivery: op} = approved!(ctx)

    assert %{success: 1} = deliver!()
    assert outreach!(ctx, op).state == :unknown
    assert %{success: 1} = reconcile!()

    assert outreach!(ctx, op).state == :failed_retryable
    assert [%{outcome: "not_accepted"}] = decisions_about!(ctx, op.id, :delivery_reconciliation)
    assert attention_for(ctx, op) == []

    later(600)
    assert %{success: 1} = deliver!()
    assert outreach!(ctx, op).state == :accepted
    assert length(captured(ctx, op)) == 1
  end

  test "a crash after the capture leaves the claim; the sweeper hands it to reconciliation",
       ctx do
    CaptureFaults.plan(:after_capture, [:crash])
    %{delivery: op} = approved!(ctx)

    # The worker crashes after the capture committed (drained without Oban's
    # safety net, the crash reaches the test).
    assert_raise RuntimeError, ~r/capture fault: crash/, fn -> deliver!() end
    assert outreach!(ctx, op).state == :attempting

    # Not stale yet: the sweeper leaves it alone.
    assert :ok = Outreach.Delivery.sweep(ctx.tenant.id)
    assert outreach!(ctx, op).state == :attempting

    later(600)
    assert :ok = Outreach.Delivery.sweep(ctx.tenant.id)
    assert outreach!(ctx, op).state == :unknown
    assert %{success: 1} = reconcile!()
    assert outreach!(ctx, op).state == :accepted
    assert length(captured(ctx, op)) == 1
  end
end
