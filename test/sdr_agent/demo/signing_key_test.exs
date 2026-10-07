defmodule SdrAgent.Demo.SigningKeyTest do
  @moduledoc """
  `bin/demo seed` registers the pinned audit-anchor *public* key
  (`docs/audit/anchor-signing-key.pub`) so anchoring works after a reset;
  idempotent, no private key material involved (S13c).
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Audit.TrustedKey
  alias SdrAgent.Demo.Seed
  alias SdrAgent.Demo.SigningKey

  setup do
    {:ok, _} = Seed.run()
    {:ok, pinned} = TrustedKey.load("docs/audit/anchor-signing-key.pub")
    %{pinned: pinned}
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
end
