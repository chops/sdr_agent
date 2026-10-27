defmodule SdrAgent.SDR.DefinitionV5UpgradeTest do
  @moduledoc """
  B1-R1 forward version (Codex `codex-b1-association-red-neighbor-delta-review-20261027.org`
  must_fix; route `claude-b1-r1-version-route-r1.md`, neighbor N9): SDRAgent v4
  may be persisted somewhere, so it is frozen (the PR #234 GREEN body,
  `SdrAgent.SDRDefinitionFixtures.v4_body/0`) and the hardened contracts are a
  new immutable definition, v5. v5 differs from v4 in exactly four action
  versions: `ValidateDraftShape` "2", `ValidateClaims` "2",
  `ValidatePersonalization` "2" and `HandOffProposal` "3". Prompts, schemas,
  flows, model policy and every other action are v4's.

  On a database already holding the frozen v4: the v4 row stays byte-identical;
  registration yields v5 idempotently; a different body under v5 is refused (the
  immutable same-version/different-hash refusal); a new assignment pins v5.

  Legacy execution: under a running run pinned to v4, each hardened action,
  performed directly on its own fresh run (one test per action), stops the run
  `:crash` with the fixed reason "the run's agent definition does not declare
  this action version" (`SdrAgent.SDR.Preconditions.declared/2`;
  `ValidateClaims` and `ValidatePersonalization` gain that check). The
  boundary (Codex clarification): the declaration check itself reads the run
  and its pinned definition, and its refusal writes the failed run; it comes
  before any proposal, evidence, settings or model work and before any
  validation or hand-off Decision or effect.

  RED: SDRAgent is still v4 with the v4 body, so registration returns the
  frozen v4 row, a new assignment pins v4, and under a v4 pin the four actions
  run (or refuse for another reason) instead of failing closed.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.SDRDefinitionFixtures

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.SDR.Actions.HandOffProposal
  alias SdrAgent.SDR.Actions.ValidateClaims
  alias SdrAgent.SDR.Actions.ValidateDraftShape
  alias SdrAgent.SDR.Actions.ValidatePersonalization
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.SDRAgent

  @moduletag :b1_r1

  @hardened %{
    "SdrAgent.SDR.Actions.ValidateDraftShape" => "2",
    "SdrAgent.SDR.Actions.ValidateClaims" => "2",
    "SdrAgent.SDR.Actions.ValidatePersonalization" => "2",
    "SdrAgent.SDR.Actions.HandOffProposal" => "3"
  }
  @legacy_reason "the run's agent definition does not declare this action version"

  setup ctx, do: ensure_offering!(ctx)

  defp short(term), do: inspect(term, limit: 8, printable_limit: 200)

  test "a v4 database keeps its row; registration yields v5 with exactly the hardened versions",
       ctx do
    legacy = register_v4!(ctx.tenant.id)
    result = SDRAgent.register(ctx.tenant.id)
    assert match?({:ok, _}, result), short(result)
    {:ok, current} = result

    assert current.version == 5, "B1-R1: SDRAgent is still registered as v#{current.version}"
    assert current.id != legacy.id

    old = v4_body()
    new = current.definition

    for %{"module" => module, "version" => version} <- old["allowed_actions"] do
      assert action_version(new, module) == Map.get(@hardened, module, version),
             "B1-R1: #{module} is declared at #{inspect(action_version(new, module))} in v5"
    end

    assert length(new["allowed_actions"]) == length(old["allowed_actions"])

    assert Map.delete(new, "allowed_actions") == Map.delete(old, "allowed_actions"),
           "B1-R1: v5 changes more than the hardened action versions"

    # The v4 row is untouched (body, hash, status) and stays the frozen body.
    {:ok, reread} = Ash.get(Agents.AgentDefinition, legacy.id, actor: ctx.admin)

    assert {reread.definition, reread.definition_sha256, reread.status} ==
             {legacy.definition, legacy.definition_sha256, legacy.status}

    assert Base.encode16(reread.definition_sha256, case: :lower) == v4_sha256()
    assert register_v4!(ctx.tenant.id).id == legacy.id

    # Idempotent at v5; another body under v5 is refused.
    assert {:ok, again} = SDRAgent.register(ctx.tenant.id)
    assert again.id == current.id

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

  test "a new assignment on a v4 database pins v5", ctx do
    legacy = register_v4!(ctx.tenant.id)
    %{run: run} = assign!(ctx, "01")

    {:ok, pinned} = Ash.get(Agents.AgentDefinition, run.agent_definition_id, actor: ctx.admin)
    assert pinned.version == 5, "B1-R1: a new assignment pinned SDRAgent v#{pinned.version}"
    refute run.agent_definition_id == legacy.id
  end

  # One test per hardened action, each on its own fresh v4-pinned run, so
  # every declaration boundary is observed on its own (Codex R2).
  for action <- [ValidateClaims, ValidatePersonalization, ValidateDraftShape, HandOffProposal] do
    @tag hardened: action
    test "under a v4 pin #{inspect(action)} fails closed at its declaration check", ctx do
      action = ctx.hardened
      legacy = register_v4!(ctx.tenant.id)
      lead = fixture_lead!(ctx, "01")

      attrs =
        legacy
        |> AgentsFixtures.run_attrs()
        |> Map.merge(%{lead_id: lead.id, campaign_id: ctx.campaign_id})

      {:ok, run} = Agents.create_run(attrs, actor: ctx.agent)
      {:ok, run} = Agents.start_run(run, actor: ctx.agent)
      assert run.agent_definition_id == legacy.id, "setup: the run is not pinned to v4"
      assert run.status == :running, "setup: the v4-pinned run is not running"

      sdr = %Context{
        actor: ctx.agent,
        tenant_id: ctx.tenant.id,
        run_id: run.id,
        correlation_id: run.correlation_id,
        signal_id: "sig-b1-r1-v4-#{inspect(action)}",
        agent_state: %{phase: :validate, campaign_id: ctx.campaign_id}
      }

      result = action.perform(legacy_params(action, lead, ctx), sdr)

      assert result == {:error, {:halt, :crash}},
             "B1-R1: #{inspect(action)} ran under a v4 pin: #{short(result)}"

      stopped = run!(ctx, run)
      assert {stopped.status, stopped.status_reason} == {:failed, :crash}
      assert stopped.failure_reason == @legacy_reason

      assert decisions!(ctx, run) == [],
             "B1-R1: #{inspect(action)} recorded a Decision under a v4 pin"
    end
  end

  # Params each hardened action's perform/2 head accepts; the declaration
  # check comes first, so their ids name no record.
  defp legacy_params(action, lead, ctx) do
    proposal = %{
      subject: "A synthetic subject",
      body: "A synthetic body.",
      angle: "A synthetic angle",
      cta: "A synthetic question?",
      claims: [],
      personalization: [],
      risk_flags: [],
      evidence_ids: []
    }

    draft = %{
      decision_id: Ecto.UUID.generate(),
      model_invocation_id: Ecto.UUID.generate(),
      proposal: proposal
    }

    check = %{passed: true, decision_id: Ecto.UUID.generate()}

    case action do
      ValidateDraftShape ->
        %{lead_id: lead.id, draft: draft}

      HandOffProposal ->
        %{
          lead_id: lead.id,
          draft: draft,
          claims_check: check,
          personalization_check: check,
          shape_check: check,
          plan: %{campaign_id: ctx.campaign_id, step: %{id: Ecto.UUID.generate()}}
        }

      _citation_check ->
        %{lead_id: lead.id, draft: draft, claims: []}
    end
  end
end
