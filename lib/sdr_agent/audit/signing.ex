defmodule SdrAgent.Audit.Signing do
  @moduledoc "Secret-safe Ed25519 signing and verification using OTP `:crypto`."

  @doc "Signs bytes with a raw 32-byte Ed25519 private key."
  def sign(bytes, private_key) when byte_size(private_key) in [32, 64] do
    :crypto.sign(:eddsa, :none, bytes, [private_key, :ed25519])
  end

  @doc "Verifies an Ed25519 signature."
  def verify(bytes, signature, public_key)
      when byte_size(signature) == 64 and byte_size(public_key) == 32 do
    :crypto.verify(:eddsa, :none, bytes, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  def verify(_, _, _), do: false

  @doc "Decodes a base64 raw key without reflecting secret input in errors."
  def decode_private_key(value) when is_binary(value) do
    value = String.trim(value)

    if String.starts_with?(value, "-----BEGIN") do
      decode_pem(value)
    else
      decode_base64(value)
    end
  rescue
    _ -> invalid_key()
  end

  defp decode_base64(value) do
    with {:ok, decoded} <- Base.decode64(value),
         true <- byte_size(decoded) in [32, 64] do
      {:ok, decoded}
    else
      _ -> invalid_key()
    end
  end

  defp decode_pem(value) do
    with [entry] <- :public_key.pem_decode(value),
         {:ECPrivateKey, version, key, {:namedCurve, {1, 3, 101, 112}}, _, _}
         when version in [1, :ecPrivkeyVer1] <-
           :public_key.pem_entry_decode(entry),
         true <- byte_size(key) == 32 do
      {:ok, key}
    else
      _ -> invalid_key()
    end
  end

  defp invalid_key, do: {:error, "invalid Ed25519 private key material"}
end
