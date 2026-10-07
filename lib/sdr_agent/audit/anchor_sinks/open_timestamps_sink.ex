defmodule SdrAgent.Audit.AnchorSinks.OpenTimestampsSink do
  @moduledoc "Submits only anchor hashes to OpenTimestamps calendars."
  @behaviour SdrAgent.Audit.AnchorSink

  defmodule Calendar do
    @moduledoc false
    @calendar "https://a.pool.opentimestamps.org/digest"
    @client_version "0.7.2"
    # DetachedTimestampFile v1 + OpSHA256 (upstream serialization format).
    @header <<0, "OpenTimestamps", 0, 0, "Proof", 0, 0xBF, 0x89, 0xE2, 0xE8, 0x84, 0xE8, 0x92,
              0x94, 1, 8>>

    def submit(hash, opts) do
      url = Keyword.get(opts, :url, @calendar)
      request = Keyword.get(opts, :request, &Req.post/2)

      with :ok <- check_version(opts) do
        submit_response(
          request.(url, body: hash, headers: [{"content-type", "application/octet-stream"}]),
          hash
        )
      end
    end

    defp submit_response(response, hash) do
      case response do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
          {:ok, @header <> hash <> body}

        {:ok, %{status: status}} ->
          {:error, {:calendar_http, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def upgrade(proof, hash, opts) do
      with :ok <- bound_to_hash(proof, hash), :ok <- check_version(opts) do
        with_proof(proof, &upgrade_path(&1, hash, opts))
      end
    end

    defp upgrade_path(path, hash, opts) do
      with {_output, 0} <- command(["upgrade", path], opts),
           {:ok, upgraded} <- File.read(path),
           :ok <- bound_to_hash(upgraded, hash),
           {:ok, attestation} <- verify_path(path, hash, opts) do
        {:ok, Map.merge(attestation, %{proof: upgraded, bitcoin_attested: true})}
      else
        {output, status} when is_integer(status) -> upgrade_error(output, status)
        error -> error
      end
    end

    defp upgrade_error(output, 1) do
      transport_warning? =
        Regex.match?(~r/^(Calendar |Ignoring attestation from calendar )/m, output)

      if String.contains?(output, "Failed! Timestamp not complete") and not transport_warning?,
        do: {:error, :ots_pending},
        else: {:error, {:ots_upgrade_exit, 1}}
    end

    defp upgrade_error(_output, status), do: {:error, {:ots_upgrade_exit, status}}

    def verify(proof, hash, opts) do
      with :ok <- bound_to_hash(proof, hash), :ok <- check_version(opts) do
        with_proof(proof, &verify_path(&1, hash, opts))
      end
    end

    defp check_version(opts) do
      case command(["--version"], opts) do
        {output, 0} ->
          actual =
            output
            |> String.split("\n", trim: true)
            |> List.last()
            |> to_string()
            |> String.trim()

          if actual == "v" <> @client_version,
            do: :ok,
            else: {:error, {:ots_client_version_mismatch, @client_version, version_label(actual)}}

        {_output, 127} ->
          {:error, :audit_tools_nix_missing}

        {_output, status} ->
          {:error, {:ots_client_version_exit, status}}
      end
    rescue
      error in ErlangError ->
        if error.original == :enoent,
          do: {:error, :audit_tools_wrapper_missing},
          else: {:error, {:ots_client_unavailable, error.original}}
    end

    defp version_label(actual) do
      if Regex.match?(~r/\Av\d+\.\d+\.\d+\z/, actual),
        do: actual,
        else: "unrecognized version output"
    end

    defp bound_to_hash(proof, hash) when byte_size(hash) == 32 do
      prefix = @header <> hash
      if String.starts_with?(proof, prefix), do: :ok, else: {:error, :ots_digest_mismatch}
    end

    defp verify_path(path, hash, opts) do
      # The upstream CLI spells its digest option -d (not --digest).
      case command(["verify", "-d", Base.encode16(hash, case: :lower), path], opts) do
        {output, 0} -> attestation(output)
        {_output, status} -> {:error, {:ots_verify_exit, status}}
      end
    end

    defp attestation(output) do
      # ots reports a day, not the full block timestamp. Use the END of that
      # UTC day as a conservative upper bound for the revocation comparison.
      with [day] <-
             Regex.run(
               ~r/Success! Bitcoin block \d+ attests existence as of (\d{4}-\d{2}-\d{2}) UTC/,
               output,
               capture: :all_but_first
             ),
           {:ok, date} <- Date.from_iso8601(day),
           {:ok, upper_bound} <- DateTime.new(Date.add(date, 1), ~T[00:00:00], "Etc/UTC") do
        {:ok, %{verified: true, timestamp: upper_bound}}
      else
        _ -> {:error, :bitcoin_attestation_missing}
      end
    end

    defp command(args, opts) do
      runner = Keyword.get(opts, :command, &System.cmd/3)

      wrapper =
        Keyword.get(
          opts,
          :wrapper,
          Application.get_env(
            :sdr_agent,
            :audit_tools_wrapper,
            Path.expand("bin/with-audit-tools")
          )
        )

      runner.(wrapper, ["ots" | args],
        stderr_to_stdout: true,
        env: [{"TZ", "UTC"}, {"SDR_AUDIT_ANCHOR_PRIVATE_KEY", nil}]
      )
    end

    defp with_proof(proof, on_success) do
      directory = Path.join(System.tmp_dir!(), "sdr-ots-#{System.unique_integer([:positive])}")
      path = Path.join(directory, "proof.ots")

      try do
        File.mkdir!(directory)
        File.write!(path, proof, [:binary, :exclusive])
        on_success.(path)
      rescue
        error in ErlangError -> {:error, {:ots_unavailable, error.original}}
      after
        File.rm_rf(directory)
      end
    end
  end

  @impl true
  def publish(hash, opts) when byte_size(hash) == 32 do
    calendar = Keyword.get(opts, :calendar, Calendar)

    with {:ok, proof} <- calendar.submit(hash, Keyword.get(opts, :calendar_options, [])) do
      {:ok, %{status: :pending, proof: proof, proof_sha256: :crypto.hash(:sha256, proof)}}
    end
  end

  def upgrade(proof, hash, opts) do
    calendar = Keyword.get(opts, :calendar, Calendar)

    with {:ok, %{proof: upgraded, bitcoin_attested: true}} <-
           calendar.upgrade(proof, hash, Keyword.get(opts, :calendar_options, [])) do
      {:ok,
       %{
         status: :confirmed,
         proof: upgraded,
         proof_sha256: :crypto.hash(:sha256, upgraded),
         anchor_hash: hash,
         bitcoin_attested: true
       }}
    end
  end

  def verify(proof, hash, opts) do
    Keyword.get(opts, :calendar, Calendar).verify(
      proof,
      hash,
      Keyword.get(opts, :calendar_options, [])
    )
  end
end
