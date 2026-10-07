defmodule SdrAgent.Audit.ExportTest do
  use SdrAgent.AuditCase, async: true

  alias SdrAgent.Audit
  alias SdrAgent.Audit.Export
  alias SdrAgent.Audit.ExportVerifier

  setup do
    tenant = bootstrap!()
    actor = human(:auditor, tenant)
    anchorer = system_actor(:anchorer, tenant)
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    {:ok, _key} =
      Audit.register_signing_key(%{key_id: "export-key", public_key: public_key},
        actor: SdrAgent.Actor.system(:kernel, tenant.id)
      )

    path = Path.join(System.tmp_dir!(), "sdr-export-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    %{tenant: tenant, actor: actor, anchorer: anchorer, private_key: private_key, path: path}
  end

  test "export is access-audited, signed, anchored and independently verified", ctx do
    assert {:ok, result} =
             Export.build(
               %{scope: :sequence_range, scope_ref: "1:latest"},
               actor: ctx.actor,
               anchor_actor: ctx.anchorer,
               private_key: ctx.private_key,
               sinks: [],
               output: ctx.path
             )

    assert result.export.status == :completed
    assert result.export.assurance_level == :signed
    assert File.exists?(ctx.path)
    assert {:ok, %{valid?: true, assurance_level: :signed}} = ExportVerifier.verify(ctx.path)

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
               output: ctx.path
             )

    File.write!(ctx.path, File.read!(ctx.path) <> "tampered")
    assert {:error, :invalid_bundle} = ExportVerifier.verify(ctx.path)
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
               output: ctx.path
             )

    refute File.exists?(ctx.path)
  end
end
