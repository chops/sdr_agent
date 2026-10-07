defmodule SdrAgent.Audit.TrustedKey do
  @moduledoc "Loads an out-of-band Ed25519 verification key and lifecycle metadata."

  @doc "Loads a pinned public-key file whose comments carry key_id/status metadata."
  def load(path, expected_key_id \\ nil) do
    with {:ok, pem} <- File.read(path),
         {:ok, key_id} <- metadata(pem, "key_id"),
         true <- is_nil(expected_key_id) or key_id == expected_key_id,
         {:ok, public_key} <- decode_public_key(pem),
         {:ok, status, revoked_at} <- lifecycle(pem) do
      {:ok, %{key_id: key_id, public_key: public_key, status: status, revoked_at: revoked_at}}
    else
      false -> {:error, :trusted_key_id_mismatch}
      _ -> {:error, :invalid_trusted_key_file}
    end
  end

  defp metadata(pem, name) do
    case Regex.run(~r/^# #{name}:\s*(.+)$/m, pem, capture: :all_but_first) do
      [value] -> {:ok, String.trim(value)}
      _ -> {:error, {:missing_metadata, name}}
    end
  end

  defp decode_public_key(pem) do
    with [entry] <- :public_key.pem_decode(pem),
         {{:ECPoint, public_key}, {:namedCurve, {1, 3, 101, 112}}} <-
           :public_key.pem_entry_decode(entry),
         true <- byte_size(public_key) == 32 do
      {:ok, public_key}
    else
      _ -> {:error, :invalid_public_key}
    end
  end

  defp lifecycle(pem) do
    with {:ok, status_text} <- metadata(pem, "status") do
      cond do
        String.starts_with?(status_text, "active") -> {:ok, :active, nil}
        String.starts_with?(status_text, "rotated") -> {:ok, :rotated, nil}
        String.starts_with?(status_text, "revoked") -> revoked_lifecycle(pem)
        true -> {:error, :invalid_key_status}
      end
    end
  end

  defp revoked_lifecycle(pem) do
    with {:ok, value} <- metadata(pem, "revoked_at"),
         {:ok, revoked_at, 0} <- DateTime.from_iso8601(value) do
      {:ok, :revoked, revoked_at}
    end
  end
end
