defmodule SdrAgent.Agents.LaunchGateTest do
  @moduledoc """
  R0-07 slice B at launch (packet section 7, rows B1, B4', B5'; entity PASS
  at 3600fcf): `admit_launch/3` repeats the admission gate after the
  profile check and before the grant terms. Every refusal of an owned
  reserved row (except a run already stopped) fails the row, opens exactly
  one critical `provider_error` Failure whose subject is the run and whose
  `operation_id` is the run's Operation, and appends `model.launch.refused`
  naming that Failure and the reserved request — all in the launch
  transaction (lock order run → Operation → invocation → charge → head).
  It returns the typed receipt `%Refused{stage: :launch}`, and the run
  stops `:model_not_admitted` on exactly that Failure.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations.Failure
  alias SdrAgent.SDR
  alias SdrAgent.SDR.Context

  @now ~U[2026-10-20 12:00:00.000000Z]
  @starts ~U[2026-10-12 00:00:00.000000Z]
  @expires ~U[2026-11-06 00:00:00.000000Z]
  @run_resource "SdrAgent.Agents.AgentRun"

  setup do
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    admin = human(:admin, tenant)

    grant =
      AgentsFixtures.grant!(
        tenant,
        %{
          total_attempts: 20,
          starts_at: @starts,
          expires_at: @expires,
          allocations: [
            %{key: :b1, applies_to: [:b1], attempts: 10},
            %{key: :proof, applies_to: [:proof], attempts: 4}
          ]
        },
        admin
      )

    admitted = AdmissionFixtures.admit_tuples!()
    %{tenant: tenant, admin: admin, grant: grant, admitted: admitted}
  end

  defp operated!(ctx, origin \\ :assignment),
    do: AgentsFixtures.operated_run(ctx.tenant, usage_origin: origin)

  defp plain!(ctx, origin \\ :assignment),
    do: AgentsFixtures.running_run(ctx.tenant, usage_origin: origin)

  defp reserve!(run, key, opts \\ []) do
    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))

    {:ok, invocation} =
      Agents.reserve_model_invocation(run.run, attrs, [actor: run.agent] ++ opts)

    invocation
  end

  defp admit(run, invocation, profile \\ :claude_cli_opus),
    do: Agents.admit_launch(invocation.id, profile, actor: run.agent)

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  defp failures(ctx), do: Ash.read!(Failure, Audit.Kernel.opts(ctx.tenant.id))

  defp reload(run) do
    {:ok, run} = Agents.get_run(run.run.id, actor: run.agent)
    run
  end

  defp model_ctx(ctx, run) do
    %Context{
      actor: run.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.run.id,
      correlation_id: run.run.correlation_id
    }
  end

  # The launch receipt end to end: the row failed and never sent, one
  # run-subject Failure (no invocation-subject one), one launch event naming
  # it and the reserved request, and the run stopped on exactly it.
  defp assert_launch_refused(ctx, run, invocation, reason, profile \\ :claude_cli_opus) do
    before = failures(ctx)

    assert {:error, %Refused{stage: :launch, reason: ^reason} = refused} =
             admit(run, invocation, profile)

    row = stored(invocation.id)
    assert {row.status, row.sent_at} == {:failed, nil}
    assert row.error["kind"] == "launch_refused"
    assert row.error["reason"] == Atom.to_string(reason)

    assert [failure] = failures(ctx) -- before
    assert failure.id == refused.failure_id
    assert {failure.subject_resource, failure.subject_id} == {@run_resource, run.run.id}
    assert {failure.class, failure.severity} == {:provider_error, :critical}
    assert failure.operation_id == run.run.operation_id

    assert [event] =
             ctx.tenant
             |> events_of_type("model.launch.refused")
             |> Enum.filter(&(&1.model_invocation_id == invocation.id))

    assert event.agent_run_id == run.run.id
    assert event.idempotency_key == invocation.idempotency_key
    assert event.payload["reason"] == Atom.to_string(reason)
    assert event.payload["failure_id"] == failure.id
    assert {refused.event_id, refused.request_id} == {event.id, invocation.idempotency_key}

    refute Enum.any?(
             events_of_type(ctx.tenant, "model.invocation.sent"),
             &(&1.model_invocation_id == invocation.id)
           )

    assert {:ok, stopped} = SDR.Model.stop_refused(model_ctx(ctx, run), reload(run), refused)
    assert {stopped.status, stopped.status_reason} == {:failed, :model_not_admitted}
    assert stopped.attention_failure_id == failure.id
    assert [_] = failures(ctx) -- before
    refused
  end

  describe "an admitted launch" do
    test "is sent", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "ok")
      assert {:ok, %{status: :sent}} = admit(run, invocation)
    end
  end

  describe "gate refusals at launch" do
    test ":tuple_not_promoted (a run with an Operation)", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "tuple")
      AdmissionFixtures.put_entries!([])
      assert_launch_refused(ctx, run, invocation, :tuple_not_promoted)
    end

    test ":witness_store_untrusted (a run without an Operation)", ctx do
      run = plain!(ctx)
      invocation = reserve!(run, "store")
      AdmissionFixtures.put_root!(nil)
      assert_launch_refused(ctx, run, invocation, :witness_store_untrusted)
    end

    test ":witness_store_untrusted when the same root became untrusted", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "chmod")
      File.chmod!(ctx.admitted.root, 0o770)
      assert_launch_refused(ctx, run, invocation, :witness_store_untrusted)
    end

    test ":result_gate_inactive", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "gate")
      AdmissionFixtures.gate_inactive!()
      assert_launch_refused(ctx, run, invocation, :result_gate_inactive)
    end

    test "a calibration call is re-admitted from its recorded authority", ctx do
      AdmissionFixtures.put_entries!([])
      run = plain!(ctx, :proof)
      marker = CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry())
      invocation = reserve!(run, "cal", calibration: marker)
      assert {:ok, %{status: :sent}} = admit(run, invocation)
    end

    test "a calibration call whose earlier predecessor is unlatched is refused", ctx do
      marker = CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry())
      first_run = plain!(ctx, :proof)
      first = reserve!(first_run, "cal-first", calibration: marker)
      {:ok, _sent} = admit(first_run, first)

      # A row reserved after an unlatched one is a defect, and still blocks
      # at launch; the invocation excludes only itself.
      run = plain!(ctx, :proof)
      second = force_reserve!(ctx, run, "cal-second", marker)

      refused = assert_launch_refused(ctx, run, second, :calibration_evidence_pending)
      assert refused.check == {:predecessor_unlatched, first.id}
    end
  end

  describe "the existing launch refusals now carry the receipt" do
    test "a revoked grant stops the run :model_not_admitted with one Failure", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "revoked")
      {:ok, _} = Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)
      assert_launch_refused(ctx, run, invocation, :grant_ineligible_at_launch)
    end

    test "a profile mismatch stops the run :model_not_admitted with one Failure", ctx do
      run = plain!(ctx)
      invocation = reserve!(run, "mismatch")

      assert_launch_refused(
        ctx,
        run,
        invocation,
        :profile_mismatch_at_launch,
        :claude_cli_sonnet
      )
    end

    test "identity and state refusals still change nothing and are no cause", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "replay")
      {:ok, _sent} = admit(run, invocation)
      before = failures(ctx)

      assert {:error, :invocation_not_reserved} = admit(run, invocation)
      assert failures(ctx) == before

      [event] =
        ctx.tenant
        |> events_of_type("model.launch.refused")
        |> Enum.filter(&(&1.model_invocation_id == invocation.id))

      refute Map.has_key?(event.payload, "failure_id")
    end
  end

  describe "atomicity" do
    test "a failed event append rolls the whole refusal back", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "append-fails")
      AdmissionFixtures.put_entries!([])
      before = failures(ctx)

      # Fault injection inside this test's transaction only.
      tamper!("""
      CREATE FUNCTION pg_temp.refuse_launch_event() RETURNS trigger AS $$
      BEGIN
        IF NEW.event_type = 'model.launch.refused' THEN
          RAISE EXCEPTION 'injected append failure';
        END IF;
        RETURN NEW;
      END $$ LANGUAGE plpgsql
      """)

      tamper!("""
      CREATE TRIGGER refuse_launch_event BEFORE INSERT ON audit_events
      FOR EACH ROW EXECUTE FUNCTION pg_temp.refuse_launch_event()
      """)

      assert {:error, _error} = admit(run, invocation)

      assert stored(invocation.id).status == :reserved
      assert failures(ctx) == before
      assert events_of_type(ctx.tenant, "model.launch.refused") == []
    end
  end

  describe "the launch receipt validator" do
    test "refuses the receipt with another request id, run or an identity event", ctx do
      run = operated!(ctx)
      first = reserve!(run, "v-1")
      second = reserve!(run, "v-2")
      AdmissionFixtures.put_entries!([])
      {:error, %Refused{} = refused} = admit(run, first)

      # A valid invocation of the same run under another request is not enough.
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.fail_run(
                 reload(run),
                 %{
                   status_reason: :model_not_admitted,
                   refusal_failure_id: refused.failure_id,
                   refusal_request_id: second.idempotency_key
                 },
                 actor: run.agent
               )

      other = operated!(ctx)

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.fail_run(
                 reload(other),
                 %{
                   status_reason: :model_not_admitted,
                   refusal_failure_id: refused.failure_id,
                   refusal_request_id: refused.request_id
                 },
                 actor: other.agent
               )

      # Not a grant stop either: the category is the launch's.
      assert {:error, %Ash.Error.Invalid{}} =
               Agents.fail_run(
                 reload(run),
                 %{
                   status_reason: :grant_unavailable,
                   refusal_failure_id: refused.failure_id,
                   refusal_request_id: refused.request_id
                 },
                 actor: run.agent
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Agents.fail_run(reload(run), %{status_reason: :model_not_admitted},
                 actor: run.agent
               )

      assert reload(run).status == :running
    end
  end

  describe "lock order" do
    test "run, then Operation FOR SHARE, then invocation, then the head", ctx do
      run = operated!(ctx)
      invocation = reserve!(run, "order")

      {{:ok, _sent}, sql} = GateFixtures.capture(fn -> admit(run, invocation) end)

      run_lock = GateFixtures.index(sql, &GateFixtures.locks?(&1, "agent_runs", "FOR UPDATE"))
      op_lock = GateFixtures.index(sql, &GateFixtures.locks?(&1, "operations", "FOR SHARE"))

      inv_lock =
        GateFixtures.index(sql, &GateFixtures.locks?(&1, "model_invocations", "FOR UPDATE"))

      assert run_lock < op_lock
      assert op_lock < inv_lock
    end
  end

  # Reserves a calibration call for `run` while an earlier calibration row is
  # still unlatched (simulating the defect the barrier prevents): reserved
  # through the admission context directly, carrying the recorded authority
  # a real admission would have written.
  defp force_reserve!(ctx, run, key, _marker) do
    AdmissionFixtures.put_entries!([])
    proof = Enum.find(ctx.grant.allocations, &(&1.key == :proof)).id

    {:ok, fake} =
      Agents.reserve_model_invocation(run.run, AgentsFixtures.model_attrs("seed-#{key}"),
        actor: run.agent
      )

    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.drop([:request])
      |> Map.merge(%{
        agent_run_id: run.run.id,
        sequence_in_run: 2,
        request_sha256: fake.request_sha256
      })

    context =
      SdrAgent.Agents.Checks.AdmissionContext.context(%{
        grant_id: ctx.grant.id,
        allocation_id: proof,
        reserved_at: @now,
        calibration_tuple: SdrAgent.Agents.Admission.Gate.tuple_record(AdmissionFixtures.entry())
      })

    {:ok, invocation} =
      ModelInvocation
      |> Ash.Changeset.for_create(:reserve, attrs, actor: run.agent, context: context)
      |> Ash.create()

    invocation
  end
end
