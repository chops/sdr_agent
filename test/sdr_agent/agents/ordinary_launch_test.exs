defmodule SdrAgent.Agents.OrdinaryLaunchTest do
  @moduledoc """
  L2 E3 (`notes/features/l2-e3-ordinary-calls.org`, plan PASS `e462d48`,
  Codex `cad33c66`): launch admission's ordinary mode
  (`Agents.admit_launch/3` with `ordinary_launch: true`, set only by the
  ordinary `ClaudeCLI.staged/3` clause).

  - The option is exactly `true`; any other present value, or the option
    together with `calibration_launch:` (an explicit nil included), is
    `:calibration_launch_invalid` before any target read (the existing
    refusal audit is kept; no invocation, charge or launch mutation).
  - Under the launch locks, after the existing run-state, legacy-row and
    profile refusals, a `:proof` run is refused (`:calibration_not_authorized`
    / `:ordinary_scope`), committed with the failed row.
  - Recorded-authority evidence stays with the existing `Gate.admit_launch/3`
    re-read under the same locks (controls: `:not_a_proof_run`,
    `:authority_invalid`, a duplicate appended after reservation).
  - Without the option, behaviour is unchanged.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Audit

  setup do
    AdmissionFixtures.admit_tuples!()
    tenant = bootstrap!()
    admin = human(:admin, tenant)

    AgentsFixtures.grant!(
      tenant,
      %{
        total_attempts: 20,
        allocations: [
          %{key: :b1, applies_to: [:b1], attempts: 10},
          %{key: :proof, applies_to: [:proof], attempts: 10}
        ]
      },
      admin
    )

    %{tenant: tenant, admin: admin, kernel: system_actor(:kernel, tenant)}
  end

  ## Fixtures

  defp ordinary!(ctx) do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    attrs = AgentsFixtures.claude_attrs("o-#{System.unique_integer([:positive])}")

    {:ok, invocation} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs, actor: agent)
      end)

    %{run: run, agent: agent, invocation: invocation}
  end

  defp proof!(ctx) do
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)
    attrs = AgentsFixtures.claude_attrs("p-#{System.unique_integer([:positive])}")

    {:ok, invocation} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs,
          actor: agent,
          calibration: AdmissionFixtures.calibration()
        )
      end)

    %{run: run, agent: agent, invocation: invocation}
  end

  defp launch(%{invocation: invocation, agent: agent}, opts) do
    AdmissionFixtures.admitting(fn ->
      Agents.admit_launch(invocation.id, :claude_cli_opus, [actor: agent] ++ opts)
    end)
  end

  defp stored(%{invocation: invocation}),
    do: Ash.get!(ModelInvocation, invocation.id, authorize?: false)

  defp launch_refusals(ctx, %{invocation: invocation}) do
    ctx.tenant
    |> events_of_type("model.launch.refused")
    |> Enum.filter(&(&1.subject_id == invocation.id))
  end

  @reservation "event_type = 'model.invocation.reserved' AND model_invocation_id = $1"

  defp reservation_payload(%{invocation: invocation}) do
    %{rows: [[payload]]} =
      Repo.query!("SELECT payload FROM audit_events WHERE #{@reservation}", [
        Ecto.UUID.dump!(invocation.id)
      ])

    payload
  end

  defp set_reservation_payload!(%{invocation: invocation}, payload) do
    tamper!("UPDATE audit_events SET payload = $2 WHERE #{@reservation}", [
      Ecto.UUID.dump!(invocation.id),
      payload
    ])

    assert %{rows: [["origin"]]} = Repo.query!("SHOW session_replication_role")
  end

  defp append_duplicate_reservation!(ctx, %{invocation: invocation}) do
    {:ok, _} =
      Audit.append(
        %{
          event_type: "model.invocation.reserved",
          category: :model,
          subject_resource: "SdrAgent.Agents.ModelInvocation",
          subject_id: invocation.id,
          action: "reserve",
          model_invocation_id: invocation.id,
          agent_run_id: invocation.agent_run_id,
          payload: %{"arguments" => %{}}
        },
        actor: ctx.kernel
      )
  end

  defp assert_refused(result, reason, check, message) do
    assert match?({:error, %Refused{stage: :launch, reason: ^reason, check: ^check}}, result),
           message <> "; got " <> inspect(result)
  end

  ## The proof run

  describe "ordinary mode on a proof run" do
    test "is refused by the locked run, committed with the failed row", ctx do
      target = proof!(ctx)

      assert_refused(
        launch(target, ordinary_launch: true),
        :calibration_not_authorized,
        :ordinary_scope,
        "E3: ordinary mode refuses a :proof run at launch"
      )

      row = stored(target)
      assert {row.status, row.sent_at} == {:failed, nil}
      assert [event] = launch_refusals(ctx, target)
      assert event.payload["reason"] == "calibration_not_authorized"
    end

    test "control: the run-state refusal still comes first", ctx do
      target = proof!(ctx)
      {:ok, _} = Agents.cancel_run(target.run, actor: ctx.admin)

      # A run stopped before launch is the existing bare refusal.
      assert launch(target, ordinary_launch: true) == {:error, :run_not_running_at_launch}
    end
  end

  ## The option's shape

  describe "the ordinary_launch option" do
    for value <- [nil, false, "true", 1] do
      test "ordinary_launch: #{inspect(value)} is :calibration_launch_invalid", ctx do
        target = ordinary!(ctx)
        result = launch(target, ordinary_launch: unquote(value))

        assert result == {:error, :calibration_launch_invalid},
               "E3: only ordinary_launch: true is valid; got #{inspect(result)}"

        assert stored(target).status == :reserved
      end
    end

    test "together with a well-formed calibration_launch is invalid", ctx do
      target = ordinary!(ctx)

      expected = %{
        run_id: target.run.id,
        tenant_id: ctx.tenant.id,
        request_sha256: target.invocation.request_sha256,
        prompt_ref: SdrAgent.CalibrationConsole.Prompt.prompt_ref(),
        schema_ref: SdrAgent.CalibrationConsole.Prompt.schema_ref()
      }

      result = launch(target, ordinary_launch: true, calibration_launch: expected)

      assert result == {:error, :calibration_launch_invalid},
             "E3: the two launch modes exclude each other; got #{inspect(result)}"

      assert stored(target).status == :reserved
    end

    test "control: together with an explicit calibration_launch: nil is invalid", ctx do
      target = ordinary!(ctx)

      assert launch(target, ordinary_launch: true, calibration_launch: nil) ==
               {:error, :calibration_launch_invalid}

      assert stored(target).status == :reserved
    end

    test "control: an ordinary reservation in ordinary mode is sent", ctx do
      target = ordinary!(ctx)
      assert {:ok, %ModelInvocation{status: :sent}} = launch(target, ordinary_launch: true)
    end
  end

  ## Recorded authority stays with the gate's locked re-read

  describe "control: the gate's recorded-authority evidence in ordinary mode" do
    test "an assignment row whose reservation names a tuple is :not_a_proof_run", ctx do
      tuple = proof!(ctx) |> reservation_payload() |> get_in(["arguments", "calibration_tuple"])
      assert is_map(tuple)
      target = ordinary!(ctx)
      payload = reservation_payload(target)
      arguments = Map.put(payload["arguments"] || %{}, "calibration_tuple", tuple)
      set_reservation_payload!(target, Map.put(payload, "arguments", arguments))

      assert_refused(
        launch(target, ordinary_launch: true),
        :calibration_not_authorized,
        :not_a_proof_run,
        "the gate refuses recorded authority on a non-proof run"
      )
    end

    test "a missing reservation event is :authority_invalid", ctx do
      target = ordinary!(ctx)

      tamper!("DELETE FROM audit_events WHERE #{@reservation}", [
        Ecto.UUID.dump!(target.invocation.id)
      ])

      assert %{rows: [["origin"]]} = Repo.query!("SHOW session_replication_role")

      assert_refused(
        launch(target, ordinary_launch: true),
        :calibration_not_authorized,
        :authority_invalid,
        "missing evidence fails closed"
      )
    end

    test "a duplicate appended after reservation is seen at launch: :authority_invalid", ctx do
      target = ordinary!(ctx)
      append_duplicate_reservation!(ctx, target)

      assert_refused(
        launch(target, ordinary_launch: true),
        :calibration_not_authorized,
        :authority_invalid,
        "a late duplicate is seen by the locked re-read"
      )
    end
  end
end
