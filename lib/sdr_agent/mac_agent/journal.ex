defmodule SdrAgent.MacAgent.Journal do
  @moduledoc """
  IDs-only, fail-closed local launch journal for the Mac worker.

  Exclusive creation of a per-call launching marker wins before any child
  starts. Files and their directory are synced before returning. A launching
  marker is never replayed, even after an uncertain result or restart. Only
  a still-requested nonce may retrieve the same remote claim. Missing local
  state creates a fresh nonce, leaving any old remote claim to expire.

  The directory must be operator-owned and private; do not share it between
  different worker enrollments. No prompts, transcripts or tokens are stored.
  """

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @nonce ~r/\A[0-9a-f]{32}\z/

  @doc "Create a new private directory, or refuse an unsafe existing one."
  def prepare(root) when is_binary(root) do
    if Path.type(root) == :absolute and Path.expand(root) == root do
      ensure_directory(root)
    else
      {:error, :unsafe_journal}
    end
  end

  def prepare(_), do: {:error, :unsafe_journal}

  defp ensure_directory(root) do
    case File.mkdir(root) do
      :ok ->
        with :ok <- File.chmod(root, 0o700), do: safe_directory(root)

      {:error, :eexist} ->
        safe_directory(root)

      _ ->
        {:error, :unsafe_journal}
    end
  end

  @doc "Return the current requested nonce, or durably create a fresh one."
  def next_nonce(root) do
    with :ok <- safe_directory(root) do
      path = Path.join(root, "current.requested")

      case read_private(path) do
        {:ok, nonce} -> requested_nonce(root, path, nonce)
        {:error, :enoent} -> create_nonce(root, path)
        _ -> {:error, :unsafe_journal}
      end
    end
  end

  @doc "Durably retire a claim nonce, including an empty/spent claim response."
  def close_nonce(root, nonce) do
    with true <- valid_nonce?(nonce),
         :ok <- safe_directory(root) do
      case exclusive(root, nonce <> ".closed", nonce) do
        :ok -> :ok
        {:error, :eexist} -> sync_existing(root, nonce <> ".closed")
        _ -> {:error, :unsafe_journal}
      end
    else
      _ -> {:error, :unsafe_journal}
    end
  end

  @doc "Exclusively record launch admission before the child is opened."
  def launch_once(root, call_id, nonce) do
    with true <- valid_identity?(call_id, nonce),
         :ok <- safe_directory(root) do
      record_launch(root, call_id, nonce)
    else
      false -> {:error, :invalid_identity}
      error -> error
    end
  end

  defp record_launch(root, call_id, nonce) do
    case exclusive(root, call_id <> ".launching", call_id <> "\n" <> nonce) do
      :ok ->
        close_nonce(root, nonce)

      {:error, :eexist} ->
        with :ok <- close_nonce(root, nonce), do: existing_launch(root, call_id)

      _ ->
        {:error, :unsafe_journal}
    end
  end

  @doc "Record delivery acknowledgement without persisting result content."
  def reported(root, call_id, nonce) do
    with true <- valid_identity?(call_id, nonce),
         :ok <- safe_directory(root) do
      body = call_id <> "\n" <> nonce

      case exclusive(root, call_id <> ".reported", body) do
        :ok -> :ok
        {:error, :eexist} -> validate_existing(root, call_id <> ".reported", body)
        _ -> {:error, :unsafe_journal}
      end
    else
      false -> {:error, :invalid_identity}
      error -> error
    end
  end

  defp requested_nonce(root, path, nonce) do
    if valid_nonce?(nonce) do
      read_requested(root, path, nonce)
    else
      {:error, :unsafe_journal}
    end
  end

  defp read_requested(root, path, nonce) do
    case read_private(Path.join(root, nonce <> ".closed")) do
      {:error, :enoent} ->
        {:ok, nonce}

      {:ok, ^nonce} ->
        with :ok <- File.rm(path), :ok <- sync_directory(root), do: next_nonce(root)

      _ ->
        {:error, :unsafe_journal}
    end
  end

  defp create_nonce(root, _path) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    case exclusive(root, "current.requested", nonce) do
      :ok -> {:ok, nonce}
      {:error, :eexist} -> next_nonce(root)
      _ -> {:error, :unsafe_journal}
    end
  end

  defp existing_launch(root, call_id) do
    # Even a marker whose writer has not finished is spent. Never inspect
    # partial contents to decide whether a second launch may start.
    case File.lstat(Path.join(root, call_id <> ".launching")) do
      {:ok, %{type: :regular}} -> {:error, :already_launched}
      _ -> {:error, :unsafe_journal}
    end
  end

  defp sync_existing(root, name) do
    path = Path.join(root, name)

    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:raw, :read]) do
      try do
        with :ok <- :file.sync(io), do: sync_directory(root)
      after
        :file.close(io)
      end
    else
      _ -> {:error, :unsafe_journal}
    end
  end

  defp validate_existing(root, name, body) do
    case read_private(Path.join(root, name)) do
      {:ok, ^body} -> :ok
      _ -> {:error, :unsafe_journal}
    end
  end

  defp exclusive(root, name, body) do
    path = Path.join(root, name)

    case :file.open(String.to_charlist(path), [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        result =
          try do
            with :ok <- File.chmod(path, 0o600),
                 :ok <- :file.write(io, body),
                 do: :file.sync(io)
          after
            :file.close(io)
          end

        with :ok <- result, do: sync_directory(root)

      error ->
        error
    end
  end

  defp read_private(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and Bitwise.band(stat.mode, 0o777) == 0o600,
         true <- stat.size <= 256 do
      File.read(path)
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :unsafe_journal}
    end
  end

  defp safe_directory(root) do
    with {:ok, stat} <- File.lstat(root),
         true <- stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :unsafe_journal}
    end
  end

  defp sync_directory(root) do
    case :file.open(String.to_charlist(root), [:raw, :read, :directory]) do
      {:ok, io} ->
        try do
          :file.sync(io)
        after
          :file.close(io)
        end

      _ ->
        {:error, :unsafe_journal}
    end
  end

  defp valid_identity?(id, nonce),
    do: is_binary(id) and Regex.match?(@uuid, id) and valid_nonce?(nonce)

  defp valid_nonce?(nonce), do: is_binary(nonce) and Regex.match?(@nonce, nonce)
end
