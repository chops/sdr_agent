defmodule SdrAgent.Audit.Verifier do
  @moduledoc """
  Chain verifier (ADR-0002 "Threat model": detects silent edits, deletions,
  reordering and insertion).

  Called by `SdrAgent.Audit.verify_chain/1` (which authorizes the caller and
  records the verification as an AuditAccess) with the chain head locked.
  Checks, per tenant:

    * `:sequence_gap` — sequences are exactly 1, 2, 3, …;
    * `:prev_hash_mismatch` — each `prev_hash` equals the previous
      `event_hash` (genesis: 32 zero bytes);
    * `:event_hash_mismatch` — `event_hash = sha256(canonical_bytes)`;
    * `:row_mismatch` — the stored columns re-encode to exactly
      `canonical_bytes` (hashes are recomputed from the bytes, never from
      the jsonb copies);
    * `:head_mismatch` — the chain head equals the newest event;
    * `:payload_hash_mismatch` — every Payload's content hashes to its key;
    * `:record_hash_mismatch` / `:record_missing` — for resources whose
      every write is audited (they export `__sdr_audited__/0`), the newest
      event's `record_sha256` equals the canonical hash of the current row.

  Returns `%{valid?: boolean, issues: [map], last_sequence: integer,
  events_checked: integer}`. Anchor divergence is added in S11.
  """

  require Ash.Query

  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Payload
  alias SdrAgent.Audit.RecordHash

  @doc "Verifies `tenant_id`'s chain against its (already locked) `head`."
  @spec verify(Ecto.UUID.t(), struct()) :: map()
  def verify(tenant_id, head) do
    events =
      AuditEvent
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!()

    issues =
      chain_issues(events) ++
        head_issues(head, List.last(events)) ++
        payload_issues(tenant_id) ++ record_issues(events)

    last = List.last(events)

    %{
      valid?: issues == [],
      issues: issues,
      last_sequence: (last && last.sequence) || 0,
      events_checked: length(events)
    }
  end

  defp chain_issues(events) do
    {issues, _expected, _prev} =
      Enum.reduce(events, {[], 1, Kernel.zero_hash()}, fn event, {issues, expected, prev} ->
        found =
          [
            event.sequence != expected &&
              %{type: :sequence_gap, sequence: event.sequence, expected: expected},
            event.prev_hash != prev && %{type: :prev_hash_mismatch, sequence: event.sequence},
            :crypto.hash(:sha256, event.canonical_bytes) != event.event_hash &&
              %{type: :event_hash_mismatch, sequence: event.sequence},
            row_mismatch?(event) && %{type: :row_mismatch, sequence: event.sequence}
          ]
          |> Enum.filter(& &1)

        {issues ++ found, event.sequence + 1, event.event_hash}
      end)

    issues
  end

  defp row_mismatch?(event) do
    case Canonical.encode(Kernel.canonical_map(event)) do
      {:ok, bytes} -> bytes != event.canonical_bytes
      {:error, _} -> true
    end
  end

  defp head_issues(head, nil) do
    if head.last_sequence == 0 and head.last_event_hash == Kernel.zero_hash(),
      do: [],
      else: [%{type: :head_mismatch, sequence: head.last_sequence}]
  end

  defp head_issues(head, last) do
    if head.last_sequence == last.sequence and head.last_event_hash == last.event_hash,
      do: [],
      else: [%{type: :head_mismatch, sequence: head.last_sequence, newest: last.sequence}]
  end

  defp payload_issues(tenant_id) do
    Payload
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.read!()
    |> Enum.reject(fn payload ->
      :crypto.hash(:sha256, payload.content) == payload.sha256 and
        byte_size(payload.content) == payload.byte_size
    end)
    |> Enum.map(&%{type: :payload_hash_mismatch, sha256: Base.encode16(&1.sha256, case: :lower)})
  end

  defp record_issues(events) do
    events
    |> Enum.filter(&is_binary(get_in(&1.payload, ["record_sha256"])))
    |> Enum.group_by(&{&1.subject_resource, &1.subject_id})
    |> Enum.flat_map(fn {{resource, subject_id}, subject_events} ->
      newest = Enum.max_by(subject_events, & &1.sequence)
      check_record(audited_module(resource), subject_id, newest)
    end)
  end

  defp check_record(nil, _subject_id, _event), do: []

  defp check_record(module, subject_id, event) do
    case Ash.get(module, subject_id, Kernel.opts(event.tenant_id)) do
      {:ok, record} ->
        if RecordHash.hex(record) == event.payload["record_sha256"],
          do: [],
          else: [record_issue(:record_hash_mismatch, module, subject_id, event)]

      {:error, _} ->
        [record_issue(:record_missing, module, subject_id, event)]
    end
  end

  defp record_issue(type, module, subject_id, event) do
    %{type: type, resource: inspect(module), subject_id: subject_id, sequence: event.sequence}
  end

  defp audited_module(name) when is_binary(name) do
    module = String.to_existing_atom("Elixir." <> name)

    if Code.ensure_loaded?(module) and function_exported?(module, :__sdr_audited__, 0),
      do: module
  rescue
    ArgumentError -> nil
  end

  defp audited_module(_name), do: nil
end
