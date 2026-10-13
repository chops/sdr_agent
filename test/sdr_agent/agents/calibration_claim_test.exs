defmodule SdrAgent.Agents.CalibrationClaimTest do
  @moduledoc """
  R0-07 slice E4c, sub-slice c1 (packet 8.12 E4c-2 "Durable claim
  binding", entity PASS at 25c1b18): the reservation event of a calibration
  call records the console's launch-record claim, so a crash between
  reserve and `launch_pending` still associates the claim with its
  invocation.

    * `CalibrationAdmission.context(profile_id, entry, claim: instance_id)`
      (test-seam builds) carries the claim inside the admission marker;
      `context/2` stays claimless.
    * The original `model.invocation.reserved` event records
      `calibration_claim: %{"instance_id" => id}` next to
      `calibration_tuple`, set only from the admitted marker. A caller
      cannot supply it, and a malformed claim makes the marker invalid
      (`:calibration_not_authorized`), never a claimless reservation.
    * `Gate.recorded_claim/1` re-derives it from the one original event:
      `{:ok, %{instance_id: id}}`, `{:ok, nil}` (none recorded), or
      `{:error, :claim_unrecorded}` (missing or duplicated event, malformed
      claim).
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Gate
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

    # After the fixtures: missing APIs fail as assertions.
    Code.ensure_loaded!(CalibrationAdmission)
    Code.ensure_loaded!(Gate)

    assert function_exported?(CalibrationAdmission, :context, 3),
           "CalibrationAdmission.context/3 (with claim:) is not defined"

    assert function_exported?(Gate, :recorded_claim, 1), "Gate.recorded_claim/1 is not defined"

    %{tenant: tenant}
  end

  test "a claimed calibration reservation records the claim on its reserved event", ctx do
    %{run: run, agent: agent} = proof_run(ctx)
    claim = Ash.UUIDv7.generate()

    assert {:ok, invocation} = reserve(run, agent, calibration: marker(claim: claim))
    assert [event] = reserved_events(ctx, invocation)

    assert event.payload["arguments"]["calibration_claim"] == %{"instance_id" => claim}
    assert event.payload["arguments"]["calibration_tuple"]["profile_id"] == "claude_cli_opus"
    assert Gate.recorded_claim(invocation) == {:ok, %{instance_id: claim}}
  end

  test "a claimless calibration reservation records no claim", ctx do
    %{run: run, agent: agent} = proof_run(ctx)

    assert {:ok, invocation} =
             reserve(run, agent,
               calibration: CalibrationAdmission.context(:claude_cli_opus, entry())
             )

    assert [event] = reserved_events(ctx, invocation)
    assert event.payload["arguments"]["calibration_claim"] == nil
    assert Gate.recorded_claim(invocation) == {:ok, nil}
  end

  test "a business reservation records no claim", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    assert {:ok, invocation} = reserve(run, agent, [])
    assert Gate.recorded_claim(invocation) == {:ok, nil}
  end

  test "a caller cannot supply a claim", ctx do
    %{run: run, agent: agent} = proof_run(ctx)
    claim = Ash.UUIDv7.generate()

    result =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(
          run,
          Map.put(attrs(), :calibration_claim, %{"instance_id" => claim}),
          actor: agent,
          calibration: CalibrationAdmission.context(:claude_cli_opus, entry())
        )
      end)

    assert match?({:error, _}, result), inspect(result)
    assert reserved_with_claim(ctx, claim) == []
  end

  test "a malformed claim is an invalid marker, never a claimless reservation", ctx do
    for bad <- ["not-a-uuid", 7, %{"instance_id" => Ash.UUIDv7.generate()}] do
      %{run: run, agent: agent} = proof_run(ctx)

      forged = %{
        sdr_calibration_admission: %{profile_id: :claude_cli_opus, entry: entry(), claim: bad}
      }

      result = reserve(run, agent, calibration: forged)
      assert match?({:error, _}, result), inspect(bad)
      assert inspect(result) =~ "calibration_not_authorized", inspect(result)
    end

    assert_raise ArgumentError, fn ->
      CalibrationAdmission.context(:claude_cli_opus, entry(), claim: "not-a-uuid")
    end
  end

  test "recorded_claim refuses an invocation without its original reservation event", ctx do
    %{run: run, agent: agent} = proof_run(ctx)
    {:ok, invocation} = reserve(run, agent, calibration: marker(claim: Ash.UUIDv7.generate()))

    assert Gate.recorded_claim(%{invocation | id: Ash.UUIDv7.generate()}) ==
             {:error, :claim_unrecorded}
  end

  ## Fixtures

  defp proof_run(ctx), do: AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

  defp entry, do: AdmissionFixtures.entry()

  defp marker(opts), do: CalibrationAdmission.context(:claude_cli_opus, entry(), opts)

  defp attrs, do: AgentsFixtures.claude_attrs("claim-#{System.unique_integer([:positive])}")

  defp reserve(run, agent, opts) do
    AdmissionFixtures.admitting(fn ->
      Agents.reserve_model_invocation(run, attrs(), [actor: agent] ++ opts)
    end)
  end

  defp reserved_events(ctx, invocation) do
    ctx.tenant
    |> events_of_type("model.invocation.reserved")
    |> Enum.filter(&(&1.model_invocation_id == invocation.id))
  end

  defp reserved_with_claim(ctx, claim) do
    ctx.tenant
    |> events_of_type("model.invocation.reserved")
    |> Enum.filter(
      &(get_in(&1.payload, ["arguments", "calibration_claim", "instance_id"]) == claim)
    )
  end
end
