# DRAFT r2 (outside the repository; review only). Deny-only declarations:
# every function returns {:error, :not_implemented}. Compiled only in builds
# with the prototype authority; the production build has no cluster code.
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

    Stage: deny-only (S4 IF-7 r2 draft). Every function returns
    `{:error, :not_implemented}`.
    """

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

    @doc "The pinned cluster facts (equal to `bin/prototype-pg:26-29`)."
    @spec pinned() :: paths() | {:error, :not_implemented}
    def pinned, do: red({:error, :not_implemented})

    @doc "The closed failure family, in step order."
    @spec reasons() :: [failure()] | {:error, :not_implemented}
    def reasons, do: red({:error, :not_implemented})

    @doc "Runs the proof on the pinned facts."
    @spec marker() :: {:ok, marker()} | {:error, failure() | :not_implemented}
    def marker, do: red({:error, :not_implemented})

    @doc "Runs the proof on an explicit, trusted paths map (tests, scratch roots)."
    @spec check(term()) :: {:ok, marker()} | {:error, failure() | :not_implemented}
    def check(_paths), do: red({:error, :not_implemented})

    @doc """
    Pure: the exact marker template. `{:ok, fields}` with the field TEXTS, or
    `{:error, :marker_invalid}`. The bytes must be printable ASCII
    (0x20-0x7E) except one final `"\\n"`, with no other control byte,
    whitespace or key:
    `{"system_identifier":"<1-20 [0-9]>","data_dir":"<P>","socket_dir":"<P>","port":<1-5 [0-9]>,"binary":"<P>"}\\n`,
    where `<P>` is 1..1024 bytes of printable ASCII without `"` or `\\`.
    """
    @spec parse_marker(binary()) :: {:ok, fields()} | {:error, :marker_invalid | :not_implemented}
    def parse_marker(_bytes), do: red({:error, :not_implemented})

    @doc """
    Pure: the control-file identifier TEXT from captured `pg_controldata`
    output: exactly one line equal to `Database system identifier:` + one
    or more spaces + 1-20 ASCII digits; at most 65536 bytes in total.
    """
    @spec parse_control(binary()) ::
            {:ok, String.t()} | {:error, :control_unreadable | :not_implemented}
    def parse_control(_output), do: red({:error, :not_implemented})

    @doc "Pure: `id -u` output, exactly 1-10 ASCII digits and one `\"\\n\"`."
    @spec parse_uid(binary()) ::
            {:ok, non_neg_integer()} | {:error, :uid_unknown | :not_implemented}
    def parse_uid(_output), do: red({:error, :not_implemented})

    @doc "Pure: the paths-map shape (step 0)."
    @spec paths_ok?(term()) :: boolean() | {:error, :not_implemented}
    def paths_ok?(_paths), do: red({:error, :not_implemented})

    # RED stub result, typed dynamic() so callers compile against it.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
