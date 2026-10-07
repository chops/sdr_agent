defmodule SdrAgent.Agents.Witness.Store do
  @moduledoc """
  Bounded, read-only reader of the S12a `llm-otel-proxy` wire-witness store
  (protocol v1; S12 C7, ADR-0005 S12 amendment).

  Layout beneath the configured root (the proxy's blob directory):

      witnesses/<invocation uuid>/<record uuid>.started.json   start marker
      witnesses/<invocation uuid>/<record uuid>.json           terminal record
      witness/sha256/<aa>/<sha256>.json                        raw body blob

  Every path is derived only from a validated lowercase invocation UUID,
  validated record names and validated digests. Each component below the
  root is `lstat`ed and must be a real directory or regular file — no
  symlink is ever followed. Entry counts, record and blob sizes are capped;
  records must match the strict schema-v1 key set and name their own path;
  blob bytes are re-hashed. The legacy preview namespace `<root>/sha256` is
  never read. Nothing is written, and no request header exists in the store.

  Trust boundary: the store is the owner's proxy directory (0700/0600,
  atomically published by hard link). Group- or world-writable entries are
  refused. Reads are bounded (at most cap + 1 bytes from the opened file)
  and the path is re-`lstat`ed afterwards: the same device/inode/size/mtime
  must still be there. Erlang offers no `O_NOFOLLOW`, so a same-user process
  that swaps a component between the checks and the open is outside what
  this reader can exclude (such a process can equally alter the proxy that
  writes the store); a directory listing is read whole before its entry cap
  applies.
  """

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @entry ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})(\.started)?\.json\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @max_entries 64
  @max_record_bytes 65_536
  @max_blob_bytes 8_388_608

  @required ~w(schema_version record_id invocation_id proxy_version route method traceparent
               started_at outcome request_bytes_seen response_bytes_seen
               request_capture_complete response_capture_complete stream_complete)
  @optional ~w(completed_at http_status request_sha256 response_sha256 request_capture_sha256
               response_capture_sha256 response_content_encoding)
  @routes ["/anthropic/v1/messages", "/anthropic/v1/messages/count_tokens", "/anthropic/unknown"]

  @type exchange :: %{record_id: String.t(), record: map(), state: :terminal | :open}

  @doc "Maximum raw blob size read (bytes)."
  def max_blob_bytes, do: @max_blob_bytes

  @doc """
  The exchanges recorded for `invocation_id`: `{:ok, %{exchanges: [exchange],
  anomalies: []}}`, or `{:error, reason}` with `:store_unconfigured`,
  `:invalid_invocation_id`, `:witness_missing`, `:unsafe_path`,
  `:too_many_entries`, `:record_invalid` or `:record_too_large`.
  A start marker without a terminal record is an `:open` exchange.
  """
  def inventory(nil, _invocation_id), do: {:error, :store_unconfigured}

  def inventory(root, invocation_id) when is_binary(root) do
    with :ok <- valid_uuid(invocation_id),
         {:ok, dir} <- safe_dir(root, ["witnesses", invocation_id]),
         {:ok, names} <- list(dir),
         {:ok, entries} <- classify(names) do
      read_exchanges(dir, invocation_id, entries)
    end
  end

  @doc """
  The raw bytes of blob `digest` (lowercase hex), verified against the
  digest. Errors: `:invalid_digest`, `:blob_missing`, `:unsafe_path`,
  `:blob_too_large`, `:blob_corrupt`, `:store_unconfigured`.
  """
  def blob(nil, _digest), do: {:error, :store_unconfigured}

  def blob(root, digest) when is_binary(root) and is_binary(digest) do
    with true <- Regex.match?(@hex64, digest) || {:error, :invalid_digest},
         {:ok, dir} <-
           safe_dir(root, ["witness", "sha256", binary_part(digest, 0, 2)], :blob_missing),
         {:ok, path, size, stat} <- regular(dir, digest <> ".json", :blob_missing),
         :ok <- if(size <= @max_blob_bytes, do: :ok, else: {:error, :blob_too_large}),
         {:ok, bytes} <- blob_read(path, stat) do
      if :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == digest,
        do: {:ok, bytes},
        else: {:error, :blob_corrupt}
    end
  end

  def blob(_root, _digest), do: {:error, :invalid_digest}

  defp blob_read(path, stat) do
    case read(path, stat, @max_blob_bytes, :blob_missing) do
      {:error, :too_large} -> {:error, :blob_too_large}
      other -> other
    end
  end

  defp record_read(path, stat) do
    case read(path, stat, @max_record_bytes, :record_invalid) do
      {:error, :too_large} -> {:error, :record_too_large}
      other -> other
    end
  end

  @doc """
  A metadata-only fingerprint of the invocation's inventory (entry names
  with device, inode, size and mtime; no content read), used to detect a
  store change between observation and persistence. Same errors as
  `inventory/2`.
  """
  def fingerprint(nil, _invocation_id), do: {:error, :store_unconfigured}

  def fingerprint(root, invocation_id) when is_binary(root) do
    with :ok <- valid_uuid(invocation_id),
         {:ok, dir} <- safe_dir(root, ["witnesses", invocation_id]),
         {:ok, names} <- list(dir),
         {:ok, _entries} <- classify(names) do
      names
      |> Enum.sort()
      |> Enum.map(&entry_identity(dir, &1))
      |> then(&{:ok, :erlang.phash2(&1, 4_294_967_296)})
    end
  end

  defp entry_identity(dir, name) do
    case File.lstat(Path.join(dir, name)) do
      {:ok, stat} -> {name, stat.major_device, stat.inode, stat.size, stat.mtime}
      {:error, reason} -> {name, reason}
    end
  end

  defp valid_uuid(id) when is_binary(id),
    do: if(Regex.match?(@uuid, id), do: :ok, else: {:error, :invalid_invocation_id})

  defp valid_uuid(_id), do: {:error, :invalid_invocation_id}

  # Walks `parts` below `root`, refusing anything that is not a real,
  # owner-controlled directory (no symlink, not group/world-writable).
  defp safe_dir(root, parts, missing \\ :witness_missing) do
    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, dir} ->
      path = Path.join(dir, part)

      case dir_check(path, missing) do
        :ok -> {:cont, {:ok, path}}
        error -> {:halt, error}
      end
    end)
  end

  defp dir_check(path, missing) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        if writable_by_others?(stat), do: {:error, :unsafe_path}, else: :ok

      {:ok, _other} ->
        {:error, :unsafe_path}

      {:error, :enoent} ->
        {:error, missing}

      {:error, _reason} ->
        {:error, :unsafe_path}
    end
  end

  defp regular(dir, name, missing) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size} = stat} ->
        if writable_by_others?(stat), do: {:error, :unsafe_path}, else: {:ok, path, size, stat}

      {:ok, _other} ->
        {:error, :unsafe_path}

      {:error, :enoent} ->
        {:error, missing}

      {:error, _reason} ->
        {:error, :unsafe_path}
    end
  end

  defp writable_by_others?(%File.Stat{mode: mode}), do: Bitwise.band(mode, 0o022) != 0

  # Reads at most `max + 1` bytes from the opened file, then re-`lstat`s the
  # path: the same regular file (device, inode, size, mtime) must still be
  # there, so a replacement or growth between check and read is refused.
  defp read(path, stat, max, missing) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, fd} ->
        result = :file.read(fd, max + 1)
        :file.close(fd)
        verify_read(result, path, stat, max)

      {:error, :enoent} ->
        {:error, missing}

      {:error, _reason} ->
        {:error, :unsafe_path}
    end
  end

  defp verify_read({:ok, bytes}, path, stat, max) when byte_size(bytes) <= max do
    with {:ok, %File.Stat{type: :regular} = after_read} <- File.lstat(path),
         true <- same_file?(stat, after_read) and byte_size(bytes) == stat.size do
      {:ok, bytes}
    else
      _ -> {:error, :unsafe_path}
    end
  end

  defp verify_read(:eof, path, stat, max), do: verify_read({:ok, ""}, path, stat, max)
  defp verify_read({:ok, _bytes}, _path, _stat, _max), do: {:error, :too_large}
  defp verify_read(_result, _path, _stat, _max), do: {:error, :unsafe_path}

  defp same_file?(a, b) do
    {a.major_device, a.inode, a.size, a.mtime} == {b.major_device, b.inode, b.size, b.mtime}
  end

  defp list(dir) do
    case File.ls(dir) do
      # The proxy publishes through `.witness-*` temporary files it removes.
      {:ok, names} -> {:ok, Enum.reject(names, &String.starts_with?(&1, ".witness-"))}
      {:error, _reason} -> {:error, :unsafe_path}
    end
  end

  defp classify(names) when length(names) > @max_entries, do: {:error, :too_many_entries}

  defp classify(names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
      case Regex.run(@entry, name) do
        [_, id] -> {:cont, {:ok, Map.update(acc, id, [:terminal], &[:terminal | &1])}}
        [_, id, ".started"] -> {:cont, {:ok, Map.update(acc, id, [:started], &[:started | &1])}}
        nil -> {:halt, {:error, :record_invalid}}
      end
    end)
  end

  defp read_exchanges(dir, invocation_id, entries) do
    entries
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {record_id, kinds}, {:ok, acc} ->
      {name, state} =
        if :terminal in kinds,
          do: {record_id <> ".json", :terminal},
          else: {record_id <> ".started.json", :open}

      case read_record(dir, name, record_id, invocation_id) do
        {:ok, record} ->
          {:cont, {:ok, [%{record_id: record_id, record: record, state: state} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, exchanges} -> {:ok, %{exchanges: Enum.reverse(exchanges), anomalies: []}}
      error -> error
    end
  end

  defp read_record(dir, name, record_id, invocation_id) do
    with {:ok, path, size, stat} <- regular(dir, name, :record_invalid),
         :ok <- if(size <= @max_record_bytes, do: :ok, else: {:error, :record_too_large}),
         {:ok, bytes} <- record_read(path, stat),
         {:ok, record} when is_map(record) <- decode(bytes),
         :ok <- valid_record(record, record_id, invocation_id) do
      {:ok, record}
    else
      {:error, reason} when reason in [:unsafe_path, :record_too_large] -> {:error, reason}
      _invalid -> {:error, :record_invalid}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _ -> {:error, :record_invalid}
    end
  end

  defp valid_record(record, record_id, invocation_id) do
    if shape?(record) and identity?(record, record_id, invocation_id) and types?(record),
      do: :ok,
      else: {:error, :record_invalid}
  end

  defp shape?(record) do
    keys = Map.keys(record)

    Enum.all?(@required, &Map.has_key?(record, &1)) and
      Enum.all?(keys, &(&1 in @required or &1 in @optional))
  end

  defp identity?(record, record_id, invocation_id) do
    record["schema_version"] == 1 and record["record_id"] == record_id and
      record["invocation_id"] == invocation_id and record["route"] in @routes
  end

  defp types?(record) do
    Enum.all?(~w(proxy_version outcome traceparent started_at), &is_binary(record[&1])) and
      Enum.all?(~w(request_bytes_seen response_bytes_seen), &non_negative?(record[&1])) and
      Enum.all?(
        ~w(request_capture_complete response_capture_complete stream_complete),
        &is_boolean(record[&1])
      ) and
      Enum.all?(
        ~w(request_sha256 response_sha256 request_capture_sha256 response_capture_sha256),
        &digest?(record[&1])
      )
  end

  defp digest?(nil), do: true
  defp digest?(value), do: is_binary(value) and Regex.match?(@hex64, value)

  defp non_negative?(value), do: is_integer(value) and value >= 0
end
