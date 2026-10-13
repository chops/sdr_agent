defmodule SdrAgent.Agents.AdmissionGateTest do
  @moduledoc """
  R0-07 slice B before reservation (packet section 7, rows B1–B5, B4', B5';
  entity PASS at 3600fcf): a real (generation-2 ClaudeCLI) reservation is
  admitted only when the result gate is active, the witness store root is
  trusted and the call's exact runtime identity is promoted on the shipped
  allowlist; a `:proof` run additionally needs the test-seam calibration
  authority and a latched predecessor ledger. Every refusal writes no
  invocation, payload or counter, records one `provider_error` Failure of
  the run and a `model.reservation.refused` event, and stops the run
  `:model_not_admitted` linking exactly that Failure.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.Agents.Checks.CalibrationContext
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Clock
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

  defp run!(ctx, origin \\ :assignment),
    do: AgentsFixtures.running_run(ctx.tenant, usage_origin: origin)

  defp attrs(key, overrides \\ %{}) do
    key
    |> AgentsFixtures.claude_attrs()
    |> Map.put(:request, ~s({"request":"#{key}"}))
    |> Map.merge(overrides)
  end

  defp reserve(run, key, overrides \\ %{}, opts \\ []),
    do:
      Agents.reserve_model_invocation(run.run, attrs(key, overrides), [actor: run.agent] ++ opts)

  defp profile_attrs(profile),
    do: SdrAgent.AI.ModelProvider.ClaudeCLI.provenance(profile)

  defp marker(profile \\ :claude_cli_opus, entry \\ AdmissionFixtures.entry()),
    do: CalibrationAdmission.context(profile, entry)

  defp invocations(run) do
    {:ok, invocations} = Agents.list_model_invocations(run.run.id, actor: run.agent)
    invocations
  end

  defp admission_failures(ctx) do
    Failure
    |> Ash.Query.filter(class == :provider_error and subject_resource == ^@run_resource)
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))
  end

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

  # The refusal changed nothing, recorded one Failure and one event, and the
  # run stops :model_not_admitted on exactly that Failure.
  defp assert_refused(ctx, run, key, reason, overrides \\ %{}, opts \\ []) do
    before = reload(run).budget
    assert {:error, %Refused{reason: ^reason} = refused} = reserve(run, key, overrides, opts)

    assert invocations(run) == []
    assert reload(run).budget == before

    assert [failure] =
             ctx |> admission_failures() |> Enum.filter(&(&1.subject_id == run.run.id))

    assert failure.id == refused.failure_id
    assert failure.severity == :critical
    assert failure.operation_id == run.run.operation_id
    assert failure.message =~ Atom.to_string(reason)

    assert [event] =
             ctx.tenant
             |> events_of_type("model.reservation.refused")
             |> Enum.filter(&(&1.idempotency_key == key))

    assert event.payload["reason"] == Atom.to_string(reason)
    assert event.payload["failure_id"] == failure.id
    assert {refused.event_id, refused.request_id, refused.stage} == {event.id, key, :reservation}

    assert {:ok, stopped} = SDR.Model.stop_refused(model_ctx(ctx, run), reload(run), refused)
    assert {stopped.status, stopped.status_reason} == {:failed, :model_not_admitted}
    assert stopped.attention_failure_id == failure.id
    assert [_] = ctx |> admission_failures() |> Enum.filter(&(&1.subject_id == run.run.id))
    refute Enum.any?(all_failures(ctx), &(&1.class == :run_stopped))
    refused
  end

  defp all_failures(ctx), do: Ash.read!(Failure, Audit.Kernel.opts(ctx.tenant.id))

  describe "an admitted call" do
    test "proceeds with a promoted tuple, a trusted store and an active gate", ctx do
      run = run!(ctx)
      assert {:ok, invocation} = reserve(run, "ok")
      assert invocation.ledger_generation == 2
      assert admission_failures(ctx) == []
    end

    test "a Sonnet call proceeds on its own exact entry", ctx do
      run = run!(ctx)

      assert {:ok, %{profile_id: :claude_cli_sonnet}} =
               reserve(run, "sonnet", profile_attrs(:claude_cli_sonnet))
    end
  end

  describe "refusals before reservation" do
    test ":result_gate_inactive (the refuse-only seam)", ctx do
      AdmissionFixtures.gate_inactive!()
      assert_refused(ctx, run!(ctx), "gate", :result_gate_inactive)
    end

    test ":witness_store_untrusted for an unset root", ctx do
      AdmissionFixtures.put_root!(nil)
      assert_refused(ctx, run!(ctx), "unset", :witness_store_untrusted)
    end

    test ":witness_store_untrusted for an untrusted root", ctx do
      File.chmod!(ctx.admitted.root, 0o770)
      assert_refused(ctx, run!(ctx), "untrusted", :witness_store_untrusted)
    end

    test ":tuple_not_promoted with an empty allowlist", ctx do
      AdmissionFixtures.put_entries!([])
      assert_refused(ctx, run!(ctx), "empty", :tuple_not_promoted)
    end

    test ":tuple_not_promoted for Sonnet when only Opus is promoted", ctx do
      AdmissionFixtures.put_entries!([AdmissionFixtures.entry(:claude_cli_opus)])

      assert_refused(
        ctx,
        run!(ctx),
        "sonnet-only-opus",
        :tuple_not_promoted,
        profile_attrs(:claude_cli_sonnet)
      )
    end

    test "the gate checks come before the grant checks", ctx do
      {:ok, _} = Agents.revoke_grant(ctx.grant, %{expected_revision: 1}, actor: ctx.admin)
      AdmissionFixtures.put_entries!([])
      assert_refused(ctx, run!(ctx), "order", :tuple_not_promoted)
    end

    test "a run without a usage origin is still refused :no_usage_origin first", ctx do
      AdmissionFixtures.put_entries!([])
      run = run!(ctx)

      tamper!("UPDATE agent_runs SET usage_origin = NULL WHERE id = $1", [
        Ecto.UUID.dump!(run.run.id)
      ])

      assert {:error, %Refused{reason: :no_usage_origin}} = reserve(run, "origin")
    end
  end

  describe "store observation (B5')" do
    test "the filesystem probe runs before the first row lock, never under one", ctx do
      run = run!(ctx)
      me = self()
      handler = "probe-order-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:sdr_agent, :admission, :store_probe, :start], [:sdr_agent, :repo, :query]],
        fn
          [:sdr_agent, :admission, :store_probe, :start], _m, _meta, _ ->
            if self() == me, do: send(me, {:order, :probe})

          [:sdr_agent, :repo, :query], _m, meta, _ ->
            if self() == me and meta.query =~ ~r/\bFOR (UPDATE|SHARE)\b/,
              do: send(me, {:order, :lock})
        end,
        nil
      )

      try do
        assert {:ok, _} = reserve(run, "probe-order")
      after
        :telemetry.detach(handler)
      end

      order = collect_order([])
      assert [:probe | rest] = order
      assert :lock in rest
      refute :probe in rest
    end

    defp collect_order(acc) do
      receive do
        {:order, kind} -> collect_order([kind | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end

  describe "the pre-call tuple predicate (B2)" do
    setup do
      %{opus: ModelInvocation |> struct(identity(:claude_cli_opus))}
    end

    defp identity(profile) do
      provenance = SdrAgent.AI.ModelProvider.ClaudeCLI.provenance(profile)

      %{
        provider: :claude_cli,
        provider_version: provenance.provider_version,
        profile_id: profile,
        model_id: provenance.model_id,
        ledger_generation: 2
      }
    end

    test "an exact entry of a supported projection id promotes the identity", ctx do
      for projection <- [Projection.version(), Projection.version_v2(), Projection.version_v3()] do
        assert Witness.promoted?(ctx.opus, [AdmissionFixtures.entry(:claude_cli_opus, projection)])
      end
    end

    test "nothing else does", ctx do
      opus = AdmissionFixtures.entry(:claude_cli_opus)

      refute Witness.promoted?(ctx.opus, [])
      refute Witness.promoted?(ctx.opus, [AdmissionFixtures.entry(:claude_cli_sonnet)])
      refute Witness.promoted?(ctx.opus, [%{opus | profile_id: nil}])
      refute Witness.promoted?(ctx.opus, [%{opus | model_id: "claude-sonnet-5-5"}])
      refute Witness.promoted?(ctx.opus, [%{opus | cli_version: "9.9.9"}])
      refute Witness.promoted?(ctx.opus, [%{opus | method: :inferred}])
      refute Witness.promoted?(ctx.opus, [:propagated_id])
      refute Witness.promoted?(ctx.opus, [Map.put(opus, :stage, :calibration)])

      # A literal id of the supported registry only: no suffix or substring match.
      for projection <- [
            "claude-message-json/9+prompt-builder/1",
            "claude-message-json/3+prompt-builder/2",
            "x" <> Projection.version_v3()
          ] do
        refute Witness.promoted?(ctx.opus, [%{opus | projection_version: projection}])
      end

      # A generation-1 row is never a promoted generation-2 identity.
      refute Witness.promoted?(%{ctx.opus | ledger_generation: 1}, [opus])
    end

    test "ordinary admission never reads a per-call method override" do
      source = File.read!("lib/sdr_agent/agents/admission/gate.ex")
      refute source =~ "allow_method_override"
      refute source =~ ":methods"
    end
  end

  describe "calibration authority (B4)" do
    test "a forged :proof run without the marker is refused", ctx do
      assert_refused(ctx, run!(ctx, :proof), "forged", :calibration_not_authorized)
    end

    test "the marker on an ordinary run is refused", ctx do
      assert_refused(ctx, run!(ctx), "ordinary", :calibration_not_authorized, %{},
        calibration: marker()
      )
    end

    test "an inexact or foreign-profile entry is refused", ctx do
      inexact = Map.put(AdmissionFixtures.entry(), :stage, :calibration)

      assert_refused(ctx, run!(ctx, :proof), "inexact", :calibration_not_authorized, %{},
        calibration: CalibrationAdmission.context(:claude_cli_opus, inexact)
      )

      assert_refused(ctx, run!(ctx, :proof), "foreign", :calibration_not_authorized, %{},
        calibration: marker(:claude_cli_opus, AdmissionFixtures.entry(:claude_cli_sonnet))
      )
    end

    test "an authorized calibration call is admitted on its own entry, not the allowlist", ctx do
      AdmissionFixtures.put_entries!([])
      run = run!(ctx, :proof)
      assert {:ok, invocation} = reserve(run, "cal-1", %{}, calibration: marker())

      # The admitted entry is recorded on the immutable reservation event.
      assert [event] =
               ctx.tenant
               |> events_of_type("model.invocation.reserved")
               |> Enum.filter(&(&1.model_invocation_id == invocation.id))

      assert event.payload["arguments"]["calibration_tuple"]["profile_id"] == "claude_cli_opus"
    end

    test "a caller cannot record a calibration tuple without the authority", ctx do
      run = run!(ctx)

      assert {:error, _} =
               reserve(run, "smuggled", %{calibration_tuple: %{"profile_id" => "claude_cli_opus"}})
    end
  end

  describe "calibration predecessors (B4')" do
    defp calibration!(ctx, key, profile \\ :claude_cli_opus) do
      run = run!(ctx, :proof)

      {:ok, invocation} =
        reserve(run, key, profile_attrs(profile),
          calibration: marker(profile, AdmissionFixtures.entry(profile))
        )

      Map.put(run, :invocation, invocation)
    end

    defp latch!(%{invocation: invocation, agent: agent}) do
      {:ok, sent} = Agents.mark_model_invocation_sent(invocation, actor: agent)

      {:ok, failed} =
        Agents.fail_model_invocation(sent, %{error: %{"kind" => "provider_error"}}, actor: agent)

      {:ok, latch} =
        Agents.decide_result_release(
          %{
            model_invocation_id: failed.id,
            disposition: :calibration,
            reason: :calibration,
            evidence_sha256: hex(digest("evidence #{failed.id}"))
          },
          actor: agent,
          context: CalibrationContext.context(failed.profile_id, failed.id)
        )

      latch
    end

    test "an unlatched predecessor of any status or profile blocks", ctx do
      first = calibration!(ctx, "pred-1", :claude_cli_sonnet)

      refused =
        assert_refused(ctx, run!(ctx, :proof), "next-1", :calibration_evidence_pending, %{},
          calibration: marker()
        )

      assert refused.check == {:predecessor_unlatched, first.invocation.id}
      latch!(first)
      assert %{invocation: _} = calibration!(ctx, "next-2")
    end

    test "a preceding Fake proof row does not block", ctx do
      run = run!(ctx, :proof)

      {:ok, _fake} =
        Agents.reserve_model_invocation(
          run.run,
          "fake-proof" |> AgentsFixtures.model_attrs() |> Map.put(:provider, :fake),
          actor: run.agent
        )

      assert %{invocation: _} = calibration!(ctx, "after-fake")
    end

    test "tied and rolled-back clocks do not hide a predecessor", ctx do
      tie = calibration!(ctx, "tie-1")
      # The same instant, then an instant before the predecessor's.
      refused =
        assert_refused(ctx, run!(ctx, :proof), "tie-2", :calibration_evidence_pending, %{},
          calibration: marker()
        )

      assert refused.check == {:predecessor_unlatched, tie.invocation.id}
      Clock.freeze(DateTime.add(@now, -3600, :second))

      assert {:error, %Refused{reason: :calibration_evidence_pending}} =
               reserve(run!(ctx, :proof), "rollback", %{}, calibration: marker())
    end

    test "real history without a recorded authority blocks, fail-closed", ctx do
      run = run!(ctx, :proof)

      context =
        AdmissionContext.context(%{
          grant_id: ctx.grant.id,
          allocation_id: proof_allocation(ctx),
          reserved_at: @now
        })

      {:ok, fake} =
        Agents.reserve_model_invocation(run.run, AgentsFixtures.model_attrs("seed-legacy"),
          actor: run.agent
        )

      legacy =
        "legacy-proof"
        |> AgentsFixtures.claude_attrs()
        |> Map.drop([:request])
        |> Map.merge(%{
          agent_run_id: run.run.id,
          sequence_in_run: 2,
          request_sha256: fake.request_sha256
        })

      # A row written before slice B: its reservation event names no tuple.
      {:ok, legacy} =
        ModelInvocation
        |> Ash.Changeset.for_create(:reserve, legacy, actor: run.agent, context: context)
        |> Ash.create()

      refused =
        assert_refused(ctx, run!(ctx, :proof), "after-legacy", :calibration_evidence_pending, %{},
          calibration: marker()
        )

      assert refused.check == {:predecessor_authority_invalid, legacy.id}
      [failure] = Enum.filter(admission_failures(ctx), &(&1.id == refused.failure_id))
      assert failure.message =~ "(predecessor_authority_invalid)"
      # The blocking row's id is structured metadata on the refusal event
      # (and the Failure's dedupe detail), not prose.
      {:ok, event} =
        Ash.get(SdrAgent.Audit.AuditEvent, refused.event_id,
          actor: SdrAgent.Actor.system(:kernel, nil),
          authorize?: false
        )

      assert event.payload["check"] == "predecessor_authority_invalid:#{legacy.id}"
    end

    # Review (B4'): a recorded tuple that decodes but names another profile
    # than its own row is invalid authority, not merely unlatched.
    test "a predecessor whose tuple names another profile is invalid authority", ctx do
      run = run!(ctx, :proof)

      context =
        AdmissionContext.context(%{
          grant_id: ctx.grant.id,
          allocation_id: proof_allocation(ctx),
          reserved_at: @now,
          calibration_tuple:
            SdrAgent.Agents.Admission.Gate.tuple_record(
              AdmissionFixtures.entry(:claude_cli_sonnet)
            )
        })

      {:ok, fake} =
        Agents.reserve_model_invocation(run.run, AgentsFixtures.model_attrs("seed-foreign"),
          actor: run.agent
        )

      foreign =
        "foreign-proof"
        |> AgentsFixtures.claude_attrs()
        |> Map.drop([:request])
        |> Map.merge(%{
          agent_run_id: run.run.id,
          sequence_in_run: 2,
          request_sha256: fake.request_sha256
        })

      {:ok, foreign} =
        ModelInvocation
        |> Ash.Changeset.for_create(:reserve, foreign, actor: run.agent, context: context)
        |> Ash.create()

      refused =
        assert_refused(
          ctx,
          run!(ctx, :proof),
          "after-foreign",
          :calibration_evidence_pending,
          %{},
          calibration: marker()
        )

      assert refused.check == {:predecessor_authority_invalid, foreign.id}
    end

    test "an exhausted proof allocation stops the run :grant_exhausted", ctx do
      for n <- 1..4 do
        cal = calibration!(ctx, "spend-#{n}")
        latch!(cal)
      end

      run = run!(ctx, :proof)

      assert {:error, %Refused{reason: {:budget_exhausted, :allocation}}} =
               reserve(run, "spent", %{}, calibration: marker())
    end
  end

  defp proof_allocation(ctx), do: Enum.find(ctx.grant.allocations, &(&1.key == :proof)).id
end
