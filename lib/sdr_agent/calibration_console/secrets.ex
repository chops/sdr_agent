defmodule SdrAgent.CalibrationConsole.Secrets do
  @moduledoc """
  The calibration console's per-machine secrets: the endpoint
  `secret_key_base` (session cookies, LiveView) and the AshAuthentication
  token signing secret it serves with. The test build's checked-in values
  are public, so a local process could forge a signed admin session for the
  calibration database, which holds the single G-R0 grant; the console
  never uses them.

  The values live in one file outside the repository,
  `~/.local/state/sdr-agent/calibration/secrets` (`default_path/0`):

    * **First use.** Two values of 64 random bytes each
      (`:crypto.strong_rand_bytes/1`, base64) are written to a temporary
      file in the 0700 directory, made 0600 and hard-linked into place, so
      the file appears complete or not at all, and simultaneous first uses
      agree on one set (the losers read the winner's file).
    * **Later uses.** The same values are read back, so sessions survive a
      restart.
    * **Refused.** A directory or file that is a symlink, is not owned by
      this user (the effective UID, `id -u`), or is readable or writable by
      group or others; a malformed file.

  No value is ever printed, logged, put on a command line or included in an
  error; errors name only the path and the reason.
  """

  import Bitwise

  alias SdrAgent.Agents.Witness.Store

  @keys [:secret_key_base, :token_signing_secret]
  @bytes 64

  @typedoc "The console's secrets (base64 strings)."
  @type t :: %{secret_key_base: String.t(), token_signing_secret: String.t()}

  @doc "`~/.local/state/sdr-agent/calibration/secrets`."
  def default_path,
    do: Path.join(System.user_home!(), ".local/state/sdr-agent/calibration/secrets")

  @doc """
  Reads the secrets at `path`, creating them on first use. `uid` is the
  owner required of the directory and file (default: this VM's effective
  UID).
  """
  @spec load_or_create(Path.t(), non_neg_integer() | nil) :: {:ok, t()} | {:error, String.t()}
  def load_or_create(path \\ default_path(), uid \\ nil) do
    case uid || Store.effective_uid() do
      uid when is_integer(uid) ->
        dir = Path.dirname(path)

        with :ok <- ensure_dir(dir, uid),
             :ok <- ensure_file(path, dir, uid) do
          read(path)
        end

      _unavailable ->
        {:error, "could not read this user's UID (id -u); refusing #{path}"}
    end
  end

  ## The directory

  defp ensure_dir(dir, uid) do
    case File.lstat(dir) do
      {:ok, stat} -> check(dir, stat, :directory, uid)
      {:error, :enoent} -> create_dir(dir, uid)
      {:error, reason} -> {:error, "cannot read #{dir}: #{reason}"}
    end
  end

  # Made 0700 under a temporary name, then renamed into place: the
  # directory is never visible with the umask's mode.
  defp create_dir(dir, uid) do
    parent = Path.dirname(dir)
    temp = Path.join(parent, ".#{Path.basename(dir)}.tmp-#{token()}")

    with :ok <- mkdir_p(parent),
         :ok <- mkdir(temp),
         :ok <- chmod(temp, 0o700) do
      case :file.rename(temp, dir) do
        :ok -> :ok
        {:error, _exists} -> File.rmdir(temp)
      end

      ensure_dir_exists(dir, uid)
    end
  end

  defp ensure_dir_exists(dir, uid) do
    case File.lstat(dir) do
      {:ok, stat} -> check(dir, stat, :directory, uid)
      {:error, reason} -> {:error, "cannot create #{dir}: #{reason}"}
    end
  end

  ## The file

  defp ensure_file(path, dir, uid) do
    case File.lstat(path) do
      {:ok, stat} -> check(path, stat, :regular, uid)
      {:error, :enoent} -> create_file(path, dir, uid)
      {:error, reason} -> {:error, "cannot read #{path}: #{reason}"}
    end
  end

  # Written to a temporary file inside the 0700 directory, made 0600, then
  # hard-linked into place (which fails if the file already exists).
  defp create_file(path, dir, uid) do
    temp = Path.join(dir, ".secrets.tmp-#{token()}")
    body = Enum.map_join(@keys, fn key -> "#{key}=#{generate()}\n" end)

    result =
      with :ok <- write_new(temp, body),
           :ok <- chmod(temp, 0o600) do
        case File.ln(temp, path) do
          :ok -> :ok
          {:error, :eexist} -> :ok
          {:error, reason} -> {:error, "cannot create #{path}: #{reason}"}
        end
      end

    File.rm(temp)

    with :ok <- result do
      case File.lstat(path) do
        {:ok, stat} -> check(path, stat, :regular, uid)
        {:error, reason} -> {:error, "cannot create #{path}: #{reason}"}
      end
    end
  end

  defp write_new(temp, body) do
    case File.write(temp, body, [:exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write #{Path.dirname(temp)}: #{reason}"}
    end
  end

  ## Checks and parsing

  defp check(path, %File.Stat{type: type, uid: owner, mode: mode}, expected, uid) do
    cond do
      type != expected ->
        {:error, "#{path} is not a #{describe(expected)} (it is a #{type})"}

      owner != uid ->
        {:error, "#{path} is not owned by this user (uid #{uid})"}

      (mode &&& 0o077) != 0 ->
        {:error,
         "#{path} is readable or writable by group or others (mode " <>
           "#{Integer.to_string(mode &&& 0o777, 8)}); it must be " <>
           "#{if expected == :directory, do: "0700", else: "0600"}"}

      true ->
        :ok
    end
  end

  defp describe(:directory), do: "directory"
  defp describe(:regular), do: "regular file"

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, secrets} <- parse(body) do
      {:ok, secrets}
    else
      {:error, reason} when is_atom(reason) -> {:error, "cannot read #{path}: #{reason}"}
      :malformed -> {:error, "#{path} is malformed; move it aside to generate new values"}
    end
  end

  defp parse(body) do
    pairs =
      for line <- String.split(body, "\n", trim: true),
          [key, value] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {key, value}

    values = for key <- @keys, do: {key, Map.get(pairs, Atom.to_string(key))}

    if map_size(pairs) == length(@keys) and Enum.all?(values, &strong?(elem(&1, 1))),
      do: {:ok, Map.new(values)},
      else: :malformed
  end

  defp strong?(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, raw} -> byte_size(raw) >= @bytes
      :error -> false
    end
  end

  defp strong?(_missing), do: false

  defp generate, do: @bytes |> :crypto.strong_rand_bytes() |> Base.encode64()
  defp token, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{reason}"}
    end
  end

  defp mkdir(dir) do
    case File.mkdir(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{reason}"}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot set the mode of #{path}: #{reason}"}
    end
  end
end
