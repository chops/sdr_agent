defmodule SdrAgent.Inbox.AuditRef do
  @moduledoc "Deterministic version-first, byte-bounded metadata reference for one auditor Home view."

  alias SdrAgent.Audit.Canonical

  @doc "Encode a complete reference or fail closed; never truncate shown references."
  def encode(%{version: "c1-inbox-view/1", shown: shown, metrics: metrics} = reference)
      when is_list(shown) and length(shown) <= 50 and is_list(metrics) do
    with true <- Enum.all?(Map.keys(reference), &(&1 in [:version, :shown, :metrics, :scope])),
         {:ok, <<"{", rest::binary>>} <- Canonical.encode(Map.delete(reference, :version)) do
      bounded(~s({"version":"c1-inbox-view/1",) <> rest)
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  def encode(_), do: {:error, :audit_unavailable}

  defp bounded(encoded) when byte_size(encoded) <= 12_000, do: {:ok, encoded}
  defp bounded(_), do: {:error, :audit_unavailable}
end
