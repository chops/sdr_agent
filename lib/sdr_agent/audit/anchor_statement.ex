defmodule SdrAgent.Audit.AnchorStatement do
  @moduledoc "Builds the canonical signed statement defined by ADR-0005."

  alias SdrAgent.Audit.Canonical

  @fields [
    :tenant_id,
    :anchor_number,
    :head_event_hash,
    :prior_anchor_hash,
    :canonicalization_version,
    :sdr_agent_git_sha,
    :trigger,
    :key_id,
    :key_status_at_signing
  ]

  @doc "Encodes an anchor statement using the audit canonicalization format."
  def encode!(attrs) do
    attrs = Map.new(attrs)

    attrs
    |> Map.take(@fields)
    |> Map.put(:event_range, %{
      from: Map.fetch!(attrs, :from_sequence),
      to: Map.fetch!(attrs, :to_sequence)
    })
    |> Map.update!(:head_event_hash, &hex/1)
    |> maybe_hex(:prior_anchor_hash)
    |> Canonical.encode!()
  end

  @doc "SHA-256 digest of statement bytes."
  def hash(bytes), do: :crypto.hash(:sha256, bytes)

  defp maybe_hex(map, field) do
    case Map.get(map, field) do
      nil -> map
      value -> Map.put(map, field, hex(value))
    end
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
