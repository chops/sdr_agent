defmodule SdrAgent.Agents.ReleasePrelockedSavepointTest do
  @moduledoc """
  R0-07 slice A code review MF1 (Codex REQUEST_CHANGES at 5ae6549): a
  `ReleaseDecision.Prelocked` context must not survive a `ROLLBACK TO
  SAVEPOINT` that released the locks it vouches for.

  On a real connection (`sandbox: false`): the finalizer stand-in takes its
  dependent locks after `SAVEPOINT probe`, establishes the context, then
  rolls back to the savepoint. Another connection can now lock the
  invocation (the lock really is gone), and the context is refused: no
  release, no event. Nested variants: a rollback to a savepoint taken after
  the locks but before the context is also refused (conservative); a
  rollback to a savepoint taken after the context leaves the locks and the
  context intact, and the decision proceeds without a lock clause.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleaseDecision.Prelocked
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo

  @tables ~w(model_result_releases wire_witness_links model_invocations model_call_allocations
             model_call_grants anchor_sink_receipts audit_exports audit_anchors
             audit_signing_keys audit_accesses audit_events audit_chain_heads
             retention_markers decisions tool_invocations agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    previous = AgentsFixtures.put_allowlist!()

    on_exit(fn ->
      Application.put_env(:sdr_agent, SdrAgent.Agents.Witness, previous)
      with_connection(&cleanup!/0)
    end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    rec = SdrAgent.Actor.system(:reconciler, tenant.id)
    invocation = AgentsFixtures.claude_completed!(run, agent, "sp-1")
    link = AgentsFixtures.reconciled_link!(invocation, rec)
    %{tenant: tenant, agent: agent, invocation: invocation, link: link}
  end

  defp attrs(ctx),
    do: %{
      model_invocation_id: ctx.invocation.id,
      disposition: :released,
      reason: :reconciled,
      wire_witness_link_id: ctx.link.id
    }

  defp bindings(ctx),
    do: %{
      tenant_id: ctx.tenant.id,
      model_invocation_id: ctx.invocation.id,
      wire_witness_link_id: ctx.link.id,
      receipt_id: nil
    }

  defp sql!(statement), do: SQL.query!(Repo, statement, [])

  defp lock_dependents!(ctx) do
    for {resource, id} <- [{ModelInvocation, ctx.invocation.id}, {WireWitnessLink, ctx.link.id}] do
      {:ok, %{}} =
        resource
        |> Ash.Query.for_read(:read, %{}, Kernel.opts(ctx.tenant.id))
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.lock("FOR SHARE")
        |> Ash.read_one()
    end

    {:ok, _head} = Kernel.lock_head(ctx.tenant.id)
  end

  # Whether another connection can take the invocation row FOR UPDATE now.
  defp lockable_elsewhere?(ctx) do
    id = Ecto.UUID.dump!(ctx.invocation.id)

    Task.async(fn -> with_connection(fn -> lock_attempt(id) end) end)
    |> Task.await(10_000)
    |> then(&(&1 == {:error, :acquired}))
  end

  defp lock_attempt(id), do: Repo.transaction(fn -> try_lock(id) end)

  defp try_lock(id) do
    case SQL.query(Repo, "SELECT 1 FROM model_invocations WHERE id = $1 FOR UPDATE NOWAIT", [id]) do
      {:ok, _} -> Repo.rollback(:acquired)
      {:error, _} -> Repo.rollback(:busy)
    end
  end

  defp nothing_written(ctx) do
    aud = SdrAgent.Actor.system(:auditor_cli, ctx.tenant.id)
    assert {:ok, []} = Agents.list_result_releases(actor: aud)
    {:ok, events} = Audit.list_events(actor: aud)
    refute Enum.any?(events, &(&1.event_type =~ "model.result."))
  end

  test "ROLLBACK TO a savepoint before the locks: the locks are gone and the context refused",
       ctx do
    result =
      Audit.transaction(fn ->
        sql!("SAVEPOINT probe")
        lock_dependents!(ctx)

        Prelocked.run(bindings(ctx), fn context ->
          refute lockable_elsewhere?(ctx)
          sql!("ROLLBACK TO SAVEPOINT probe")
          assert lockable_elsewhere?(ctx)

          assert {:error, :prelocked_context_refused} = Prelocked.verify(context)

          Agents.decide_result_release(attrs(ctx), actor: ctx.agent, prelocked: context)
        end)
      end)

    assert {:error, _} = result
    nothing_written(ctx)
  end

  test "a rollback to a savepoint after the locks but before the context is refused too",
       ctx do
    result =
      Audit.transaction(fn ->
        lock_dependents!(ctx)
        sql!("SAVEPOINT between")

        Prelocked.run(bindings(ctx), fn context ->
          sql!("ROLLBACK TO SAVEPOINT between")
          # The locks were taken before the savepoint and are still held,
          # but the context cannot tell, so it is refused (conservative).
          refute lockable_elsewhere?(ctx)
          assert {:error, :prelocked_context_refused} = Prelocked.verify(context)
          :refused
        end)
      end)

    assert {:ok, :refused} = result
    nothing_written(ctx)
  end

  test "a rollback to a savepoint taken after the context keeps it (and its locks)", ctx do
    result =
      Audit.transaction(fn ->
        lock_dependents!(ctx)

        Prelocked.run(bindings(ctx), fn context ->
          sql!("SAVEPOINT after_context")
          sql!("ROLLBACK TO SAVEPOINT after_context")
          refute lockable_elsewhere?(ctx)
          assert {:ok, _} = Prelocked.verify(context)

          case Agents.decide_result_release(attrs(ctx), actor: ctx.agent, prelocked: context) do
            {:ok, release} -> release
            {:error, error} -> Repo.rollback(error)
          end
        end)
      end)

    assert {:ok, %{disposition: :released}} = result
  end

  test "a nested savepoint rolled back inside a rolled-back outer one is refused", ctx do
    result =
      Audit.transaction(fn ->
        sql!("SAVEPOINT outer_sp")
        lock_dependents!(ctx)
        sql!("SAVEPOINT inner_sp")

        Prelocked.run(bindings(ctx), fn context ->
          sql!("ROLLBACK TO SAVEPOINT inner_sp")
          sql!("ROLLBACK TO SAVEPOINT outer_sp")
          assert lockable_elsewhere?(ctx)
          assert {:error, :prelocked_context_refused} = Prelocked.verify(context)
          :refused
        end)
      end)

    assert {:ok, :refused} = result
    nothing_written(ctx)
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
