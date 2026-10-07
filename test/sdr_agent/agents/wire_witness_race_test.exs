defmodule SdrAgent.Agents.WireWitnessRaceTest do
  @moduledoc """
  C4 under real concurrency (`sandbox: false`, as S3's concurrency suite):
  REC processes race to supersede the same WireWitnessLink head, each in
  its own connection and transaction. Exactly one successor commits; the
  lineage stays a single chain and the audit chain stays valid. Committed
  rows are removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit

  @tables ~w(wire_witness_links anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers qualification_evidences qualifications evidence_claims
             research_artifacts campaign_enrollments leads campaigns sequence_steps sequences
             contacts accounts icp_definitions decisions tool_invocations model_invocations
             agent_runs failures operations agent_definitions tokens users payloads
             provenance_snapshots tenants)

  @racers 8

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    :ok
  end

  test "concurrent supersedes of one head: exactly one commits, no fork" do
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)

    attrs = AgentsFixtures.model_attrs("race-1") |> Map.put(:provider, :claude_cli)
    {:ok, invocation} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    {:ok, invocation} = Agents.mark_model_invocation_sent(invocation, actor: agent)

    {:ok, invocation} =
      Agents.complete_model_invocation(invocation, AgentsFixtures.completion(), actor: agent)

    ref = Ash.UUIDv7.generate()
    assert {:ok, root} = Agents.link_wire_witness(link(invocation, ref, nil), actor: rec)

    results =
      1..@racers
      |> Enum.map(fn _ ->
        Task.async(fn ->
          with_connection(fn ->
            Agents.link_wire_witness(link(invocation, ref, root.id), actor: rec)
          end)
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ash.Error.Invalid{}}, &1)) == @racers - 1

    {:ok, links} = Agents.list_wire_witness_links(invocation.id, actor: rec)
    assert length(links) == 2
    assert {:ok, [current]} = Agents.current_wire_witness_links(invocation.id, actor: rec)
    assert current.supersedes_id == root.id

    aud = SdrAgent.Actor.system(:auditor_cli, tenant.id)
    {:ok, report} = Audit.verify_chain(actor: aud)
    assert report.valid?, inspect(report.issues)

    assert length(
             Enum.filter(
               Audit.list_events(actor: aud) |> elem(1),
               &(&1.event_type ==
                   "agents.witness.linked")
             )
           ) ==
             2
  end

  defp link(invocation, ref, supersedes_id) do
    evidence = %{
      "witness_schema" => 1,
      "projection_version" => "claude-message-json/1+prompt-builder/1",
      "reason_codes" => ["propagated_id_match"]
    }

    %{
      model_invocation_id: invocation.id,
      proxy_record_ref: ref,
      link_status: :inferred,
      method: :propagated_id,
      supersedes_id: supersedes_id,
      evidence:
        if(supersedes_id, do: Map.put(evidence, "supersede_reason", "race"), else: evidence)
    }
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(SdrAgent.Repo)
    end
  end

  defp cleanup! do
    SdrAgent.Repo.transaction(fn ->
      SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])

      %{rows: rows} =
        SQL.query!(
          SdrAgent.Repo,
          "SELECT t FROM unnest($1::text[]) t WHERE to_regclass(t) IS NOT NULL",
          [@tables]
        )

      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(List.flatten(rows), ", ")} CASCADE", [])
    end)
  end
end
