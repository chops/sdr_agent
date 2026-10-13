defmodule SdrAgent.Agents.RecoverCalibrationTest do
  @moduledoc """
  R0-07 slice E4c, sub-slice c2 (packet 8.12 E4c-4/E4c-5, entity PASS at
  25c1b18): the calibration recovery action
  `SdrAgent.Agents.recover_calibration(invocation, decision, actor:)` and
  the audited owner attestation.

  Test-seam builds and the calibration console only; AGT of the tenant; its
  own generation-2 real-profile ClaudeCLI invocation of a `:proof` run with
  no Operation and exactly one original reservation event. In one
  transaction (run `FOR UPDATE` → invocation `FOR UPDATE` → head):

    * `reserved` with `:unlaunched` → `failed` (`abandoned_before_launch`);
    * `sent` with `{:quiescent, observation}` or `{:attested, attestation}`
      → `unknown`; `sent` otherwise → `:calibration_not_quiescent`, nothing
      written;
    * a terminal invocation needs no transition (a sent-history one is
      never unlaunched);
    * `{:attested, attestation}` appends `calibration.owner_attested` with
      the immutable metadata payload, deduplicated by `attestation_id`
      (identical replay reuses it; a different payload under the same id
      is `:attestation_conflict`). The attestation must bind this
      invocation and its recorded claim (`:attestation_mismatch`).

  No grant, no model call, the original charge kept.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.AgentsFixtures

  setup do
    tenant = bootstrap!()

    AgentsFixtures.grant!(tenant, %{
      total_attempts: 10,
      allocations: [
        %{key: :b1, applies_to: [:b1], attempts: 5},
        %{key: :proof, applies_to: [:proof], attempts: 5}
      ]
    })

    # After the fixtures: a missing action fails as an assertion.
    Code.ensure_loaded!(Agents)

    assert function_exported?(Agents, :recover_calibration, 3),
           "Agents.recover_calibration/3 is not defined"

    %{tenant: tenant}
  end

  describe "transitions" do
    test "reserved and unlaunched → failed (abandoned_before_launch)", ctx do
      %{invocation: reserved, agent: agent} = claimed!(ctx, :reserved)

      assert {:ok, %{invocation: failed}} = recover(reserved, :unlaunched, agent)
      assert failed.status == :failed
      assert failed.error == %{"kind" => "abandoned_before_launch"}
      assert is_nil(failed.sent_at)
      assert events_of_type(ctx.tenant, "calibration.owner_attested") == []
    end

    test "sent is never unlaunched: nothing written", ctx do
      %{invocation: sent, agent: agent} = claimed!(ctx, :sent)
      before = event_count(ctx)

      assert {:error, :calibration_not_quiescent} = recover(sent, :unlaunched, agent)
      assert event_count(ctx) == before
      assert reload(sent, agent).status == :sent
    end

    test "sent and observed quiescent → unknown", ctx do
      %{invocation: sent, agent: agent} = claimed!(ctx, :sent)
      observation = %{state: "launched", root_pid: 9001, process_group_id: 9001}

      assert {:ok, %{invocation: unknown}} = recover(sent, {:quiescent, observation}, agent)
      assert unknown.status == :unknown
      assert events_of_type(ctx.tenant, "calibration.owner_attested") == []
    end

    test "sent and attested → unknown with one owner_attested event", ctx do
      %{invocation: sent, agent: agent, claim: claim} = claimed!(ctx, :sent)
      attestation = attestation(sent, claim)

      assert {:ok, %{invocation: unknown}} = recover(sent, {:attested, attestation}, agent)
      assert unknown.status == :unknown

      assert [event] = events_of_type(ctx.tenant, "calibration.owner_attested")
      assert event.model_invocation_id == sent.id
      assert event.payload == stringify(attestation)
    end

    test "an attestation replay reuses its event; another payload conflicts", ctx do
      %{invocation: sent, agent: agent, claim: claim} = claimed!(ctx, :sent)
      attestation = attestation(sent, claim)
      {:ok, %{invocation: unknown}} = recover(sent, {:attested, attestation}, agent)
      before = event_count(ctx)

      assert {:ok, %{invocation: replayed}} = recover(unknown, {:attested, attestation}, agent)
      assert {replayed.id, replayed.status} == {unknown.id, :unknown}
      assert event_count(ctx) == before

      changed = %{attestation | confirmed_at: timestamp()}
      assert {:error, :attestation_conflict} = recover(unknown, {:attested, changed}, agent)
      assert event_count(ctx) == before
    end

    test "a sent-history terminal invocation needs no transition", ctx do
      %{invocation: sent, agent: agent, claim: claim} = claimed!(ctx, :sent)

      {:ok, failed} =
        Agents.fail_model_invocation(sent, %{error: %{"kind" => "launch_failed"}}, actor: agent)

      before = event_count(ctx)
      assert {:error, :calibration_not_quiescent} = recover(failed, :unlaunched, agent)
      assert event_count(ctx) == before

      assert {:ok, %{invocation: same}} =
               recover(failed, {:attested, attestation(failed, claim)}, agent)

      assert same.status == :failed
      assert same.error == %{"kind" => "launch_failed"}
      assert length(events_of_type(ctx.tenant, "calibration.owner_attested")) == 1
    end

    test "a pre-sent refusal (failed, never sent) is unlaunched with its reason kept", ctx do
      %{invocation: reserved, agent: agent} = claimed!(ctx, :reserved)

      {:ok, refused} =
        Agents.fail_model_invocation(
          reserved,
          %{error: %{"kind" => "calibration_grant_mismatch"}},
          actor: agent
        )

      before = event_count(ctx)
      assert {:ok, %{invocation: same}} = recover(refused, :unlaunched, agent)
      assert same.error == %{"kind" => "calibration_grant_mismatch"}
      assert event_count(ctx) == before
    end
  end

  describe "binding" do
    test "an attestation of another invocation, claim or shape is a mismatch", ctx do
      %{invocation: sent, agent: agent, claim: claim} = claimed!(ctx, :sent)
      good = attestation(sent, claim)
      before = event_count(ctx)

      for wrong <- [
            %{good | invocation_id: Ash.UUIDv7.generate()},
            %{good | instance_id: Ash.UUIDv7.generate()},
            Map.put(good, :extra, "x"),
            Map.delete(good, :ticket_id),
            %{good | observation: Map.put(good.observation, :extra, 1)}
          ] do
        assert recover(sent, {:attested, wrong}, agent) == {:error, :attestation_mismatch},
               inspect(wrong)
      end

      assert event_count(ctx) == before
      assert reload(sent, agent).status == :sent
    end

    test "an invocation without a recorded claim cannot be attested", ctx do
      %{invocation: sent, agent: agent} = claimed!(ctx, :sent, claim: nil)
      attestation = attestation(sent, Ash.UUIDv7.generate())

      assert {:error, :attestation_mismatch} = recover(sent, {:attested, attestation}, agent)
    end

    test "an unknown decision is refused", ctx do
      %{invocation: sent, agent: agent} = claimed!(ctx, :sent)

      for decision <- [:stopped, {:quiescent, nil}, {:attested, nil}, nil] do
        assert {:error, :calibration_not_recoverable} == recover(sent, decision, agent),
               inspect(decision)
      end
    end
  end

  describe "scope" do
    test "a business invocation is not recoverable here", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      {:ok, business} =
        AdmissionFixtures.admitting(fn ->
          Agents.reserve_model_invocation(run, attrs(), actor: agent)
        end)

      assert {:error, :calibration_not_recoverable} = recover(business, :unlaunched, agent)
    end

    test "only the tenant's AGT may recover", ctx do
      %{invocation: reserved} = claimed!(ctx, :reserved)
      auditor = system_actor(:auditor_cli, ctx.tenant)
      foreign = system_actor(:agent_runtime, %{ctx.tenant | id: Ash.UUIDv7.generate()})

      for actor <- [auditor, foreign, nil] do
        assert {:error, %Ash.Error.Forbidden{}} = recover(reserved, :unlaunched, actor)
      end
    end
  end

  ## Fixtures

  # A proof-run calibration invocation reserved under a console claim and
  # advanced to `state`.
  defp claimed!(ctx, state, opts \\ []) do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)
    claim = Keyword.get(opts, :claim, Ash.UUIDv7.generate())

    marker =
      if claim,
        do:
          CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry(), claim: claim),
        else: CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry())

    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs(), actor: agent, calibration: marker)
      end)

    invocation =
      case state do
        :reserved ->
          reserved

        :sent ->
          {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
          sent
      end

    %{invocation: invocation, agent: agent, claim: claim, run: run}
  end

  defp attestation(invocation, claim) do
    %{
      schema: "r0-calibration-attestation/1",
      attestation_id: Ash.UUIDv7.generate(),
      instance_id: claim,
      invocation_id: invocation.id,
      ticket_id: Ash.UUIDv7.generate(),
      observation: %{state: "launch_pending", root_pid: nil, process_group_id: nil},
      confirmed_at: timestamp()
    }
  end

  defp stringify(%{} = map),
    do: Map.new(map, fn {k, v} -> {Atom.to_string(k), stringify(v)} end)

  defp stringify(value), do: value

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp attrs, do: AgentsFixtures.claude_attrs("recover-#{System.unique_integer([:positive])}")

  defp recover(invocation, decision, actor),
    do: apply(Agents, :recover_calibration, [invocation, decision, [actor: actor]])

  defp reload(invocation, agent) do
    {:ok, [stored]} =
      Agents.list_model_invocations(invocation.agent_run_id, actor: agent)
      |> then(fn {:ok, rows} -> {:ok, Enum.filter(rows, &(&1.id == invocation.id))} end)

    stored
  end

  defp event_count(ctx), do: length(events(ctx.tenant))
end
