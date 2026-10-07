defmodule SdrAgent.Audit.ExportVerifier do
  @moduledoc "Offline verifier for signed S11 JSON export bundles."

  alias SdrAgent.Audit.Signing

  def verify(path, opts \\ []) do
    with {:ok, trusted_key} <- trusted_key(opts),
         {:ok, wrapper} <- File.read(path),
         {:ok, %{"payload" => payload64, "signature" => signature64}} <- Jason.decode(wrapper),
         {:ok, payload} <- Base.decode64(payload64),
         {:ok, signature} <- Base.decode64(signature64),
         {:ok, decoded} <- Jason.decode(payload),
         true <- trusted_key_matches?(decoded["signing_key"], trusted_key),
         true <- Signing.verify(payload, signature, trusted_key.public_key),
         true <- valid_chain?(decoded["events"], decoded["chain_index"], decoded["scope"]),
         true <- valid_payloads?(decoded["payloads"] || []),
         true <- valid_anchor?(decoded["anchor"], decoded["events"], trusted_key.public_key),
         true <-
           valid_anchor_chain?(
             decoded["anchors"] || [decoded["anchor"]],
             decoded["anchor"],
             trusted_key.public_key
           ),
         true <- anchor_head_matches_index?(decoded["anchor"], decoded["chain_index"]),
         {:ok, revocation} <- valid_at_signing?(decoded["anchor"], trusted_key) do
      {:ok,
       %{
         valid?: true,
         assurance_level:
           assurance(decoded["sink_receipts"] || [], decoded["anchor"], revocation, opts),
         issues: revocation.issues,
         events_checked: length(decoded["events"])
       }}
    else
      {:error, :trusted_key_required} = error -> error
      _ -> {:error, :invalid_bundle}
    end
  end

  defp trusted_key(opts) do
    case Keyword.fetch(opts, :trusted_key) do
      {:ok, %{key_id: key_id, public_key: public_key} = key}
      when is_binary(key_id) and byte_size(public_key) == 32 ->
        {:ok, Map.merge(%{status: :active, revoked_at: nil}, key)}

      _ ->
        {:error, :trusted_key_required}
    end
  end

  defp trusted_key_matches?(embedded, trusted) do
    with %{"key_id" => key_id, "public_key" => encoded} <- embedded,
         {:ok, public_key} <- Base.decode64(encoded) do
      key_id == trusted.key_id and public_key == trusted.public_key
    else
      _ -> false
    end
  end

  defp valid_anchor?(anchor, events, public_key) do
    with {:ok, statement} <- Base.decode64(anchor["statement"]),
         {:ok, signature} <- Base.decode64(anchor["signature"]),
         {:ok, anchor_hash} <- Base.decode16(anchor["anchor_hash"], case: :mixed),
         {:ok, decoded_statement} <- Jason.decode(statement) do
      :crypto.hash(:sha256, statement) == anchor_hash and
        Signing.verify(statement, signature, public_key) and
        statement_matches_anchor?(decoded_statement, anchor) and
        head_matches_when_present?(anchor, events)
    else
      _ -> false
    end
  end

  defp statement_matches_anchor?(statement, anchor) do
    [
      statement["tenant_id"] == anchor["tenant_id"],
      statement["anchor_number"] == anchor["anchor_number"],
      statement["event_range"] == %{
        "from" => anchor["from_sequence"],
        "to" => anchor["to_sequence"]
      },
      statement["head_event_hash"] == anchor["head_event_hash"],
      statement["prior_anchor_hash"] == anchor["prior_anchor_hash"],
      statement["canonicalization_version"] == anchor["canonicalization_version"],
      statement["sdr_agent_git_sha"] == anchor["sdr_agent_git_sha"],
      statement["trigger"] == anchor["trigger"],
      statement["key_id"] == anchor["key_id"],
      statement["key_status_at_signing"] == anchor["key_status_at_signing"]
    ]
    |> Enum.all?()
  end

  defp head_matches_when_present?(anchor, events) do
    case Enum.find(events, &(&1["sequence"] == anchor["to_sequence"])) do
      nil -> true
      event -> anchor["head_event_hash"] == event["event_hash"]
    end
  end

  defp valid_anchor_chain?(anchors, current, public_key) when is_list(anchors) do
    chain_valid? =
      anchors
      |> Enum.with_index()
      |> Enum.all?(fn {anchor, index} ->
        valid_anchor?(anchor, [], public_key) and
          if index == 0 do
            anchor["anchor_number"] == 1 and is_nil(anchor["prior_anchor_hash"])
          else
            prior = Enum.at(anchors, index - 1)

            anchor["anchor_number"] == prior["anchor_number"] + 1 and
              anchor["from_sequence"] == prior["to_sequence"] + 1 and
              anchor["prior_anchor_hash"] == prior["anchor_hash"]
          end
      end)

    anchors != [] and List.last(anchors)["anchor_hash"] == current["anchor_hash"] and chain_valid?
  end

  defp valid_anchor_chain?(_, _, _), do: false

  defp anchor_head_matches_index?(anchor, chain_index) do
    case Enum.find(chain_index, &(&1["sequence"] == anchor["to_sequence"])) do
      nil -> false
      entry -> entry["event_hash"] == anchor["head_event_hash"]
    end
  end

  defp assurance(receipts, anchor, revocation, opts) do
    anchor_hash = anchor["anchor_hash"]

    confirmed_git? =
      Enum.any?(receipts, fn receipt ->
        receipt["sink"] == "git" and receipt["status"] == "confirmed" and
          verify_receipt(receipt, anchor_hash, Keyword.get(opts, :git_verifier))
      end)

    confirmed_ots? =
      Enum.any?(receipts, fn receipt ->
        receipt["sink"] == "ots" and receipt["status"] == "confirmed" and
          verify_receipt(receipt, anchor_hash, Keyword.get(opts, :ots_verifier))
      end)

    cond do
      revocation.assurance == :chain_verified -> :chain_verified
      confirmed_ots? -> :ots_anchored
      confirmed_git? -> :git_anchored
      true -> :signed
    end
  end

  defp verify_receipt(_receipt, _anchor_hash, nil), do: false

  defp verify_receipt(receipt, anchor_hash, verifier),
    do: verifier.(receipt["receipt"], anchor_hash)

  defp valid_chain?([], _chain_index, _scope), do: false

  defp valid_chain?(events, chain_index, scope) do
    valid_events? =
      Enum.with_index(events)
      |> Enum.all?(&valid_event?(&1, events))

    valid_events? and valid_chain_index?(chain_index) and
      selected_events_in_index?(events, chain_index) and valid_scope?(events, scope)
  end

  defp valid_event?({event, index}, events) do
    with {:ok, canonical} <- Base.decode64(event["canonical_bytes"]),
         {:ok, event_hash} <- Base.decode16(event["event_hash"], case: :mixed),
         {:ok, prev_hash} <- Base.decode16(event["prev_hash"], case: :mixed),
         {:ok, canonical_event} <- Jason.decode(canonical) do
      :crypto.hash(:sha256, canonical) == event_hash and
        canonical_event["sequence"] == event["sequence"] and
        canonical_event["prev_hash"] == event["prev_hash"] and
        (event["sequence"] != 1 or prev_hash == <<0::256>>) and
        (index == 0 or valid_predecessor?(Enum.at(events, index - 1), event))
    else
      _ -> false
    end
  end

  defp valid_chain_index?([first | rest]) do
    with {:ok, zero} <- Base.decode16(first["prev_hash"], case: :mixed),
         true <- first["sequence"] == 1 and zero == <<0::256>> do
      Enum.reduce_while(rest, first, &continue_chain/2) != false
    else
      _ -> false
    end
  end

  defp valid_chain_index?(_), do: false

  defp continue_chain(entry, previous) do
    if entry["sequence"] == previous["sequence"] + 1 and
         entry["prev_hash"] == previous["event_hash"] do
      {:cont, entry}
    else
      {:halt, false}
    end
  end

  defp selected_events_in_index?(events, chain_index) do
    index = Map.new(chain_index, &{&1["sequence"], &1})

    Enum.all?(events, fn event ->
      case Map.get(index, event["sequence"]) do
        nil ->
          false

        entry ->
          entry["event_hash"] == event["event_hash"] and
            entry["prev_hash"] == event["prev_hash"]
      end
    end)
  end

  defp valid_predecessor?(previous, event) do
    event["sequence"] > previous["sequence"] and
      (event["sequence"] != previous["sequence"] + 1 or
         event["prev_hash"] == previous["event_hash"])
  end

  defp valid_scope?(events, %{"scope" => "sequence_range", "scope_ref" => ref}) do
    with [from, to] <- String.split(ref, ":", parts: 2),
         {from, ""} <- Integer.parse(from),
         expected_to <-
           if(to == "latest", do: List.last(events)["sequence"], else: String.to_integer(to)) do
      Enum.map(events, & &1["sequence"]) == Enum.to_list(from..expected_to)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_scope?(events, %{"scope" => scope, "scope_ref" => ref})
       when scope in ["lead", "draft"] do
    Enum.all?(events, fn event ->
      {:ok, canonical} = Base.decode64(event["canonical_bytes"])
      decoded = Jason.decode!(canonical)

      decoded["subject_id"] == ref and
        String.ends_with?(String.downcase(decoded["subject_resource"] || ""), scope)
    end)
  rescue
    _ -> false
  end

  defp valid_scope?(events, %{"scope" => "agent_run", "scope_ref" => ref}) do
    Enum.all?(events, fn event ->
      {:ok, canonical} = Base.decode64(event["canonical_bytes"])
      Jason.decode!(canonical)["agent_run_id"] == ref
    end)
  rescue
    _ -> false
  end

  defp valid_scope?(_, _), do: false

  defp valid_payloads?(payloads) do
    Enum.all?(payloads, fn payload ->
      with {:ok, content} <- Base.decode64(payload["content"]),
           {:ok, expected} <- Base.decode16(payload["sha256"], case: :mixed) do
        :crypto.hash(:sha256, content) == expected
      else
        _ -> false
      end
    end)
  end

  defp valid_at_signing?(_anchor, %{status: status}) when status in [:active, :rotated],
    do: {:ok, %{assurance: :signed, issues: []}}

  defp valid_at_signing?(anchor, %{status: :revoked, revoked_at: %DateTime{} = revoked_at}) do
    with {:ok, inserted_at, 0} <- DateTime.from_iso8601(anchor["inserted_at"]),
         true <- DateTime.before?(inserted_at, revoked_at) do
      {:ok, %{assurance: :chain_verified, issues: [:signing_key_revoked_after_signing]}}
    else
      _ -> {:error, :signature_at_or_after_key_revocation}
    end
  end

  defp valid_at_signing?(_anchor, _trusted_key), do: {:error, :invalid_revocation_metadata}
end
