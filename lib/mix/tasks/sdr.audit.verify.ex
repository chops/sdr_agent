defmodule Mix.Tasks.Sdr.Audit.Verify do
  @moduledoc "Verifies a signed S11 audit export bundle without requiring application secrets."
  @shortdoc "Verify a signed SDR audit export bundle"
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [public_key: :string, key_id: :string])

    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")
    [path] = args
    key_path = Keyword.get(opts, :public_key, "docs/audit/anchor-signing-key.pub")
    expected_id = Keyword.get(opts, :key_id, System.get_env("SDR_AUDIT_ANCHOR_KEY_ID"))
    {:ok, trusted_key} = SdrAgent.Audit.TrustedKey.load(key_path, expected_id)

    case SdrAgent.Audit.ExportVerifier.verify(path,
           trusted_key: trusted_key,
           ots_verifier: &verify_ots/2
         ) do
      {:ok, report} ->
        Mix.shell().info(
          "valid assurance=#{report.assurance_level} events=#{report.events_checked}"
        )

      {:error, reason} ->
        Mix.raise("verification failed: #{inspect(reason)}")
    end
  rescue
    MatchError ->
      Mix.raise("usage: mix sdr.audit.verify [--public-key PATH] [--key-id ID] PATH")
  end

  defp verify_ots(receipt, anchor_hash) do
    with proof when is_binary(proof) <- receipt["proof"],
         {:ok, proof} <- Base.decode64(proof),
         {:ok, hash} <- Base.decode16(anchor_hash, case: :mixed),
         {:ok, _attestation} <-
           SdrAgent.Audit.AnchorSinks.OpenTimestampsSink.verify(proof, hash, []) do
      true
    else
      _ -> false
    end
  end
end
