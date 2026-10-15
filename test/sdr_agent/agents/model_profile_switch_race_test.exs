defmodule SdrAgent.Agents.ModelProfileSwitchRaceTest do
  @moduledoc """
  C2-02a (#52, slice a), on independent connections: the first-row
  upsert race and the lock order of a switch request
  (`docs/product/r0/c2-02a-interface.md`, "The first setting row"; the
  probe evidence is recorded there). Every process uses its own
  non-sandboxed connection. Committed rows are removed afterwards with
  triggers disabled, as in `SdrAgent.Audit.ConcurrencyTest`.

  RED: the functions don't exist on main; calls are presence-guarded.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Repo

  @tables ~w(model_profile_switches model_profile_settings audit_accesses audit_events
             audit_chain_heads model_call_allocations model_call_grants failures operations
             model_invocations agent_runs agent_definitions tokens users payloads
             provenance_snapshots tenants)

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)

    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admins = for _ <- 1..2, do: SdrAgent.AuditCase.new_human(:admin, tenant)

    %{
      tenant: tenant,
      admins: admins,
      runtime: struct(SdrAgent.Actor, type: :model_runtime, tenant_id: tenant.id)
    }
  end

  defp call(fun, args) do
    assert function_exported?(Agents, fun, length(args)),
           "C2-02a: SdrAgent.Agents.#{fun}/#{length(args)} is not implemented"

    apply(Agents, fun, args)
  end

  defp request(admin, generation),
    do:
      call(:request_profile_switch, [
        %{to_profile_id: :claude_cli_sonnet, expected_revision: 1, server_generation: generation},
        [actor: admin]
      ])

  defp events(tenant, type) do
    Repo.query!(
      "SELECT count(*) FROM audit_events WHERE tenant_id = $1 AND event_type = $2",
      [Ecto.UUID.dump!(tenant.id), type]
    ).rows
  end

  test "two concurrent first requests: one setting, one initialization, one pending switch",
       ctx do
    assert function_exported?(Agents, :request_profile_switch, 2),
           "C2-02a: SdrAgent.Agents.request_profile_switch/2 is not implemented"

    results =
      ctx.admins
      |> Enum.with_index(1)
      |> Enum.map(fn {admin, generation} ->
        Task.async(fn -> with_connection(fn -> request(admin, generation) end) end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1

    assert [[1, "claude_cli_opus"]] =
             Repo.query!("SELECT revision, desired_profile_id FROM model_profile_settings").rows

    assert events(ctx.tenant, "model.profile.setting_initialized") == [[1]]
    assert events(ctx.tenant, "model.profile.switch_requested") == [[1]]
    assert [[1]] = Repo.query!("SELECT count(*) FROM model_profile_switches").rows
  end

  test "a request waits on the setting row before taking the chain head", ctx do
    [admin, _] = ctx.admins
    assert {:ok, first} = request(admin, 1)

    assert {:ok, _} =
             call(:fail_profile_switch, [
               first,
               %{server_generation: 1, failure_reason: "test"},
               [actor: ctx.runtime]
             ])

    parent = self()

    holder =
      Task.async(fn ->
        with_connection(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT 1 FROM model_profile_settings FOR UPDATE")
            send(parent, :holding)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :holding, 10_000

    waiter =
      Task.async(fn ->
        with_connection(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:waiter, pid})
          request(admin, 2)
        end)
      end)

    assert_receive {:waiter, waiter_pid}, 10_000

    waiting =
      Enum.find_value(1..100, fn _ ->
        Process.sleep(20)

        case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [
               waiter_pid
             ]).rows do
          [["Lock"]] -> true
          _ -> nil
        end
      end)

    assert waiting, "the request did not wait on the held setting row"

    holds_head? =
      Repo.query!(
        "SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
          "WHERE l.pid = $1 AND l.granted AND c.relname = 'audit_chain_heads' AND l.mode IN ('RowShareLock', 'RowExclusiveLock')",
        [waiter_pid]
      ).rows

    assert holds_head? == [[0]], "the request held the chain head while waiting on the setting"

    send(holder.pid, :release)
    Task.await(holder, 10_000)
    assert {:ok, %{status: :pending}} = Task.await(waiter, 10_000)
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
    existing =
      Enum.filter(@tables, fn table ->
        Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table]).rows == [[true]]
      end)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")
      Repo.query!("TRUNCATE #{Enum.join(existing, ", ")} CASCADE")
    end)
  end
end
