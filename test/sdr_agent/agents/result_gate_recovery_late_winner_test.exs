defmodule SdrAgent.Agents.ResultGateRecoveryLateWinnerTest do
  @moduledoc """
  R0-07 slice C, row G7, review round 2 (`sandbox: false`, each side on its
  own connection): a standalone decider commits a release while recovery,
  having read none, waits for the chain head. Recovery honours that late
  winner as it honours one found first: a `:released` one returns its
  output, a bound withheld one stops the still-running run on its original
  cause. No second release, no new cause, and never `:release_raced`.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  import SdrAgent.AuditCase, only: [human: 2]

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations
  alias SdrAgent.Repo

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             oban_jobs agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    previous = AgentsFixtures.put_allowlist!()
    on_exit(fn -> Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous) end)

    %{run: run, agent: agent} = AgentsFixtures.operated_run(tenant)
    %{tenant: tenant, run: run, agent: agent, admin: human(:admin, tenant)}
  end

  test "a late :released winner is returned, not raced; the run keeps running", ctx do
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "late-released")
    link = AgentsFixtures.reconciled_link!(invocation, rec(ctx))

    decide = fn ->
      {:ok, release} =
        Agents.decide_result_release(
          %{
            model_invocation_id: invocation.id,
            disposition: :released,
            reason: :reconciled,
            wire_witness_link_id: link.id
          },
          actor: ctx.agent
        )

      release
    end

    {winner, recovery} = race(ctx, invocation, [{WireWitnessLink, link.id}], decide)

    assert {:released, %{id: id}, _output} = recovery
    assert id == winner.id
    assert releases(ctx) == [winner.id]
    assert run!(ctx).status == :running
  end

  test "a late bound withheld winner stops the run on its cause; nothing new", ctx do
    invocation = AgentsFixtures.claude_completed!(ctx.run, ctx.agent, "late-withheld")
    cause = GateFixtures.cause!(invocation, operation_id: ctx.run.operation_id)
    before = length(attention(ctx))

    decide = fn ->
      bindings = %{
        tenant_id: ctx.tenant.id,
        model_invocation_id: invocation.id,
        wire_witness_link_id: nil,
        receipt_id: cause.id
      }

      Prelocked.run(bindings, fn prelocked ->
        attrs = %{
          model_invocation_id: invocation.id,
          disposition: :withheld,
          reason: :gate_interrupted,
          gate_cause_id: cause.id,
          gate_classification: :interrupted
        }

        {:ok, release} =
          Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: prelocked)

        release
      end)
    end

    {winner, recovery} = race(ctx, invocation, [], decide)

    assert {:withheld, %{id: id}, run} = recovery
    assert id == winner.id
    assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
    assert run.attention_failure_id == cause.id
    assert releases(ctx) == [winner.id]
    assert length(attention(ctx)) == before
  end

  # The winner holds the invocation (and `shared` rows) FOR SHARE and the
  # chain head; recovery starts, reads no release and blocks at the head;
  # then the winner decides and commits.
  defp race(ctx, invocation, shared, decide) do
    parent = self()

    winner =
      Task.async(fn ->
        with_connection(fn ->
          {:ok, release} =
            Audit.transaction(fn ->
              lock_share(ModelInvocation, invocation.id, ctx.tenant.id)
              Enum.each(shared, fn {resource, id} -> lock_share(resource, id, ctx.tenant.id) end)
              {:ok, _} = Kernel.lock_head(ctx.tenant.id)
              send(parent, :head_held)

              receive do
                :decide -> decide.()
              after
                30_000 -> raise "never told to decide"
              end
            end)

          release
        end)
      end)

    assert_receive :head_held, 10_000

    recovery =
      Task.async(fn ->
        with_connection(fn ->
          Recovery.run(invocation, %{run_id: ctx.run.id, operation_id: ctx.run.operation_id})
        end)
      end)

    # Recovery is waiting on the winner's locks, not finished.
    assert Task.yield(recovery, 700) == nil
    send(winner.pid, :decide)
    winner_release = Task.await(winner, 30_000)
    {winner_release, Task.await(recovery, 30_000)}
  end

  defp lock_share(resource, id, tenant_id) do
    {:ok, %{}} =
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one()
  end

  defp rec(ctx), do: SdrAgent.Actor.system(:reconciler, ctx.tenant.id)

  defp run!(ctx) do
    {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    run
  end

  defp attention(ctx) do
    {:ok, all} = Operations.list_attention(actor: ctx.admin)
    all
  end

  defp releases(ctx) do
    auditor = SdrAgent.Actor.system(:auditor_cli, ctx.tenant.id)
    {:ok, all} = Agents.list_result_releases(actor: auditor)
    Enum.map(all, & &1.id)
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
