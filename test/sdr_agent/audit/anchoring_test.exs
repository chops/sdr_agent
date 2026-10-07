defmodule SdrAgent.Audit.AnchoringTest do
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Audit
  alias SdrAgent.Audit.AnchorSinkReceipt
  alias SdrAgent.Audit.AnchorWorker
  alias SdrAgent.Audit.Anchoring

  defmodule FakeOtsSink do
    def publish(hash, _opts), do: {:ok, %{status: :pending, proof: "pending:" <> hash}}

    def upgrade("pending:" <> hash, hash, _opts),
      do: {:ok, %{status: :confirmed, proof: "confirmed:" <> hash}}
  end

  defmodule FailOnceSink do
    def publish(_statement, opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :counter), fn
        0 -> {{:error, :temporary_failure}, 1}
        count -> {{:ok, %{status: :confirmed, attempt: count + 1}}, count + 1}
      end)
    end
  end

  setup do
    tenant = bootstrap!()
    anchorer = system_actor(:anchorer, tenant)
    admin = human(:admin, tenant)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      Audit.register_signing_key(
        %{key_id: "test-ed25519", public_key: public_key, activated_at: SdrAgent.Clock.utc_now()},
        actor: SdrAgent.Actor.system(:kernel, tenant.id)
      )

    %{tenant: tenant, anchorer: anchorer, admin: admin, key: key, private_key: private_key}
  end

  test "genesis anchor covers sequence one through the observed chain head", ctx do
    assert {:ok, anchor} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: []
             )

    assert anchor.anchor_number == 1
    assert anchor.from_sequence == 1
    assert anchor.to_sequence >= 1
    assert anchor.prior_anchor_id == nil
    assert anchor.key_id == ctx.key.key_id
    assert anchor.key_status_at_signing == :active
    assert byte_size(anchor.signature) == 64
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    assert anchor.sdr_agent_git_sha == String.trim(sha)
  end

  test "an export with no new events reuses the latest anchor", ctx do
    assert {:ok, first} =
             Anchoring.anchor(
               trigger: :export,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: []
             )

    assert {:ok, {:existing, second}} =
             Anchoring.anchor(
               trigger: :export,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: []
             )

    assert second.id == first.id
  end

  test "rotation preserves historical validity; revocation reduces assurance", ctx do
    assert {:ok, anchor} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: []
             )

    assert {:ok, %{valid?: true, assurance_level: :signed}} =
             Anchoring.verify(anchor, actor: ctx.admin)

    assert {:ok, _} = Audit.rotate_signing_key(ctx.key.id, actor: ctx.admin)
    assert {:ok, %{valid?: true}} = Anchoring.verify(anchor, actor: ctx.admin)

    # A revoked key invalidates signatures made at/after revocation and lowers
    # assurance for older signatures with an explicit issue.
    {:ok, replacement} =
      Audit.register_signing_key(
        %{key_id: "replacement", public_key: elem(:crypto.generate_key(:eddsa, :ed25519), 0)},
        actor: SdrAgent.Actor.system(:kernel, ctx.tenant.id)
      )

    assert replacement.status == :active

    assert {:ok, revoked_key} =
             Audit.revoke_signing_key(ctx.key.id, "operator revocation", actor: ctx.admin)

    assert {:ok, report} = Anchoring.verify(anchor, actor: ctx.admin)
    assert report.valid?
    assert report.assurance_level == :chain_verified
    assert :signing_key_revoked_after_signing in report.issues

    post_revocation = %{anchor | inserted_at: revoked_key.revoked_at}
    assert {:ok, post_report} = Anchoring.verify(post_revocation, actor: ctx.admin)
    refute post_report.valid?
    assert :signature_at_or_after_key_revocation in post_report.issues
  end

  test "refuses a private key that does not match the active public key", ctx do
    {_public_key, stale_private_key} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:error, :private_key_does_not_match_active_key} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: stale_private_key,
               sinks: []
             )
  end

  test "OTS upgrade appends a confirmed receipt without changing the pending receipt", ctx do
    assert {:ok, anchor} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [{:ots, FakeOtsSink, []}]
             )

    [pending] = receipts_for(anchor, ctx.anchorer)
    assert pending.status == :pending
    pending_receipt = pending.receipt

    assert {:ok, confirmed} =
             Anchoring.upgrade_ots(anchor, actor: ctx.anchorer, sink: FakeOtsSink)

    assert confirmed.status == :confirmed
    assert confirmed.id != pending.id

    assert [persisted_pending, persisted_confirmed] = receipts_for(anchor, ctx.anchorer)
    assert persisted_pending.id == pending.id
    assert persisted_pending.receipt == pending_receipt
    assert persisted_pending.status == :pending
    assert persisted_confirmed.id == confirmed.id
    assert persisted_confirmed.status == :confirmed
  end

  test "failed sink attempts are recorded and an empty-range retry republishes", ctx do
    counter = start_supervised!({Agent, fn -> 0 end})
    sinks = [{:file, FailOnceSink, [counter: counter]}]

    assert {:error, {:sink_failures, [{:file, :temporary_failure}]}} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: sinks
             )

    assert {:ok, {:existing, anchor}} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: sinks
             )

    receipts =
      AnchorSinkReceipt
      |> Ash.Query.for_read(:read, %{}, actor: ctx.anchorer)
      |> Ash.Query.filter(anchor_id == ^anchor.id and sink == :file)
      |> Ash.Query.sort(recorded_at: :asc)
      |> Ash.read!()

    assert Enum.map(receipts, & &1.status) == [:failed, :confirmed]

    assert {:ok, {:existing, _}} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: sinks
             )

    assert Agent.get(counter, & &1) == 2
  end

  test "forced cadence worker loads the configured key and creates an anchor", ctx do
    previous = System.get_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY")
    System.put_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY", Base.encode64(ctx.private_key))

    on_exit(fn ->
      if previous,
        do: System.put_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY", previous),
        else: System.delete_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY")
    end)

    assert :ok = AnchorWorker.perform(%Oban.Job{args: %{"force" => true}})

    assert {:ok, [_anchor]} =
             SdrAgent.Audit.AuditAnchor
             |> Ash.Query.for_read(:read, %{}, actor: ctx.anchorer)
             |> Ash.read()
  end

  test "cadence excludes bookkeeping and idle intervals, but runs for new events", ctx do
    put_worker_key(ctx.private_key)

    assert {:ok, anchor} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: []
             )

    SdrAgent.Clock.freeze(DateTime.add(anchor.inserted_at, 901, :second))
    {:ok, before} = Audit.list_events(actor: ctx.admin)
    for _ <- 1..3, do: assert(:ok == AnchorWorker.perform(%Oban.Job{args: %{}}))
    {:ok, after_idle} = Audit.list_events(actor: ctx.admin)
    assert length(after_idle) == length(before)

    assert {:ok, _} =
             Audit.append(%{event_type: "test.new_work", category: :system}, actor: ctx.anchorer)

    assert :ok = AnchorWorker.perform(%Oban.Job{args: %{}})

    anchors =
      SdrAgent.Audit.AuditAnchor
      |> Ash.Query.for_read(:read, %{}, actor: ctx.anchorer)
      |> Ash.Query.sort(anchor_number: :asc)
      |> Ash.read!()

    assert length(anchors) == 2
    assert List.last(anchors).trigger == :interval
  end

  test "event count cadence runs only at its threshold", ctx do
    put_worker_key(ctx.private_key)
    old = Application.get_env(:sdr_agent, :anchor_event_count)
    Application.put_env(:sdr_agent, :anchor_event_count, 2)

    on_exit(fn ->
      if old,
        do: Application.put_env(:sdr_agent, :anchor_event_count, old),
        else: Application.delete_env(:sdr_agent, :anchor_event_count)
    end)

    assert {:ok, _} =
             Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: []
             )

    assert {:ok, _} =
             Audit.append(%{event_type: "test.one", category: :system}, actor: ctx.anchorer)

    assert :ok = AnchorWorker.perform(%Oban.Job{args: %{}})

    anchors =
      SdrAgent.Audit.AuditAnchor
      |> Ash.Query.for_read(:read, %{}, actor: ctx.anchorer)
      |> Ash.read!()

    assert length(anchors) == 1

    assert {:ok, _} =
             Audit.append(%{event_type: "test.two", category: :system}, actor: ctx.anchorer)

    assert :ok = AnchorWorker.perform(%Oban.Job{args: %{}})

    anchors =
      SdrAgent.Audit.AuditAnchor
      |> Ash.Query.for_read(:read, %{}, actor: ctx.anchorer)
      |> Ash.Query.sort(anchor_number: :asc)
      |> Ash.read!()

    assert length(anchors) == 2
    assert List.last(anchors).trigger == :event_count
  end

  defp put_worker_key(private) do
    previous = System.get_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY")
    System.put_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY", Base.encode64(private))

    on_exit(fn ->
      if previous,
        do: System.put_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY", previous),
        else: System.delete_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY")
    end)
  end

  test "Oban retry republishes a failed sink without starting an idle cadence loop", ctx do
    put_worker_key(ctx.private_key)
    counter = start_supervised!({Agent, fn -> 0 end})
    old = Application.get_env(:sdr_agent, :anchor_sinks)
    Application.put_env(:sdr_agent, :anchor_sinks, [{:file, FailOnceSink, [counter: counter]}])

    on_exit(fn ->
      if old,
        do: Application.put_env(:sdr_agent, :anchor_sinks, old),
        else: Application.delete_env(:sdr_agent, :anchor_sinks)
    end)

    assert {:error, {:sink_failures, [{:file, :temporary_failure}]}} =
             AnchorWorker.perform(%Oban.Job{args: %{"force" => true}, attempt: 1})

    assert :ok = AnchorWorker.perform(%Oban.Job{args: %{}, attempt: 2})
    assert :ok = AnchorWorker.perform(%Oban.Job{args: %{}, attempt: 1})
    assert Agent.get(counter, & &1) == 2
  end

  defp receipts_for(anchor, actor) do
    AnchorSinkReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(anchor_id == ^anchor.id and sink == :ots)
    |> Ash.Query.sort(recorded_at: :asc)
    |> Ash.read!()
  end
end
