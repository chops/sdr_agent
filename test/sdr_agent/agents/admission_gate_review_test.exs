defmodule SdrAgent.Agents.AdmissionGateReviewTest do
  @moduledoc """
  R0-07 slice B, code review of #145 (Codex probes, adapted): MF1 a
  historical calibration tuple that no longer matches the current reviewed
  profile cannot launch; MF2 a supplied malformed calibration marker is
  refused, never treated as an ordinary call; MF3 a caller that may not
  reserve on the run causes no store probe.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.AgentsFixtures

  setup do
    tenant = bootstrap!()

    grant =
      AgentsFixtures.grant!(tenant, %{
        total_attempts: 10,
        allocations: [
          %{key: :b1, applies_to: [:b1], attempts: 5},
          %{key: :proof, applies_to: [:proof], attempts: 5}
        ]
      })

    AdmissionFixtures.admit_tuples!()
    %{tenant: tenant, grant: grant}
  end

  test "malformed supplied calibration authority must not become an ordinary call", ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    marker = %{sdr_calibration_admission: %{profile_id: :unknown_profile, entry: %{}}}

    assert {:error, %Refused{reason: :calibration_not_authorized}} =
             Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("bad-marker"),
               actor: agent,
               calibration: marker
             )
  end

  test "historic calibration tuple matching stored identity but not current profile cannot launch",
       ctx do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

    {:ok, fake} =
      Agents.reserve_model_invocation(run, AgentsFixtures.model_attrs("body"), actor: agent)

    {:ok, run} = Agents.get_run(run.id, actor: agent)
    entry = %{AdmissionFixtures.entry() | cli_version: "0.0.1", model_id: "old-reviewed-model"}
    proof = Enum.find(ctx.grant.allocations, &(&1.key == :proof))
    # Valid historical admitted row/event: the snapshot and its reservation tuple agree.
    # Its profile id still exists, but the current reviewed identity has changed.
    context =
      AdmissionContext.context(%{
        grant_id: ctx.grant.id,
        allocation_id: proof.id,
        reserved_at: SdrAgent.Clock.utc_now(),
        calibration_tuple: Agents.Admission.Gate.tuple_record(entry)
      })

    attrs =
      AgentsFixtures.claude_attrs("historic")
      |> Map.drop([:request])
      |> Map.merge(%{
        agent_run_id: run.id,
        sequence_in_run: 2,
        request_sha256: fake.request_sha256,
        provider_version: entry.cli_version,
        model_id: entry.model_id
      })

    {:ok, invocation} =
      Agents.ModelInvocation
      |> Ash.Changeset.for_create(:reserve, attrs, actor: agent, context: context)
      |> Ash.create()

    assert {:error, %Refused{stage: :launch, reason: :calibration_not_authorized}} =
             Agents.admit_launch(invocation.id, :claude_cli_opus, actor: agent)
  end

  test "unauthorized reservation must be refused before probing the store", ctx do
    %{run: run} = AgentsFixtures.running_run(ctx.tenant)
    parent = self()
    handler = "codex-unauth-store-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :admission, :store_probe, :start],
      fn _, _, _, _ -> send(parent, :store_was_probed) end,
      nil
    )

    try do
      assert {:error, %Ash.Error.Forbidden{}} =
               Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("unauth"),
                 actor: human(:reviewer, ctx.tenant)
               )

      refute_received :store_was_probed
    after
      :telemetry.detach(handler)
    end
  end
end
