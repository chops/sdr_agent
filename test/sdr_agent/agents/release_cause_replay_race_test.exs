defmodule SdrAgent.Agents.ReleaseCauseReplayRaceTest do
  @moduledoc """
  R0-07 slice C, row R7-1 under real concurrency (`sandbox: false`): two
  finalizers decide the same withheld release with different gate causes,
  each in its own connection and transaction. They serialise; exactly one
  release and one withheld event commit, binding the winner's cause, and
  the loser gets a typed `ReleaseConflict` naming that cause.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Errors.ReleaseConflict
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Operations
  alias SdrAgent.Repo

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)
    invocation = AgentsFixtures.claude_completed!(run, agent, "replay-race")
    causes = for n <- 1..2, do: cause!(rec, invocation, n)
    %{tenant: tenant, agent: agent, invocation: invocation, causes: causes}
  end

  defp cause!(rec, invocation, n) do
    {:ok, failure} =
      Operations.open_failure(
        %{
          subject_resource: "SdrAgent.Agents.ModelInvocation",
          subject_id: invocation.id,
          class: :reconciliation_required,
          severity: :warning,
          message: "wire witness race test #{n}: model invocation needs operator review",
          retryable: false
        },
        actor: rec
      )

    failure
  end

  defp finalize(ctx, cause) do
    with_connection(fn ->
      Audit.transaction(fn ->
        {:ok, %{}} =
          ModelInvocation
          |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
          |> Ash.Query.filter(id == ^ctx.invocation.id)
          |> Ash.Query.lock("FOR SHARE")
          |> Ash.read_one()

        {:ok, _head} = Kernel.lock_head(ctx.tenant.id)
        Prelocked.run(bindings(ctx, cause), &decide(ctx, cause, &1))
      end)
    end)
  end

  defp bindings(ctx, cause),
    do: %{
      tenant_id: ctx.tenant.id,
      model_invocation_id: ctx.invocation.id,
      wire_witness_link_id: nil,
      receipt_id: cause.id
    }

  defp decide(ctx, cause, prelocked) do
    attrs = %{
      model_invocation_id: ctx.invocation.id,
      disposition: :withheld,
      reason: :witness_missing,
      gate_cause_id: cause.id,
      gate_classification: :inferred
    }

    case Agents.decide_result_release(attrs, actor: ctx.agent, prelocked: prelocked) do
      {:ok, release} -> release
      {:error, error} -> Repo.rollback(error)
    end
  end

  test "different causes: one release and one event commit; the loser conflicts", ctx do
    results =
      ctx.causes
      |> Enum.map(fn cause -> Task.async(fn -> finalize(ctx, cause) end) end)
      |> Task.await_many(60_000)

    {wins, losses} = Enum.split_with(results, &match?({:ok, _}, &1))
    assert [{:ok, release}] = wins
    assert [{:error, %ReleaseConflict{existing_id: id, existing_cause_id: bound}}] = losses
    assert id == release.id

    aud = SdrAgent.Actor.system(:auditor_cli, ctx.tenant.id)
    {:ok, [_one]} = Agents.list_result_releases(actor: aud)
    {:ok, events} = Audit.list_events(actor: aud)
    assert [event] = Enum.filter(events, &(&1.event_type == "model.result.withheld"))
    assert event.payload["arguments"]["gate_cause_id"] == bound
    assert bound in Enum.map(ctx.causes, & &1.id)
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
