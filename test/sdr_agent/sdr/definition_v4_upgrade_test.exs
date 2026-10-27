defmodule SdrAgent.SDR.DefinitionV4UpgradeTest do
  @moduledoc """
  B1-04/B1-05 change the `SDRAgent` definition body (Codex r1 M1; plan
  `claude-b1-research-draft-plan-r2.md`): two prompt templates change, three
  action contracts change (`BuildEvidenceBundle`, `DraftEmail`,
  `HandOffProposal` to version "2") and `ValidateDraftShape` (version "1")
  is added, so SDRAgent is a new immutable definition, v4.

  On a database already holding SDRAgent v3 (the frozen v3 body of
  `SdrAgent.SDRDefinitionFixtures`): the v3 row stays byte-identical; the
  frozen v4 body (`v4_body/0`, PR #234 GREEN `5e4c82da`) registers as v4
  idempotently with only those differences; a different body under v4 is
  refused; a new assignment pins the current definition. B1-R1 (route
  `claude-b1-r1-version-route-r1.md`): the current definition is v5 (its
  upgrade from the frozen v4 is `SdrAgent.SDR.DefinitionV5UpgradeTest`), so
  these tests describe the frozen v4 body rather than the current
  registration.

  Legacy execution (conservative refusal): a run pinned to a definition
  that does not declare a changed action at its current version (any
  pre-v4 run, queued or an operator retry, which keeps its pin) fails
  closed at that action, as `:crash` with the fixed failure reason
  "the run's agent definition does not declare this action version",
  before any settings read or model call. Unchanged actions (for example
  `ClassifyReply` for reply runs) are not affected.

  RED: SDRAgent is still v3 with the v3 body, so registration returns the
  existing v3 row and a v3-pinned retry runs the whole flow.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.SDRDefinitionFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.SDR
  alias SdrAgent.SDR.SDRAgent

  @moduletag :b1_04
  @moduletag :b1_05

  @changed %{
    "SdrAgent.SDR.Actions.BuildEvidenceBundle" => "2",
    "SdrAgent.SDR.Actions.DraftEmail" => "2",
    "SdrAgent.SDR.Actions.HandOffProposal" => "2"
  }
  @added %{"SdrAgent.SDR.Actions.ValidateDraftShape" => "1"}
  @changed_prompts [:evidence_extraction, :outreach_proposal]
  @unchanged_prompts [:qualification, :reply_classification]
  @legacy_reason "the run's agent definition does not declare this action version"

  defmodule InvalidQualification do
    @moduledoc "Test responder: an invalid qualification score fails the run."
    alias SdrAgent.SDR.FakeBrain

    def respond("sdr.qualification" = op, input),
      do: %{FakeBrain.respond(op, input) | score: "high"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  setup ctx, do: ensure_offering!(ctx)

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  test "a v3 database keeps its row; the frozen v4 registers with only the intended changes",
       ctx do
    legacy = register_v3!(ctx.tenant.id)
    current = register_v4!(ctx.tenant.id)

    assert current.version == 4, "B1: SDRAgent is still registered as v#{current.version}"
    assert current.id != legacy.id

    old = v3_body()
    new = current.definition

    for %{"module" => module, "version" => version} <- old["allowed_actions"] do
      assert action_version(new, module) == Map.get(@changed, module, version),
             "B1: #{module} is declared at #{inspect(action_version(new, module))} in v4"
    end

    for {module, version} <- @added do
      assert action_version(new, module) == version, "B1: v4 does not declare #{module}"
    end

    assert length(new["allowed_actions"]) == length(old["allowed_actions"]) + map_size(@added)

    for purpose <- @changed_prompts do
      changed = ref(new, "prompt_templates", purpose)
      refute changed == ref(old, "prompt_templates", purpose), "B1: #{purpose} prompt unchanged"
      assert changed["version"] == "2", "B1: the changed #{purpose} prompt keeps its version"
    end

    for purpose <- @unchanged_prompts do
      assert ref(new, "prompt_templates", purpose) == ref(old, "prompt_templates", purpose)
    end

    assert new["output_schemas"] == old["output_schemas"]
    assert new["flows"] == old["flows"]
    assert new["model_policy"] == old["model_policy"]

    # The v3 row is untouched (body, hash, status).
    {:ok, reread} = Ash.get(Agents.AgentDefinition, legacy.id, actor: ctx.admin)

    assert {reread.definition, reread.definition_sha256, reread.status} ==
             {legacy.definition, legacy.definition_sha256, legacy.status}

    assert Base.encode16(reread.definition_sha256, case: :lower) == v3_sha256()

    # Idempotent at v4; another body under v4 is refused.
    assert register_v4!(ctx.tenant.id).id == current.id
    assert current.definition == v4_body()

    assert {:error, error} =
             Agents.register_definition(
               %{
                 name: "SDRAgent",
                 version: current.version,
                 module: inspect(SDRAgent),
                 definition: Map.put(current.definition, "flows", [])
               },
               actor: Actor.system(:kernel, ctx.tenant.id)
             )

    assert Exception.message(error) =~ "registered with another hash"
  end

  test "a new assignment on a v3 database pins the current definition", ctx do
    legacy = register_v3!(ctx.tenant.id)
    %{run: run} = assign!(ctx, "01")

    {:ok, pinned} = Ash.get(Agents.AgentDefinition, run.agent_definition_id, actor: ctx.admin)

    assert pinned.version == SDRAgent.version(),
           "B1: a new assignment pinned SDRAgent v#{pinned.version}"

    refute run.agent_definition_id == legacy.id
  end

  test "a retry of a v3-pinned run fails closed at research before any model call", ctx do
    legacy = register_v3!(ctx.tenant.id)

    %{run: original} =
      assign!(ctx, "01", model: [provider_options: [responder: InvalidQualification]])

    drain!()
    failed = run!(ctx, original)
    assert failed.status == :failed

    # A failed run pinned to v3 on the same lead, trigger and Operation, built
    # through domain actions only (as `SchemaDefinitionUpgradeTest`).
    {:ok, legacy_run} =
      Agents.create_run(
        %{
          agent_definition_id: legacy.id,
          lead_id: failed.lead_id,
          campaign_id: failed.campaign_id,
          trigger_signal_type: failed.trigger_signal_type,
          trigger_signal_id: failed.trigger_signal_id,
          correlation_id: failed.correlation_id,
          phase: failed.phase,
          usage_origin: failed.usage_origin,
          operation_id: failed.operation_id,
          max_model_calls: 5,
          max_tool_calls: 20
        },
        actor: ctx.agent
      )

    {:ok, legacy_run} = Agents.start_run(legacy_run, actor: ctx.agent)

    {:ok, legacy_run} =
      Agents.fail_run(legacy_run, %{status_reason: :invalid_model_output}, actor: ctx.agent)

    result = SDR.retry_run(legacy_run.id, actor: ctx.admin)
    assert match?({:ok, %{run: _}}, result), short(result)
    {:ok, %{run: child}} = result
    assert child.agent_definition_id == legacy.id, "setup: the retry did not keep the v3 pin"

    drain!()
    child = run!(ctx, child)

    assert {child.status, child.status_reason} == {:failed, :crash},
           "B1: a v3-pinned retry ran the changed actions (#{child.status})"

    assert child.failure_reason == @legacy_reason

    assert invocations!(ctx, child) == [],
           "B1: a v3-pinned retry made a model call under the v4 actions"

    refute Enum.any?(decisions!(ctx, child), &(&1.kind == :research_caps))
  end
end
