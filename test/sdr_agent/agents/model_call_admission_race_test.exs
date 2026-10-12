defmodule SdrAgent.Agents.ModelCallAdmissionRaceTest do
  @moduledoc """
  Real concurrency for C9 admission (as `SdrAgent.Audit.ConcurrencyTest`):
  every process reserves on its own non-sandboxed connection, so the
  reservations genuinely race for the run and chain-head locks. The last
  unit of an allocation is charged exactly once, and concurrent refusals of
  the same key open exactly one Failure. Committed rows are removed
  afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Operations.Failure

  @tables ~w(audit_accesses audit_events audit_chain_heads model_invocations
             model_call_allocations model_call_grants agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{tenant: tenant}
  end

  test "concurrent reservations for the last unit: exactly one wins", ctx do
    grant =
      AgentsFixtures.grant!(ctx.tenant, %{
        total_attempts: 1,
        allocations: [%{key: :b1, applies_to: [:b1], attempts: 1}]
      })

    runs = for _ <- 1..6, do: AgentsFixtures.running_run(ctx.tenant)

    results =
      runs
      |> Enum.with_index()
      |> Enum.map(fn {%{run: run, agent: agent}, n} ->
        Task.async(fn ->
          with_connection(fn ->
            Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("last-#{n}"),
              actor: agent
            )
          end)
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)

    assert Enum.count(results, &(&1 == {:error, {:budget_exhausted, :grant}})) == 5,
           inspect(results)

    charged =
      Agents.ModelInvocation
      |> Ash.Query.filter(grant_id == ^grant.id)
      |> Ash.count!(authorize?: false)

    assert charged == 1
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "concurrent refusals of the same key open one Failure", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

    results =
      1..6
      |> Enum.map(fn n ->
        Task.async(fn ->
          with_connection(fn ->
            Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("refused-#{n}"),
              actor: agent
            )
          end)
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.all?(results, &(&1 == {:error, :no_eligible_grant})), inspect(results)

    failures =
      Failure
      |> Ash.Query.filter(class == :budget_exhausted and subject_id == ^run.id)
      |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))

    assert length(failures) == 1

    {:ok, events} = Audit.list_events(actor: auditor(ctx))
    assert Enum.count(events, &(&1.event_type == "model.reservation.refused")) == 6
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  defp auditor(ctx), do: struct(SdrAgent.Actor, type: :auditor_cli, tenant_id: ctx.tenant.id)

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
      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(@tables, ", ")} CASCADE", [])
    end)
  end
end
