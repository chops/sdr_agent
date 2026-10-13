defmodule SdrAgent.Agents.CalibrationGrantBindingTest do
  @moduledoc """
  R0-07 slice E, packet 8.3 (R10-2; round 11 obligations 8.11), sub-slice
  d2a: G-R0 selection and the grant binding at reservation.

    * `Agents.select_calibration_grant(tenant_id, profile_id, actor:)` —
      read-only preflight: exactly one grant in the tenant with the G-R0
      shape (active; profiles opus and sonnet; 4 attempts; expires
      2026-10-19 05:59:00Z; exactly two unreleased allocations, key `:proof`,
      `applies_to: [:proof]`, 2 attempts, one per profile) gives
      `{:ok, %{grant_id, grant_revision, allocation_id, profile_id}}`;
      zero, several or a deviating shape is
      `{:error, :calibration_grant_unavailable}`, creating nothing.
    * The binding travels in the calibration marker
      (`CalibrationAdmission.context(profile, entry, claim:, binding:)`).
      At reservation, under the existing locks, the candidate set is the
      bound grant only; its revision, its G-R0 shape, the tenant's
      uniqueness of that shape and the charged allocation must still match,
      else `:calibration_grant_mismatch` through the existing refusal
      receipt (one Failure, `model.reservation.refused`). The binding is
      recorded on the original reservation event (`calibration_binding`)
      only from the admitted charge; `Gate.recorded_binding/1` re-derives
      it.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Clock
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations.Failure

  # Within G-R0's window.
  @now ~U[2026-10-15 12:00:00.000000Z]
  @expires ~U[2026-10-19 05:59:00.000000Z]

  setup do
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()

    Code.ensure_loaded!(Agents)
    Code.ensure_loaded!(Gate)

    assert function_exported?(Agents, :select_calibration_grant, 3),
           "Agents.select_calibration_grant/3 is not defined"

    assert function_exported?(Gate, :recorded_binding, 1),
           "Gate.recorded_binding/1 is not defined"

    %{tenant: tenant}
  end

  describe "selection" do
    test "exactly one G-R0 grant gives the profile's binding", ctx do
      grant = g_r0!(ctx)
      before = event_count(ctx)

      for profile <- [:claude_cli_opus, :claude_cli_sonnet] do
        assert {:ok, binding} = select(ctx, profile)
        allocation = Enum.find(grant.allocations, &(&1.profile_id == profile))

        assert binding == %{
                 grant_id: grant.id,
                 grant_revision: grant.revision,
                 allocation_id: allocation.id,
                 profile_id: profile
               }
      end

      assert event_count(ctx) == before, "selection writes nothing"
    end

    test "no G-R0 grant, or two, is unavailable", ctx do
      assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}
      g_r0!(ctx)
      g_r0!(ctx, %{name: "G-R0-B"})
      assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}
    end

    for {label, overrides} <- [
          {"total attempts", %{total_attempts: 5}},
          {"expiry", %{expires_at: ~U[2026-10-20 05:59:00.000000Z]}},
          {"allocation key",
           %{
             allocations: [
               %{
                 key: :rehearsal,
                 applies_to: [:proof],
                 attempts: 2,
                 profile_id: :claude_cli_opus
               },
               %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
             ]
           }},
          {"allocation attempts",
           %{
             allocations: [
               %{key: :proof, applies_to: [:proof], attempts: 3, profile_id: :claude_cli_opus},
               %{key: :proof, applies_to: [:proof], attempts: 1, profile_id: :claude_cli_sonnet}
             ]
           }},
          {"allocation without profile",
           %{
             allocations: [
               %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: nil},
               %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
             ]
           }},
          {"three allocations",
           %{
             allocations: [
               %{key: :proof, applies_to: [:proof], attempts: 1, profile_id: :claude_cli_opus},
               %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet},
               %{key: :rehearsal, applies_to: [:proof], attempts: 1, profile_id: :claude_cli_opus}
             ]
           }}
        ] do
      test "a deviating #{label} is unavailable", ctx do
        g_r0!(ctx, unquote(Macro.escape(overrides)))
        assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}
      end
    end

    test "only the tenant's agent runtime may select", ctx do
      g_r0!(ctx)

      # Built first: creating a human actor's user is itself audited.
      actors = [
        nil,
        human(:admin, ctx.tenant),
        human(:reviewer, ctx.tenant),
        system_actor(:reconciler, ctx.tenant),
        struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: Ash.UUIDv7.generate())
      ]

      before = event_count(ctx)

      for actor <- actors do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Agents.select_calibration_grant(ctx.tenant.id, :claude_cli_opus, actor: actor),
               inspect(actor)
      end

      assert event_count(ctx) == before
    end

    test "the G-R0 window: before its start and at its expiry it is unavailable", ctx do
      g_r0!(ctx, %{starts_at: ~U[2026-10-16 00:00:00.000000Z]})
      assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}

      # At its start (inclusive) it is selectable.
      Clock.freeze(~U[2026-10-16 00:00:00.000000Z])
      assert {:ok, _} = select(ctx, :claude_cli_opus)

      Clock.freeze(~U[2026-10-19 05:58:59.999999Z])
      assert {:ok, _} = select(ctx, :claude_cli_opus)

      # At its expiry (exclusive) it is not.
      Clock.freeze(@expires)
      assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}
    end

    test "an otherwise valid revoked grant is unavailable", ctx do
      grant = g_r0!(ctx)

      {:ok, _revoked} =
        Agents.revoke_grant(grant, %{expected_revision: grant.revision},
          actor: human(:admin, ctx.tenant)
        )

      assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}
    end

    test "a released allocation is unavailable", ctx do
      grant = g_r0!(ctx)

      {:ok, _released} =
        Agents.release_allocation(
          grant,
          %{expected_revision: grant.revision, key: :proof, profile_id: :claude_cli_opus},
          actor: human(:admin, ctx.tenant)
        )

      assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}
      assert select(ctx, :claude_cli_sonnet) == {:error, :calibration_grant_unavailable}
    end

    test "a revoked grant or a released allocation is unavailable", ctx do
      grant = g_r0!(ctx)

      {:ok, released} =
        Agents.release_allocation(
          grant,
          %{expected_revision: grant.revision, key: :proof, profile_id: :claude_cli_opus},
          actor: human(:admin, ctx.tenant)
        )

      assert select(ctx, :claude_cli_opus) == {:error, :calibration_grant_unavailable}

      {:ok, _revoked} =
        Agents.revoke_grant(released, %{expected_revision: released.revision},
          actor: human(:admin, ctx.tenant)
        )

      assert select(ctx, :claude_cli_sonnet) == {:error, :calibration_grant_unavailable}
    end
  end

  describe "reservation" do
    test "a bound reservation charges the bound allocation and records the binding", ctx do
      grant = g_r0!(ctx)
      # An unrelated eligible grant must not be charged.
      AgentsFixtures.grant!(ctx.tenant, %{name: "G-OTHER"})
      {:ok, binding} = select(ctx, :claude_cli_opus)
      %{run: run, agent: agent} = proof_run(ctx)

      assert {:ok, invocation} = reserve(run, agent, marker(binding))
      assert {invocation.grant_id, invocation.allocation_id} == {grant.id, binding.allocation_id}

      assert [event] = reserved_events(ctx, invocation)

      assert event.payload["arguments"]["calibration_binding"] == %{
               "grant_id" => binding.grant_id,
               "grant_revision" => binding.grant_revision,
               "allocation_id" => binding.allocation_id,
               "profile_id" => "claude_cli_opus"
             }

      assert Gate.recorded_binding(invocation) == {:ok, binding}
    end

    test "a grant amended after selection refuses the reservation", ctx do
      grant = g_r0!(ctx)
      {:ok, binding} = select(ctx, :claude_cli_opus)

      {:ok, _amended} =
        Agents.update_grant_terms(
          grant,
          %{expected_revision: grant.revision, name: "G-R0 renamed"},
          actor: human(:admin, ctx.tenant)
        )

      assert_mismatch(ctx, binding)
    end

    test "a second G-R0-shaped grant inserted after selection refuses the reservation", ctx do
      g_r0!(ctx)
      {:ok, binding} = select(ctx, :claude_cli_opus)
      g_r0!(ctx, %{name: "G-R0-LATE"})
      assert_mismatch(ctx, binding)
    end

    test "a released bound allocation refuses the reservation", ctx do
      grant = g_r0!(ctx)
      {:ok, binding} = select(ctx, :claude_cli_opus)

      {:ok, _released} =
        Agents.release_allocation(
          grant,
          %{expected_revision: grant.revision, key: :proof, profile_id: :claude_cli_opus},
          actor: human(:admin, ctx.tenant)
        )

      assert_mismatch(ctx, binding)
    end

    test "a binding naming another allocation refuses the reservation", ctx do
      g_r0!(ctx)
      {:ok, opus} = select(ctx, :claude_cli_opus)
      {:ok, sonnet} = select(ctx, :claude_cli_sonnet)
      assert_mismatch(ctx, %{opus | allocation_id: sonnet.allocation_id})
    end

    test "a caller cannot supply a binding", ctx do
      g_r0!(ctx)
      {:ok, binding} = select(ctx, :claude_cli_opus)
      %{run: run, agent: agent} = proof_run(ctx)

      result =
        AdmissionFixtures.admitting(fn ->
          Agents.reserve_model_invocation(
            run,
            Map.put(
              attrs(),
              :calibration_binding,
              Map.new(binding, fn {k, v} -> {to_string(k), v} end)
            ),
            actor: agent,
            calibration: CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry())
          )
        end)

      assert match?({:error, %Ash.Error.Forbidden{}}, result), inspect(result)
      assert {:ok, []} = Agents.list_model_invocations(run.id, actor: agent)
      assert events_of_type(ctx.tenant, "model.invocation.reserved") == []
    end

    test "a mismatch is one receipt, and its replay adds none", ctx do
      grant = g_r0!(ctx)
      {:ok, binding} = select(ctx, :claude_cli_opus)

      {:ok, _amended} =
        Agents.update_grant_terms(grant, %{expected_revision: grant.revision, name: "renamed"},
          actor: human(:admin, ctx.tenant)
        )

      %{run: run, agent: agent} = proof_run(ctx)
      call = attrs()

      reserve = fn ->
        AdmissionFixtures.admitting(fn ->
          Agents.reserve_model_invocation(run, call, actor: agent, calibration: marker(binding))
        end)
      end

      assert {:error, %Refused{reason: :calibration_grant_mismatch} = refused} = reserve.()
      failures = failures_of(ctx, run)
      assert [failure] = failures
      assert failure.id == refused.failure_id
      assert failure.class == :provider_error
      assert length(events_of_type(ctx.tenant, "model.reservation.refused")) == 1

      # The existing receipt contract: a repeated refusal adds a deduplicated
      # event naming the same Failure, never a second Failure.
      assert {:error, %Refused{reason: :calibration_grant_mismatch}} = reserve.()
      assert failures_of(ctx, run) == failures
      events = events_of_type(ctx.tenant, "model.reservation.refused")
      assert Enum.map(events, & &1.payload["deduplicated"]) == [false, true]
      assert Enum.all?(events, &(&1.payload["failure_id"] == failure.id))
    end

    test "run, grants, allocations, then the head; no row lock after it", ctx do
      g_r0!(ctx)
      {:ok, binding} = select(ctx, :claude_cli_opus)
      %{run: run, agent: agent} = proof_run(ctx)

      {result, sql} = GateFixtures.capture(fn -> reserve(run, agent, marker(binding)) end)
      assert {:ok, _invocation} = result

      at = &GateFixtures.index(sql, fn q -> GateFixtures.locks?(q, &1, &2) end)
      run_lock = at.("agent_runs", "FOR UPDATE")
      grants = at.("model_call_grants", "FOR SHARE")
      allocations = at.("model_call_allocations", "FOR SHARE")
      head = at.("audit_chain_heads", "FOR UPDATE")

      assert run_lock && grants && allocations && head, inspect(sql)
      assert run_lock < grants and grants < allocations and allocations < head

      # No grant or allocation lock after the head: the fresh G-R0
      # uniqueness observation under the head is a read. (The ordinary
      # reservation's re-lock of the run row it already holds is unchanged.)
      after_head =
        sql
        |> Enum.drop(head + 1)
        |> Enum.filter(
          &(GateFixtures.locks?(&1, "model_call_grants", "FOR SHARE") or
              GateFixtures.locks?(&1, "model_call_grants", "FOR UPDATE") or
              GateFixtures.locks?(&1, "model_call_allocations", "FOR SHARE") or
              GateFixtures.locks?(&1, "model_call_allocations", "FOR UPDATE"))
        )

      assert after_head == [], inspect(after_head)
    end

    test "a malformed binding or one of another profile is an invalid marker", ctx do
      g_r0!(ctx)
      {:ok, binding} = select(ctx, :claude_cli_opus)

      for bad <- [
            %{binding | grant_id: "nope"},
            %{binding | grant_revision: 0},
            Map.delete(binding, :allocation_id),
            %{binding | profile_id: :claude_cli_sonnet}
          ] do
        assert_raise ArgumentError, fn -> marker(bad) end

        forged = %{
          sdr_calibration_admission: %{
            profile_id: :claude_cli_opus,
            entry: AdmissionFixtures.entry(),
            binding: bad
          }
        }

        %{run: run, agent: agent} = proof_run(ctx)
        result = reserve(run, agent, forged)
        assert inspect(result) =~ "calibration_not_authorized", inspect({bad, result})
      end
    end
  end

  ## Fixtures

  defp g_r0!(ctx, overrides \\ %{}) do
    AgentsFixtures.grant!(
      ctx.tenant,
      Map.merge(
        %{
          name: "G-R0",
          profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
          total_attempts: 4,
          starts_at: ~U[2026-10-12 00:00:00.000000Z],
          expires_at: @expires,
          allocations: [proof(:claude_cli_opus, 2), proof(:claude_cli_sonnet, 2)]
        },
        overrides
      )
    )
  end

  defp proof(profile_id, attempts),
    do: %{key: :proof, applies_to: [:proof], attempts: attempts, profile_id: profile_id}

  defp select(ctx, profile),
    do:
      Agents.select_calibration_grant(ctx.tenant.id, profile,
        actor: system_actor(:agent_runtime, ctx.tenant)
      )

  defp marker(binding),
    do:
      CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry(),
        claim: Ash.UUIDv7.generate(),
        binding: binding
      )

  defp proof_run(ctx), do: AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

  defp attrs, do: AgentsFixtures.claude_attrs("bind-#{System.unique_integer([:positive])}")

  defp reserve(run, agent, marker) do
    AdmissionFixtures.admitting(fn ->
      Agents.reserve_model_invocation(run, attrs(), actor: agent, calibration: marker)
    end)
  end

  defp assert_mismatch(ctx, binding) do
    %{run: run, agent: agent} = proof_run(ctx)
    before = length(events_of_type(ctx.tenant, "model.reservation.refused"))

    result = reserve(run, agent, marker(binding))

    assert match?({:error, %Refused{reason: :calibration_grant_mismatch}}, result),
           inspect(result)

    assert length(events_of_type(ctx.tenant, "model.reservation.refused")) == before + 1
    assert {:ok, []} = Agents.list_model_invocations(run.id, actor: agent)
  end

  defp reserved_events(ctx, invocation) do
    ctx.tenant
    |> events_of_type("model.invocation.reserved")
    |> Enum.filter(&(&1.model_invocation_id == invocation.id))
  end

  defp event_count(ctx), do: length(events(ctx.tenant))

  defp failures_of(ctx, run) do
    Failure
    |> Ash.read!(SdrAgent.Audit.Kernel.opts(ctx.tenant.id))
    |> Enum.filter(&(&1.subject_id == run.id))
    |> Enum.sort_by(& &1.id)
  end
end
