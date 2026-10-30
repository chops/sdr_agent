defmodule SdrAgent.Prototype.ReleasedOutputRefTest do
  @moduledoc """
  RED, D-269 G4 (Codex m_codex_d268_hash_blocker_20261030T160530): the
  authoritative draft's input ref of its ModelInvocation.

  `SdrAgent.SDR.Support.authoritative_draft/3` reads the invocation as the
  agent with no read context, so a generation-2 ClaudeCLI row's output
  fields are `Ash.ForbiddenField` (the R0-07 field policy) and
  `SdrAgent.Audit.RecordHash.hex/1` of it raises in `Canonical.encode!/1`
  (ValidateDraftShape and ValidatePersonalization crash). The fix keeps the
  field policy and the hash: `SdrAgent.Agents.released_output_ref/2`
  returns ONLY the input ref (resource, id, `record_sha256` of the whole
  stored row), computed behind the same released-output read as
  `released_output/2`, and refuses exactly where that read refuses.

  Over a real committed `released_unverified` release (S1 provisioning and
  `ResultGate.finalize/4`); synthetic fixture completion only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Audit.RecordHash
  alias SdrAgent.PrototypeGateFixtures, as: G

  setup do
    fx = G.prototype!()
    run = G.run!(fx)
    invocation = G.completed!(fx, run)
    result = G.finalize(invocation, run)

    assert match?({:released, %{disposition: :released_unverified}, _}, result),
           "prerequisite: the release: #{inspect(result)}"

    %{fx: fx, invocation: invocation}
  end

  defp ref(ctx, actor) do
    assert function_exported?(Agents, :released_output_ref, 2),
           "SdrAgent.Agents.released_output_ref/2 is not built"

    apply(Agents, :released_output_ref, [ctx.invocation, [actor: actor]])
  end

  test "the boundary: the agent's plain read masks the output fields, so hashing it raises",
       ctx do
    {:ok, masked} = Agents.get_model_invocation(ctx.invocation.id, actor: ctx.fx.agent)
    assert %Ash.ForbiddenField{} = masked.parsed_output
    assert_raise ArgumentError, ~r/cannot canonicalize/, fn -> RecordHash.hex(masked) end
  end

  test "prototype runtime: only the ref, hashing the whole stored row", ctx do
    stored = Ash.get!(ModelInvocation, ctx.invocation.id, authorize?: false)

    assert ref(ctx, ctx.fx.agent) ==
             {:ok,
              %{
                resource: inspect(ModelInvocation),
                id: ctx.invocation.id,
                record_sha256: RecordHash.hex(stored)
              }}
  end

  test "ordinary runtime: refused exactly like the released-output read", ctx do
    :ok = PrototypeFixtures.leave_runtime()
    assert ref(ctx, ctx.fx.agent) == {:error, :result_not_released}
  end

  test "another tenant's actor: not_found", ctx do
    foreign = SdrAgent.Actor.system(:agent_runtime, Ecto.UUID.generate())
    assert ref(ctx, foreign) == {:error, :not_found}
  end

  # Controls (Codex review codex-d269-ref-entity-red-review-20261030.org).
  test "a live binding drift (invalid prototype basis): refused like the read", ctx do
    G.drift!()
    read = Agents.released_output(ctx.invocation, actor: ctx.fx.agent)
    assert match?({:error, _}, read)
    assert ref(ctx, ctx.fx.agent) == read
  end

  test "an unreleased generation-2 invocation: result_not_released", %{fx: fx} do
    run = G.run!(fx)
    unreleased = G.completed!(fx, run)
    ctx = %{fx: fx, invocation: unreleased}
    assert Agents.released_output(unreleased, actor: fx.agent) == {:error, :result_not_released}
    assert ref(ctx, fx.agent) == {:error, :result_not_released}
  end

  test "a Fake invocation outside the gate: the full-row ref, never the output", %{fx: fx} do
    run = G.run!(fx)
    :ok = PrototypeFixtures.leave_runtime()
    key = "d269-ref-fake-#{System.unique_integer([:positive])}"

    {:ok, reserved} =
      Agents.reserve_model_invocation(run, SdrAgent.AgentsFixtures.model_attrs(key),
        actor: fx.agent
      )

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: fx.agent)

    {:ok, fake} =
      Agents.complete_model_invocation(sent, SdrAgent.AgentsFixtures.completion(),
        actor: fx.agent
      )

    assert {:ok, _output} = Agents.released_output(fake, actor: fx.agent)
    stored = Ash.get!(ModelInvocation, fake.id, authorize?: false)

    assert ref(%{invocation: fake}, fx.agent) ==
             {:ok,
              %{
                resource: inspect(ModelInvocation),
                id: fake.id,
                record_sha256: RecordHash.hex(stored)
              }}
  end
end
