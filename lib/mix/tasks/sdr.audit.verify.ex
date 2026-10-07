defmodule Mix.Tasks.Sdr.Audit.Verify do
  @moduledoc "Verifies a signed S11 audit export bundle without requiring application secrets."
  @shortdoc "Verify a signed SDR audit export bundle"
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [public_key: :string, key_id: :string, key_set: :string])

    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")
    [path] = args
    {:ok, trusted_keys} = load_keys(opts)

    case SdrAgent.Audit.ExportVerifier.verify(path,
           trusted_keys: trusted_keys,
           ots_verifier: &verify_ots/2
         ) do
      {:ok, report} ->
        report.valid? || Mix.raise("verification uncertain: #{inspect(report.issues)}")

        Mix.shell().info(
          "valid assurance=#{report.assurance_level} events=#{report.events_checked}"
        )

      {:error, reason} ->
        Mix.raise("verification failed: #{inspect(reason)}")
    end
  rescue
    MatchError ->
      Mix.raise(
        "usage: mix sdr.audit.verify [--key-set MANIFEST | --public-key PATH --key-id ID] PATH"
      )
  end

  defp load_keys(opts) do
    case Keyword.fetch(opts, :public_key) do
      {:ok, path} ->
        with {:ok, key} <- SdrAgent.Audit.TrustedKey.load(path, opts[:key_id]), do: {:ok, [key]}

      :error ->
        SdrAgent.Audit.TrustedKey.load_set(
          Keyword.get(opts, :key_set, "docs/audit/trusted-keys.json")
        )
    end
  end

  defp verify_ots(receipt, anchor_hash) do
    with proof when is_binary(proof) <- receipt["proof"],
         {:ok, proof} <- Base.decode64(proof),
         {:ok, hash} <- Base.decode16(anchor_hash, case: :mixed),
         {:ok, attestation} <-
           SdrAgent.Audit.AnchorSinks.OpenTimestampsSink.verify(proof, hash, []) do
      {:ok, attestation}
    else
      _ -> false
    end
  end
end
