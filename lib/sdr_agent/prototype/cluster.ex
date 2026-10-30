# Read-only IF-7 identity proof. Compiled only in builds with the
# prototype authority; the production build has no cluster code.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Cluster do
    @moduledoc """
    The read-only IF-7 cluster identity proof for the D-237 prototype
    cluster (interfaces r6 IF-7 "Cluster"; S4 interface r2), used by S1's
    setup phase 0 (`Setup.real_effects/1` effect `cluster_marker`).

    `marker/0` runs `check(pinned())`. It returns `{:ok, %{system_identifier:
    n, data_dir: path}}` (exactly these two keys) or `{:error, reason}` with
    `reason` one of the 11 atoms of `reasons/0`, in the step order below; the
    first failing step wins. It never creates, writes, deletes or adopts
    anything, connects to no database, runs no `pg_ctl`, `psql` or `lsof`,
    prints nothing and logs nothing. It reads no environment value except
    through `SdrAgent.ChildEnv`'s snapshot.

    Steps (each path is checked with `File.lstat/1`, which never follows a
    symlink at that instant):

      0. paths map: exactly the keys `root`, `socket_dir`, `port`, `pg_bin`;
         absolute canonical paths, `port` an integer 1..65535; else
         `:cluster_check_failed` (a trusted-caller defect; `marker/0` takes
         no input);
      1. uid: `/usr/bin/id -u`, both streams captured; exit 0 and output
         exactly ASCII `[0-9]{1,10}` followed by one `"\\n"`; else
         `:uid_unknown`;
      2. root ancestors: `root` lies strictly under the pinned trusted base
         `/Users/charles` (a project fact like the root itself; no HOME
         read), and every component from that base down to `root`
         inclusive is a real directory owned by the uid, not group- or
         world-writable; else `:marker_not_owned`. The socket directory's
         parent `/private/tmp` is root-owned and sticky; only the socket
         directory itself is checked (step 11);
      3. marker present: `lstat` of `<root>/CLUSTER` is not `:enoent`; an
         `:enoent` is `:marker_missing`, any other `lstat` error is
         `:marker_not_owned`;
      4. marker owned: a regular file, owned by the uid, mode exactly 0600;
         else `:marker_not_owned`;
      5. marker bytes: a bounded read of at most 4097 bytes; the content is
         at most 4096 bytes and is exactly the template of `parse_marker/1`;
         else `:marker_invalid`;
      6. marker fields: `data_dir == root <> "/pgdata"`, `socket_dir`,
         `port` equal the paths map, as exact strings; else
         `:marker_mismatch`;
      7. data directory, `pgdata/global` and `pgdata/global/pg_control`:
         real directories owned by the uid, mode 0700, and a regular file
         owned by the uid, mode 0600; else `:data_dir_not_owned`;
      8. binary: the marker's `binary` equals `pg_bin`; else
         `:binary_mismatch`;
      9. control: `<pg_bin>/pg_controldata -D <data>`, both streams
         captured, `LC_ALL=C` set over the ChildEnv base; exit 0, output
         at most 65536 bytes, and exactly one line
         `Database system identifier:` + spaces + ASCII digits; else
         `:control_unreadable` (an `:enoent`/`:eacces` spawn error
         included);
     10. control digits equal the marker's digit TEXT exactly; else
         `:control_mismatch`;
     11. socket directory: a real directory owned by the uid, mode 0700;
         else `:socket_dir_not_owned`;
     12. the identifier text converts to an integer `1..2^64-1`; else
         `:marker_invalid` (Elixir-side strictness; a real control file
         never names 0).

    Any other raise, throw or exit gives `:cluster_check_failed`; the caught
    kind, reason and any captured bytes are never read beyond the parsers,
    formatted, printed or logged.

    **Trust and race bounds.** The prototype is single-user: processes of
    the same uid are trusted not to mutate the root, the marker, the data
    directory or the socket directory concurrently. `lstat` and a later read
    or exec are not atomic; a same-uid swap between them is outside this
    proof. The proof establishes only "these pinned paths, at check time,
    passed these checks" — never absence, adoption of another directory, or
    permission to repair.

    Both child commands capture their output in memory. The parser bounds
    are not child-output allocation limits or wall-clock/kill guarantees.
    """

    alias SdrAgent.ChildEnv

    @type marker :: %{system_identifier: pos_integer(), data_dir: String.t()}
    @type failure ::
            :uid_unknown
            | :marker_missing
            | :marker_not_owned
            | :marker_invalid
            | :marker_mismatch
            | :data_dir_not_owned
            | :binary_mismatch
            | :control_unreadable
            | :control_mismatch
            | :socket_dir_not_owned
            | :cluster_check_failed
    @type paths :: %{
            root: String.t(),
            socket_dir: String.t(),
            port: 1..65_535,
            pg_bin: String.t()
          }
    @type fields :: %{
            system_identifier: String.t(),
            data_dir: String.t(),
            socket_dir: String.t(),
            port: String.t(),
            binary: String.t()
          }

    @reasons [
      :uid_unknown,
      :marker_missing,
      :marker_not_owned,
      :marker_invalid,
      :marker_mismatch,
      :data_dir_not_owned,
      :binary_mismatch,
      :control_unreadable,
      :control_mismatch,
      :socket_dir_not_owned,
      :cluster_check_failed
    ]
    # bin/prototype-pg:26-29 (S4 09ad3ce).
    @pinned %{
      root: "/Users/charles/.local/state/sdr-agent/prototype/d237-5542",
      socket_dir: "/private/tmp/d237-pg-5542",
      port: 5542,
      pg_bin: "/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6/bin"
    }
    @path_keys [:pg_bin, :port, :root, :socket_dir]
    # <P>: 1..1024 bytes of printable ASCII without `"` (0x22) or `\` (0x5C).
    @p "[\\x20\\x21\\x23-\\x5B\\x5D-\\x7E]{1,1024}"
    @marker ~r/\A\{"system_identifier":"([0-9]{1,20})","data_dir":"(#{@p})","socket_dir":"(#{@p})","port":([0-9]{1,5}),"binary":"(#{@p})"\}\n\z/
    @marker_max 4096
    @control_label "Database system identifier:"
    @control_line ~r/\ADatabase system identifier: +([0-9]{1,20})\z/
    @control_max 65_536
    @uid ~r/\A([0-9]{1,10})\n\z/
    @path_byte ~r/\A[\x20-\x7E]+\z/

    @doc "The pinned cluster facts (equal to `bin/prototype-pg:26-29`)."
    @spec pinned() :: paths()
    def pinned, do: @pinned

    @doc "The closed failure family, in step order."
    @spec reasons() :: [failure()]
    def reasons, do: @reasons

    @doc "Runs the proof on the pinned facts."
    @spec marker() :: {:ok, marker()} | {:error, failure()}
    def marker, do: check(pinned())

    @doc "Runs the proof on an explicit, trusted paths map (tests, scratch roots)."
    @spec check(term()) :: {:ok, marker()} | {:error, failure()}
    def check(paths) do
      if paths_ok?(paths), do: proof(paths), else: {:error, :cluster_check_failed}
    catch
      _kind, _reason -> {:error, :cluster_check_failed}
    end

    defp proof(paths) do
      data = paths.root <> "/pgdata"

      with {:ok, uid} <- uid(),
           :ok <- ancestors(paths.root, uid),
           :ok <- marker_owned(paths.root <> "/CLUSTER", uid),
           {:ok, fields} <- read_marker(paths.root <> "/CLUSTER"),
           :ok <- marker_fields(fields, paths, data),
           :ok <- data_owned(data, uid),
           :ok <- equal(fields.binary, paths.pg_bin, :binary_mismatch),
           {:ok, digits} <- control(paths.pg_bin, data),
           :ok <- equal(digits, fields.system_identifier, :control_mismatch),
           true <- owned?(paths.socket_dir, uid, :directory, 0o700),
           {:ok, identifier} <- identifier(fields.system_identifier) do
        {:ok, %{system_identifier: identifier, data_dir: data}}
      else
        false -> {:error, :socket_dir_not_owned}
        {:error, _reason} = error -> error
      end
    end

    defp uid do
      case System.cmd("/usr/bin/id", ["-u"], env: ChildEnv.cmd([]), stderr_to_stdout: true) do
        {output, 0} -> parse_uid(output)
        _other -> {:error, :uid_unknown}
      end
    catch
      _kind, _reason -> {:error, :uid_unknown}
    end

    defp ancestors(root, uid) do
      base = "/Users/charles"

      if String.starts_with?(root, base <> "/") do
        components = root |> Path.relative_to(base) |> Path.split()
        paths = [base | Enum.scan(components, base, &Path.join(&2, &1))]

        if Enum.all?(paths, &safe_ancestor?(&1, uid)),
          do: :ok,
          else: {:error, :marker_not_owned}
      else
        {:error, :marker_not_owned}
      end
    end

    defp safe_ancestor?(path, uid) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} ->
          Bitwise.band(mode, 0o022) == 0

        _other ->
          false
      end
    end

    defp marker_owned(path, uid) do
      case File.lstat(path) do
        {:error, :enoent} ->
          {:error, :marker_missing}

        {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode}} ->
          if Bitwise.band(mode, 0o7777) == 0o600,
            do: :ok,
            else: {:error, :marker_not_owned}

        _other ->
          {:error, :marker_not_owned}
      end
    end

    defp read_marker(path) do
      case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
        {:ok, file} ->
          try do
            case :file.read(file, @marker_max + 1) do
              {:ok, bytes} -> parse_marker(bytes)
              _other -> {:error, :marker_invalid}
            end
          after
            :file.close(file)
          end

        _other ->
          {:error, :marker_invalid}
      end
    end

    defp marker_fields(fields, paths, data) do
      if fields.data_dir == data and fields.socket_dir == paths.socket_dir and
           fields.port == Integer.to_string(paths.port),
         do: :ok,
         else: {:error, :marker_mismatch}
    end

    defp data_owned(data, uid) do
      if owned?(data, uid, :directory, 0o700) and
           owned?(data <> "/global", uid, :directory, 0o700) and
           owned?(data <> "/global/pg_control", uid, :regular, 0o600),
         do: :ok,
         else: {:error, :data_dir_not_owned}
    end

    defp owned?(path, uid, type, expected_mode) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: ^type, uid: ^uid, mode: mode}} ->
          Bitwise.band(mode, 0o7777) == expected_mode

        _other ->
          false
      end
    end

    defp control(binary, data) do
      case System.cmd(binary <> "/pg_controldata", ["-D", data],
             env: ChildEnv.cmd([], [{"LC_ALL", "C"}]),
             stderr_to_stdout: true
           ) do
        {output, 0} -> parse_control(output)
        _other -> {:error, :control_unreadable}
      end
    catch
      _kind, _reason -> {:error, :control_unreadable}
    end

    defp equal(value, value, _reason), do: :ok
    defp equal(_left, _right, reason), do: {:error, reason}

    defp identifier(digits) do
      value = String.to_integer(digits)

      if value in 1..18_446_744_073_709_551_615,
        do: {:ok, value},
        else: {:error, :marker_invalid}
    end

    @doc """
    Pure: the exact marker template. `{:ok, fields}` with the field TEXTS, or
    `{:error, :marker_invalid}`. The bytes must be printable ASCII
    (0x20-0x7E) except one final `"\\n"`, with no other control byte,
    whitespace or key:
    `{"system_identifier":"<1-20 [0-9]>","data_dir":"<P>","socket_dir":"<P>","port":<1-5 [0-9]>,"binary":"<P>"}\\n`,
    where `<P>` is 1..1024 bytes of printable ASCII without `"` or `\\`.
    """
    @spec parse_marker(binary()) :: {:ok, fields()} | {:error, :marker_invalid}
    def parse_marker(bytes) when is_binary(bytes) and byte_size(bytes) <= @marker_max do
      case Regex.run(@marker, bytes, capture: :all_but_first) do
        [identifier, data_dir, socket_dir, port, binary] ->
          {:ok,
           %{
             system_identifier: identifier,
             data_dir: data_dir,
             socket_dir: socket_dir,
             port: port,
             binary: binary
           }}

        nil ->
          {:error, :marker_invalid}
      end
    end

    def parse_marker(_bytes), do: {:error, :marker_invalid}

    @doc """
    Pure: the control-file identifier TEXT from captured `pg_controldata`
    output: exactly one line equal to `Database system identifier:` + one
    or more spaces + 1-20 ASCII digits; at most 65536 bytes in total. Any
    other line starting with the label also refuses.
    """
    @spec parse_control(binary()) :: {:ok, String.t()} | {:error, :control_unreadable}
    def parse_control(output) when is_binary(output) and byte_size(output) <= @control_max do
      labelled =
        output
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, @control_label))

      with [line] <- labelled,
           [digits] <- Regex.run(@control_line, line, capture: :all_but_first) do
        {:ok, digits}
      else
        _other -> {:error, :control_unreadable}
      end
    end

    def parse_control(_output), do: {:error, :control_unreadable}

    @doc "Pure: `id -u` output, exactly 1-10 ASCII digits and one `\"\\n\"`."
    @spec parse_uid(binary()) :: {:ok, non_neg_integer()} | {:error, :uid_unknown}
    def parse_uid(output) when is_binary(output) do
      case Regex.run(@uid, output, capture: :all_but_first) do
        [digits] -> {:ok, String.to_integer(digits)}
        nil -> {:error, :uid_unknown}
      end
    end

    def parse_uid(_output), do: {:error, :uid_unknown}

    @doc """
    Pure: the paths-map shape (step 0): a map with exactly the keys `root`,
    `socket_dir`, `port` and `pg_bin`; each path an absolute canonical
    printable-ASCII path (not `/`, no trailing `/`, no `//`, no `.` or `..`
    component); `port` an integer 1..65535.
    """
    @spec paths_ok?(term()) :: boolean()
    def paths_ok?(%{root: root, socket_dir: socket_dir, port: port, pg_bin: pg_bin} = paths) do
      exact_keys? = paths |> Map.keys() |> Enum.sort() == @path_keys
      port? = is_integer(port) and port in 1..65_535
      exact_keys? and port? and Enum.all?([root, socket_dir, pg_bin], &canonical_path?/1)
    end

    def paths_ok?(_paths), do: false

    defp canonical_path?(path) when is_binary(path) do
      String.starts_with?(path, "/") and path != "/" and not String.ends_with?(path, "/") and
        not String.contains?(path, "//") and Regex.match?(@path_byte, path) and
        path |> String.split("/", trim: true) |> Enum.all?(&(&1 not in [".", ".."]))
    end

    defp canonical_path?(_path), do: false
  end
end
