defmodule SdrAgent.Audit.RecordHash do
  @moduledoc """
  Canonical `record_sha256` of a persisted row (ADR-0009 "Audit coupling").

  The hash covers every attribute of the resource, encoded with
  `SdrAgent.Audit.Canonical`; binary attributes are written as lowercase
  hex. Each audit event of an audited write carries this hash of the row
  after the write, so the verifier can detect a row edited outside the
  application by recomputing it.
  """

  alias SdrAgent.Audit.Canonical

  @doc "Canonical map of a record's attributes (binaries as hex)."
  @spec canonical_map(Ash.Resource.record()) :: map()
  def canonical_map(%resource{} = record) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Map.new(fn attribute ->
      {attribute.name, value(attribute.type, Map.get(record, attribute.name))}
    end)
  end

  @doc "SHA-256 of the record's canonical encoding."
  @spec sha256(Ash.Resource.record()) :: binary()
  def sha256(record), do: record |> canonical_map() |> Canonical.sha256()

  @doc "Lowercase hex of `sha256/1`."
  @spec hex(Ash.Resource.record()) :: String.t()
  def hex(record), do: record |> sha256() |> Base.encode16(case: :lower)

  defp value(Ash.Type.Binary, bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp value(_type, value), do: value
end
