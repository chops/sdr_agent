defmodule SdrAgent.Agents.WitnessEvidence do
  @moduledoc """
  The bounded, allowlisted `evidence` map of a `SdrAgent.Agents.WireWitnessLink`
  (S12 entity condition C5, plan P2; ADR-0005 S12 amendment).

  Evidence binds what a link claims — proxy schema/version, the classified
  route, exchange timing and completeness flags, the projection version,
  application/projection digests, the inventory snapshot digest and typed
  reason codes — and nothing else. It never carries request headers,
  tokens, raw bodies, local paths or account identifiers (Claude's
  `metadata.user_id` stays only in the owner's proxy store).

  Rules (`validate/1`):

    * keys are strings (atoms are converted) from the allowlist below;
      values are scalars or, for `reason_codes`, a list of codes — no maps;
    * each value has a fixed type: integer ranges, booleans, enums, strict
      patterns (lowercase hex digests, snake_case codes of at most 39
      characters, versions), RFC 3339 UTC timestamps;
    * every free-form string (versions, codes, encodings) must pass
      `SdrAgent.Operations.Redactor` unchanged, so secret-shaped values are
      refused even when they fit a pattern (digests are typed hex and
      exempt);
    * the canonical JSON encoding is at most 4096 bytes. The typed maxima
      keep any valid map below that bound; the check is the backstop.
  """

  alias SdrAgent.Operations.Redactor

  @max_bytes 4096
  @code ~r/\A[a-z][a-z0-9_]{0,38}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @timestamp ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\z/
  # name/N[+builder/N], at most 39 bytes (below the redactor's 40-char run).
  @projection ~r/\A(?=.{1,39}\z)[a-z][a-z0-9-]*\/[0-9]{1,4}(?:\+[a-z][a-z0-9-]*\/[0-9]{1,4})?\z/
  @routes ["/anthropic/v1/messages", "/anthropic/v1/messages/count_tokens", "/anthropic/unknown"]
  @classifications ["primary", "ancillary", "unclassified", "ambiguous"]

  @allowed %{
    "witness_schema" => {:integer, 1, 99},
    "proxy_version" => {:text, ~r/\A[A-Za-z0-9_.-]{1,32}\z/},
    "cli_version" => {:text, ~r/\A[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}\z/},
    "route" => {:enum, @routes},
    "http_method" => {:text, ~r/\A[A-Z]{3,7}\z/},
    "http_status" => {:integer, 100, 599},
    "outcome" => {:text, @code},
    "started_at" => :timestamp,
    "completed_at" => :timestamp,
    "request_bytes_seen" => {:integer, 0, 1_000_000_000_000},
    "response_bytes_seen" => {:integer, 0, 1_000_000_000_000},
    "request_capture_complete" => :boolean,
    "response_capture_complete" => :boolean,
    "stream_complete" => :boolean,
    "traceparent_match" => :boolean,
    "response_content_encoding" => {:text, ~r/\A[a-z0-9-]{1,16}\z/},
    "classification" => {:enum, @classifications},
    "projection_version" => {:text, @projection},
    "app_request_sha256" => :sha256,
    "app_response_sha256" => :sha256,
    "projected_request_sha256" => :sha256,
    "projected_response_sha256" => :sha256,
    "observed_request_projection_sha256" => :sha256,
    "observed_response_projection_sha256" => :sha256,
    "inventory_sha256" => :sha256,
    "reason_codes" => {:codes, 16},
    "supersede_reason" => {:text, @code},
    # S12d projection v2 context group (entity PASS f04a7e44)
    "reminder_count" => {:integer, 0, 4},
    "reminder_sha256s" => {:digests, 4},
    "reminder_bytes" => {:sizes, 4, 8192},
    "trailing_system_count" => {:integer, 0, 2},
    "trailing_system_sha256s" => {:digests, 2},
    "trailing_system_bytes" => {:sizes, 2, 32_768},
    "request_extras_sha256" => :sha256,
    "request_fields" => :request_fields
  }
  @group ~w(reminder_count reminder_sha256s reminder_bytes trailing_system_count
            trailing_system_sha256s trailing_system_bytes request_extras_sha256 request_fields)
  @field_codes Enum.flat_map(
                 ~w(system thinking output_config context_management),
                 &["#{&1}_present", "#{&1}_null"]
               )

  @doc "The allowlisted keys and their types."
  def allowed, do: @allowed

  @doc "Maximum canonical JSON size in bytes."
  def max_bytes, do: @max_bytes

  @doc """
  Returns `{:ok, evidence}` with string keys, or `{:error, message}` naming
  the first offending allowlisted key (never a value, never a refused key).
  """
  @spec validate(term()) :: {:ok, map()} | {:error, String.t()}
  def validate(evidence) when is_map(evidence) do
    with {:ok, normalized} <- normalize_keys(evidence),
         :ok <- validate_values(normalized),
         :ok <- validate_group(normalized),
         :ok <- validate_size(normalized) do
      {:ok, normalized}
    end
  end

  def validate(_evidence), do: {:error, "must be a map"}

  defp normalize_keys(evidence) do
    Enum.reduce_while(evidence, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key) and not is_nil(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) ->
          {:halt, {:error, "keys must be strings"}}

        not Map.has_key?(@allowed, key) ->
          {:halt, {:error, "contains a key outside the allowlist"}}

        Map.has_key?(acc, key) ->
          {:halt, {:error, "key #{key} is given twice"}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp validate_values(evidence) do
    Enum.find_value(evidence, :ok, fn {key, value} ->
      if valid?(Map.fetch!(@allowed, key), value), do: nil, else: {:error, "#{key} is invalid"}
    end)
  end

  @doc "The S12d v2 context-group keys (all present together or none)."
  def context_group, do: @group

  # All-or-none; counts equal their list lengths; field codes are unique,
  # in the fixed order, and `_null` only after its `_present`.
  defp validate_group(evidence) do
    present = Enum.filter(@group, &Map.has_key?(evidence, &1))

    cond do
      present == [] -> :ok
      length(present) != length(@group) -> {:error, "context group is incomplete"}
      not counts_match?(evidence) -> {:error, "context group counts differ from lists"}
      true -> :ok
    end
  end

  defp counts_match?(e) do
    length(e["reminder_sha256s"]) == e["reminder_count"] and
      length(e["reminder_bytes"]) == e["reminder_count"] and
      length(e["trailing_system_sha256s"]) == e["trailing_system_count"] and
      length(e["trailing_system_bytes"]) == e["trailing_system_count"]
  end

  defp validate_size(evidence) do
    if byte_size(Jason.encode!(evidence)) <= @max_bytes,
      do: :ok,
      else: {:error, "exceeds #{@max_bytes} bytes"}
  end

  defp valid?({:integer, min, max}, value), do: is_integer(value) and value in min..max
  defp valid?(:boolean, value), do: is_boolean(value)
  defp valid?({:enum, values}, value), do: is_binary(value) and value in values
  defp valid?(:sha256, value), do: is_binary(value) and Regex.match?(@hex64, value)
  defp valid?({:text, pattern}, value), do: text?(value, pattern)

  defp valid?(:timestamp, value) do
    is_binary(value) and Regex.match?(@timestamp, value) and
      match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))
  end

  defp valid?({:digests, max}, value),
    do: is_list(value) and length(value) <= max and Enum.all?(value, &valid?(:sha256, &1))

  defp valid?({:sizes, max, cap}, value),
    do:
      is_list(value) and length(value) <= max and
        Enum.all?(value, &(is_integer(&1) and &1 in 0..cap))

  defp valid?(:request_fields, value) do
    is_list(value) and Enum.all?(value, &(&1 in @field_codes)) and
      value == Enum.filter(@field_codes, &(&1 in value)) and
      Enum.all?(value, fn code ->
        not String.ends_with?(code, "_null") or
          String.replace_suffix(code, "_null", "_present") in value
      end)
  end

  defp valid?({:codes, max}, value) do
    is_list(value) and length(value) <= max and length(Enum.uniq(value)) == length(value) and
      Enum.all?(value, &text?(&1, @code))
  end

  defp text?(value, pattern),
    do: is_binary(value) and Regex.match?(pattern, value) and Redactor.redact(value) == value
end
