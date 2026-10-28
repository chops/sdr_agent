defmodule SdrAgent.Prototype.LaunchTest do
  @moduledoc """
  IF-4 launch (interfaces r6; amendment item 4 "Re-derived at launch"; Codex
  P1), D-237 slice S2, in prototype runtime.

  Launch (`Agents.admit_launch/3`, unchanged arity; the prototype branch of
  `Admission.Gate.admit_launch/3` under `Admission.lock_charge/1` and the
  head) compares every one of the 14 recorded keys of the invocation's one
  original `model.invocation.reserved` event with the boot snapshot, the
  compiled entries and the invocation's charge, and the grant's current
  revision, creator and updater. Any difference, or a missing, duplicated
  or malformed record, refuses with `:prototype_not_authorized` and the
  exact check; a launch refusal keeps its charge (the invocation is failed,
  never sent, never refunded).

  RED-b1 (before S1 provisioning): a reservation recorded without prototype
  authority (reserved before prototype runtime) refuses `authority_unrecorded`;
  a live binding drift refuses `binding_mismatch` first; a set store root
  refuses `witness_mode_mismatch`, even with a promoted tuple. The
  comparisons of each recorded key and of the provisioned grant's current
  revision, creator and updater follow as RED-b2.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G

  defp refused_at_launch(result, check) do
    match?(
      {:error, %Refused{reason: :prototype_not_authorized, check: ^check, stage: :launch}},
      result
    )
  end

  defp status(invocation),
    do: Ash.get!(ModelInvocation, invocation.id, authorize?: false).status

  defp assert_charged_refusal(ctx, result, check) do
    assert refused_at_launch(result, check), "launch: #{inspect(result)}"
    assert status(ctx.invocation) == :failed
    assert G.charged(ctx.fx) == 1
  end

  describe "before provisioning: a reservation recorded without prototype authority" do
    # Reserved through the ordinary domain path before prototype runtime was
    # entered (an admin's ordinary grant; the ordinary admission gate), so its
    # one reservation event records no prototype authority. Launch in
    # prototype runtime never falls back to the ordinary launch checks.
    setup do
      fx = G.bound!()
      grant = AgentsFixtures.grant!(fx.tenant, %{}, fx.admin)
      run = G.run!(fx)

      {:ok, invocation} =
        AdmissionFixtures.admitting(fn ->
          SdrAgent.Agents.reserve_model_invocation(run, G.call_attrs(), actor: fx.agent)
        end)

      G.enter!(fx)
      %{fx: Map.put(fx, :grant, grant), run: run, invocation: invocation}
    end

    test "it refuses authority_unrecorded, charged", ctx do
      assert_charged_refusal(ctx, G.launch(ctx.fx, ctx.invocation), :authority_unrecorded)
    end

    test "a live binding drift refuses binding_mismatch first, charged (check_live row)", ctx do
      G.drift!()
      assert_charged_refusal(ctx, G.launch(ctx.fx, ctx.invocation), :binding_mismatch)
    end

    test "a set store root refuses witness_mode_mismatch, even with a promoted tuple", ctx do
      AdmissionFixtures.admit_tuples!()
      assert_charged_refusal(ctx, G.launch(ctx.fx, ctx.invocation), :witness_mode_mismatch)
    end
  end
end
