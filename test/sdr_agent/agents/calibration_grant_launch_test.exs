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
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
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

    assert_launch_mismatch(ctx, run, invocation, agent)
  end

  test "a grant revoked after reservation refuses the launch", ctx do
    %{invocation: invocation, agent: agent, run: run} = bound!(ctx)

    {:ok, _revoked} =
      Agents.revoke_grant(ctx.grant, %{expected_revision: ctx.grant.revision},
        actor: human(:admin, ctx.tenant)
      )

    assert_launch_mismatch(ctx, run, invocation, agent)
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

  defp assert_launch_mismatch(ctx, run, invocation, agent) do
    before = failures(ctx)
    result = launch(invocation, agent)

    assert match?(
             {:error, %Refused{stage: :launch, reason: :calibration_grant_mismatch}},
             result
           ),
           inspect(result)

    {:error, refused} = result
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
