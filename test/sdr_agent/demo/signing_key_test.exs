defmodule SdrAgent.Demo.SigningKeyTest do
  @moduledoc """
  `bin/demo seed` registers the pinned audit-anchor *public* key
  (`docs/audit/anchor-signing-key.pub`) so anchoring works after a reset;
  idempotent, no private key material involved (S13c).
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.TrustedKey
  alias SdrAgent.Demo.Seed
  alias SdrAgent.Demo.SigningKey
  alias SdrAgent.Demo.Status

  @pinned "docs/audit/anchor-signing-key.pub"

  setup do
    {:ok, _} = Seed.run()
    {:ok, pinned} = TrustedKey.load(@pinned)
    {:ok, tenant_id} = Kernel.singleton_tenant_id()
    %{pinned: pinned, tenant: %{id: tenant_id}, kernel: Actor.system(:kernel, tenant_id)}
  end

  test "registers the pinned public key once; a second call writes nothing", %{pinned: pinned} do
    assert SigningKey.registered?() == false
    assert {:ok, :registered} = SigningKey.ensure()
    assert SigningKey.registered?()

    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()
    tenant = %{id: tenant_id}
    before = length(events(tenant))

    assert {:ok, :already_registered} = SigningKey.ensure()
    assert length(events(tenant)) == before
    assert [%{key_id: key_id, public_key: public_key, status: :active}] = SigningKey.keys()
    assert {key_id, public_key} == {pinned.key_id, pinned.public_key}
  end

  test "the registration is the audited kernel path", _ctx do
    {:ok, :registered} = SigningKey.ensure()
    {:ok, tenant_id} = SdrAgent.Audit.Kernel.singleton_tenant_id()

    assert [_] = events_of_type(%{id: tenant_id}, "audit.signing_key.registered")
  end

  # Codex review of #22 @f4738b5 (adopted as RED).
  describe "the registry must hold exactly the pinned key, active" do
    test "same id with different public bytes is neither registered nor ready; ensure refuses",
         ctx do
      {:ok, _} =
        Audit.register_signing_key(
          %{
            key_id: ctx.pinned.key_id,
            public_key: :crypto.hash(:sha256, "review alternate public key")
          },
          actor: ctx.kernel
        )

      observed = {SigningKey.registered?(), Status.ready?(Status.report()), SigningKey.ensure()}
      assert {false, false, {:error, :pinned_key_mismatch}} = observed
      # Only the conflicting registration itself; nothing overwritten or added.
      assert [_conflicting] = events_of_type(ctx.tenant, "audit.signing_key.registered")
      assert [%{public_key: alternate}] = SigningKey.keys()
      refute alternate == ctx.pinned.public_key
      assert Status.report().signing_key == {:invalid, :pinned_key_mismatch}
    end

    test "a rotated registry row for the pin is not reactivated or re-registered", ctx do
      {:ok, :registered} = SigningKey.ensure()
      [key] = SigningKey.keys()
      admin = new_human(:admin, ctx.tenant)
      {:ok, _} = Audit.rotate_signing_key(key.id, actor: admin)

      assert SigningKey.ensure() == {:error, {:pinned_key_inactive, :rotated}}
      refute SigningKey.registered?()
      assert [_only_the_first] = events_of_type(ctx.tenant, "audit.signing_key.registered")
      assert [%{status: :rotated}] = SigningKey.keys()
    end

    test "a revoked out-of-band pin is never auto-registered active", ctx do
      root =
        Path.join(
          System.tmp_dir!(),
          "sdr-review-revoked-pin-#{System.unique_integer([:positive])}"
        )

      dir = Path.join(root, "docs/audit")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(root) end)

      pem =
        @pinned
        |> File.read!()
        |> String.replace(
          ~r/^# status:.*$/m,
          "# status: revoked\n# revoked_at: 2026-10-07T00:00:00Z"
        )

      File.write!(Path.join(dir, "anchor-signing-key.pub"), pem)
      {:ok, %{status: :revoked}} = TrustedKey.load(Path.join(dir, "anchor-signing-key.pub"))

      assert {:error, {:pin_not_active, :revoked}} = File.cd!(root, fn -> SigningKey.ensure() end)
      assert events_of_type(ctx.tenant, "audit.signing_key.registered") == []
    end

    test "refuses where demo seeding is disabled, without a registration write", ctx do
      previous = Application.get_env(:sdr_agent, :seeding_allowed?)
      Application.put_env(:sdr_agent, :seeding_allowed?, false)
      on_exit(fn -> Application.put_env(:sdr_agent, :seeding_allowed?, previous) end)

      assert SigningKey.ensure() == {:error, :demo_not_allowed}
      assert events_of_type(ctx.tenant, "audit.signing_key.registered") == []
    end
  end
end
