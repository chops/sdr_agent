defmodule SdrAgent.SDR.TerminalSentRecoveryRaceTest do
  @moduledoc """
  L2 E1 under real concurrency (plan `notes/features/l2-e1-terminal-sent.org`
  items 15 and 16c; the `SdrAgent.Agents.LaunchAdmissionRaceTest` harness):
  every process works on its own non-sandboxed connection, and lock waits
  are observed in `pg_stat_activity`. `Agents.mark_terminal_run_sent_unknown/3`
  locks the run first, so it is serialized with an operator cancel and with
  a late settlement that waits on the same run lock. Committed rows are
  removed afterwards, in a verified test database only.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock
  alias SdrAgent.SDR.StaleRunSweeper

  @tables ~w(audit_accesses audit_events audit_chain_heads model_invocations
             model_call_allocations model_call_grants agent_runs failures operations
             agent_definitions tokens users payloads provenance_snapshots tenants)
  @t0 ~U[2026-10-20 12:00:00.000000Z]

  setup do
    SdrAgent.AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    on_exit(&Clock.unfreeze/0)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admin = AuditCase.human(:admin, tenant)
    AgentsFixtures.grant!(tenant, %{}, admin)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)

    attrs = "race" |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"r":"race"}))
    Clock.freeze(@t0)
    {:ok, reserved} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    {:ok, _} = Agents.admit_launch(reserved.id, :claude_cli_opus, actor: agent)
    sent = stored(reserved.id)
    Clock.freeze(DateTime.add(sent.sent_at, StaleRunSweeper.stale_after_seconds() + 1, :second))

    %{tenant: tenant, admin: admin, run: run, agent: agent, sent: sent}
  end

  # Asserted in the test process before any contender starts, so a missing
  # function fails the test itself, not a linked task.
  defp assert_e1_defined! do
    assert Code.ensure_loaded?(Agents) and
             function_exported?(Agents, :mark_terminal_run_sent_unknown, 3),
           "E1: Agents.mark_terminal_run_sent_unknown/3 is not defined"
  end

  defp e1(run_id, actor) do
    Function.capture(Agents, :mark_terminal_run_sent_unknown, 3).(
      run_id,
      StaleRunSweeper.stale_after_seconds(),
      actor: actor
    )
  end

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  # A transaction holding the run row until `:go`; `then` runs before commit.
  defp hold_run(ctx, then) do
    parent = self()

    Task.async(fn -> with_connection(fn -> held(ctx.run.id, parent, then) end) end)
  end

  defp held(run_id, parent, then) do
    Audit.transaction(fn ->
      lock!("SELECT id FROM agent_runs WHERE id = $1 FOR UPDATE", run_id)
      send(parent, :run_locked)
      receive do: (:go -> :ok)
      then.()
    end)
  end

  test "an operator cancel holding the run: the pass waits, then normalizes", ctx do
    assert_e1_defined!()
    holder = hold_run(ctx, fn -> {:ok, _} = Agents.cancel_run(ctx.run, actor: ctx.admin) end)
    assert_receive :run_locked, 10_000

    pass = Task.async(fn -> with_connection(fn -> e1(ctx.run.id, ctx.agent) end) end)
    await_lock_waiters(1)
    send(holder.pid, :go)

    assert {:ok, _} = Task.await(holder, 30_000)
    assert Task.await(pass, 30_000) == {:ok, 1}, "E1: the pass converts once the run is terminal"
    assert stored(ctx.sent.id).status == :unknown
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  test "a holder that leaves the run running: the pass finds it not terminal", ctx do
    assert_e1_defined!()
    holder = hold_run(ctx, fn -> :ok end)
    assert_receive :run_locked, 10_000

    pass = Task.async(fn -> with_connection(fn -> e1(ctx.run.id, ctx.agent) end) end)
    await_lock_waiters(1)
    send(holder.pid, :go)

    assert {:ok, :ok} = Task.await(holder, 30_000)
    assert Task.await(pass, 30_000) == {:error, :not_terminal}
    assert stored(ctx.sent.id).status == :sent
  end

  # Plan item 16c: the facade's re-read saw `sent` before recovery, then its
  # settlement (`Agents.complete_model_invocation/3`, the facade's next step)
  # waits on the run lock ahead of the pass. It gets the existing refusal
  # observed through the facade for a run stopped mid-call ("run is not
  # running"); the pass then normalizes the row.
  test "a settlement waiting on the run lock ahead of the pass", ctx do
    assert_e1_defined!()
    {:ok, _} = Agents.cancel_run(ctx.run, actor: ctx.admin)
    holder = hold_run(ctx, fn -> :ok end)
    assert_receive :run_locked, 10_000

    settle =
      Task.async(fn ->
        with_connection(fn ->
          Agents.complete_model_invocation(ctx.sent, AgentsFixtures.completion(),
            actor: ctx.agent
          )
        end)
      end)

    await_lock_waiters(1)
    pass = Task.async(fn -> with_connection(fn -> e1(ctx.run.id, ctx.agent) end) end)
    await_lock_waiters(2)
    send(holder.pid, :go)

    assert {:ok, :ok} = Task.await(holder, 30_000)

    assert {:error, %Ash.Error.Invalid{errors: errors}} = Task.await(settle, 30_000)

    assert Enum.any?(
             errors,
             &match?(
               %Ash.Error.Changes.InvalidAttribute{field: :status, message: "run is not running"},
               &1
             )
           )

    assert Task.await(pass, 30_000) == {:ok, 1}, "E1: the pass normalizes after the refusal"
    row = stored(ctx.sent.id)
    assert {row.status, row.response_sha256} == {:unknown, nil}

    refute ModelResultRelease
           |> Ash.Query.filter(model_invocation_id == ^row.id)
           |> Ash.exists?(authorize?: false)
  end

  defp lock!(sql, id), do: SQL.query!(SdrAgent.Repo, sql, [Ecto.UUID.dump!(id)])

  # Waits until `count` backends of this database wait on a row or tuple lock.
  defp await_lock_waiters(count, attempts \\ 200) do
    %{rows: [[waiting]]} =
      SQL.query!(
        SdrAgent.Repo,
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
          "AND wait_event_type = 'Lock'",
        []
      )

    cond do
      waiting >= count -> :ok
      attempts == 0 -> flunk("expected #{count} lock waiters, saw #{waiting}")
      true -> Process.sleep(25) && await_lock_waiters(count, attempts - 1)
    end
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
    database = SdrAgent.Repo.config()[:database]

    unless is_binary(database) and Regex.match?(~r/\Asdr_agent_test[a-z0-9_]*\z/, database) do
      raise "refusing to truncate #{inspect(database)}: not a test database"
    end

    SdrAgent.Repo.transaction(fn ->
      SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])
      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(@tables, ", ")} CASCADE", [])
    end)
  end
end
