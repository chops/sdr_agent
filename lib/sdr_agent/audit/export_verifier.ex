defmodule SdrAgent.Audit.ExportVerifier do
  @moduledoc "Offline verifier for signed S11 JSON export bundles."

  alias SdrAgent.Audit.Signing

  def verify(path, opts \\ []) do
    with {:ok, wrapper} <- File.read(path),
         {:ok, %{"payload" => payload64, "signature" => signature64}} <- Jason.decode(wrapper),
         {:ok, payload} <- Base.decode64(payload64),
         {:ok, signature} <- Base.decode64(signature64),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, public_key} <- Base.decode64(get_in(decoded, ["signing_key", "public_key"])),
         true <- Signing.verify(payload, signature, public_key),
         true <- valid_chain?(decoded["events"]),
         true <- valid_anchor?(decoded["anchor"], decoded["events"], public_key) do
      {:ok,
       %{
         valid?: true,
         assurance_level: assurance(decoded["sink_receipts"] || [], opts),
         events_checked: length(decoded["events"])
       }}
    else
      _ -> {:error, :invalid_bundle}
    end
  end

  defp valid_anchor?(anchor, events, public_key) do
    with {:ok, statement} <- Base.decode64(anchor["statement"]),
         {:ok, signature} <- Base.decode64(anchor["signature"]),
         {:ok, anchor_hash} <- Base.decode16(anchor["anchor_hash"], case: :mixed),
         event when not is_nil(event) <-
           Enum.find(events, &(&1["sequence"] == anchor["to_sequence"])) do
      :crypto.hash(:sha256, statement) == anchor_hash and
        Signing.verify(statement, signature, public_key) and
        anchor["head_event_hash"] == event["event_hash"]
    else
      _ -> false
    end
  end

  defp assurance(receipts, opts) do
    confirmed_git? = Enum.any?(receipts, &(&1["sink"] == "git" and &1["status"] == "confirmed"))

    confirmed_ots? =
      Enum.any?(receipts, fn receipt ->
        receipt["sink"] == "ots" and receipt["status"] == "confirmed" and
          verify_ots(receipt, opts)
      end)

    cond do
      confirmed_ots? -> :ots_anchored
      confirmed_git? -> :git_anchored
      true -> :signed
    end
  end

  defp verify_ots(receipt, opts) do
    case Keyword.get(opts, :ots_verifier) do
      nil -> false
      verifier -> verifier.(receipt["receipt"])
    end
  end

  defp valid_chain?([]), do: false

  defp valid_chain?(events) do
    Enum.with_index(events)
    |> Enum.all?(fn {event, index} ->
      with {:ok, canonical} <- Base.decode64(event["canonical_bytes"]),
           {:ok, event_hash} <- Base.decode16(event["event_hash"], case: :mixed) do
        :crypto.hash(:sha256, canonical) == event_hash and
          (index == 0 or event["prev_hash"] == Enum.at(events, index - 1)["event_hash"])
      else
        _ -> false
      end
    end)
  end
end
