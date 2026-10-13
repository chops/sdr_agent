defmodule SdrAgent.Audit.OutputCommitmentTest do
  @moduledoc """
  R0-07 slice A round 5, contract (a) (packet section 5.2; Codex PASS at
  dc8cae7, clarifications 1, 2 and 5): an audit event of a generation-2
  ClaudeCLI ModelInvocation write carries `sdr-output-commitment/1`
  commitments, never the output-bearing fields (`parsed_output`,
  `validation_errors`, `refusal`) themselves. A commitment is the
  lowercase hex SHA-256 of the field's `sdr-canonical-json/1` encoding, or
  the JSON `null` marker for nil. `record_sha256` still covers the full
  stored row and the chain verifies. Generation-1 and Fake events keep
  their plaintext after-images.

  A unique canary is placed only in unreleased model results (valid,
  invalid and failed validation). It is absent from every decoded event
  after-image and canonical event bytes, the decoded events of an audit
  export, and generic reads of the three fields. The export's audited raw
  response Payload is the disclosed, authorized exception.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Export
  alias SdrAgent.Audit.ExportVerifier
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.RecordHash

  @fields ~w(parsed_output validation_errors refusal)

  setup do
    tenant = bootstrap!()
    AgentsFixtures.grant!(tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
    canary = "canary-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    %{tenant: tenant, run: run, agent: agent, canary: canary}
  end

  defp completion(canary) do
    %{
      AgentsFixtures.completion()
      | response: ~s({"result":"#{canary}"}),
        parsed_output: %{"qualified" => true, "note" => canary}
    }
  end

  defp invalid_completion(canary) do
    %{
      completion(canary)
      | validation_status: :invalid,
        validation_errors: [%{"message" => "bad value #{canary}"}]
    }
    |> Map.put(:refusal, "refused: #{canary}")
  end

  defp sent!(ctx, key) do
    {:ok, reserved} =
      Agents.reserve_model_invocation(ctx.run, AgentsFixtures.claude_attrs(key), actor: ctx.agent)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: ctx.agent)
    sent
  end

  # The three unreleased generation-2 results, each carrying the canary.
  defp gated_results!(ctx) do
    {:ok, valid} =
      ctx
      |> sent!("oc-valid")
      |> Agents.complete_model_invocation(completion(ctx.canary), actor: ctx.agent)

    {:ok, invalid} =
      ctx
      |> sent!("oc-invalid")
      |> Agents.complete_model_invocation(invalid_completion(ctx.canary), actor: ctx.agent)

    failed_attrs =
      ctx.canary
      |> invalid_completion()
      |> Map.put(:error, %{"kind" => "validation_failed"})

    {:ok, failed} =
      ctx |> sent!("oc-failed") |> Agents.fail_model_invocation(failed_attrs, actor: ctx.agent)

    [valid, invalid, failed]
  end

  defp invocation_events(ctx, invocation) do
    ctx.tenant
    |> events()
    |> Enum.filter(&(&1.subject_id == invocation.id and &1.event_type =~ "model.invocation."))
  end

  defp stored(invocation) do
    {:ok, row} =
      Ash.get(ModelInvocation, invocation.id, Kernel.integrity_opts(invocation.tenant_id))

    row
  end

  defp commitment(nil), do: nil

  defp commitment(value),
    do:
      value
      |> Canonical.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  describe "generation-2 ClaudeCLI events" do
    test "no event after-image or canonical bytes carries the canary", ctx do
      for invocation <- gated_results!(ctx), event <- invocation_events(ctx, invocation) do
        refute Jason.encode!(event.payload) =~ ctx.canary, event.event_type
        refute event.canonical_bytes =~ ctx.canary, event.event_type
      end
    end

    test "completed and failed events carry commitments, the version and the status", ctx do
      [valid, invalid, failed] = gated_results!(ctx)

      for {invocation, type} <- [
            {valid, "model.invocation.completed"},
            {invalid, "model.invocation.completed"},
            {failed, "model.invocation.failed"}
          ] do
        [event] = Enum.filter(invocation_events(ctx, invocation), &(&1.event_type == type))
        row = stored(invocation)
        changes = event.payload["changes"]

        for field <- @fields do
          refute Map.has_key?(changes, field), "#{type} #{field}"
          expected = commitment(Map.fetch!(row, String.to_existing_atom(field)))
          # A field written by this action is a commitment in `changes`.
          if Map.has_key?(changes, field <> "_sha256"),
            do: assert(Map.fetch!(changes, field <> "_sha256") == expected, "#{type} #{field}")

          # The stored row's commitment is always in `output_commitment`.
          assert Map.fetch!(event.payload["output_commitment"]["fields"], field <> "_sha256") ==
                   expected
        end

        assert Map.has_key?(changes, "parsed_output_sha256")
        assert Map.has_key?(changes, "validation_errors_sha256")
        if invocation != valid, do: assert(Map.has_key?(changes, "refusal_sha256"))

        assert %{
                 "version" => "sdr-output-commitment/1",
                 "canonicalization" => "sdr-canonical-json/1",
                 "validation_status" => status,
                 "output_schema_id" => "qualification_result",
                 "output_schema_version" => "1"
               } = event.payload["output_commitment"]

        assert status == Atom.to_string(row.validation_status)
        assert event.payload["record_sha256"] == RecordHash.hex(row)
      end
    end

    test "a nil field is the JSON null marker; the key is never dropped", ctx do
      {:ok, valid} =
        ctx
        |> sent!("oc-nil")
        |> Agents.complete_model_invocation(completion(ctx.canary), actor: ctx.agent)

      for event <- invocation_events(ctx, valid) do
        fields = event.payload["output_commitment"]["fields"]

        assert Map.keys(fields) |> Enum.sort() ==
                 Enum.map(@fields, &(&1 <> "_sha256")) |> Enum.sort()

        # `refusal` stays nil on every write: a null marker, never a hash of "null".
        assert Map.fetch!(fields, "refusal_sha256") == nil, event.event_type
        refute fields["refusal_sha256"] == commitment("null")
      end

      [reserved] = Enum.filter(invocation_events(ctx, valid), &(&1.event_type =~ "reserved"))
      assert reserved.payload["changes"]["parsed_output_sha256"] == nil
      assert Map.has_key?(reserved.payload["changes"], "parsed_output_sha256")
      # [] is a value and is hashed.
      assert reserved.payload["changes"]["validation_errors_sha256"] == commitment([])
    end

    test "the chain and every record hash still verify", ctx do
      gated_results!(ctx)
      assert {:ok, report} = Audit.verify_chain(actor: human(:admin, ctx.tenant))
      assert report.valid?, inspect(report.issues)
    end

    test "generic reads mask all three output-bearing fields; REC reads them", ctx do
      [_valid, invalid, failed] = gated_results!(ctx)

      for invocation <- [invalid, failed] do
        for actor <- [ctx.agent, human(:admin, ctx.tenant), system_actor(:kernel, ctx.tenant)] do
          {:ok, row} = Ash.get(ModelInvocation, invocation.id, actor: actor)

          for field <- [:parsed_output, :validation_errors, :refusal],
              do:
                assert(
                  %Ash.ForbiddenField{} = Map.fetch!(row, field),
                  "#{field} #{inspect(actor)}"
                )
        end

        {:ok, row} =
          Ash.get(ModelInvocation, invocation.id, actor: system_actor(:reconciler, ctx.tenant))

        assert row.refusal =~ ctx.canary
        assert inspect(row.validation_errors) =~ ctx.canary
      end
    end
  end

  test "generation-1 and Fake events keep their plaintext after-images", ctx do
    {:ok, fake} =
      Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("oc-fake"),
        actor: ctx.agent
      )

    {:ok, fake} = Agents.mark_model_invocation_sent(fake, actor: ctx.agent)
    {:ok, fake} = Agents.complete_model_invocation(fake, completion(ctx.canary), actor: ctx.agent)

    legacy = sent!(ctx, "oc-legacy")

    tamper!(
      "UPDATE model_invocations SET ledger_generation = 1, profile_id = NULL, grant_id = NULL, " <>
        "allocation_id = NULL WHERE id = $1",
      [Ecto.UUID.dump!(legacy.id)]
    )

    {:ok, legacy} = Ash.get(ModelInvocation, legacy.id, actor: ctx.agent)

    {:ok, legacy} =
      Agents.complete_model_invocation(legacy, completion(ctx.canary), actor: ctx.agent)

    for invocation <- [fake, legacy] do
      [event] =
        Enum.filter(
          invocation_events(ctx, invocation),
          &(&1.event_type == "model.invocation.completed")
        )

      assert event.payload["changes"]["parsed_output"]["note"] == ctx.canary
      refute Map.has_key?(event.payload, "output_commitment")
    end
  end

  describe "audit export" do
    setup ctx do
      {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, key} =
        Audit.register_signing_key(%{key_id: "oc-key", public_key: public_key},
          actor: system_actor(:kernel, ctx.tenant)
        )

      path = Path.join(System.tmp_dir!(), "sdr-oc-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)
      %{key: key, private_key: private_key, path: path}
    end

    test "decoded event after-images omit the canary; the raw Payload is the audited exception",
         ctx do
      gated_results!(ctx)
      auditor = human(:auditor, ctx.tenant)

      assert {:ok, _} =
               Export.build(%{scope: :sequence_range, scope_ref: "1:latest"},
                 actor: auditor,
                 anchor_actor: system_actor(:anchorer, ctx.tenant),
                 private_key: ctx.private_key,
                 sinks: [],
                 output: ctx.path,
                 output_root: Path.dirname(ctx.path)
               )

      trusted = Map.take(ctx.key, [:key_id, :public_key, :status, :revoked_at])
      assert {:ok, %{valid?: true}} = ExportVerifier.verify(ctx.path, trusted_key: trusted)

      wrapper = ctx.path |> File.read!() |> Jason.decode!()
      bundle = wrapper["payload"] |> Base.decode64!() |> Jason.decode!()

      # Decoded event after-images, never a search of the encoded bundle.
      for event <- bundle["events"] do
        decoded = event["canonical_bytes"] |> Base.decode64!() |> Jason.decode!()
        payload = decoded["payload"] || %{}

        for part <- ["changes", "previous", "arguments"] do
          refute inspect(payload[part], limit: :infinity) =~ ctx.canary,
                 "#{event["sequence"]} #{part}"
        end

        refute inspect(decoded, limit: :infinity) =~ ctx.canary, inspect(event["sequence"])
      end

      # Disclosed exception: the audited raw response Payload, read through
      # `read_content` with an AuditAccess, may carry the quarantined output.
      raw = Enum.map(bundle["payloads"], &Base.decode64!(&1["content"]))
      assert Enum.any?(raw, &(&1 =~ ctx.canary))
      {:ok, accesses} = Audit.list_accesses(actor: auditor)
      assert Enum.any?(accesses, &(&1.access_kind == :export))
      assert Enum.any?(accesses, &(&1.access_kind == :payload_view))
    end
  end
end
