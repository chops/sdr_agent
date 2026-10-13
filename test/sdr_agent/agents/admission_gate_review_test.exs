defmodule SdrAgent.Agents.AdmissionGateReviewTest do
  @moduledoc """
  R0-07 slice B, code review of #145 (Codex's probes, adapted and widened):

    * MF1: a historical calibration tuple that agrees with its own stored
      invocation but not with the profile's current reviewed CLI version or
      model cannot launch; one that matches today's identity still can;
    * MF2: a supplied but malformed calibration marker is refused on proof
      and ordinary runs alike, never read as "no marker";
    * MF3: a caller that may not reserve on the run (or launch the
      invocation) causes no store probe and no reservation.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Checks.AdmissionContext
  alias SdrAgent.Agents.ModelInvocation
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

  describe "MF1: launch revalidates the current reviewed identity" do
    test "an old CLI version and model is refused before it is sent", ctx do
      entry = %{AdmissionFixtures.entry() | cli_version: "0.0.1", model_id: "old-reviewed-model"}
      assert_launch_refused(ctx, entry)
    end

    test "an old CLI version alone is refused", ctx do
      assert_launch_refused(ctx, %{AdmissionFixtures.entry() | cli_version: "0.0.1"})
    end

    test "an old model alone is refused", ctx do
      assert_launch_refused(ctx, %{AdmissionFixtures.entry() | model_id: "old-reviewed-model"})
    end

    test "the current reviewed identity still launches", ctx do
      {invocation, agent} = historic!(ctx, AdmissionFixtures.entry())

      assert {:ok, %{status: :sent}} =
               Agents.admit_launch(invocation.id, :claude_cli_opus, actor: agent)
    end
  end

  describe "MF2: a supplied malformed marker is refused" do
    for {label, marker} <- [
          {"an unknown profile",
           %{sdr_calibration_admission: %{profile_id: :unknown, entry: %{}}}},
          {"a missing entry", %{sdr_calibration_admission: %{profile_id: :claude_cli_opus}}},
          {"a non-atom profile", %{sdr_calibration_admission: %{profile_id: "x", entry: %{}}}},
          {"a map without the marker", %{something: :else}},
          {"a string", "calibrate"}
        ],
        origin <- [:assignment, :proof] do
      test "#{label} on a #{origin} run", ctx do
        %{run: run, agent: agent} =
          AgentsFixtures.running_run(ctx.tenant, usage_origin: unquote(origin))

        attrs = AgentsFixtures.claude_attrs("marker-#{unquote(origin)}")

        assert {:error, %Refused{reason: :calibration_not_authorized}} =
                 Agents.reserve_model_invocation(run, attrs,
                   actor: agent,
                   calibration: unquote(Macro.escape(marker))
                 )

        assert reservations(ctx) == 0
      end
    end
  end

  describe "MF3: no store probe before an authorized, tenant-scoped preflight" do
    test "a reviewer", ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)
      assert_no_probe(ctx, fn -> reserve(run, human(:reviewer, ctx.tenant)) end)
    end

    test "no actor", ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)
      assert_no_probe(ctx, fn -> reserve(run, nil) end)
    end

    test "another system actor", ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)
      assert_no_probe(ctx, fn -> reserve(run, system_actor(:reconciler, ctx.tenant)) end)
    end

    test "an agent of another tenant", ctx do
      %{run: run} = AgentsFixtures.running_run(ctx.tenant)
      assert_no_probe(ctx, fn -> reserve(run, foreign_agent()) end)
    end

    test "a run id that does not exist", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      missing = %{run | id: Ash.UUIDv7.generate()}
      assert_no_probe(ctx, fn -> reserve(missing, agent) end)
    end

    test "launch: an invocation id that does not exist", ctx do
      %{agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      assert_no_probe(ctx, fn ->
        Agents.admit_launch(Ash.UUIDv7.generate(), :claude_cli_opus, actor: agent)
      end)
    end

    test "launch: another tenant's invocation", ctx do
      {invocation, _agent} = historic!(ctx, AdmissionFixtures.entry())

      assert_no_probe(ctx, fn ->
        Agents.admit_launch(invocation.id, :claude_cli_opus, actor: foreign_agent())
      end)
    end

    test "an authorized agent is still probed", ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      attach_probe()
      assert {:ok, _invocation} = reserve(run, agent)
      assert_received :store_was_probed
    end
  end

  defp assert_launch_refused(ctx, entry) do
    {invocation, agent} = historic!(ctx, entry)

    assert {:error, %Refused{stage: :launch, reason: :calibration_not_authorized}} =
             Agents.admit_launch(invocation.id, :claude_cli_opus, actor: agent)
  end

  # A valid admitted proof reservation whose recorded calibration tuple and
  # stored identity agree on `entry`, built through the admitted-charge seam
  # (as a reservation made under an earlier reviewed profile would be).
  defp historic!(ctx, entry) do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

    {:ok, fake} =
      Agents.reserve_model_invocation(run, AgentsFixtures.model_attrs("body"), actor: agent)

    {:ok, run} = Agents.get_run(run.id, actor: agent)
    proof = Enum.find(ctx.grant.allocations, &(&1.key == :proof))

    context =
      AdmissionContext.context(%{
        grant_id: ctx.grant.id,
        allocation_id: proof.id,
        reserved_at: SdrAgent.Clock.utc_now(),
        calibration_tuple: Agents.Admission.Gate.tuple_record(entry)
      })

    attrs =
      AgentsFixtures.claude_attrs("historic-#{System.unique_integer([:positive])}")
      |> Map.drop([:request])
      |> Map.merge(%{
        agent_run_id: run.id,
        sequence_in_run: 2,
        request_sha256: fake.request_sha256,
        provider_version: entry.cli_version,
        model_id: entry.model_id
      })

    {:ok, invocation} =
      ModelInvocation
      |> Ash.Changeset.for_create(:reserve, attrs, actor: agent, context: context)
      |> Ash.create()

    {invocation, agent}
  end

  # The deployment has one singleton tenant, so another tenant's agent is
  # an agent runtime actor scoped to a tenant id that is not this one.
  defp foreign_agent,
    do: struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: Ash.UUIDv7.generate())

  defp reserve(run, actor),
    do:
      Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs("preflight"), actor: actor)

  defp assert_no_probe(ctx, fun) do
    before = reservations(ctx)
    attach_probe()
    assert {:error, _denied} = fun.()
    refute_received :store_was_probed
    assert reservations(ctx) == before
  end

  defp attach_probe do
    parent = self()
    handler = "review-store-probe-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :admission, :store_probe, :start],
      fn _event, _measurements, _meta, _config -> send(parent, :store_was_probed) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp reservations(ctx) do
    auditor = system_actor(:auditor_cli, ctx.tenant)

    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: auditor)
    |> Ash.read!()
    |> Enum.count(&(&1.provider == :claude_cli))
  end
end
