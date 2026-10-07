defmodule SdrAgent.LiveEventsTest do
  @moduledoc """
  Commit-time notifications for live views (ADR-0012), on real
  (non-sandboxed) connections: an appended AuditEvent is relayed to its
  tenant's PubSub topic only once its transaction commits — never for a
  rollback — carrying ids and type only. The committed rows are removed
  afterwards with triggers disabled (as in `SdrAgent.Audit.ConcurrencyTest`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit
  alias SdrAgent.LiveEvents
  alias SdrAgent.Repo

  @tables ~w(delivery_receipts delivery_operations send_quota_days approvals
             revision_citations draft_revisions drafts suppressions anchor_sink_receipts audit_exports audit_anchors audit_signing_keys
             audit_accesses audit_events audit_chain_heads retention_markers
             qualification_evidences qualifications evidence_claims research_artifacts
             campaign_enrollments leads campaigns sequence_steps sequences contacts accounts
             icp_definitions decisions tool_invocations model_invocations agent_runs
             failures operations agent_definitions tokens users payloads
             provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    :ok = LiveEvents.subscribe(tenant.id)
    %{tenant: tenant, kernel: struct(SdrAgent.Actor, type: :kernel, tenant_id: tenant.id)}
  end

  defp event(type, subject_id \\ "subject-1") do
    %{
      event_type: type,
      category: :system,
      subject_resource: "Test",
      subject_id: subject_id,
      action: "test",
      payload: %{n: 1}
    }
  end

  test "a committed append reaches the tenant topic with ids and type only", ctx do
    {:ok, appended} = Audit.append(event("test.live"), actor: ctx.kernel)

    assert_receive {:sdr_audit_event, %{event_type: "test.live"} = live}, 5_000

    tenant_id = ctx.tenant.id

    assert %{
             tenant_id: ^tenant_id,
             category: "system",
             subject_resource: "Test",
             subject_id: "subject-1",
             agent_run_id: nil
           } = live

    assert live.sequence == appended.sequence

    assert live |> Map.keys() |> Enum.sort() ==
             ~w(agent_run_id category event_type sequence subject_id subject_resource tenant_id)a
  end

  test "a rolled-back append is never announced", ctx do
    {:error, :rolled_back} =
      Repo.transaction(fn ->
        {:ok, _} = Audit.append(event("test.rolled_back"), actor: ctx.kernel)
        Repo.rollback(:rolled_back)
      end)

    {:ok, _} = Audit.append(event("test.after"), actor: ctx.kernel)

    assert_receive {:sdr_audit_event, %{event_type: "test.after"}}, 5_000
    refute_received {:sdr_audit_event, %{event_type: "test.rolled_back"}}
  end

  test "an append inside a larger transaction is announced only after its commit", ctx do
    parent = self()

    {:ok, :ok} =
      Repo.transaction(fn ->
        {:ok, _} = Audit.append(event("test.in_transaction"), actor: ctx.kernel)
        send(parent, :appended)
        refute_receive {:sdr_audit_event, %{event_type: "test.in_transaction"}}, 300
        :ok
      end)

    assert_received :appended
    assert_receive {:sdr_audit_event, %{event_type: "test.in_transaction"}}, 5_000
  end

  test "a long subject ref (an access list of ids) is omitted, not truncated", ctx do
    long = Enum.map_join(1..5, ",", fn _ -> Ecto.UUID.generate() end)
    {:ok, _} = Audit.append(event("test.long_subject", long), actor: ctx.kernel)

    assert_receive {:sdr_audit_event, %{event_type: "test.long_subject", subject_id: nil}},
                   5_000
  end

  test "malformed payloads decode to :error" do
    assert LiveEvents.event("not json") == :error
    assert LiveEvents.event(~s({"event_type": "x"})) == :error
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp cleanup! do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SET LOCAL session_replication_role = replica", [])
      SQL.query!(Repo, "TRUNCATE #{Enum.join(@tables, ", ")} CASCADE", [])
    end)
  end
end
