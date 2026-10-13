defmodule SdrAgent.Agents.ResultGateRecoveryRaceTest do
  @moduledoc """
  R0-07 slice C, rows G5 and G7 under real concurrency (`sandbox: false`,
  each side on its own connection): the facade's finalization (with its
  one recovery attempt) races run recovery (`ResultGate.Recovery.run/3`)
  for the same completed generation-2 invocation. Whichever wins:

    * exactly one release is written;
    * the run is stopped once, with no crash;
    * the loser respects the winner's release, and both report it.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.GateFixtures
  alias SdrAgent.Repo

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             oban_jobs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    root = GateFixtures.root!()

    on_exit(fn ->
      File.rm_rf!(root)
      with_connection(&cleanup!/0)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{tenant: tenant, root: root}
  end

  defp contender(fun) do
    parent = self()

    Task.async(fn ->
      with_connection(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> fun.()
        after
          30_000 -> raise "never started"
        end
      end)
    end)
  end

  # The facade's step 3 and its one G7 recovery (ResultGate.gate/3 without
  # the wait), for the receipt of the gate's own reconcile.
  defp facade(invocation, gate, receipt) do
    case ResultGate.finalize(invocation, gate, {:timeout, receipt}) do
      {:error, _refused} -> Recovery.run(invocation, gate)
      decided -> decided
    end
  end

  for round <- 1..3 do
    test "round #{round}: one release, one stop, no crash; both report it", ctx do
      %{run: run, agent: agent} = AgentsFixtures.operated_run(ctx.tenant)
      invocation = AgentsFixtures.claude_completed!(run, agent, "race-#{unquote(round)}")
      gate = %{run_id: run.id, operation_id: run.operation_id}

      {:timeout, receipt} = ResultGate.await(invocation, gate, store_root: ctx.root)

      tasks = [
        contender(fn -> facade(invocation, gate, receipt) end),
        contender(fn -> Recovery.run(invocation, gate) end)
      ]

      for _ <- tasks, do: assert_receive({:ready, _pid}, 10_000)
      Enum.each(tasks, &send(&1.pid, :go))
      results = Task.await_many(tasks, 60_000)

      aud = SdrAgent.Actor.system(:auditor_cli, ctx.tenant.id)
      {:ok, releases} = Agents.list_result_releases(actor: aud)
      assert [release] = Enum.filter(releases, &(&1.model_invocation_id == invocation.id))

      for result <- results do
        assert {:withheld, %{id: id}, %{status: :failed}} = result
        assert id == release.id
      end

      {:ok, events} = Audit.list_events(actor: aud)

      stops =
        Enum.filter(events, &(&1.event_type == "agents.run.failed" and &1.agent_run_id == run.id))

      assert [stop] = stops
      refute stop.payload["changes"]["status_reason"] == "crash"
    end
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

      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT t FROM unnest($1::text[]) t WHERE to_regclass(t) IS NOT NULL",
          [@tables]
        )

      SQL.query!(Repo, "TRUNCATE #{Enum.join(List.flatten(rows), ", ")} CASCADE", [])
    end)
  end
end
