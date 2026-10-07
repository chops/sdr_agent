defmodule SdrAgent.Audit.OtsUpgradeWorkerTest do
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Audit
  alias SdrAgent.Audit.AnchorSinkReceipt
  alias SdrAgent.Audit.Anchoring
  alias SdrAgent.Audit.OtsUpgradeWorker

  defmodule Calendar do
    def submit(hash, _opts), do: {:ok, "pending:" <> hash}

    def upgrade("pending:" <> hash, hash, opts) do
      Agent.get_and_update(opts[:counter], fn {mode, count} ->
        result =
          case mode do
            :complete -> {:ok, %{proof: "confirmed:" <> hash, bitcoin_attested: true}}
            :incomplete -> {:error, :ots_pending}
            :error -> {:error, :calendar_unreachable}
          end

        {result, {mode, count + 1}}
      end)
    end
  end

  setup do
    tenant = bootstrap!()
    actor = system_actor(:anchorer, tenant)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, _} =
      Audit.register_signing_key(%{key_id: "upgrade-test", public_key: public},
        actor: system_actor(:kernel, tenant)
      )

    counter = start_supervised!({Agent, fn -> {:complete, 0} end})
    sink_opts = [calendar: Calendar, calendar_options: [counter: counter]]
    old = Application.get_env(:sdr_agent, :anchor_sinks)

    Application.put_env(:sdr_agent, :anchor_sinks, [
      {:ots, SdrAgent.Audit.AnchorSinks.OpenTimestampsSink, sink_opts}
    ])

    on_exit(fn -> Application.put_env(:sdr_agent, :anchor_sinks, old) end)
    %{tenant: tenant, actor: actor, private: private, counter: counter, sink_opts: sink_opts}
  end

  defp anchor(ctx) do
    {:ok, anchor} =
      Anchoring.anchor(
        trigger: :interval,
        actor: ctx.actor,
        private_key: ctx.private,
        sinks: Application.fetch_env!(:sdr_agent, :anchor_sinks)
      )

    anchor
  end

  defp receipts(anchor, actor) do
    AnchorSinkReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(anchor_id == ^anchor.id)
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!()
  end

  defp job(anchor, pending),
    do: %Oban.Job{
      args: %{"anchor_id" => anchor.id, "pending_receipt_id" => pending.id},
      attempt: 1
    }

  test "confirmed upgrade appends one receipt and replay does no work", ctx do
    anchor = anchor(ctx)
    [pending] = receipts(anchor, ctx.actor)
    assert Code.ensure_loaded?(OtsUpgradeWorker)
    assert :ok = OtsUpgradeWorker.perform(job(anchor, pending))
    assert :ok = OtsUpgradeWorker.perform(job(anchor, pending))
    assert Enum.map(receipts(anchor, ctx.actor), & &1.status) == [:pending, :confirmed]
    assert Agent.get(ctx.counter, &elem(&1, 1)) == 1
  end

  test "an incomplete proof remains pending without an added receipt", ctx do
    Agent.update(ctx.counter, fn _ -> {:incomplete, 0} end)
    anchor = anchor(ctx)
    [pending] = receipts(anchor, ctx.actor)
    assert Code.ensure_loaded?(OtsUpgradeWorker)
    assert :ok = OtsUpgradeWorker.perform(job(anchor, pending))
    assert [%{id: id, status: :pending}] = receipts(anchor, ctx.actor)
    assert id == pending.id
  end

  test "a queued job upgrades its named receipt even when a later pending row exists", ctx do
    anchor = anchor(ctx)
    [pending] = receipts(anchor, ctx.actor)

    {:ok, _later} =
      AnchorSinkReceipt
      |> Ash.Changeset.for_create(
        :record,
        %{
          anchor_id: anchor.id,
          sink: :ots,
          status: :pending,
          recorded_at: DateTime.add(pending.recorded_at, 1, :second),
          receipt: %{proof: Base.encode64("different later proof")}
        },
        actor: ctx.actor
      )
      |> Ash.create()

    result =
      try do
        OtsUpgradeWorker.perform(job(anchor, pending))
      rescue
        _ -> :wrong_receipt_used
      end

    assert result == :ok
    confirmed = Enum.find(receipts(anchor, ctx.actor), &(&1.status == :confirmed))
    assert confirmed.receipt["pending_receipt_id"] == pending.id
  end

  test "real upgrade errors return failure and preserve append-only failed evidence", ctx do
    Agent.update(ctx.counter, fn _ -> {:error, 0} end)
    anchor = anchor(ctx)
    [pending] = receipts(anchor, ctx.actor)
    assert Code.ensure_loaded?(OtsUpgradeWorker)
    assert {:error, _} = OtsUpgradeWorker.perform(job(anchor, pending))
    assert Enum.map(receipts(anchor, ctx.actor), & &1.status) == [:pending, :failed]
  end

  test "scheduler batch is bounded and per-anchor receipt jobs are unique", ctx do
    assert Code.ensure_loaded?(OtsUpgradeWorker)
    old = Application.get_env(:sdr_agent, :ots_upgrade_batch_size)
    Application.put_env(:sdr_agent, :ots_upgrade_batch_size, 2)

    on_exit(fn ->
      if old,
        do: Application.put_env(:sdr_agent, :ots_upgrade_batch_size, old),
        else: Application.delete_env(:sdr_agent, :ots_upgrade_batch_size)
    end)

    for n <- 1..4 do
      {:ok, _} = Audit.append(%{event_type: "test.ots.#{n}", category: :system}, actor: ctx.actor)
      anchor(ctx)
    end

    assert :ok = OtsUpgradeWorker.perform(%Oban.Job{args: %{}})
    assert :ok = OtsUpgradeWorker.perform(%Oban.Job{args: %{}})
    jobs = Oban.Testing.all_enqueued(repo: Repo, worker: OtsUpgradeWorker)
    assert length(jobs) == 2
    assert length(Enum.uniq_by(jobs, & &1.args["anchor_id"])) == 2
    assert Enum.all?(jobs, &is_binary(&1.args["pending_receipt_id"]))
    assert Enum.all?(jobs, &(&1.max_attempts <= 5))
  end

  test "offline mode prevents both dispatch and queued proof network work", ctx do
    anchor = anchor(ctx)
    [pending] = receipts(anchor, ctx.actor)
    Application.put_env(:sdr_agent, :anchor_sinks, [])
    assert :ok = OtsUpgradeWorker.perform(%Oban.Job{args: %{}})

    assert {:cancel, :ots_sink_disabled} =
             OtsUpgradeWorker.perform(job(anchor, pending))

    assert Agent.get(ctx.counter, &elem(&1, 1)) == 0
    assert [%{status: :pending}] = receipts(anchor, ctx.actor)
  end

  test "worker retries, backoff and execution are explicitly bounded" do
    changeset =
      OtsUpgradeWorker.new(%{
        anchor_id: Ecto.UUID.generate(),
        pending_receipt_id: Ecto.UUID.generate()
      })

    assert Ecto.Changeset.get_field(changeset, :max_attempts) == 3
    assert OtsUpgradeWorker.backoff(%Oban.Job{attempt: 1}) == 60
    assert OtsUpgradeWorker.backoff(%Oban.Job{attempt: 20}) == 600
    assert OtsUpgradeWorker.timeout(%Oban.Job{}) == 60_000
  end
end
