defmodule SdrAgent.Inbox.CommandRaceTest do
  @moduledoc """
  C1-03 real-connection races. pg_blocking_pids proves each contender is
  waiting on the held source lock before a change/revocation or release.
  Fixtures and cleanup are confined to this suite's owned synthetic tenant
  in the explicitly verified test database; all contenders are joined.
  """
  use ExUnit.Case, async: false

  import SdrAgent.InboxCommandFixtures
  import SdrAgent.InboxFixtures
  import SdrAgent.OutreachFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Accounts
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.InboxConcurrencyFixtures, as: Connections
  alias SdrAgent.Repo
  alias SdrAgent.Sales

  @moduletag timeout: 120_000
  @applied {:ok, %{outcome: :applied, refresh?: true}}
  @tables ~w(approvals revision_citations draft_revisions drafts suppressions
    audit_accesses audit_events audit_chain_heads retention_markers
    qualification_evidences qualifications evidence_claims research_artifacts
    campaign_enrollments leads campaigns sequence_steps sequences contacts accounts
    icp_definitions decisions tool_invocations model_invocations agent_runs
    failures operations agent_definitions users payloads settings_revisions
    run_settings_snapshots delivery_operations)

  test "source edit committed while command waits is not overwritten by the earlier token" do
    require_command!()

    fixture!(fn ctx ->
      {_, request} = displayed!(ctx.session, ctx.draft, :edit_draft, edit(ctx, "My old edit"))
      holder = hold!(ctx)
      contender = start_command(ctx, ctx.session, request)

      try do
        blocked!(holder.backend, contender.backend)

        release!(holder, fn ->
          assert {:ok, _} =
                   SdrAgent.Outreach.edit_draft(ctx.draft, edit(ctx, "Concurrent edit"),
                     actor: ctx.admin
                   )
        end)

        error!(Task.await(contender.task, 10_000), :stale, %{change: :revision})
        revision = revision!(ctx, draft!(ctx, ctx.draft).current_revision_id)
        assert revision.subject == "Concurrent edit"
        assert length(SdrAgent.AuditCase.events_of_type(ctx.tenant, "outreach.draft.edited")) == 1
      after
        stop!(holder.task)
        stop!(contender.task)
      end
    end)
  end

  test "recipient changed during the draft-lock wait invalidates even an unchanged revision" do
    require_command!()

    fixture!(fn ctx ->
      {_, request} =
        displayed!(ctx.session, ctx.draft, :reject_draft, %{reason: "Old recipient review"})

      holder = hold!(ctx)
      contender = start_command(ctx, ctx.session, request)

      try do
        blocked!(holder.backend, contender.backend)
        contact = contact!(ctx, ctx.lead)

        assert {:ok, _} =
                 Sales.update(contact, :change_email, %{email: "race-new@example.test"},
                   actor: ctx.admin
                 )

        before = effects!(ctx, ctx.draft)
        release!(holder)
        error!(Task.await(contender.task, 10_000), :stale, %{change: :recipient})
        assert effects!(ctx, ctx.draft) == before
      after
        stop!(holder.task)
        stop!(contender.task)
      end
    end)
  end

  for change <- [:revoke, :demote] do
    test "#{change} during source lock wait is rechecked using the real session" do
      require_command!()

      fixture!(fn ctx ->
        session = session!(ctx.reviewer)
        {_, request} = displayed!(session, ctx.draft, :approve_capture)
        before = effects!(ctx, ctx.draft)
        holder = hold!(ctx)
        contender = start_command(ctx, session, request)

        try do
          blocked!(holder.backend, contender.backend)

          case unquote(change) do
            :revoke ->
              assert :ok =
                       AshAuthentication.TokenResource.Actions.revoke(
                         SdrAgent.Accounts.Token,
                         session
                       )

            :demote ->
              assert {:ok, _} = Accounts.change_role(ctx.reviewer, :auditor, actor: ctx.admin)
          end

          release!(holder)
          error!(Task.await(contender.task, 10_000), :forbidden)
          assert effects!(ctx, ctx.draft) == before
        after
          stop!(holder.task)
          stop!(contender.task)
        end
      end)
    end
  end

  for action <- [:approve_capture, :edit_draft, :reject_draft] do
    test "two independently blocked #{action} commands produce one source mutation" do
      require_command!()

      fixture!(fn ctx ->
        {_, request} =
          displayed!(ctx.session, ctx.draft, unquote(action), args(ctx, unquote(action)))

        holder = hold!(ctx)
        a = start_command(ctx, ctx.session, request)
        b = start_command(ctx, ctx.session, request)

        try do
          blocked!(holder.backend, a.backend)
          blocked!(holder.backend, b.backend)
          release!(holder)
          results = [Task.await(a.task, 10_000), Task.await(b.task, 10_000)]
          assert Enum.count(results, &(&1 == @applied)) == 1
          assert [stale] = Enum.reject(results, &(&1 == @applied))
          error!(stale, :stale)
          assert_mutation!(ctx, unquote(action))
        after
          stop!(holder.task)
          stop!(a.task)
          stop!(b.task)
        end
      end)
    end
  end

  defp fixture!(fun) do
    Connections.connection(fn ->
      Connections.assert_test_database!()
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM tenants")
      Clock.freeze(DateTime.add(Fixtures.epoch(), 1, :day))

      try do
        assert {:ok, _} = SdrAgent.Demo.Seed.run()
        assert {:ok, tenant_id} = Audit.Kernel.singleton_tenant_id()
        seeder = SdrAgent.Actor.system(:seeder, tenant_id, "c103-race")
        assert {:ok, admin} = Accounts.get_user(hd(Fixtures.users()).id, actor: seeder)

        assert {:ok, tenant} =
                 Ash.get(SdrAgent.Audit.Tenant, tenant_id, Audit.Kernel.opts(tenant_id))

        ctx = %{
          tenant: tenant,
          admin: admin,
          agent: SdrAgent.Actor.system(:agent_runtime, tenant_id),
          campaign_id: Fixtures.campaign().id,
          task_supervisor: start_supervised!(Task.Supervisor)
        }

        # Only fixture generation shares a connection with its inline Oban
        # work. Subject contenders below each check out their own connection.
        try do
          :ok = Sandbox.mode(Repo, {:shared, self()})
          drafted = drafted!(ctx)
          manual_connection!()
          ctx = Map.merge(ctx, drafted)
          ctx = Map.merge(ctx, %{reviewer: operator!(ctx, :reviewer), session: session!(admin)})
          fun.(ctx)
        after
          manual_connection!()
          cleanup!(ctx)
        end
      after
        Sandbox.mode(Repo, :manual)
        Clock.unfreeze()
      end
    end)
  end

  defp hold!(ctx) do
    parent = self()
    tag = make_ref()

    task =
      Task.Supervisor.async_nolink(ctx.task_supervisor, fn ->
        Connections.connection(fn -> held_transaction(ctx, parent, tag) end)
      end)

    assert_receive {^tag, :held, backend}, 5_000
    %{task: task, tag: tag, backend: backend}
  end

  defp held_transaction(ctx, parent, tag) do
    Audit.transaction(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

      Repo.query!("SELECT id FROM drafts WHERE id = $1 AND tenant_id = $2 FOR UPDATE", [
        Ecto.UUID.dump!(ctx.draft.id),
        Ecto.UUID.dump!(ctx.tenant.id)
      ])

      send(parent, {tag, :held, backend})

      receive do
        {^tag, :release, work} ->
          work.()
          :released
      after
        15_000 -> Repo.rollback(:holder_not_released)
      end
    end)
  end

  defp manual_connection! do
    # Switching out of shared mode checks existing proxies back in.
    # Re-acquire the parent's independent real connection explicitly.
    :ok = Sandbox.mode(Repo, :manual)
    assert Sandbox.checkout(Repo, sandbox: false) in [:ok, {:already, :owner}]
  end

  defp release!(holder, work \\ fn -> :ok end) do
    send(holder.task.pid, {holder.tag, :release, work})
    assert {:ok, :released} = Task.await(holder.task, 10_000)
  end

  defp start_command(ctx, session, request) do
    parent = self()
    tag = make_ref()

    task =
      Task.Supervisor.async_nolink(ctx.task_supervisor, fn ->
        Connections.connection(fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {tag, :backend, backend})
          command(session, request)
        end)
      end)

    assert_receive {^tag, :backend, backend}, 5_000
    %{task: task, backend: backend}
  end

  defp blocked!(holder, contender) do
    Connections.observer(fn observer ->
      deadline = System.monotonic_time(:millisecond) + 3_000

      assert wait_blocked(observer, holder, contender, deadline),
             "command never waited on the held source lock"
    end)
  end

  defp wait_blocked(observer, holder, contender, deadline) do
    # A second contender can queue behind the first contender's tuple lock;
    # follow that wait chain rather than requiring a direct blocker edge.
    query = """
    WITH RECURSIVE blockers(pid) AS (
      SELECT unnest(pg_blocking_pids($2::int))
      UNION
      SELECT unnest(pg_blocking_pids(pid)) FROM blockers
    ) SELECT EXISTS (SELECT 1 FROM blockers WHERE pid = $1::int)
    """

    case Postgrex.query!(observer, query, [holder, contender]).rows do
      [[true]] ->
        true

      [[false]] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          wait_blocked(observer, holder, contender, deadline)
        else
          false
        end
    end
  end

  defp stop!(task) do
    Task.shutdown(task, :brutal_kill)
  end

  defp assert_mutation!(ctx, :approve_capture) do
    assert [_] = approvals!(ctx, ctx.draft)
    assert length(SdrAgent.AuditCase.events_of_type(ctx.tenant, "outreach.approval.granted")) == 1

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM delivery_operations WHERE draft_id = $1", [
               Ecto.UUID.dump!(ctx.draft.id)
             ])
  end

  defp assert_mutation!(ctx, :reject_draft) do
    assert [%{verdict: :rejected}] = approvals!(ctx, ctx.draft)

    assert length(SdrAgent.AuditCase.events_of_type(ctx.tenant, "outreach.approval.rejected")) ==
             1
  end

  defp assert_mutation!(ctx, :edit_draft) do
    assert length(SdrAgent.AuditCase.events_of_type(ctx.tenant, "outreach.draft.edited")) == 1

    assert %{rows: [[2]]} =
             Repo.query!("SELECT count(*) FROM draft_revisions WHERE draft_id = $1", [
               Ecto.UUID.dump!(ctx.draft.id)
             ])
  end

  defp edit(ctx, subject), do: %{subject: subject, body_text: ctx.revision.body_text}
  defp args(ctx, :edit_draft), do: edit(ctx, "Concurrent duplicate edit")
  defp args(_ctx, :reject_draft), do: %{reason: "Concurrent duplicate rejection"}
  defp args(_ctx, :approve_capture), do: %{}

  defp cleanup!(ctx) do
    Connections.assert_test_database!()
    tenant_id = Ecto.UUID.dump!(ctx.tenant.id)

    assert %{rows: [["demo"]]} =
             Repo.query!("SELECT slug FROM tenants WHERE id = $1", [tenant_id])

    subjects =
      for fixture <- Fixtures.users() do
        assert {:ok, user} = Accounts.get_user(fixture.id, actor: ctx.admin)
        AshAuthentication.user_to_subject(user)
      end

    assert {:ok, _} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL session_replication_role = replica")
               Repo.query!("DELETE FROM tokens WHERE subject = ANY($1::text[])", [subjects])
               # Every literal table below has tenant_id. Global provenance
               # snapshots have no fixture owner and are deliberately kept.
               Enum.each(@tables, fn table ->
                 Repo.query!("DELETE FROM #{table} WHERE tenant_id = $1", [tenant_id])
               end)

               # Oban has no tenant_id column; scope its JSON args explicitly.
               Repo.query!("DELETE FROM oban_jobs WHERE args->>'tenant_id' = $1", [ctx.tenant.id])

               assert %{num_rows: 1} =
                        Repo.query!("DELETE FROM tenants WHERE id = $1", [tenant_id])
             end)
  end
end
