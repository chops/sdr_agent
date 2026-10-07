defmodule SdrAgent.Audit.AnchorCryptoTest do
  use ExUnit.Case, async: true

  alias SdrAgent.Audit.AnchorStatement
  alias SdrAgent.Audit.Signing

  test "canonical statement binds the full anchor range and prior anchor" do
    attrs = %{
      tenant_id: "018f0000-0000-7000-8000-000000000001",
      anchor_number: 2,
      from_sequence: 8,
      to_sequence: 12,
      head_event_hash: :crypto.hash(:sha256, "head"),
      prior_anchor_hash: :crypto.hash(:sha256, "prior"),
      canonicalization_version: "sdr-canonical-json/1",
      sdr_agent_git_sha: String.duplicate("a", 40),
      trigger: :event_count,
      key_id: "test-key",
      key_status_at_signing: :active
    }

    bytes = AnchorStatement.encode!(attrs)
    decoded = Jason.decode!(bytes)

    assert decoded["anchor_number"] == 2
    assert decoded["event_range"] == %{"from" => 8, "to" => 12}
    assert decoded["head_event_hash"] == Base.encode16(attrs.head_event_hash, case: :lower)
    assert decoded["prior_anchor_hash"] == Base.encode16(attrs.prior_anchor_hash, case: :lower)
    assert decoded["trigger"] == "event_count"
    assert decoded["sdr_agent_git_sha"] == attrs.sdr_agent_git_sha
    assert decoded["canonicalization_version"] == "sdr-canonical-json/1"
    assert decoded["key_status_at_signing"] == "active"
    assert AnchorStatement.hash(bytes) == :crypto.hash(:sha256, bytes)
  end

  test "OTP crypto Ed25519 signatures verify and tampering fails" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    bytes = "canonical anchor statement"

    signature = Signing.sign(bytes, private_key)

    assert byte_size(signature) == 64
    assert Signing.verify(bytes, signature, public_key)
    refute Signing.verify(bytes <> "!", signature, public_key)
  end

  test "secret-safe decoding accepts base64 raw private material and never includes it in errors" do
    {_public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    encoded = Base.encode64(private_key)

    assert {:ok, ^private_key} = Signing.decode_private_key(encoded)
    assert {:error, message} = Signing.decode_private_key("definitely-not-a-key")
    refute message =~ "definitely-not-a-key"
  end

  test "decodes the PKCS8 Ed25519 PEM format stored by sops" do
    {_public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    entry =
      :public_key.pem_entry_encode(
        :ECPrivateKey,
        {:ECPrivateKey, 1, private_key, {:namedCurve, {1, 3, 101, 112}}, :asn1_NOVALUE,
         :asn1_NOVALUE}
      )

    assert {:ok, ^private_key} = Signing.decode_private_key(:public_key.pem_encode([entry]))
  end
end
