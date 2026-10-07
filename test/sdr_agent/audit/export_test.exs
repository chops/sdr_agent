defmodule SdrAgent.Audit.ExportTest do
  use SdrAgent.AuditCase, async: true

  alias SdrAgent.Audit
  alias SdrAgent.Audit.AuditExport
  alias SdrAgent.Audit.Export
  alias SdrAgent.Audit.ExportVerifier

  defmodule ConfirmedSink do
    def publish(_hash, _opts), do: {:ok, %{status: :confirmed, proof: "test-proof"}}
  end

  defmodule ConfirmedGitSink do
    def publish(_statement, _opts),
      do:
        {:ok,
         %{
           status: :confirmed,
           repository: "git@github.com:chops/sdr_agent-audit-anchors.git",
           commit_id: String.duplicate("a", 40),
           blob_id: String.duplicate("b", 40)
         }}
  end

  setup do
    tenant = bootstrap!()
    actor = human(:auditor, tenant)
    anchorer = system_actor(:anchorer, tenant)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, key} =
      Audit.register_signing_key(%{key_id: "export-key", public_key: public_key},
        actor: SdrAgent.Actor.system(:kernel, tenant.id)
      )

    path = Path.join(System.tmp_dir!(), "sdr-export-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    %{
      tenant: tenant,
      actor: actor,
      anchorer: anchorer,
      key: key,
      private_key: private_key,
      path: path
    }
  end

  test "export is access-audited, signed, anchored and independently verified", ctx do
    assert {:ok, result} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    assert result.export.status == :completed
    assert result.export.assurance_level == :signed
    assert File.exists?(ctx.path)
    assert File.stat!(ctx.path).mode |> Bitwise.band(0o777) == 0o600

    assert {:ok, %{valid?: true, assurance_level: :signed}} =
             ExportVerifier.verify(ctx.path, trusted_key: trusted_key(ctx.key))

    assert {:ok, accesses} = Audit.list_accesses(actor: ctx.actor)
    assert Enum.any?(accesses, &(&1.access_kind == :export))
  end

  test "tampering with a completed bundle is detected", ctx do
    assert {:ok, _} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    File.write!(ctx.path, File.read!(ctx.path) <> "tampered")

    assert {:error, :invalid_bundle} =
             ExportVerifier.verify(ctx.path, trusted_key: trusted_key(ctx.key))
  end

  test "access failure withholds export bytes", ctx do
    denied = human(:reviewer, ctx.tenant)

    assert {:error, _} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "1:latest"},
               actor: denied,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    refute File.exists?(ctx.path)
  end

  test "offline verification refuses the bundle-embedded key as a trust root", ctx do
    assert {:ok, _} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    assert {:error, :trusted_key_required} = ExportVerifier.verify(ctx.path)

    {forged_public, _forged_private} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:error, :invalid_bundle} =
             ExportVerifier.verify(ctx.path,
               trusted_key: %{key_id: ctx.key.key_id, public_key: forged_public, status: :active}
             )
  end

  test "offline revocation cannot trust signer-controlled backdated timestamps",
       ctx do
    assert {:ok, result} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    after_signing = DateTime.add(result.anchor.inserted_at, 1, :second)

    assert {:ok, %{valid?: false, assurance_level: :chain_verified, issues: issues}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: %{trusted_key(ctx.key) | status: :revoked, revoked_at: after_signing}
             )

    assert :revocation_time_unproven in issues

    assert {:ok, %{valid?: false, assurance_level: :chain_verified}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: %{
                 trusted_key(ctx.key)
                 | status: :revoked,
                   revoked_at: result.anchor.inserted_at
               }
             )
  end

  test "offline verification after rotation uses each anchor's pinned key", ctx do
    assert {:ok, _} =
             SdrAgent.Audit.Anchoring.anchor(
               trigger: :interval,
               actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [{:git, ConfirmedGitSink, []}]
             )

    admin = human(:admin, ctx.tenant)
    assert {:ok, rotated} = Audit.rotate_signing_key(ctx.key.id, actor: admin)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:ok, replacement} =
             Audit.register_signing_key(
               %{key_id: "replacement", public_key: public},
               actor: SdrAgent.Actor.system(:kernel, ctx.tenant.id)
             )

    assert {:ok, exported} =
             Export.build(%{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: private,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    assert exported.export.assurance_level == :signed

    assert {:ok, %{valid?: true, assurance_level: :signed}} =
             ExportVerifier.verify(ctx.path,
               trusted_keys: [trusted_key(rotated), trusted_key(replacement)]
             )

    assert {:error, :invalid_bundle} =
             ExportVerifier.verify(ctx.path,
               trusted_keys: [trusted_key(replacement)]
             )
  end

  test "confirmed receipts require verifier evidence and revoked anchors require independent time",
       ctx do
    assert {:ok, result} =
             Export.build(%{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [{:git, ConfirmedSink, []}, {:ots, ConfirmedSink, []}],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    assert {:ok, %{assurance_level: :signed}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: trusted_key(ctx.key)
             )

    digest = Base.encode16(result.anchor.anchor_hash, case: :lower)

    assert {:ok, %{assurance_level: :git_anchored}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: trusted_key(ctx.key),
               git_verifier: fn _, hash -> hash == digest end
             )

    assert {:ok, %{assurance_level: :ots_anchored}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: trusted_key(ctx.key),
               ots_verifier: fn _, hash ->
                 {:ok, %{verified: hash == digest, timestamp: result.anchor.inserted_at}}
               end
             )

    revoked = %{
      trusted_key(ctx.key)
      | status: :revoked,
        revoked_at: DateTime.add(result.anchor.inserted_at, 1, :second)
    }

    assert {:ok, %{valid?: true, assurance_level: :chain_verified}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: revoked,
               ots_verifier: fn _, ^digest ->
                 {:ok, %{verified: true, timestamp: result.anchor.inserted_at}}
               end
             )

    assert {:ok, %{valid?: false, issues: [:revocation_time_unproven]}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: revoked,
               ots_verifier: fn _, _ ->
                 {:ok, %{verified: true, timestamp: revoked.revoked_at}}
               end
             )

    assert {:ok, %{valid?: false}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: revoked,
               git_verifier: fn _, _ -> true end
             )

    # A thief possessing the private key can re-sign the bundle after altering
    # the unsigned anchor timestamp. This still establishes no trusted time.
    wrapper = Jason.decode!(File.read!(ctx.path))
    decoded = wrapper["payload"] |> Base.decode64!() |> Jason.decode!()
    backdate = &Map.put(&1, "inserted_at", "2000-01-01T00:00:00Z")

    bytes =
      decoded
      |> Map.update!("anchor", backdate)
      |> Map.update!("anchors", &Enum.map(&1, backdate))
      |> Jason.encode!()

    File.write!(
      ctx.path,
      Jason.encode!(%{
        payload: Base.encode64(bytes),
        signature: Base.encode64(SdrAgent.Audit.Signing.sign(bytes, ctx.private_key))
      })
    )

    assert {:ok, %{valid?: false, issues: [:revocation_time_unproven]}} =
             ExportVerifier.verify(ctx.path,
               trusted_key: revoked
             )
  end

  test "export refuses a symlink below its allowed root", ctx do
    root = Path.join(System.tmp_dir!(), "sdr-root-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.ln_s!(Path.dirname(ctx.path), Path.join(root, "escape"))
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, :output_outside_allowed_root} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               output: Path.join(root, "escape/leaked.json"),
               output_root: root
             )
  end

  test "lead scope excludes other leads and unreferenced payloads", ctx do
    {:ok, wanted_payload} =
      Audit.put_payload("wanted", "text/plain", actor: system_actor(:agent_runtime, ctx.tenant))

    {:ok, other_payload} =
      Audit.put_payload("other", "text/plain", actor: system_actor(:agent_runtime, ctx.tenant))

    {:ok, wanted_event} =
      Audit.append(
        %{
          event_type: "sdr.lead.updated",
          category: :domain_change,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: "lead-wanted",
          payload: %{body_sha256: Base.encode16(wanted_payload.sha256, case: :lower)}
        },
        actor: system_actor(:agent_runtime, ctx.tenant),
        tenant_id: ctx.tenant.id
      )

    {:ok, other_event} =
      Audit.append(
        %{
          event_type: "sdr.lead.updated",
          category: :domain_change,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: "lead-other",
          payload: %{body_sha256: Base.encode16(other_payload.sha256, case: :lower)}
        },
        actor: system_actor(:agent_runtime, ctx.tenant),
        tenant_id: ctx.tenant.id
      )

    assert {:ok, _} =
             Export.build(
               %{scope: :lead, scope_ref: "lead-wanted"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    wrapper = Jason.decode!(File.read!(ctx.path))
    payload = wrapper["payload"] |> Base.decode64!() |> Jason.decode!()
    assert Enum.map(payload["events"], & &1["sequence"]) == [wanted_event.sequence]
    refute Enum.any?(payload["events"], &(&1["sequence"] == other_event.sequence))
    assert Enum.map(payload["payloads"], & &1["content"]) == [Base.encode64("wanted")]

    assert {:ok, %{valid?: true}} =
             ExportVerifier.verify(ctx.path, trusted_key: trusted_key(ctx.key))
  end

  test "export errors terminalize the request as failed without leaving bytes", ctx do
    assert {:error, :invalid_sequence_range} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "not-a-range"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path,
               output_root: Path.dirname(ctx.path)
             )

    refute File.exists?(ctx.path)

    [export] =
      AuditExport
      |> Ash.Query.for_read(:read, %{}, actor: ctx.actor)
      |> Ash.read!()

    assert export.status == :failed
    assert export.failure_reason =~ "invalid_sequence_range"
  end

  defp trusted_key(key) do
    %{
      key_id: key.key_id,
      public_key: key.public_key,
      status: key.status,
      revoked_at: key.revoked_at
    }
  end
end
