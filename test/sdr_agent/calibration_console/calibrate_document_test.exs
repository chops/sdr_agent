defmodule SdrAgent.CalibrationConsole.CalibrateDocumentTest do
  @moduledoc """
  R0-07 slice E, sub-slice d3c (packet 8.14.8, entity/action PASS at
  623e7db): the evidence document `calibrate` builds.

  `Calibrate.document/1` is pure: it takes snapshots the command gathered
  outside any database lock (the fresh invocation and run, the recorded
  tuple, the `Outcome.classify/1` result, the receipt's own link, the
  parsed output read through the scoped calibration read, and the
  observation time) and returns the `r0-calibration-evidence/1` document,
  or `{:error, :evidence_input_invalid}`.

    * Digests are lowercase hex: each link's `evidence_sha256`, the output
      commitment and the prompt and schema references; `inventory_sha256`
      is the own link's validated digest. Times are microsecond UTC.
    * Only the receipt's own link is named; an unread blob's link keeps its
      method, and the valid init pair is kept, with only the projection nil.
    * No prompt, response, output or error text enters the document.
    * `Evidence.publish/3` accepts and `validate/3` validates the built
      document against the committed rows; a second publish replays the
      frozen file.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.CalibrationConsole.Calibrate
  alias SdrAgent.CalibrationConsole.Evidence
  alias SdrAgent.CalibrationConsole.Outcome
  alias SdrAgent.CalibrationConsole.Prompt

  @moduletag :tmp_dir
  @v3 "claude-message-json/3+prompt-builder/1"
  @canary "canary-7a3e91d0"
  @output %{"answer" => "blue #{@canary}", "confidence" => 0.9}
  @inventory String.duplicate("ab", 32)
  @observed ~U[2026-10-13 22:00:00.123456Z]

  setup %{tmp_dir: tmp} = tags do
    tenant = bootstrap!()

    AgentsFixtures.grant!(tenant, %{
      total_attempts: 6,
      allocations: [
        %{key: :b1, applies_to: [:b1], attempts: 2},
        %{key: :proof, applies_to: [:proof], attempts: 4}
      ]
    })

    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant, usage_origin: :proof)
    rec = system_actor(:reconciler, tenant)
    invocation = proof!(run, agent, Map.get(tags, :call, :completed))

    dir = Path.join(tmp, "evidence")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    # After every fixture: a missing builder fails as an assertion.
    assert Code.ensure_loaded?(Calibrate), "SdrAgent.CalibrationConsole.Calibrate is not defined"

    assert function_exported?(Calibrate, :document, 1),
           "Calibrate.document/1 is not defined"

    %{tenant: tenant, run: run, agent: agent, rec: rec, invocation: invocation, dir: dir}
  end

  test "a completed call's document is published and validated, and replays frozen", ctx do
    link = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, evidence: v3_evidence())
    {:ok, document} = Calibrate.document(snapshot(ctx, link, {:ok, receipt(:reconciled, link)}))

    assert document.outcome == "match"

    assert document.links == [
             %{id: link.id, evidence_sha256: hex(Canonical.sha256(link.evidence))}
           ]

    assert document.inventory_sha256 == @inventory

    assert {document.evaluated_projection_version, document.evaluated_method} ==
             {@v3, "propagated_id"}

    assert {document.attested_cli_version, document.attested_model_id} ==
             {ctx.invocation.provider_version, ctx.invocation.model_id}

    assert document.output_sha256 == hex(Canonical.sha256(@output))
    assert document.prompt.sha256 == hex(Prompt.prompt_ref().sha256)
    assert document.output_schema.sha256 == hex(Prompt.schema_ref().sha256)
    assert document.candidate == Map.new(candidate(), fn {k, v} -> {k, to_string(v)} end)
    assert {document.invocation_status, document.validation_status} == {"completed", "valid"}

    for key <- [:reserved_at, :sent_at, :completed_at, :observed_at],
        do: assert(%DateTime{microsecond: {_, 6}} = Map.fetch!(document, key))

    assert document.observed_at == @observed
    refute inspect(document) =~ @canary

    assert {:ok, %{path: path, sha256: sha}} = Evidence.publish(ctx.dir, document, opts(ctx))
    assert {:ok, _validated} = Evidence.validate(path, target(ctx), opts(ctx))
    refute File.read!(path) =~ @canary
    assert {:ok, %{sha256: ^sha}} = Evidence.publish(ctx.dir, document, opts(ctx))
  end

  test "without the receipt's own link: no links, no inventory, no evaluation", ctx do
    gate = {:ok, %{status: :unwitnessed, link_id: nil, cause_id: nil, codes: ["witness_missing"]}}
    {:ok, document} = Calibrate.document(snapshot(ctx, nil, gate))

    assert {document.outcome, document.links, document.inventory_sha256} == {"missing", [], nil}
    assert {document.evaluated_projection_version, document.evaluated_method} == {nil, nil}
    assert {:ok, %{path: path}} = Evidence.publish(ctx.dir, document, opts(ctx))
    assert {:ok, _validated} = Evidence.validate(path, target(ctx), opts(ctx))
  end

  test "an unread blob: unreadable, nil projection, the link's method and valid init", ctx do
    link = blob_link!(ctx)
    gate = {:ok, %{receipt(:inferred, link) | codes: ["blob_missing"]}}
    {:ok, document} = Calibrate.document(snapshot(ctx, link, gate))

    assert document.outcome == "unreadable"
    assert document.evaluated_projection_version == nil
    assert document.evaluated_method == "propagated_id"

    assert {document.attested_cli_version, document.attested_model_id} ==
             {ctx.invocation.provider_version, ctx.invocation.model_id}

    assert {:ok, %{path: path}} = Evidence.publish(ctx.dir, document, opts(ctx))
    assert {:ok, _validated} = Evidence.validate(path, target(ctx), opts(ctx))
  end

  test "an own link without a lowercase hex inventory digest is a hard stop", ctx do
    link = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, evidence: v3_evidence())

    for bad <- [String.upcase(@inventory), "abc", 42, nil] do
      malformed = %{link | evidence: Map.put(link.evidence, "inventory_sha256", bad)}

      assert Calibrate.document(snapshot(ctx, malformed, {:ok, receipt(:reconciled, malformed)})) ==
               {:error, :evidence_input_invalid},
             inspect(bad)
    end
  end

  test "a link that is not the receipt's own is never named", ctx do
    own = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, evidence: v3_evidence())
    other = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, evidence: v3_evidence())

    assert Calibrate.document(snapshot(ctx, other, {:ok, receipt(:reconciled, own)})) ==
             {:error, :evidence_input_invalid}
  end

  test "no output, prompt, response or error text enters the document", ctx do
    link = AgentsFixtures.reconciled_link!(ctx.invocation, ctx.rec, evidence: v3_evidence())
    {:ok, document} = Calibrate.document(snapshot(ctx, link, {:ok, receipt(:reconciled, link)}))
    encoded = Canonical.encode!(document)

    for text <- [@canary, Prompt.render(), Jason.encode!(@output)] do
      refute encoded =~ text
    end
  end

  @tag call: :unlaunched
  test "an unlaunched call: launch_failed, no evaluation, no output", ctx do
    {:ok, document} = Calibrate.document(snapshot(ctx, nil, nil))

    assert document.outcome == "launch_failed"
    assert {document.links, document.inventory_sha256, document.output_sha256} == {[], nil, nil}
    assert {document.evaluated_projection_version, document.evaluated_method} == {nil, nil}
    assert {document.attested_cli_version, document.attested_model_id} == {nil, nil}
    assert {document.invocation_status, document.sent_at} == {"failed", nil}
    refute Canonical.encode!(document) =~ "calibration_grant_mismatch"
    assert {:ok, %{path: path}} = Evidence.publish(ctx.dir, document, opts(ctx))
    assert {:ok, _validated} = Evidence.validate(path, target(ctx), opts(ctx))
  end

  ## Fixtures

  # The snapshots `calibrate` gathers (outside any lock) before building the
  # document: the fresh rows, the recorded tuple, the await result and its
  # own link, the server attestation, the parsed output and the observation
  # time. A nil gate is the unlaunched path (no await, no attestation).
  defp snapshot(ctx, link, gate) do
    {:ok, invocation} = Agents.get_model_invocation(ctx.invocation.id, actor: ctx.agent)
    {:ok, tuple} = Gate.recorded_tuple(invocation)

    %{
      invocation: invocation,
      run: ctx.run,
      tuple: tuple,
      gate: gate,
      link: link,
      attestation: gate && attestation(invocation),
      output: if(invocation.status == :completed, do: @output),
      observed_at: @observed
    }
  end

  defp attestation(invocation),
    do: %{
      status: :attested,
      reason: nil,
      model: invocation.model_id,
      version: invocation.provider_version
    }

  defp receipt(status, link),
    do: %{status: status, link_id: link.id, cause_id: nil, codes: []}

  defp proof!(run, agent, call) do
    {:ok, reserved} =
      AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, attrs("doc-#{System.unique_integer([:positive])}"),
          actor: agent,
          calibration: CalibrationAdmission.context(:claude_cli_opus, candidate())
        )
      end)

    settle(reserved, agent, call)
  end

  defp attrs(key) do
    prompt = Prompt.prompt_ref()
    schema = Prompt.schema_ref()

    key
    |> AgentsFixtures.claude_attrs()
    |> Map.merge(%{
      prompt_template_id: prompt.id,
      prompt_template_version: prompt.version,
      prompt_template_sha256: prompt.sha256,
      output_schema_id: schema.id,
      output_schema_version: schema.version,
      output_schema_sha256: schema.sha256
    })
  end

  defp settle(reserved, agent, :completed) do
    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)

    completion = %{
      AgentsFixtures.completion()
      | response: Jason.encode!(@output),
        parsed_output: @output
    }

    {:ok, done} = Agents.complete_model_invocation(sent, completion, actor: agent)
    done
  end

  # Refused before any process: failed, never sent.
  defp settle(reserved, agent, :unlaunched) do
    {:ok, failed} =
      Agents.fail_model_invocation(
        reserved,
        %{error: %{"kind" => "launch_refused", "reason" => "calibration_grant_mismatch"}},
        actor: agent
      )

    failed
  end

  defp candidate, do: AdmissionFixtures.entry(:claude_cli_opus, @v3)

  defp v3_evidence do
    %{
      "projection_version" => @v3,
      "reminder_count" => 0,
      "reminder_sha256s" => [],
      "reminder_bytes" => [],
      "trailing_system_count" => 0,
      "trailing_system_sha256s" => [],
      "trailing_system_bytes" => [],
      "request_extras_sha256" => String.duplicate("c3", 32),
      "request_fields" => [],
      "trailing_output_config" => [],
      "inventory_sha256" => @inventory
    }
  end

  # What `Witness` records for an unreadable primary blob: an inferred
  # primary link with a `blob_*` reason and no evaluated projection (packet
  # 8.14.8, store-failure table).
  defp blob_link!(ctx) do
    attrs =
      AgentsFixtures.link_attrs(ctx.invocation, %{
        link_status: :inferred,
        evidence: %{"reason_codes" => ["blob_missing"], "inventory_sha256" => @inventory}
      })

    attrs = update_in(attrs.evidence, &Map.delete(&1, "projection_version"))
    {:ok, link} = Agents.link_wire_witness(attrs, actor: ctx.rec)
    link
  end

  defp target(ctx),
    do: %{
      invocation_id: ctx.invocation.id,
      run_id: ctx.run.id,
      tenant_id: ctx.tenant.id,
      profile_id: :claude_cli_opus
    }

  defp opts(ctx), do: [actor: system_actor(:agent_runtime, ctx.tenant)]
end
