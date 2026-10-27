defmodule SdrAgent.Audit.RecordHash do
  @moduledoc """
  Canonical `record_sha256` of a persisted row (ADR-0009 "Audit coupling").

  The hash covers every attribute of the resource, encoded with
  `SdrAgent.Audit.Canonical`; binary attributes are written as lowercase
  hex and case-insensitive strings as their stored text. Each audit event of an audited write carries this hash of the row
  after the write, so the verifier can detect a row edited outside the
  application by recomputing it.

  Record-hash groups (ADR-0009 C2* record-hash continuity amendment, D-226):
  a resource may declare closed groups of nullable attributes added after
  its first release (`__sdr_record_hash_groups__/0`). A group's members are
  left out of the row map together exactly when every one of them is nil
  as loaded; when any member is non-nil, all of them are included (nil as
  JSON null). Every other attribute, and every resource without a group, is
  unchanged. Exactly one group exists: `SdrAgent.Agents.ModelResultRelease`'s
  `c2star-demo-exception`, so every release decided before its migration
  keeps the hash its event committed. The encoding (`sdr-canonical-json/1`)
  is unchanged.
  """

  alias SdrAgent.Audit.Canonical

  @doc "Canonical map of a record's attributes (binaries as hex), with declared groups applied."
  @spec canonical_map(Ash.Resource.record()) :: map()
  def canonical_map(%resource{} = record) do
    full =
      resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(fn attribute ->
        {attribute.name, value(attribute.type, Map.get(record, attribute.name))}
      end)

    Enum.reduce(groups(resource), full, fn {_name, members}, map ->
      if Enum.all?(members, &is_nil(Map.fetch!(map, &1))),
        do: Map.drop(map, members),
        else: map
    end)
  end

  @doc """
  The record-hash groups `resource` declares (`{name, members}`), or `[]`
  for every resource that declares none.
  """
  @spec groups(module()) :: [{String.t(), [atom()]}]
  def groups(resource) do
    if Code.ensure_loaded?(resource) and
         function_exported?(resource, :__sdr_record_hash_groups__, 0),
       do: resource.__sdr_record_hash_groups__(),
       else: []
  end

  @doc "Canonical form of one attribute value of `resource` (as in `canonical_map/1`)."
  @spec attribute_value(module(), atom(), term()) :: term()
  def attribute_value(resource, name, value) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> value
      attribute -> value(attribute.type, value)
    end
  end

  @doc "SHA-256 of the record's canonical encoding."
  @spec sha256(Ash.Resource.record()) :: binary()
  def sha256(record), do: record |> canonical_map() |> Canonical.sha256()

  @doc "Lowercase hex of `sha256/1`."
  @spec hex(Ash.Resource.record()) :: String.t()
  def hex(record), do: record |> sha256() |> Base.encode16(case: :lower)

  defp value(Ash.Type.Binary, bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp value(Ash.Type.CiString, %Ash.CiString{} = string), do: to_string(string)
  defp value(_type, value), do: value
end
