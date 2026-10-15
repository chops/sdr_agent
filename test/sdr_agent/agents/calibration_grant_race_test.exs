defmodule SdrAgent.Agents.CalibrationGrantRaceTest do
  @moduledoc """
  R0-07 slice E d2a (Codex 01a13625): G-R0 uniqueness is re-checked at the
  admission instant. A bound reservation discovers its candidate grants
  and then waits for their share locks; while it waits, a second
  G-R0-shaped grant commits. Under the chain head the reservation observes
  the tenant's grants afresh (a read, never a new lock) and refuses with
  `:calibration_grant_mismatch`: no invocation, no charge, no fallback.
  Every process uses its own non-sandboxed connection; committed rows are
  removed afterwards with triggers disabled.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Clock

  @now ~U[2026-10-15 12:00:00.000000Z]

  @tables ~w(audit_accesses audit_events audit_chain_heads model_result_releases
             wire_witness_links model_invocations model_call_allocations model_call_grants
             agent_runs failures operations oban_jobs agent_definitions tokens users
             payloads provenance_snapshots tenants)

  setup do
    AdmissionFixtures.admit_tuples!()
    :ok = Sandbox.checkout(SdrAgent.Repo, sandbox: false)
    cleanup!()
    on_exit(fn -> with_connection(&cleanup!/0) end)
    Clock.freeze(@now)
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    admin = AuditCase.human(:admin, tenant)
    grant = g_r0!(tenant, admin, "G-R0")
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, usage_origin: :proof)

    Code.ensure_loaded!(Agents)

    assert function_exported?(Agents, :select_calibration_grant, 3),
           "Agents.select_calibration_grant/3 is not defined"

    {:ok, binding} = Agents.select_calibration_grant(tenant.id, :claude_cli_opus, actor: agent)
    %{tenant: tenant, admin: admin, grant: grant, run: run, agent: agent, binding: binding}
  end

  test "a second G-R0 grant committed after candidate discovery refuses", ctx do
    parent = self()

    # Holds the bound grant row, so the reservation discovers its candidate
    # ids and then waits for their share locks.
    holder =
      Task.async(fn ->
        with_connection(fn ->
          SdrAgent.Repo.transaction(fn ->
            SQL.query!(
              SdrAgent.Repo,
              "SELECT id FROM model_call_grants WHERE id = $1 FOR UPDATE",
              [
                Ecto.UUID.dump!(ctx.grant.id)
              ]
            )

            send(parent, :grant_held)
            receive do: (:go -> :ok)
          end)
        end)
      end)

    assert_receive :grant_held, 10_000
    reservation = Task.async(fn -> reserve(ctx) end)
    await_lock_waiters(1)

    # Committed while the reservation waits, after its candidate discovery.
    late =
      Task.async(fn -> with_connection(fn -> g_r0!(ctx.tenant, ctx.admin, "G-R0-LATE") end) end)

    assert %{id: _} = Task.await(late, 30_000)

    send(holder.pid, :go)
    assert {:ok, _} = Task.await(holder, 30_000)

    result = Task.await(reservation, 30_000)

    assert match?({:error, %Refused{reason: :calibration_grant_mismatch}}, result),
           inspect(result)

    assert {:ok, []} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    assert AuditCase.events_of_type(ctx.tenant, "model.invocation.reserved") == []
    assert {:ok, %{valid?: true}} = Audit.verify_chain(actor: auditor(ctx))
  end

  defp reserve(ctx) do
    with_connection(fn ->
      Clock.freeze(@now)

      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(ctx.run, AgentsFixtures.claude_attrs("race-bound"),
          actor: ctx.agent,
          calibration:
            CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry(),
              claim: Ash.UUIDv7.generate(),
              binding: ctx.binding
            )
        )
      end)
    end)
  end

  defp g_r0!(tenant, admin, name) do
    Clock.freeze(@now)

    AgentsFixtures.grant!(
      tenant,
      %{
        name: name,
        profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
        total_attempts: 4,
        starts_at: ~U[2026-10-12 00:00:00.000000Z],
        expires_at: ~U[2026-10-19 05:59:00.000000Z],
        allocations: [
          %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_opus},
          %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
        ]
      },
      admin
    )
  end

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
    SdrAgent.Repo.transaction(fn ->
      SQL.query!(SdrAgent.Repo, "SET LOCAL session_replication_role = replica", [])
      SQL.query!(SdrAgent.Repo, "TRUNCATE #{Enum.join(@tables, ", ")} CASCADE", [])
    end)
  end
end
