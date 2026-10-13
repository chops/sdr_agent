defmodule SdrAgent.Agents.CalibrationGrantLaunchTest do
  @moduledoc """
  R0-07 slice E, packet 8.3 "At launch" (R10-2; round 11 obligations
  8.11), sub-slice d2b: the G-R0 binding re-checked at launch admission.

  Under the existing launch order (run → Operation → invocation → grant
  `FOR SHARE` → allocation `FOR SHARE` → head), a calibration invocation
  whose original reservation event records a binding launches only while
  its charged grant and allocation equal the binding and the grant's
  revision still equals the bound revision. An amendment or revocation
  between reservation and launch refuses the launch with
  `:calibration_grant_mismatch` through B1's one-Failure launch receipt,
  never falling back to another budget. An invocation without a recorded
  binding launches as before.

  The recorded binding itself is checked at launch, not only its revision:
  a malformed recorded binding beside a valid calibration tuple refuses
  (`:binding_unrecorded`), never treated as a legacy absence, and a
  well-shaped binding naming another grant, allocation or profile refuses
  (`:binding_changed`) (Codex 01a13652). Such history cannot be created
  through the domain, so those cases rewrite only the binding inside the
  original reservation event's payload with `AuditCase.tamper!/2`
  (triggers disabled, as a database administrator would).
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure

  @now ~U[2026-10-15 12:00:00.000000Z]

  setup do
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()

    Code.ensure_loaded!(Agents)

    assert function_exported?(Agents, :select_calibration_grant, 3),
           "Agents.select_calibration_grant/3 is not defined"

    grant = g_r0!(tenant)
    %{tenant: tenant, grant: grant}
  end

  test "an unchanged bound invocation launches", ctx do
    %{invocation: invocation, agent: agent} = bound!(ctx)
    assert {:ok, sent} = launch(invocation, agent)
    assert sent.status == :sent
  end

  test "a grant amended after reservation refuses the launch", ctx do
    %{invocation: invocation, agent: agent, run: run} = bound!(ctx)

    {:ok, _amended} =
      Agents.update_grant_terms(
        ctx.grant,
        %{expected_revision: ctx.grant.revision, name: "G-R0 2"},
        actor: human(:admin, ctx.tenant)
      )

    assert_launch_mismatch(ctx, run, invocation, agent, :binding_changed)
  end

  test "a grant revoked after reservation refuses the launch", ctx do
    %{invocation: invocation, agent: agent, run: run} = bound!(ctx)

    {:ok, _revoked} =
      Agents.revoke_grant(ctx.grant, %{expected_revision: ctx.grant.revision},
        actor: human(:admin, ctx.tenant)
      )

    assert_launch_mismatch(ctx, run, invocation, agent, :binding_changed)
  end

  for form <- [:missing_key, :extra_key, :not_a_map] do
    test "a malformed recorded binding (#{form}) beside a valid tuple refuses", ctx do
      %{invocation: invocation, agent: agent, run: run} = bound!(ctx)
      rebind!(ctx, invocation, &malformed(&1, unquote(form)))

      # The tuple gate still passes: only the binding is malformed.
      assert {:ok, %{}} = Gate.recorded_tuple(invocation)
      assert Gate.recorded_binding(invocation) == {:error, :binding_unrecorded}

      assert_launch_mismatch(ctx, run, invocation, agent, :binding_unrecorded)
    end
  end

  for field <- [:grant_id, :allocation_id, :profile_id] do
    test "a well-shaped binding naming another #{field} refuses", ctx do
      %{invocation: invocation, agent: agent, run: run} = bound!(ctx)
      rebind!(ctx, invocation, &other(&1, unquote(field), ctx))

      # Well-shaped, at the unchanged revision: only #{field} differs.
      assert {:ok, %{grant_revision: revision}} = Gate.recorded_binding(invocation)
      assert revision == ctx.grant.revision

      assert_launch_mismatch(ctx, run, invocation, agent, :binding_changed)
    end
  end

  test "an invocation without a recorded binding launches as before", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

    {:ok, invocation} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs(),
          actor: agent,
          calibration: CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry())
        )
      end)

    assert {:ok, %{status: :sent}} = launch(invocation, agent)
  end

  ## Fixtures

  defp bound!(ctx) do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

    {:ok, binding} =
      Agents.select_calibration_grant(ctx.tenant.id, :claude_cli_opus, actor: agent)

    {:ok, invocation} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs(),
          actor: agent,
          calibration:
            CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry(),
              claim: Ash.UUIDv7.generate(),
              binding: binding
            )
        )
      end)

    %{run: run, agent: agent, invocation: invocation}
  end

  defp launch(invocation, agent) do
    AdmissionFixtures.admitting(fn ->
      Agents.admit_launch(invocation.id, :claude_cli_opus, actor: agent)
    end)
  end

  # Rewrites `arguments.calibration_binding` of the invocation's one
  # original reservation event (fixture only; triggers disabled).
  defp rebind!(ctx, invocation, change) do
    [event] =
      Enum.filter(
        events_of_type(ctx.tenant, "model.invocation.reserved"),
        &(&1.model_invocation_id == invocation.id)
      )

    stored = event.payload["arguments"]["calibration_binding"]
    assert is_map(stored)

    %{num_rows: 1} =
      tamper!(
        """
        UPDATE audit_events
           SET payload = jsonb_set(payload, '{arguments,calibration_binding}', $2::jsonb)
         WHERE tenant_id = $1 AND id = $3
        """,
        [Ecto.UUID.dump!(ctx.tenant.id), change.(stored), Ecto.UUID.dump!(event.id)]
      )

    :ok
  end

  defp malformed(stored, :missing_key), do: Map.delete(stored, "allocation_id")
  defp malformed(stored, :extra_key), do: Map.put(stored, "extra", 1)
  defp malformed(_stored, :not_a_map), do: "binding"

  defp other(stored, :grant_id, _ctx), do: %{stored | "grant_id" => Ash.UUIDv7.generate()}

  # The other profile's real allocation in the same grant.
  defp other(stored, :allocation_id, ctx) do
    %{allocations: allocations} = Ash.load!(ctx.grant, :allocations, authorize?: false)
    [sonnet] = Enum.filter(allocations, &(&1.profile_id == :claude_cli_sonnet))
    %{stored | "allocation_id" => sonnet.id}
  end

  defp other(stored, :profile_id, _ctx), do: %{stored | "profile_id" => "claude_cli_sonnet"}

  defp assert_launch_mismatch(ctx, run, invocation, agent, check) do
    before = failures(ctx)
    result = launch(invocation, agent)

    assert match?(
             {:error, %Refused{stage: :launch, reason: :calibration_grant_mismatch}},
             result
           ),
           inspect(result)

    {:error, refused} = result
    assert refused.check == check

    assert [%{id: event_id}] =
             Enum.filter(
               events_of_type(ctx.tenant, "model.launch.refused"),
               &(&1.model_invocation_id == invocation.id)
             )

    assert event_id == refused.event_id

    row = Ash.get!(ModelInvocation, invocation.id, authorize?: false)
    assert {row.status, row.sent_at} == {:failed, nil}
    assert row.error["reason"] == "calibration_grant_mismatch"
    # The charge stays on the bound grant: no fallback to another budget.
    assert {row.grant_id, row.allocation_id} == {invocation.grant_id, invocation.allocation_id}

    assert [failure] = failures(ctx) -- before
    assert failure.id == refused.failure_id
    assert {failure.class, failure.subject_id} == {:provider_error, run.id}

    refute Enum.any?(
             events_of_type(ctx.tenant, "model.invocation.sent"),
             &(&1.model_invocation_id == invocation.id)
           )
  end

  defp g_r0!(tenant) do
    AgentsFixtures.grant!(tenant, %{
      name: "G-R0",
      profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
      total_attempts: 4,
      starts_at: ~U[2026-10-12 00:00:00.000000Z],
      expires_at: ~U[2026-10-19 05:59:00.000000Z],
      allocations: [
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_opus},
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
      ]
    })
  end

  defp attrs, do: AgentsFixtures.claude_attrs("launch-#{System.unique_integer([:positive])}")

  defp failures(ctx), do: Ash.read!(Failure, SdrAgent.Audit.Kernel.opts(ctx.tenant.id))
end
