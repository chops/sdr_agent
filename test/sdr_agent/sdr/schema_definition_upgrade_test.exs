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

    # The recorded hash is that of the schema actually stored for this call
    # (read through the authorized REC payload API).
    rec = system_actor(:reconciler, ctx.tenant)
    {:ok, %{request: request}} = Agents.read_reconciliation_payloads(invocation, actor: rec)
    stored = request |> JSON.decode!() |> Map.fetch!("schema")
    assert invocation.output_schema_sha256 == Canonical.sha256(stored)

    assert Canonical.encode!(stored) ==
             :reply_classification
             |> Schemas.for_purpose()
             |> JsonSchema.render()
             |> Canonical.encode!()

    # The run keeps its admission definition; the v2 row is unchanged.
    {:ok, reread_run} = Agents.get_run(run.id, actor: ctx.agent)
    assert reread_run.agent_definition_id == legacy.id
    {:ok, reread} = Ash.get(Agents.AgentDefinition, legacy.id, actor: ctx.admin)

    assert {reread.definition, reread.definition_sha256} ==
             {legacy.definition, legacy.definition_sha256}
  end

  defmodule InvalidQualification do
    @moduledoc "Test responder: an invalid qualification score fails the run."
    alias SdrAgent.SDR.FakeBrain

    def respond("sdr.qualification" = op, input),
      do: %{FakeBrain.respond(op, input) | score: "high"}

    def respond(op, input), do: FakeBrain.respond(op, input)
  end

  test "an operator retry of a legacy-v2-pinned failed run keeps v2 while v3 is current", ctx do
    legacy = register_legacy!(ctx)
    lead = fixture_lead!(ctx, "01")

    assigned =
      SdrAgent.SDR.assign_lead(lead,
        campaign_id: ctx.campaign_id,
        actor: ctx.admin,
        model: [provider_options: [responder: InvalidQualification]]
      )

    assert match?({:ok, _}, assigned), inspect(assigned)
    assert %{success: 1} = drain!()

    [failed] =
      Agents.AgentRun |> Ash.read!(actor: ctx.agent) |> Enum.filter(&(&1.lead_id == lead.id))

    assert failed.status == :failed
    refute failed.agent_definition_id == legacy.id

    # A failed run pinned to legacy v2 on the same lead, trigger and
    # Operation, built through domain actions only.
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
          operation_id: failed.operation_id,
          max_model_calls: 5,
          max_tool_calls: 10
        },
        actor: ctx.agent
      )

    {:ok, legacy_run} = Agents.start_run(legacy_run, actor: ctx.agent)

    {:ok, legacy_run} =
      Agents.fail_run(legacy_run, %{status_reason: :invalid_model_output}, actor: ctx.agent)

    result = SdrAgent.SDR.retry_run(legacy_run.id, actor: ctx.admin)
    assert match?({:ok, %{run: _}}, result), inspect(result)
    {:ok, %{run: child}} = result
    assert child.retry_of_id == legacy_run.id
    assert child.agent_definition_id == legacy.id
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
