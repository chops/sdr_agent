defmodule SdrAgent.Audit.ExportVerifier do
  @moduledoc "Offline verifier for signed S11 JSON export bundles."

  alias SdrAgent.Audit.Signing

  def verify(path, opts \\ []) do
    with {:ok, keys} <- trusted_keys(opts),
         {:ok, wrapper} <- File.read(path),
         {:ok, %{"payload" => payload64, "signature" => signature64}} <- Jason.decode(wrapper),
         {:ok, payload} <- Base.decode64(payload64),
         {:ok, signature} <- Base.decode64(signature64),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, trusted_key} <- lookup_key(keys, decoded["signing_key"]["key_id"]),
         true <- trusted_key_matches?(decoded["signing_key"], trusted_key),
         true <- Signing.verify(payload, signature, trusted_key.public_key),
         true <- valid_chain?(decoded["events"], decoded["chain_index"], decoded["scope"]),
         true <- valid_payloads?(decoded["payloads"] || []),
         {:ok, anchor_key} <- lookup_key(keys, decoded["anchor"]["key_id"]),
         true <- valid_anchor?(decoded["anchor"], decoded["events"], anchor_key.public_key),
         true <-
           valid_anchor_chain?(
             decoded["anchors"] || [decoded["anchor"]],
             decoded["anchor"],
             keys
           ),
         true <- anchor_head_matches_index?(decoded["anchor"], decoded["chain_index"]),
         revocation <- lifecycle_report(decoded, keys, opts) do
      {:ok,
       %{
         valid?: revocation.valid?,
         assurance_level:
           assurance(decoded["sink_receipts"] || [], decoded["anchor"], revocation, opts),
         issues: revocation.issues,
         events_checked: length(decoded["events"])
       }}
    else
      {:error, :trusted_key_required} = error -> error
      _ -> {:error, :invalid_bundle}
    end
  rescue
    _ -> {:error, :invalid_bundle}
  end

  defp trusted_keys(opts) do
    keys = Keyword.get(opts, :trusted_keys, List.wrap(Keyword.get(opts, :trusted_key)))

    if keys != [] and Enum.all?(keys, &valid_key?/1) and
         length(Enum.uniq_by(keys, & &1.key_id)) == length(keys) do
      {:ok, Map.new(keys, &{&1.key_id, &1})}
    else
      {:error, :trusted_key_required}
    end
  end

  defp valid_key?(%{key_id: id, public_key: public, status: status} = key)
       when is_binary(id) and byte_size(public) == 32 and status in [:active, :rotated, :revoked],
       do: status != :revoked or match?(%DateTime{}, key[:revoked_at])

  defp valid_key?(_), do: false

  defp lookup_key(keys, id), do: Map.fetch(keys, id)

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

  defp valid_anchor_chain?(anchors, current, keys) when is_list(anchors) do
    chain_valid? =
      anchors
      |> Enum.with_index()
      |> Enum.all?(fn {anchor, index} ->
        match?({:ok, _}, lookup_key(keys, anchor["key_id"])) and
          valid_anchor?(anchor, [], keys[anchor["key_id"]].public_key) and
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
    confirmed_git? =
      Enum.any?(receipts, &confirmed_receipt?(&1, "git", anchor, opts[:git_verifier]))

    confirmed_ots? =
      Enum.any?(receipts, &confirmed_receipt?(&1, "ots", anchor, opts[:ots_verifier]))

    cond do
      revocation.assurance == :chain_verified -> :chain_verified
      confirmed_ots? -> :ots_anchored
      confirmed_git? -> :git_anchored
      true -> :signed
    end
  end

  defp confirmed_receipt?(receipt, sink, anchor, verifier) do
    receipt["anchor_id"] == anchor["id"] and receipt["sink"] == sink and
      receipt["status"] == "confirmed" and
      verify_receipt(receipt, anchor["anchor_hash"], verifier)
  end

  defp verify_receipt(_receipt, _anchor_hash, nil), do: false

  defp verify_receipt(receipt, anchor_hash, verifier),
    do: verified?(verifier.(receipt["receipt"], anchor_hash))

  defp verified?(true), do: true
  defp verified?({:ok, %{verified: true}}), do: true
  defp verified?(_), do: false

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

  # Neither inserted_at nor a Git author's commit date is independent time
  # evidence: a stolen signing key can backdate both. Only a verified Bitcoin
  # attestation binding this exact statement digest can establish an upper bound.
  defp lifecycle_report(decoded, keys, opts) do
    receipts = decoded["sink_receipts"] || []

    issues =
      Enum.flat_map(decoded["anchors"] || [decoded["anchor"]], fn anchor ->
        revocation_issues(anchor, keys[anchor["key_id"]], receipts, opts)
      end)
      |> Enum.uniq()

    %{
      valid?: :revocation_time_unproven not in issues,
      assurance: if(issues == [], do: :signed, else: :chain_verified),
      issues: issues
    }
  end

  defp revocation_issues(anchor, %{status: :revoked} = key, receipts, opts) do
    if independently_predates_revocation?(anchor, receipts, key.revoked_at, opts),
      do: [:signing_key_revoked_after_signing],
      else: [:revocation_time_unproven]
  end

  defp revocation_issues(_anchor, _key, _receipts, _opts), do: []

  defp independently_predates_revocation?(anchor, receipts, revoked_at, opts) do
    verifier = Keyword.get(opts, :ots_verifier)

    is_function(verifier, 2) and
      Enum.any?(receipts, &predates_revocation?(&1, anchor, revoked_at, verifier))
  end

  defp predates_revocation?(receipt, anchor, revoked_at, verifier) do
    with true <- receipt["anchor_id"] == anchor["id"],
         true <- receipt["sink"] == "ots" and receipt["status"] == "confirmed",
         {:ok, %{verified: true, timestamp: %DateTime{} = timestamp}} <-
           verifier.(receipt["receipt"], anchor["anchor_hash"]) do
      DateTime.before?(timestamp, revoked_at)
    else
      _ -> false
    end
  end
end
