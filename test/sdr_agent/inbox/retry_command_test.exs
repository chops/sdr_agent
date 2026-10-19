defmodule SdrAgent.Inbox.RetryCommandTest do
  @moduledoc """
  C1-03 B RED: exact displayed Failure context, current admin session,
  known-Fake source checks and durable single-attempt effects. All subjects
  use the real fixed gateway or its fixed source-domain entry.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.InboxCommandFixtures, only: [error!: 2, error!: 3]
  import SdrAgent.InboxFixtures, only: [session!: 1]
  import SdrAgent.InboxRetryFixtures

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Operations

  @applied {:ok, %{outcome: :applied, refresh?: true}}

  for trigger <- [:assignment, :reply] do
    @trigger trigger

    describe "#{trigger} retry" do
      setup ctx do
        prior = prior!(ctx, @trigger)
        displayed = displayed_retry!(ctx, prior)
        Map.put(displayed, :prior, prior)
      end

      test "exact confirmed gen2 Fake retry creates one bound child and resolves the original",
           ctx do
        assert command(ctx.session, ctx.request) == @applied
        child = child!(ctx, ctx.prior)
        assert {child.status, child.retry_of_id} == {:queued, ctx.prior.id}
        assert child.settings_snapshot_id == ctx.prior.settings_snapshot_id
        assert child.usage_origin == ctx.prior.usage_origin
        job = job!(ctx, child)
        assert job.args["c1_retry_binding"] == binding(child, ctx.prior)
        refute Map.has_key?(job.args, "model")
        assert job.max_attempts == 1

        assert {:ok, original} = Operations.get_failure(ctx.failure.id, actor: ctx.admin)
        assert {original.status, original.resolved_by_id} == {:resolved, ctx.admin.id}
        assert original.resolution_note =~ child.id
        assert run!(ctx, ctx.prior).status == ctx.prior.status
        assert invocations!(ctx, child) == []

        if child.operation_id do
          assert {:ok, operation} = Operations.get_operation(child.operation_id, actor: ctx.admin)
          assert {operation.status, operation.oban_job_id} == {:enqueued, job.id}
        else
          assert ctx.prior.operation_id == nil
          assert job.args["run_id"] == child.id
        end

        before = effects!(ctx)
        error!(command(ctx.session, ctx.request), :stale, %{change: :recovery_guard})
        assert effects!(ctx) == before
      end

      test "the source-owned entry also enforces the displayed command", ctx do
        assert source_command(ctx.session, ctx.request) == @applied
        child = child!(ctx, ctx.prior)
        assert job!(ctx, child).args["c1_retry_binding"] == binding(child, ctx.prior)
      end

      test "failure to stamp rolls back job, run, Operation and original resolution", ctx do
        # This sandbox-only constraint permits the pre-existing unmarked
        # jobs but rejects either C1 stamp insertion or the assignment's
        # Oban.update_job. It cannot affect another test database/session.
        Repo.query!("""
        ALTER TABLE oban_jobs ADD CONSTRAINT c103_test_refuse_stamp
          CHECK (NOT (args ? 'c1_retry_binding'))
        """)

        before = effects!(ctx)
        error!(command(ctx.session, ctx.request), :producer_error)
        assert effects!(ctx) == before
        assert {:ok, %{status: :open}} = Operations.get_failure(ctx.failure.id, actor: ctx.admin)
      end

      for status <- [:reserved, :sent, :unknown] do
        test "#{status} on the terminal prior blocks without settling or retrying", ctx do
          [invocation | _] = invocations!(ctx, ctx.prior)

          # Historical terminal-run anomaly, not a permissive source action.
          # Capture the post-fixture history and require it remain untouched.
          tamper!("UPDATE model_invocations SET status = $1 WHERE id = $2", [
            Atom.to_string(unquote(status)),
            Ecto.UUID.dump!(invocation.id)
          ])

          before = effects!(ctx)
          history = invocations!(ctx, ctx.prior)
          error!(command(ctx.session, ctx.request), :blocked, %{blocked_reason: :unknown_outcome})
          assert effects!(ctx) == before
          assert invocations!(ctx, ctx.prior) == history
          assert run!(ctx, ctx.prior).status == :failed
        end
      end

      test "empty invocation history is not positive proof of Fake outcome", ctx do
        tamper!("DELETE FROM model_invocations WHERE agent_run_id = $1", [
          Ecto.UUID.dump!(ctx.prior.id)
        ])

        assert invocations!(ctx, ctx.prior) == []
        before = effects!(ctx)

        error!(command(ctx.session, ctx.request), :blocked, %{
          blocked_reason: :guard_not_available
        })

        assert effects!(ctx) == before
      end

      test "a resolved displayed Failure cannot be resurrected", ctx do
        assert {:ok, _} =
                 Operations.resolve_failure(
                   ctx.failure,
                   %{resolution_note: "Synthetic resolution"},
                   actor: ctx.admin
                 )

        before = effects!(ctx)
        error!(command(ctx.session, ctx.request), :stale)
        assert effects!(ctx) == before
      end

      test "acknowledging the Failure changes its freshness, not its identity", ctx do
        assert {:ok, _} = Operations.acknowledge_failure(ctx.failure, actor: ctx.admin)
        fresh = displayed_retry!(ctx, ctx.prior, ctx.session)
        assert fresh.row.id == ctx.row.id
        refute fresh.row.freshness_token == ctx.row.freshness_token
        before = effects!(ctx)
        error!(command(ctx.session, ctx.request), :stale)
        assert effects!(ctx) == before
        assert command(ctx.session, fresh.request) == @applied
      end

      for field <- [:item_id, :expected_freshness_token] do
        test "forged #{field} cannot authorize source retry", ctx do
          request = Map.put(ctx.request, unquote(field), String.duplicate("0", 64))
          before = effects!(ctx)
          error!(command(ctx.session, request), :stale)
          assert effects!(ctx) == before
        end
      end

      for args <- [
            %{},
            %{confirm: false},
            %{confirm: "true"},
            %{confirm: true, provider: :fake},
            %{confirm: true, run_id: "00000000-0000-4000-8000-000000000001"}
          ] do
        test "strict confirmation refuses #{inspect(args)}", ctx do
          before = effects!(ctx)
          request = %{ctx.request | args: unquote(Macro.escape(args))}
          error!(command(ctx.session, request), :invalid_input)
          assert effects!(ctx) == before
        end
      end

      for role <- [:reviewer, :auditor] do
        test "#{role} has no retry mutation authority", ctx do
          actor = human(unquote(role), ctx.tenant)
          before = effects!(ctx)
          error!(command(session!(actor), ctx.request), :forbidden)
          assert effects!(ctx) == before
        end
      end

      test "a revoked current admin session has no retry authority", ctx do
        assert :ok =
                 AshAuthentication.TokenResource.Actions.revoke(
                   SdrAgent.Accounts.Token,
                   ctx.session
                 )

        before = effects!(ctx)
        error!(command(ctx.session, ctx.request), :forbidden)
        assert effects!(ctx) == before
      end

      test "a disabled admin cannot use a previously displayed retry", ctx do
        other = SdrAgent.AuditCase.new_human(:admin, ctx.tenant)
        assert {:ok, _} = Accounts.change_status(ctx.admin, :disabled, actor: other)
        before = effects!(ctx)
        error!(command(ctx.session, ctx.request), :forbidden)
        assert effects!(ctx) == before
      end

      test "a nonexistent source id does not reveal a run binding", ctx do
        before = effects!(ctx)
        request = %{ctx.request | source_id: Ecto.UUID.generate()}
        error!(command(ctx.session, request), :not_found)
        assert effects!(ctx) == before
      end
    end
  end

  test "legacy source retry remains unmarked and is not silently redefined", ctx do
    prior = prior!(ctx, :assignment)
    assert {:ok, retry} = SdrAgent.SDR.retry_run(prior.id, actor: ctx.admin)
    refute Map.has_key?(retry.job.args, "c1_retry_binding")
    assert retry.run.retry_of_id == prior.id
    assert {:ok, stored} = Agents.get_run(prior.id, actor: ctx.admin)
    assert stored.status == prior.status
  end
end
