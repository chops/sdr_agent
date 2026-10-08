defmodule SdrAgent.Outreach.WebhookRetryTest do
  @moduledoc """
  S13b operator retry of a failed WebhookEvent (soft-stop v3 PASS, Codex
  9a400910, rows B1–B4): `Outreach.retry_webhook/2` (active ADM, guarded)
  re-enqueues the exact original job after a locked check of the event, the
  job and its carried bytes; the request is audited with its ordinal (at
  most 3). The processor reruns a `failed` event only for an unconsumed
  request: success moves it `failed → processed` and resolves its Failure;
  another failure consumes the request (`webhook.retry_failed`) with no new
  Failure. Refusals write nothing.
  """
  use SdrAgent.SDRCase, async: false

  import Ecto.Query, only: [from: 2]
  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Operations
  alias SdrAgent.Operations.WebhookEvent
  alias SdrAgent.Outreach

  @worker "SdrAgent.Outreach.WebhookWorker"

  defp delivered!(ctx) do
    approved = approved!(ctx)
    assert %{success: 1} = deliver!()
    outreach!(ctx, approved.delivery)
  end

  defp webhook!(ctx, event) do
    {:ok, event} = Ash.get(WebhookEvent, event.id, actor: ctx.admin)
    event
  end

  defp job_of(event) do
    Repo.one!(
      from(j in Oban.Job,
        where: j.worker == @worker and fragment("?->>'webhook_event_id' = ?", j.args, ^event.id)
      )
    )
  end

  # A `delivered` event whose last processing attempt crashed (a transient
  # error on the final attempt): the event is `failed` (class crash) and
  # Oban discarded the job at its max attempts — the state the worker leaves.
  defp crashed_event!(ctx, delivery) do
    assert {:ok, %{status: :accepted, event: event}} =
             ingest!("delivered", outcome_body("delivered", delivery))

    whk = Actor.system(:webhook_ingestor, ctx.tenant.id)

    {:ok, _} =
      event
      |> Ash.Changeset.for_update(:mark_failed, %{class: :crash, reason: "processing error"},
        actor: whk
      )
      |> Ash.update()

    job = job_of(event)

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "discarded", attempt: 3, discarded_at: DateTime.utc_now()]
      )

    webhook!(ctx, event)
  end

  # A bounce for an unknown message: fails validation on every run.
  defp invalid_event!(ctx, delivery) do
    body = outcome_body("bounce", %{delivery | provider_message_id: "capture-0"})
    assert {:ok, %{status: :accepted, event: event}} = ingest!("bounce", body)
    assert %{success: 1} = process!()
    failed = webhook!(ctx, event)
    assert failed.processing_status == :failed
    failed
  end

  defp ledger_size(ctx), do: length(events(ctx.tenant))

  test "a crashed event is re-enqueued, processed and its Failure resolved", ctx do
    delivery = delivered!(ctx)
    event = crashed_event!(ctx, delivery)
    assert event.processing_status == :failed

    assert {:ok, %{event_id: event_id, ordinal: 1}} =
             Outreach.retry_webhook(event.id, actor: ctx.admin)

    assert event_id == event.id
    job = job_of(event)
    assert job.state == "available" and job.max_attempts > job.attempt

    assert [requested] = events_of_type(ctx.tenant, "webhook.retry_requested")
    assert requested.payload["arguments"] == %{"ordinal" => 1, "oban_job_id" => job.id}
    assert requested.actor_id == ctx.admin.id

    assert %{success: 1} = process!()
    processed = webhook!(ctx, event)
    assert processed.processing_status == :processed
    assert outreach!(ctx, delivery).state == :delivered

    {:ok, failure} = Operations.get_failure(event.failure_id, actor: ctx.admin)
    assert failure.status == :resolved

    # Processed is terminal: never retried again.
    assert Outreach.retry_webhook(event.id, actor: ctx.admin) == {:error, :not_failed}
  end

  test "a retry that fails again consumes its request; bounded at three", ctx do
    delivery = delivered!(ctx)
    event = invalid_event!(ctx, delivery)
    failures = Repo.aggregate(Operations.Failure, :count)

    for ordinal <- 1..3 do
      assert {:ok, %{ordinal: ^ordinal}} = Outreach.retry_webhook(event.id, actor: ctx.admin)
      assert %{success: 1} = process!()
      assert webhook!(ctx, event).processing_status == :failed
    end

    assert [1, 2, 3] ==
             ctx.tenant
             |> events_of_type("webhook.retry_failed")
             |> Enum.map(& &1.payload["arguments"]["ordinal"])

    # One attention entry for the event, never a duplicate.
    assert Repo.aggregate(Operations.Failure, :count) == failures

    before = ledger_size(ctx)
    assert Outreach.retry_webhook(event.id, actor: ctx.admin) == {:error, :retry_limit_reached}
    assert ledger_size(ctx) == before
  end

  test "a request whose job is still queued is :retry_pending", ctx do
    event = crashed_event!(ctx, delivered!(ctx))
    {:ok, _} = Outreach.retry_webhook(event.id, actor: ctx.admin)
    before = ledger_size(ctx)

    assert Outreach.retry_webhook(event.id, actor: ctx.admin) == {:error, :retry_pending}
    assert ledger_size(ctx) == before
  end

  test "a received, processed or rejected event is :not_failed", ctx do
    delivery = delivered!(ctx)

    assert {:ok, %{status: :accepted, event: received}} =
             ingest!("delivered", outcome_body("delivered", delivery))

    assert Outreach.retry_webhook(received.id, actor: ctx.admin) == {:error, :not_failed}
    assert %{success: 1} = process!()
    assert Outreach.retry_webhook(received.id, actor: ctx.admin) == {:error, :not_failed}

    {:ok, %{status: :rejected, event: rejected}} =
      ingest!("delivered", outcome_body("delivered", delivery), key: "wrong-key")

    assert Outreach.retry_webhook(rejected.id, actor: ctx.admin) == {:error, :not_failed}
  end

  test "a pruned job is :retry_window_expired", ctx do
    event = crashed_event!(ctx, delivered!(ctx))
    Repo.delete_all(from(j in Oban.Job, where: j.id == ^job_of(event).id))
    before = ledger_size(ctx)

    assert Outreach.retry_webhook(event.id, actor: ctx.admin) == {:error, :retry_window_expired}
    assert ledger_size(ctx) == before
  end

  test "a job whose carried bytes no longer match the event is :job_corrupt", ctx do
    event = crashed_event!(ctx, delivered!(ctx))
    job = job_of(event)
    args = Map.put(job.args, "raw_body", Base.encode64(~s({"tampered":true})))
    {1, _} = Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [args: args])

    assert Outreach.retry_webhook(event.id, actor: ctx.admin) == {:error, :job_corrupt}
    assert job_of(event).state == "discarded"
  end

  test "a duplicate or resumed job without a pending request is a no-op", ctx do
    # It would succeed if run: only an operator request may rerun it.
    event = crashed_event!(ctx, delivered!(ctx))
    before = ledger_size(ctx)

    :ok = Oban.retry_job(job_of(event).id)
    assert %{success: 1} = process!()

    assert webhook!(ctx, event).processing_status == :failed
    assert ledger_size(ctx) == before
  end

  describe "authorization" do
    for role <- [:reviewer, :auditor] do
      test "#{role}: Forbidden, one authz.denied, the job untouched", ctx do
        event = crashed_event!(ctx, delivered!(ctx))
        actor = human(unquote(role), ctx.tenant)

        assert {:error, %Ash.Error.Forbidden{}} = Outreach.retry_webhook(event.id, actor: actor)
        assert job_of(event).state == "discarded"

        assert [denial] =
                 Enum.filter(
                   events_of_type(ctx.tenant, "authz.denied"),
                   &(&1.actor_id == actor.id)
                 )

        assert denial.payload["action"] == "retry_webhook"
      end
    end

    test "the webhook ingestor cannot request a retry either", ctx do
      event = crashed_event!(ctx, delivered!(ctx))
      whk = Actor.system(:webhook_ingestor, ctx.tenant.id)

      assert {:error, %Ash.Error.Forbidden{}} = Outreach.retry_webhook(event.id, actor: whk)
      assert job_of(event).state == "discarded"
    end

    test "WebhookEvent :request_retry has no direct path, even for an admin", ctx do
      event = crashed_event!(ctx, delivered!(ctx))

      assert {:error, %Ash.Error.Forbidden{}} =
               event
               |> Ash.Changeset.for_update(:request_retry, %{ordinal: 1, oban_job_id: 1},
                 actor: ctx.admin
               )
               |> Ash.update()

      assert events_of_type(ctx.tenant, "webhook.retry_requested") == []
    end

    test "an admin cannot drive the processor's actions", ctx do
      event = crashed_event!(ctx, delivered!(ctx))

      for {action, args} <- [
            {:mark_processed, %{}},
            {:record_retry_failed, %{class: :crash, reason: "x", ordinal: 1}}
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 event
                 |> Ash.Changeset.for_update(action, args, actor: ctx.admin)
                 |> Ash.update()
      end
    end
  end
end
