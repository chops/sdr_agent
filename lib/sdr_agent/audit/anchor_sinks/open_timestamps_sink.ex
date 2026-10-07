defmodule SdrAgent.Audit.AnchorSinks.OpenTimestampsSink do
  @moduledoc "Submits only anchor hashes to OpenTimestamps calendars."
  @behaviour SdrAgent.Audit.AnchorSink

  defmodule Calendar do
    @moduledoc false
    @calendar "https://a.pool.opentimestamps.org/digest"

    def submit(hash, opts) do
      url = Keyword.get(opts, :url, @calendar)

      case Req.post(url, body: hash, headers: [{"content-type", "application/octet-stream"}]) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:calendar_http, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    def upgrade(proof, _hash, _opts) do
      with_proof(proof, ["upgrade"], &verify_upgraded/1)
    end

    defp verify_upgraded(path) do
      case System.cmd("ots", ["verify", path], stderr_to_stdout: true) do
        {_output, 0} ->
          with {:ok, upgraded} <- File.read(path),
               do: {:ok, %{proof: upgraded, bitcoin_attested: true}}

        {_output, status} ->
          {:error, {:ots_verify_exit, status}}
      end
    end

    def verify(proof, _hash, _opts) do
      with_proof(
        proof,
        ["verify"],
        fn _path -> {:ok, %{verified: true}} end
      )
    end

    defp with_proof(proof, args, on_success) do
      path = Path.join(System.tmp_dir!(), "sdr-ots-#{System.unique_integer([:positive])}.ots")

      try do
        File.write!(path, proof, [:binary, :exclusive])

        case System.cmd("ots", args ++ [path], stderr_to_stdout: true) do
          {_output, 0} -> on_success.(path)
          {_output, status} -> {:error, {:ots_exit, status}}
        end
      rescue
        error in ErlangError -> {:error, {:ots_unavailable, error.original}}
      after
        File.rm(path)
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
