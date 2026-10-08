defmodule SdrAgent.Outreach.DeliveryRestartTest do
  @moduledoc """
  S13 Oban restart acceptance for delivery: a worker that dies after the
  capture committed, then a restart that runs the job again *before* the
  sweeper notices (Oban retries the attempt), never captures a second time;
  the sweeper hands the stale claim to reconciliation (`attempting →
  unknown`), which finds the capture and accepts it — exactly one captured
  receipt, and further job runs are no-ops by state.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures

  alias SdrAgent.Clock
  alias SdrAgent.Outreach
  alias SdrAgent.Test.CaptureFaults

  setup do
    start_supervised!(CaptureFaults)
    put_env!(:capture_faults, CaptureFaults)
    :ok
  end

  defp captured(ctx, op), do: Enum.filter(receipts!(ctx, op), &(&1.kind == :captured))
  defp later(seconds), do: Clock.freeze(DateTime.add(Clock.utc_now(), seconds, :second))

  test "crash after capture, job re-run on restart, sweep, reconcile: one capture", ctx do
    CaptureFaults.plan(:after_capture, [:crash])
    %{delivery: op} = approved!(ctx)

    assert_raise RuntimeError, ~r/capture fault: crash/, fn -> deliver!() end
    assert outreach!(ctx, op).state == :attempting
    assert length(captured(ctx, op)) == 1

    # Restart: the delivery job runs again while the claim is still held.
    {:ok, _job} =
      %{"delivery_operation_id" => op.id, "tenant_id" => ctx.tenant.id}
      |> SdrAgent.Outreach.DeliveryWorker.new()
      |> Oban.insert()

    _ = Oban.drain_queue(queue: :delivery, with_scheduled: true)
    assert outreach!(ctx, op).state == :attempting
    assert length(captured(ctx, op)) == 1

    later(Outreach.Compliance.stale_after_seconds() + 1)
    assert :ok = Outreach.Delivery.sweep(ctx.tenant.id)
    assert outreach!(ctx, op).state == :unknown
    assert %{success: 1} = reconcile!()
    assert outreach!(ctx, op).state == :accepted

    # Any later run of the job is a no-op by state.
    _ = deliver!()
    assert outreach!(ctx, op).state == :accepted
    assert length(captured(ctx, op)) == 1
  end
end
