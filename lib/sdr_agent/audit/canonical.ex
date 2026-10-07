defmodule SdrAgent.Audit.Canonical do
  @moduledoc """
  Canonical serialization for every hashed audit record (ADR-0002
  "Canonical serialization"), version `sdr-canonical-json/1`.

  The version string is stored as `canonicalization_version` on every
  AuditEvent and ProvenanceSnapshot. Changing any rule below requires a new
  version constant; existing bytes are never re-encoded.

  ## Rules (`sdr-canonical-json/1`)

    * Output is UTF-8 JSON with no insignificant whitespace.
    * Objects: keys are strings (atom keys are written as their name); keys
      are sorted by raw byte order; duplicate keys after conversion raise.
    * Strings must be valid UTF-8. Only `"` (as `\\"`), `\\` (as `\\\\`) and
      bytes below 0x20 (as `\\u00xx`, lowercase hex) are escaped; every other
      code point is written literally. Binaries that are not UTF-8 are
      rejected — callers hex-encode digests explicitly.
    * Integers in decimal; floats in Erlang's shortest round-trip form
      (`:erlang.float_to_binary(f, [:short])`, e.g. `0.1`, `1.0e-7`).
    * `true`, `false`, `nil` → `true`, `false`, `null`; other atoms → their
      name as a string.
    * `DateTime` → UTC ISO-8601 with exactly six fraction digits and `Z`;
      `NaiveDateTime` is rejected; `Date` and `Time` → ISO-8601;
      `Decimal` → its string form.
    * Lists and tuples → arrays. Ash embedded resource structs → objects of
      their public attributes. Any other struct raises.

  Event hash: `sha256(canonical_bytes)` where the bytes encode every
  AuditEvent column except `event_hash` and `canonical_bytes` (see
  `SdrAgent.Audit.Kernel`).
  """

  @version "sdr-canonical-json/1"

  @doc "The canonicalization version recorded on hashed records."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Encodes `term` canonically; raises `ArgumentError` on unsupported input."
  @spec encode!(term()) :: binary()
  def encode!(term) do
    case encode(term) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise ArgumentError, "cannot canonicalize: #{inspect(reason)}"
    end
  end

  @doc "Encodes `term` canonically."
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(term) do
    {:ok, term |> enc() |> IO.iodata_to_binary()}
  catch
    {:canonical_error, reason} -> {:error, reason}
  end

  @doc "SHA-256 of the canonical encoding of `term`."
  @spec sha256(term()) :: binary()
  def sha256(term), do: :crypto.hash(:sha256, encode!(term))

  @doc """
  Normalizes `term` into the plain JSON data model that `encode/1` writes
  (string keys, string atoms, ISO timestamps), suitable for a jsonb copy.
  """
  @spec normalize(term()) :: term()
  def normalize(term), do: term |> encode!() |> Jason.decode!()

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(atom) when is_atom(atom), do: string(Atom.to_string(atom))
  defp enc(int) when is_integer(int), do: Integer.to_string(int)
  defp enc(float) when is_float(float), do: :erlang.float_to_binary(float, [:short])
  defp enc(bin) when is_binary(bin), do: string(bin)
  defp enc(list) when is_list(list), do: ["[", Enum.map_intersperse(list, ",", &enc/1), "]"]
  defp enc(tuple) when is_tuple(tuple), do: enc(Tuple.to_list(tuple))

  defp enc(%DateTime{} = dt) do
    {:ok, utc} = DateTime.shift_zone(dt, "Etc/UTC")
    {micro, _precision} = utc.microsecond
    string(DateTime.to_iso8601(%{utc | microsecond: {micro, 6}}))
  end

  defp enc(%Date{} = date), do: string(Date.to_iso8601(date))
  defp enc(%Time{} = time), do: string(Time.to_iso8601(time))
  defp enc(%NaiveDateTime{} = ndt), do: throw({:canonical_error, {:naive_datetime, ndt}})
  defp enc(%Decimal{} = dec), do: string(Decimal.to_string(dec))

  defp enc(%module{} = struct) do
    if Ash.Resource.Info.resource?(module) and Ash.Resource.Info.embedded?(module) do
      module
      |> Ash.Resource.Info.public_attributes()
      |> Map.new(&{&1.name, Map.get(struct, &1.name)})
      |> enc()
    else
      throw({:canonical_error, {:unsupported_struct, module}})
    end
  end

  defp enc(map) when is_map(map) do
    pairs =
      Enum.map(map, fn
        {key, value} when is_atom(key) and not is_nil(key) and not is_boolean(key) ->
          {Atom.to_string(key), value}

        {key, value} when is_binary(key) ->
          {key, value}

        {key, _} ->
          throw({:canonical_error, {:unsupported_key, key}})
      end)

    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) != length(keys),
      do: throw({:canonical_error, {:duplicate_keys, keys}})

    body =
      pairs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_intersperse(",", fn {key, value} -> [string(key), ":", enc(value)] end)

    ["{", body, "}"]
  end

  defp enc(other), do: throw({:canonical_error, {:unsupported, other}})

  defp string(bin) do
    if String.valid?(bin),
      do: [?", escape(bin, []), ?"],
      else: throw({:canonical_error, {:not_utf8, bin}})
  end

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])

  defp escape(<<byte, rest::binary>>, acc) when byte < 0x20 do
    hex = byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    escape(rest, ["\\u" <> hex | acc])
  end

  defp escape(<<byte, rest::binary>>, acc), do: escape(rest, [byte | acc])
end
