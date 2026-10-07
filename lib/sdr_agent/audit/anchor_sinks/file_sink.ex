defmodule SdrAgent.Audit.AnchorSinks.FileSink do
  @moduledoc "Writes immutable signed statements to a local directory (test sink)."
  @behaviour SdrAgent.Audit.AnchorSink

  @impl true
  def publish(statement, opts) do
    directory = Keyword.fetch!(opts, :directory)
    number = Keyword.fetch!(opts, :anchor_number)
    path = Path.join(directory, "anchor-#{String.pad_leading(to_string(number), 12, "0")}.json")
    File.mkdir_p!(directory)

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = IO.binwrite(io, statement)
        File.close(io)

        :ok = result
        {:ok, %{status: :confirmed, path: path, sha256: :crypto.hash(:sha256, statement)}}

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, ^statement} ->
            {:ok, %{status: :confirmed, path: path, sha256: :crypto.hash(:sha256, statement)}}

          _ ->
            {:error, :already_exists}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
