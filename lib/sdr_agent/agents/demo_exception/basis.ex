defmodule SdrAgent.Agents.DemoException.Basis do
  @moduledoc """
  The closed basis `c2star-basis/1` of a demo-exception release (ADR-0005
  C2* amendment item 8; S3 plan r2 §6).

  A basis is a JSON-native map: string keys, string, integer, boolean and
  list values, and timestamps rendered `YYYY-MM-DDTHH:MM:SS.ffffffZ`. That is
  the form the jsonb column reloads, so a new decision and a replay validate
  the same value.

  `validate/2` accepts a basis only when all of these hold:

    * every listed object and key is present, no other key appears at any
      level, and no value is NULL;
    * every literal, enum, lowercase hex-64 digest, lowercase canonical UUID
      and six-digit `Z` timestamp is exactly as the schema states;
    * the two block counts are integers 0..4 totalling 1..4; `reason_codes`
      is exactly `["method_not_enabled"]` or
      `["cli_injected_context", "method_not_enabled"]`; `current_link_ids` is
      1 to 64 sorted, distinct UUIDs including `evidence.link_id`; each
      projected digest equals its observed one;
    * `starts_at <= decided_at < effective_expires_at`;
    * `window.decided_at` and `window.effective_expires_at` are the record's
      `decided_at` and `exception_expires_at`, and `policy.entry_sha256` and
      `policy.acceptance_ref` are the expected policy entry's;
    * the canonical encoding is at most 8192 bytes.

  The expected values are passed in. A new decision passes the compiled
  entry's `entry_sha256` and `acceptance_ref`; the replay path may pass the
  recorded ones, so a replay is never compared with today's entry here. No
  clock, selector or registry is read. A refused basis is never truncated
  or repaired. `funding.authorization_id` is only typed here (a non-empty
  string): its membership in the compiled registry and its equality with
  the entry's authorization are decision authority's checks.

  `sha256_hex/1` is the lowercase hex SHA-256 of the canonical encoding.
  """

  alias SdrAgent.Audit.Canonical

  @max_bytes 8192
  @max_link_ids 64
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @acceptance_ref ~r/\AD-[0-9]{3,4}\z/
  @timestamp ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\z/
  @code_sets [["method_not_enabled"], ["cli_injected_context", "method_not_enabled"]]
  @digest_pairs [
    {"projected_request_sha256", "observed_request_projection_sha256"},
    {"projected_response_sha256", "observed_response_projection_sha256"}
  ]

  @schema %{
    "schema" => {:literal, "c2star-basis/1"},
    "policy" =>
      {:object,
       %{
         "id" => {:literal, "c2star-demo-v4/1"},
         "entry_sha256" => :hex64,
         "acceptance_ref" => :acceptance_ref
       }},
    "environment" =>
      {:object,
       %{
         "id" => {:literal, "agentenv-1"},
         "binding_sha256" => :hex64,
         "tenant_id" => :uuid
       }},
    "funding" =>
      {:object,
       %{
         "authorization_id" => :id,
         "authorization_sha256" => :hex64,
         "grant_id" => :uuid,
         "allocation_id" => :uuid
       }},
    "invocation" =>
      {:object,
       %{
         "id" => :uuid,
         "run_id" => :uuid,
         "lead_id" => :uuid,
         "usage_origin" => {:literal, "assignment"},
         "purpose" => {:one_of, ~w(evidence_extraction outreach_proposal qualification)}
       }},
    "identity" =>
      {:object,
       %{
         "provider" => {:literal, "claude_cli"},
         "cli_version" => {:literal, "2.1.294"},
         "profile_id" => {:literal, "claude_cli_opus"},
         "model_id" => {:literal, "claude-opus-5-5"},
         "prompt_builder" => {:literal, "prompt-builder/1"},
         "ledger_generation" => {:literal, 2}
       }},
    "evidence" =>
      {:object,
       %{
         "link_id" => :uuid,
         "projection_version" => {:literal, "claude-message-json/4+prompt-builder/1"},
         "method" => {:literal, "propagated_id"},
         "response_layout" => {:literal, "reasoning_then_text"},
         "response_thinking_count" => :count,
         "response_redacted_thinking_count" => :count,
         "reason_codes" => :reason_codes,
         "projected_request_sha256" => :hex64,
         "observed_request_projection_sha256" => :hex64,
         "projected_response_sha256" => :hex64,
         "observed_response_projection_sha256" => :hex64,
         "current_link_ids" => :link_ids
       }},
    "eligibility" =>
      {:object,
       %{
         "v3_allowlisted" => {:literal, true},
         "v4_allowlisted" => {:literal, false}
       }},
    "window" =>
      {:object,
       %{
         "starts_at" => :timestamp,
         "effective_expires_at" => :timestamp,
         "decided_at" => :timestamp
       }}
  }

  @typedoc "The record and policy values a basis is cross-checked against."
  @type expected :: %{
          decided_at: DateTime.t(),
          exception_expires_at: DateTime.t(),
          entry_sha256: String.t(),
          acceptance_ref: String.t()
        }

  @doc """
  `:ok` when `basis` is a valid closed `c2star-basis/1` basis for `expected`,
  otherwise `{:error, reason}` naming the first failing rule (never a value).
  """
  @spec validate(term(), expected()) :: :ok | {:error, term()}
  def validate(
        basis,
        %{
          decided_at: %DateTime{},
          exception_expires_at: %DateTime{},
          entry_sha256: entry_sha256,
          acceptance_ref: acceptance_ref
        } = expected
      )
      when is_binary(entry_sha256) and is_binary(acceptance_ref) do
    with :ok <- shape({:object, @schema}, basis, []),
         :ok <- counts(basis["evidence"]),
         :ok <- primary_link(basis["evidence"]),
         :ok <- digest_pairs(basis["evidence"]),
         :ok <- window(basis["window"]),
         :ok <- record(basis, expected) do
      size(basis)
    end
  end

  @doc "Lowercase hex SHA-256 of `basis`'s `sdr-canonical-json/1` encoding."
  @spec sha256_hex(map()) :: String.t()
  def sha256_hex(basis), do: basis |> Canonical.sha256() |> Base.encode16(case: :lower)

  ## Shape (closed keys and value types)

  defp shape({:object, fields}, value, path) when is_map(value) and not is_struct(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(fields)),
      do: Enum.reduce_while(fields, :ok, &field(&1, &2, value, path)),
      else: {:error, {:keys, path}}
  end

  defp shape({:object, _fields}, _value, path), do: {:error, {:not_an_object, path}}

  defp shape(rule, value, path),
    do: if(valid?(rule, value), do: :ok, else: {:error, {:invalid, path}})

  defp field({key, rule}, :ok, object, path) do
    case shape(rule, Map.fetch!(object, key), path ++ [key]) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp valid?({:literal, literal}, value), do: value === literal
  defp valid?({:one_of, values}, value), do: is_binary(value) and value in values
  defp valid?(:hex64, value), do: is_binary(value) and Regex.match?(@hex64, value)
  defp valid?(:uuid, value), do: uuid?(value)

  defp valid?(:acceptance_ref, value),
    do: is_binary(value) and Regex.match?(@acceptance_ref, value)

  defp valid?(:id, value), do: is_binary(value) and value != "" and String.valid?(value)
  defp valid?(:count, value), do: is_integer(value) and value in 0..4
  defp valid?(:reason_codes, value), do: value in @code_sets
  defp valid?(:timestamp, value), do: match?({:ok, _at}, instant(value))

  defp valid?(:link_ids, value) do
    is_list(value) and length(value) in 1..@max_link_ids and Enum.all?(value, &uuid?/1) and
      value == value |> Enum.uniq() |> Enum.sort()
  end

  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  # A six-digit `Z` timestamp that is its own canonical rendering.
  defp instant(value) when is_binary(value) do
    with true <- Regex.match?(@timestamp, value),
         {:ok, at, 0} <- DateTime.from_iso8601(value),
         ^value <- Canonical.normalize(at) do
      {:ok, at}
    else
      _invalid -> :error
    end
  end

  defp instant(_value), do: :error

  ## Cross-field rules

  defp counts(%{
         "response_thinking_count" => thinking,
         "response_redacted_thinking_count" => redacted
       }) do
    if (thinking + redacted) in 1..4, do: :ok, else: {:error, :block_counts}
  end

  defp primary_link(%{"link_id" => link_id, "current_link_ids" => ids}),
    do: if(link_id in ids, do: :ok, else: {:error, :primary_link_not_current})

  defp digest_pairs(evidence) do
    if Enum.all?(@digest_pairs, fn {projected, observed} ->
         evidence[projected] == evidence[observed]
       end),
       do: :ok,
       else: {:error, :digest_pair}
  end

  defp window(%{"starts_at" => starts, "effective_expires_at" => ends, "decided_at" => decided}) do
    {:ok, starts} = instant(starts)
    {:ok, ends} = instant(ends)
    {:ok, decided} = instant(decided)

    if DateTime.compare(starts, decided) != :gt and DateTime.compare(decided, ends) == :lt,
      do: :ok,
      else: {:error, :window_order}
  end

  ## Cross-checks against the record and the expected policy entry

  defp record(basis, expected) do
    {:ok, decided} = instant(basis["window"]["decided_at"])
    {:ok, ends} = instant(basis["window"]["effective_expires_at"])

    cond do
      DateTime.compare(decided, expected.decided_at) != :eq ->
        {:error, {:record_mismatch, :decided_at}}

      DateTime.compare(ends, expected.exception_expires_at) != :eq ->
        {:error, {:record_mismatch, :exception_expires_at}}

      basis["policy"]["entry_sha256"] != expected.entry_sha256 ->
        {:error, {:entry_mismatch, :entry_sha256}}

      basis["policy"]["acceptance_ref"] != expected.acceptance_ref ->
        {:error, {:entry_mismatch, :acceptance_ref}}

      true ->
        :ok
    end
  end

  defp size(basis) do
    case Canonical.encode(basis) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> :ok
      {:ok, _bytes} -> {:error, :oversize}
      {:error, _reason} -> {:error, :not_canonical}
    end
  end
end
