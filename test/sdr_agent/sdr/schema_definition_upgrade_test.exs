defmodule SdrAgent.SDR.SchemaDefinitionUpgradeTest do
  @moduledoc """
  Schema version 2 changes the `SDRAgent` definition body (its
  `output_schemas` refs), so the agent definition is a new immutable version
  (Codex #35 review 90369928; reviewer regressions adopted).

  A database that already holds SDRAgent v2, with schema-v1 refs, keeps that
  row byte-identical. Registration and new lead assignments use v3, and the
  hash-conflict guard still refuses a different body under an existing
  version. Existing runs and their retries keep their pinned definition:
  `retry_of` copies `agent_definition_id`, as covered in
  `SDR.RetryRunTest`.

  A run pinned to v2 that makes a model call after the upgrade records the
  schema version actually used ("2"). This admission-snapshot reading
  holds only for this semantics-preserving normalisation (Codex PASS
  0b73763d, condition C2).
  """
  use SdrAgent.SDRCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.JsonSchema
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Schemas
  alias SdrAgent.SDR.SDRAgent

  @purposes [:evidence_extraction, :qualification, :outreach_proposal, :reply_classification]

  defp register_legacy!(ctx) do
    refs =
      for purpose <- @purposes do
        %{
          "id" => "sdr.#{purpose}",
          "version" => "1",
          "sha256" =>
            purpose
            |> Schemas.for_purpose()
            |> Zoi.to_json_schema()
            |> Canonical.sha256()
            |> Base.encode16(case: :lower)
        }
      end

    legacy = Map.put(SDRAgent.definition_body(), "output_schemas", refs)

    assert {:ok, definition} =
             Agents.register_definition(
               %{name: "SDRAgent", version: 2, module: inspect(SDRAgent), definition: legacy},
               actor: Actor.system(:kernel, ctx.tenant.id)
             )

    assert definition.version == 2
    assert definition.definition_sha256 == Canonical.sha256(legacy)
    definition
  end

  test "the new schema regime registers a new agent-definition version without replacing v2",
       ctx do
    legacy = register_legacy!(ctx)
    result = SDRAgent.register(ctx.tenant.id)
    assert match?({:ok, _}, result), inspect(result)
    {:ok, current} = result
    assert current.id != legacy.id
    assert current.version > legacy.version
    assert Enum.all?(current.definition["output_schemas"], &(&1["version"] == "2"))

    # The legacy row is untouched (body, hash, status).
    {:ok, reread} = Ash.get(Agents.AgentDefinition, legacy.id, actor: ctx.admin)

    assert {reread.definition, reread.definition_sha256, reread.status} ==
             {legacy.definition, legacy.definition_sha256, legacy.status}

    # Registration is idempotent for the new version.
    assert {:ok, again} = SDRAgent.register(ctx.tenant.id)
    assert again.id == current.id
  end

  test "a previously used database still allows a new lead assignment after the schema upgrade",
       ctx do
    legacy = register_legacy!(ctx)
    lead = fixture_lead!(ctx, "01")

    result = SdrAgent.SDR.assign_lead(lead, campaign_id: ctx.campaign_id, actor: ctx.admin)
    assert match?({:ok, _}, result), inspect(result)

    [run] =
      Agents.AgentRun
      |> Ash.read!(actor: ctx.agent)
      |> Enum.filter(&(&1.lead_id == lead.id))

    refute run.agent_definition_id == legacy.id
    {:ok, pinned} = Ash.get(Agents.AgentDefinition, run.agent_definition_id, actor: ctx.admin)
    assert pinned.version == SDRAgent.version()
  end

  test "a legacy-v2-pinned run's post-upgrade model call records schema v2; pin and row unchanged",
       ctx do
    legacy = register_legacy!(ctx)
    {:ok, run} = Agents.create_run(AgentsFixtures.run_attrs(legacy), actor: ctx.agent)
    {:ok, run} = Agents.start_run(run, actor: ctx.agent)

    sdr = %Context{
      actor: ctx.agent,
      tenant_id: ctx.tenant.id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      signal_id: "sig-upgrade"
    }

    input = %{reply: %{subject: "Re: hello", text: "Sounds interesting, could we talk?"}}
    result = Model.call(sdr, :reply_classification, input, Ecto.UUID.generate())
    assert match?({:ok, _output, _invocation}, result), inspect(result)
    {:ok, _output, invocation} = result

    assert invocation.output_schema_version == "2"

    assert invocation.output_schema_sha256 ==
             :reply_classification
             |> Schemas.for_purpose()
             |> JsonSchema.render()
             |> Canonical.sha256()

    # The run keeps its admission definition; the v2 row is unchanged.
    {:ok, reread_run} = Agents.get_run(run.id, actor: ctx.agent)
    assert reread_run.agent_definition_id == legacy.id
    {:ok, reread} = Ash.get(Agents.AgentDefinition, legacy.id, actor: ctx.admin)

    assert {reread.definition, reread.definition_sha256} ==
             {legacy.definition, legacy.definition_sha256}
  end

  test "the hash-conflict guard still refuses a different body under an existing version",
       ctx do
    assert {:ok, current} = SDRAgent.register(ctx.tenant.id)

    altered = Map.put(current.definition, "flows", [])

    assert {:error, error} =
             Agents.register_definition(
               %{
                 name: "SDRAgent",
                 version: current.version,
                 module: inspect(SDRAgent),
                 definition: altered
               },
               actor: Actor.system(:kernel, ctx.tenant.id)
             )

    assert Exception.message(error) =~ "registered with another hash"
  end
end
