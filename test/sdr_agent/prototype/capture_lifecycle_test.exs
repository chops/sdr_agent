defmodule SdrAgent.Prototype.CaptureLifecycleTest do
  @moduledoc """
  T14-T17: the existing crash recovery on the changed prototype capture
  paths (S4 proposal r3 section 3.3 and its H3 conditions; Codex 4c72c150
  H3 and 1fabb2d3 R3). These are lifecycle controls in prototype runtime,
  each starting from a delegated delivery whose capture failed or crashed.

  - T14: a re-run of the failed delivery JOB, with its operation still
    attempting, resends nothing, does not move the attempt count, and
    charges no send quota (no recharge).
  - T15: stale recovery with a positive committed absence. The sweeper
    moves the stale operation to unknown. Reconciliation's successful lookup
    finds no captured receipt and schedules a retry. The retry runs the full
    send gate under the same idempotency key, and captures once.
  - T16: a failed lookup (the receipt source unavailable during
    reconciliation) never becomes "not found". The reconciliation job
    fails, the operation stays unknown, and no attempt is scheduled.
  - T17: an accepted receipt (an after-capture crash after a successful
    capture) is reconciled as accepted, with no resend. At max attempts a
    positive absence is reconcile_failed, with no new attempt.

  Faults are synthetic: a renamed table inside the test's sandbox
  transaction, rolled back with it; an adapter fault seam returning
  `:crash`; `max_attempts` lowered by SQL with triggers off. Synthetic
  `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.PrototypeOutreachFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Outreach.Compliance
  alias SdrAgent.Outreach.Delivery
  alias SdrAgent.Repo

  defp jobs(delivery_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT state, attempt FROM oban_jobs WHERE worker = $1 AND " <>
          "args->>'delivery_operation_id' = $2 ORDER BY id",
        ["SdrAgent.Outreach.DeliveryWorker", delivery_id]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp quota_consumed do
    %{rows: [[consumed]]} = Repo.query!("SELECT coalesce(sum(consumed), 0) FROM send_quota_days")
    consumed
  end

  defp kinds(ctx, delivery), do: ctx |> receipts!(delivery) |> Enum.map(& &1.kind) |> Enum.sort()

  # A delegated delivery whose capture fails after the claim (the
  # suppression source made unavailable in before_capture), restored
  # afterwards. The operation is left attempting on attempt 1.
  defp failed_attempt!(opts \\ []) do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)

    case Keyword.fetch(opts, :max_attempts) do
      {:ok, max} ->
        tamper!("UPDATE delivery_operations SET max_attempts = $1 WHERE id = $2", [
          max,
          Ecto.UUID.dump!(delivery.id)
        ])

      :error ->
        :ok
    end

    capture_hook!(:before_capture, fn _op ->
      tamper!("ALTER TABLE suppressions RENAME TO suppressions_unavailable")
    end)

    deliver!()
    tamper!("ALTER TABLE suppressions_unavailable RENAME TO suppressions")
    op = outreach!(ctx, delivery)

    assert {op.state, op.attempt_count} == {:attempting, 1},
           "prerequisite: the attempt did not fail after its claim"

    no_capture!(ctx, delivery)
    {ctx, delivery, op}
  end

  # Moves the clock past the stale threshold (still inside the window and
  # outside quiet hours) and runs the sweeper.
  defp sweep_stale!(ctx) do
    Clock.freeze(DateTime.add(inside_window(), Compliance.stale_after_seconds() + 60, :second))
    assert :ok = Delivery.sweep(ctx.tenant.id)
  end

  test "T14: a re-run of the failed delivery job on an attempting operation resends and charges nothing (control)" do
    {ctx, delivery, op} = failed_attempt!()
    quota = quota_consumed()
    ref = capture_hook!(:before_capture, fn _op -> :ok end)

    deliver!()

    assert messages(ref) == [], "the job re-run reached the capture again"
    rerun = outreach!(ctx, delivery)
    assert {rerun.state, rerun.attempt_count} == {:attempting, op.attempt_count}
    assert quota_consumed() == quota
    no_capture!(ctx, delivery)
  end

  test "T15: stale recovery with a positive absence retries through the full gates under the same key (control)" do
    {ctx, delivery, op} = failed_attempt!()
    sweep_stale!(ctx)
    assert outreach!(ctx, delivery).state == :unknown

    reconcile!()
    retry = outreach!(ctx, delivery)
    assert retry.state == :failed_retryable

    ref = capture_hook!(:before_capture, fn _op -> :ok end)
    deliver!()

    accepted = outreach!(ctx, delivery)
    assert {accepted.state, accepted.attempt_count} == {:accepted, 2}
    assert accepted.idempotency_key == op.idempotency_key
    assert kinds(ctx, delivery) == [:accepted, :captured]

    assert [{:entered, :before_capture, _id, 2}, {:returned, :before_capture, _id2, 2, :ok}] =
             messages(ref)
  end

  test "T16: a failed lookup never becomes not found; the operation stays unknown, no attempt is scheduled (control)" do
    {ctx, delivery, _op} = failed_attempt!()
    sweep_stale!(ctx)
    assert outreach!(ctx, delivery).state == :unknown
    before = jobs(delivery.id)

    tamper!("ALTER TABLE delivery_receipts RENAME TO delivery_receipts_unavailable")

    counts =
      try do
        reconcile!()
      after
        tamper!("ALTER TABLE delivery_receipts_unavailable RENAME TO delivery_receipts")
      end

    assert {Map.get(counts, :success), Map.get(counts, :failure)} == {0, 1}
    assert outreach!(ctx, delivery).state == :unknown
    assert jobs(delivery.id) == before
    assert kinds(ctx, delivery) == []
  end

  test "T17: an accepted receipt after an after-capture crash is reconciled as accepted, with no resend (control)" do
    ctx = prototype_drafted!()
    assert {:ok, approval} = operator_approve(ctx, ctx.draft)
    delivery = delivery_of!(ctx, approval)
    capture_hook!(:after_capture, fn _op -> :crash end)

    assert_raise RuntimeError, ~r/\Acapture fault: crash after_capture\z/, fn -> deliver!() end
    assert outreach!(ctx, delivery).state == :attempting
    assert kinds(ctx, delivery) == [:captured]

    ref = capture_hook!(:before_capture, fn _op -> :ok end)
    sweep_stale!(ctx)
    reconcile!()

    assert outreach!(ctx, delivery).state == :accepted
    assert kinds(ctx, delivery) == [:captured, :reconciled]
    assert messages(ref) == [], "reconciliation resent the message"
  end

  test "T17: at max attempts a positive absence is reconcile_failed, with no new attempt (control)" do
    {ctx, delivery, _op} = failed_attempt!(max_attempts: 1)
    sweep_stale!(ctx)
    before = jobs(delivery.id)

    reconcile!()

    failed = outreach!(ctx, delivery)
    assert failed.state == :failed_permanent
    assert failed.last_error == %{"reason" => "not_accepted_after_max_attempts"}
    assert jobs(delivery.id) == before
    no_capture!(ctx, delivery)
  end
end
