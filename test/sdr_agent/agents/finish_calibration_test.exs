defmodule SdrAgent.Agents.FinishCalibrationTest do
  @moduledoc """
  R0-07 slice E, row R11-2 (harness round 13, entity PASS at 094caa86): the
  guarded finish `SdrAgent.Agents.finish_calibration/3`, the only writer of
  `status_reason :calibration_latched`.

  For a terminal generation-2 ClaudeCLI invocation of a `:proof` run with no
  Operation, as AGT of the tenant, in one transaction (run `FOR UPDATE` →
  invocation `FOR SHARE` → head, no row lock after the head) it decides the
  `:calibration` release with the artifact's hash as `evidence_sha256`
  under a `Prelocked` context binding the tenant and invocation with nil
  link and nil receipt, then:

    * a still-running run → `:succeeded` with `:calibration_latched`,
      whatever the call's outcome (completed, failed or unknown);
    * an already-terminal run → status and reason unchanged; the latch only.

  An identical replay returns the latch; a different hash is
  `:calibration_evidence_conflict` with nothing written. The artifact file
  itself is validated by the console before this call (row R11-3).
  Concurrency is covered in `FinishCalibrationRaceTest`.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures

  setup do
    tenant = bootstrap!()

    AgentsFixtures.grant!(tenant, %{
      total_attempts: 10,
      allocations: [
        %{key: :b1, applies_to: [:b1], attempts: 5},
        %{key: :proof, applies_to: [:proof], attempts: 5}
      ]
    })

    %{tenant: tenant}
  end

  describe "a running proof run" do
    for outcome <- [:completed, :invalid, :failed, :unknown] do
      test "a #{outcome} call latches and the run succeeds as :calibration_latched", ctx do
        %{run: run, agent: agent} = proof_run(ctx)
        invocation = proof_invocation!(run, agent, unquote(outcome))
        sha = sha("evidence-#{unquote(outcome)}")

        assert {:ok, %{release: latch, run: finished}} =
                 finish(invocation, %{sha256: sha}, actor: agent)

        assert {latch.disposition, latch.reason, latch.evidence_sha256} ==
                 {:calibration, :calibration, sha}

        assert latch.model_invocation_id == invocation.id
        assert latch.wire_witness_link_id == nil
        assert {finished.status, finished.status_reason} == {:succeeded, :calibration_latched}
        assert finished.finished_at

        assert [_] = events_of_type(ctx.tenant, "model.result.calibration")
        assert [event] = events_of_type(ctx.tenant, "agents.run.calibration_latched")
        assert event.agent_run_id == run.id
      end
    end
  end

  describe "an already-terminal proof run" do
    test "a cancelled run keeps its status and reason; the latch is recorded", ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :failed)
      {:ok, cancelled} = Agents.cancel_run(run, actor: agent, attrs: %{status_reason: :crash})

      assert {:ok, %{release: latch, run: same}} =
               finish(invocation, %{sha256: sha("late")}, actor: agent)

      assert latch.disposition == :calibration
      assert {same.status, same.status_reason} == {:cancelled, :crash}
      assert same.finished_at == cancelled.finished_at
      assert events_of_type(ctx.tenant, "agents.run.calibration_latched") == []
    end
  end

  describe "an already-failed proof run" do
    test "keeps its reason, attention Failure and finish time; the latch is recorded", ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :invalid)

      {:ok, failed} =
        Agents.fail_run(run, %{status_reason: :invalid_model_output}, actor: agent)

      assert failed.attention_failure_id

      assert {:ok, %{release: latch, run: same}} =
               finish(invocation, %{sha256: sha("failed")}, actor: agent)

      assert latch.disposition == :calibration

      assert {same.status, same.status_reason, same.attention_failure_id, same.finished_at} ==
               {:failed, :invalid_model_output, failed.attention_failure_id, failed.finished_at}

      assert events_of_type(ctx.tenant, "agents.run.calibration_latched") == []
    end
  end

  describe "atomicity" do
    test "a failure of the run event rolls back the latch and the run change", ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :completed)
      before = event_count(ctx)
      fail_event!("agents.run.calibration_latched")

      assert {:error, _} = finish(invocation, %{sha256: sha("rollback")}, actor: agent)

      assert event_count(ctx) == before
      assert_unchanged(ctx, run)

      auditor = system_actor(:auditor_cli, ctx.tenant)
      assert {:ok, nil} = Agents.get_result_release(invocation.id, actor: auditor)
    end
  end

  describe "replay" do
    setup ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :completed)

      {:ok, %{release: latch}} =
        finish(invocation, %{sha256: sha("first")}, actor: agent)

      %{invocation: invocation, agent: agent, latch: latch}
    end

    test "the identical hash returns the existing latch and writes nothing", ctx do
      before = event_count(ctx)

      assert {:ok, %{release: again, run: run}} =
               finish(ctx.invocation, %{sha256: sha("first")}, actor: ctx.agent)

      assert again.id == ctx.latch.id
      assert {run.status, run.status_reason} == {:succeeded, :calibration_latched}
      assert event_count(ctx) == before
    end

    test "a different hash is a conflict and writes nothing", ctx do
      before = event_count(ctx)

      assert {:error, :calibration_evidence_conflict} =
               finish(ctx.invocation, %{sha256: sha("other")}, actor: ctx.agent)

      assert event_count(ctx) == before
    end
  end

  describe "refusals write nothing" do
    # One per test: an unlatched proof invocation is a B4' predecessor that
    # blocks any later proof reservation in the tenant.
    for status <- [:reserved, :sent] do
      test "a #{status} invocation", ctx do
        %{run: run, agent: agent} = proof_run(ctx)
        invocation = proof_invocation!(run, agent, unquote(status))
        assert_refused(ctx, run, invocation, agent, :calibration_not_finishable)
      end
    end

    test "a business run's invocation", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      invocation = AgentsFixtures.claude_completed!(run, agent, "business")
      assert_refused(ctx, run, invocation, agent, :calibration_not_finishable)
    end

    test "a proof run with an Operation", ctx do
      %{run: run, agent: agent} = AgentsFixtures.operated_run(ctx.tenant, usage_origin: :proof)
      invocation = proof_invocation!(run, agent, :failed)
      assert_refused(ctx, run, invocation, agent, :calibration_not_finishable)
    end

    test "a proof run's non-ClaudeCLI invocation", ctx do
      %{run: run, agent: agent} = proof_run(ctx)

      {:ok, fake} =
        Agents.reserve_model_invocation(run, AgentsFixtures.model_attrs("fake"), actor: agent)

      {:ok, fake} = Agents.fail_model_invocation(fake, %{error: %{"kind" => "x"}}, actor: agent)
      assert_refused(ctx, run, fake, agent, :calibration_not_finishable)
    end

    test "a malformed evidence hash", ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :failed)

      for bad <- [nil, "XYZ", String.upcase(sha("x")), sha("x") <> "0"] do
        assert {:error, _} = finish(invocation, %{sha256: bad}, actor: agent)
      end

      assert_unchanged(ctx, run)
    end

    test "actors other than this tenant's agent runtime", ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :failed)

      for actor <- [
            nil,
            human(:admin, ctx.tenant),
            human(:reviewer, ctx.tenant),
            system_actor(:reconciler, ctx.tenant),
            system_actor(:auditor_cli, ctx.tenant),
            struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: Ash.UUIDv7.generate())
          ] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 finish(invocation, %{sha256: sha("actor")}, actor: actor),
               inspect(actor)
      end

      assert events_of_type(ctx.tenant, "authz.denied") == []
      assert_unchanged(ctx, run)
    end

    test "a human auditor is denied, and the denial is audited once", ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :failed)

      assert {:error, %Ash.Error.Forbidden{}} =
               finish(invocation, %{sha256: sha("aur")}, actor: human(:auditor, ctx.tenant))

      assert [%{actor_role: :auditor}] = events_of_type(ctx.tenant, "authz.denied")
      assert_unchanged(ctx, run)
    end
  end

  describe "only the guarded finish writes :calibration_latched" do
    setup ctx, do: proof_run(ctx)

    test ":succeed sets no status reason", ctx do
      assert {:ok, run} = Agents.succeed_run(ctx.run, actor: ctx.agent)
      assert run.status_reason == nil
    end

    test ":succeed does not accept a status reason", ctx do
      changeset =
        Ash.Changeset.for_update(ctx.run, :succeed, %{status_reason: :calibration_latched},
          actor: ctx.agent
        )

      refute changeset.valid?
    end

    test ":fail and :cancel refuse :calibration_latched", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.fail_run(ctx.run, %{status_reason: :calibration_latched}, actor: ctx.agent)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.cancel_run(ctx.run,
                 actor: ctx.agent,
                 attrs: %{status_reason: :calibration_latched}
               )

      assert {:ok, %{status: :running}} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    end

    test ":finish_calibration is not callable directly without its invocation", ctx do
      assert Ash.Resource.Info.action(SdrAgent.Agents.AgentRun, :finish_calibration),
             "AgentRun :finish_calibration is not defined"

      assert {:error, _} =
               ctx.run
               |> Ash.Changeset.for_update(:finish_calibration, %{}, actor: ctx.agent)
               |> Ash.update()

      assert {:ok, %{status: :running}} = Agents.get_run(ctx.run.id, actor: ctx.agent)
    end
  end

  describe "lock order" do
    test "run FOR UPDATE, invocation FOR SHARE, then the head; no row lock after it", ctx do
      %{run: run, agent: agent} = proof_run(ctx)
      invocation = proof_invocation!(run, agent, :completed)

      {result, sql} =
        GateFixtures.capture(fn ->
          finish(invocation, %{sha256: sha("order")}, actor: agent)
        end)

      assert {:ok, _} = result
      at = &GateFixtures.index(sql, fn q -> GateFixtures.locks?(q, &1, &2) end)
      run_lock = at.("agent_runs", "FOR UPDATE")
      invocation_lock = at.("model_invocations", "FOR SHARE")
      head = at.("audit_chain_heads", "FOR UPDATE")

      assert run_lock && invocation_lock && head, inspect(sql)
      assert run_lock < invocation_lock and invocation_lock < head

      after_head =
        sql
        |> Enum.drop(head + 1)
        |> Enum.filter(&GateFixtures.lock?/1)
        |> Enum.reject(&GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE"))

      assert after_head == [], inspect(after_head)
    end
  end

  defp proof_run(ctx), do: AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

  defp proof_invocation!(run, agent, outcome) do
    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(
          run,
          AgentsFixtures.claude_attrs("cal-#{System.unique_integer([:positive])}"),
          actor: agent,
          calibration: AdmissionFixtures.calibration()
        )
      end)

    advance(reserved, agent, outcome)
  end

  defp advance(reserved, _agent, :reserved), do: reserved

  defp advance(reserved, agent, outcome) do
    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    settle(sent, agent, outcome)
  end

  defp settle(sent, _agent, :sent), do: sent

  defp settle(sent, agent, :completed) do
    {:ok, done} =
      Agents.complete_model_invocation(sent, AgentsFixtures.completion(), actor: agent)

    done
  end

  defp settle(sent, agent, :failed) do
    {:ok, failed} =
      Agents.fail_model_invocation(sent, %{error: %{"kind" => "provider_error"}}, actor: agent)

    failed
  end

  defp settle(sent, agent, :unknown) do
    {:ok, unknown} = Agents.mark_model_invocation_unknown(sent, actor: agent)
    unknown
  end

  defp settle(sent, agent, :invalid) do
    invalid = %{AgentsFixtures.completion() | validation_status: :invalid}
    {:ok, done} = Agents.complete_model_invocation(sent, invalid, actor: agent)
    done
  end

  defp assert_refused(ctx, run, invocation, agent, reason) do
    before = event_count(ctx)

    assert {:error, ^reason} =
             finish(invocation, %{sha256: sha("refused")}, actor: agent)

    assert event_count(ctx) == before
    assert_unchanged(ctx, run)
  end

  defp assert_unchanged(ctx, run) do
    auditor = system_actor(:auditor_cli, ctx.tenant)
    assert {:ok, stored} = Agents.get_run(run.id, actor: auditor)
    assert {stored.status, stored.status_reason} == {run.status, run.status_reason}
    assert events_of_type(ctx.tenant, "model.result.calibration") == []
    assert events_of_type(ctx.tenant, "agents.run.calibration_latched") == []
  end

  defp event_count(ctx), do: length(events(ctx.tenant))

  # The API is checked by assertion before it is called, so a missing
  # implementation fails as an assertion, never as a crash.
  defp finish(invocation, evidence, opts) do
    Code.ensure_loaded!(Agents)

    assert function_exported?(Agents, :finish_calibration, 3),
           "Agents.finish_calibration/3 is not defined"

    apply(Agents, :finish_calibration, [invocation, evidence, opts])
  end

  # Test-only fault: an insert of an `event_type` audit event raises, inside
  # the test's sandbox transaction (the trigger is rolled back with it).
  defp fail_event!(event_type) do
    Ecto.Adapters.SQL.query!(
      SdrAgent.Repo,
      """
      CREATE FUNCTION sdr_test_fail_calibration_event() RETURNS trigger
      LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected event failure'; END $$
      """,
      []
    )

    Ecto.Adapters.SQL.query!(
      SdrAgent.Repo,
      "CREATE TRIGGER fail_calibration_event BEFORE INSERT ON audit_events FOR EACH ROW " <>
        "WHEN (NEW.event_type = '#{event_type}') EXECUTE FUNCTION sdr_test_fail_calibration_event()",
      []
    )
  end

  defp sha(label), do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)
end
