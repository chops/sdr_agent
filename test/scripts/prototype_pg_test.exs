defmodule SdrAgent.Scripts.PrototypePgTest do
  @moduledoc """
  Hermetic tests for `bin/prototype-pg`, the D-237 isolated prototype
  cluster script (interfaces r6 IF-7 "Cluster", must-fix R5, Q2; amendment
  item 2 "Its own PostgreSQL 18 cluster").

  No real PostgreSQL cluster is ever started here. Each test runs a derived
  copy of the script that differs from `bin/prototype-pg` in exactly its
  pinned constant lines (the PostgreSQL binary directory, the root, the
  socket directory, `lsof` and `stat`), pointed at fake `initdb`, `pg_ctl`,
  `pg_controldata`, `psql`, `postgres`, `lsof` and `stat` in a scratch
  directory. The fakes record every invocation, so a test can prove that
  nothing was signalled.

  Covered: the Q2 full path from absent roots (init prepares the socket
  directory → start → live identity → status → owned stop); init refusing an
  existing data path, an existing marker, and a symlinked, wide-mode,
  foreign-owned or non-empty socket directory, unaltered; `owned!/1`
  (marker, data directory, binary, control file, socket directory) before
  start, status and stop; the socket pair absent before a start (a stale
  `postmaster.pid` with no server); no TCP listener, where only `lsof`'s
  documented no-match result admits a start and a failed, unavailable or
  signalled probe refuses before `pg_ctl` (Codex S4 bounded review R1:
  no start, no signal, no file change, no raw diagnostics); a wrong live identity
  refusing status and stop with nothing signalled; the logging GUCs written
  before the first start; a source check (no kill, rm, process listing or
  environment reads); and the doc/constant consistency check of ruling 3
  (5520 is the ordinary service, 5541 the prototype socket).
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../bin/prototype-pg", __DIR__)
  @doc_path Path.expand("../../docs/product/d237/prototype-runtime.md", __DIR__)
  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)

  @pinned_bin "/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6/bin"
  @pinned_root "/Users/charles/.local/state/sdr-agent/prototype/d237"
  @pinned_socket "/private/tmp/d237-pg"
  @constants [:PG_BIN, :ROOT, :SOCKET_DIR, :LSOF, :STAT]

  # Amendment item 7 "Server logs (D-118/5b)", set before the first start.
  @gucs [
    "listen_addresses = ''",
    "port = 5541",
    "log_min_messages = fatal",
    "log_min_error_statement = panic",
    "log_statement = none",
    "log_min_duration_statement = -1",
    "log_min_duration_sample = -1",
    "log_transaction_sample_rate = 0",
    "log_error_verbosity = terse",
    "log_parameter_max_length = 0",
    "log_parameter_max_length_on_error = 0",
    "log_connections = ''",
    "log_disconnections = off",
    "log_autovacuum_min_duration = -1",
    "log_checkpoints = off",
    "log_lock_waits = off",
    "log_lock_failures = off",
    "log_temp_files = -1",
    "shared_preload_libraries = ''",
    "session_preload_libraries = ''",
    "logging_collector = off"
  ]

  @sysid "7400000000000000001"

  setup do
    # An exclusively created root this test owns; only it is removed on exit.
    base = SdrAgent.PrototypeOutreachFixtures.exclusive_root!("d237-pg-test")

    ctx = %{
      base: base,
      bin: Path.join(base, "fakebin"),
      state: Path.join(base, "state"),
      root: Path.join([base, "home", "d237"]),
      socket: Path.join(base, "sock")
    }

    ctx =
      Map.merge(ctx, %{
        data: Path.join(ctx.root, "pgdata"),
        marker: Path.join(ctx.root, "CLUSTER"),
        log: Path.join([ctx.root, "log", "postgres.log"]),
        script: Path.join(base, "prototype-pg")
      })

    File.mkdir_p!(ctx.bin)
    File.mkdir_p!(ctx.state)
    File.write!(Path.join(ctx.state, "sysid"), @sysid <> "\n")
    write_fakes!(ctx)
    derive_script!(ctx)
    ctx
  end

  # ------------------------------------------------------------------ helpers

  defp script_present? do
    File.regular?(@script)
  end

  defp run(ctx, args) do
    {out, status} = System.cmd(ctx.script, args, stderr_to_stdout: true)
    %{out: out, status: status}
  end

  defp calls(ctx) do
    case File.read(Path.join(ctx.state, "calls.log")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp signalled?(ctx), do: Enum.any?(calls(ctx), &String.starts_with?(&1, "pg_ctl stop"))
  defp started?(ctx), do: Enum.any?(calls(ctx), &String.starts_with?(&1, "pg_ctl start"))

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.lstat(path)
    Bitwise.band(mode, 0o7777)
  end

  defp refused?(result, code),
    do: result.status == 2 and result.out =~ "prototype-pg: refused #{code}"

  defp assert_refused(result, code) do
    assert refused?(result, code),
           "expected refusal #{code} (exit 2), got exit #{result.status}: #{inspect(result.out)}"
  end

  defp assert_ok(result, what) do
    assert result.status == 0 and result.out =~ "prototype-pg: #{what} ok",
           "expected #{what} ok (exit 0), got exit #{result.status}: #{inspect(result.out)}"
  end

  defp init!(ctx) do
    result = run(ctx, ["init"])
    assert_ok(result, "init")
    result
  end

  # The outcome of a completed init, built directly (state this test
  # controls), so the start, status and stop tests reach their own named
  # behaviour; the Q2 full-path test covers init → start end to end.
  defp seeded!(ctx) do
    for dir <- [ctx.root, Path.dirname(ctx.log), ctx.socket, ctx.data] do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    File.write!(Path.join(ctx.data, "postgresql.conf"), "# seeded\n")
    File.write!(Path.join(ctx.data, "FAKE_SYSID"), @sysid <> "\n")
    File.write!(ctx.marker, expected_marker(ctx))
    File.chmod!(ctx.marker, 0o600)
    ctx
  end

  # A running owned cluster as the fakes see it: the server is up and its
  # socket pair exists.
  defp running!(ctx) do
    seeded!(ctx)
    put_state!(ctx, "running", "")
    Enum.each(socket_pair(ctx), &File.write!(&1, ""))
    ctx
  end

  defp expected_marker(ctx, sysid \\ @sysid) do
    ~s({"system_identifier":"#{sysid}","data_dir":"#{ctx.data}","socket_dir":"#{ctx.socket}",) <>
      ~s("port":5541,"binary":"#{ctx.bin}"}\n)
  end

  defp put_state!(ctx, name, value), do: File.write!(Path.join(ctx.state, name), value)

  # Everything under the cluster roots (the root and the socket directory):
  # each path's type, mode, size and file bytes. A refusal leaves it identical.
  defp snapshot(ctx) do
    for top <- [ctx.root, ctx.socket],
        match?({:ok, _}, File.lstat(top)),
        path <- [top | Path.wildcard(Path.join(top, "**"), match_dot: true)],
        into: %{} do
      {:ok, stat} = File.lstat(path)
      bytes = if stat.type == :regular, do: :crypto.hash(:sha256, File.read!(path))
      {path, {stat.type, stat.mode, stat.size, bytes}}
    end
  end

  defp socket_pair(ctx),
    do: [Path.join(ctx.socket, ".s.PGSQL.5541"), Path.join(ctx.socket, ".s.PGSQL.5541.lock")]

  # The derived copy: exactly the pinned constant lines replaced, nothing else.
  defp derive_script!(ctx) do
    if script_present?() do
      original = File.read!(@script)

      replacements = %{
        PG_BIN: ctx.bin,
        ROOT: ctx.root,
        SOCKET_DIR: ctx.socket,
        LSOF: Path.join(ctx.bin, "lsof"),
        STAT: Path.join(ctx.bin, "stat")
      }

      derived =
        Enum.reduce(replacements, original, fn {name, value}, text ->
          Regex.replace(~r/^readonly #{name}='[^']*'$/m, text, "readonly #{name}='#{value}'")
        end)

      File.write!(ctx.script, derived)
      File.chmod!(ctx.script, 0o755)
    end
  end

  defp write_fake!(ctx, name, body) do
    path = Path.join(ctx.bin, name)

    File.write!(path, """
    #!/bin/bash
    S='#{ctx.state}'
    printf '%s\\n' "#{name} $*" >> "$S/calls.log"
    #{body}
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fakes!(ctx) do
    sock = ctx.socket
    data = ctx.data

    write_fake!(ctx, "initdb", """
    d=''
    while [ $# -gt 0 ]; do case "$1" in -D) d="$2"; shift 2;; *) shift;; esac; done
    /bin/mkdir -m 0700 "$d" || exit 1
    printf '# fake postgresql.conf\\n' > "$d/postgresql.conf"
    printf '18\\n' > "$d/PG_VERSION"
    /bin/cat "$S/sysid" > "$d/FAKE_SYSID"
    """)

    write_fake!(ctx, "pg_controldata", """
    d=''
    while [ $# -gt 0 ]; do case "$1" in -D) d="$2"; shift 2;; *) shift;; esac; done
    [ -f "$d/FAKE_SYSID" ] || exit 1
    printf 'pg_control version number:            1800\\n'
    printf 'Database system identifier:           %s\\n' "$(/bin/cat "$d/FAKE_SYSID")"
    """)

    write_fake!(ctx, "pg_ctl", """
    cmd=''; log=''
    while [ $# -gt 0 ]; do
      case "$1" in -D|-m|-t) shift 2;; -l) log="$2"; shift 2;; -w|-W|-s) shift;; *) cmd="$1"; shift;; esac
    done
    case "$cmd" in
      status) if [ -f "$S/running" ]; then echo 'pg_ctl: server is running'; exit 0; fi
              echo 'pg_ctl: no server running'; exit 3;;
      start) [ -f "$S/running" ] && exit 1
             : > "$S/running"; printf 'fake server started\\n' >> "$log"
             : > '#{sock}/.s.PGSQL.5541'; : > '#{sock}/.s.PGSQL.5541.lock'; exit 0;;
      stop) /bin/rm -f "$S/running" '#{sock}/.s.PGSQL.5541' '#{sock}/.s.PGSQL.5541.lock'; exit 0;;
      *) exit 1;;
    esac
    """)

    write_fake!(ctx, "psql", """
    [ -f "$S/running" ] || exit 2
    if [ -f "$S/live_sysid" ]; then sysid=$(/bin/cat "$S/live_sysid"); else sysid=$(/bin/cat '#{data}/FAKE_SYSID'); fi
    if [ -f "$S/live_datadir" ]; then dir=$(/bin/cat "$S/live_datadir"); else dir='#{data}'; fi
    printf '%s|%s\\n' "$sysid" "$dir"
    """)

    write_fake!(ctx, "postgres", "exit 0")

    # lsof: by default its documented no-match result (exit 1, no output at
    # all). state/lsof_out, lsof_err, lsof_rc and lsof_signal play a
    # listener, diagnostics, another status, or death by a signal.
    write_fake!(ctx, "lsof", """
    [ -f "$S/lsof_out" ] && /bin/cat "$S/lsof_out"
    [ -f "$S/lsof_err" ] && /bin/cat "$S/lsof_err" >&2
    [ -f "$S/lsof_signal" ] && /bin/kill -KILL $$
    [ -f "$S/lsof_rc" ] && exit "$(/bin/cat "$S/lsof_rc")"
    [ -f "$S/lsof_out" ] && exit 0
    exit 1
    """)

    # A pass-through to the real lstat-based stat, reporting uid 0 for any
    # path listed in state/foreign (a foreign-owned directory without sudo).
    write_fake!(ctx, "stat", """
    out=$(/usr/bin/stat "$@") || exit $?
    last="${@: -1}"
    if [ -f "$S/foreign" ] && /usr/bin/grep -qxF -- "$last" "$S/foreign"; then out="0:${out#*:}"; fi
    printf '%s\\n' "$out"
    """)
  end

  # ------------------------------------------------------------------ script and derivation

  test "the script exists, is executable and pins every constant exactly once" do
    assert script_present?(), "bin/prototype-pg does not exist"
    assert Bitwise.band(mode(@script), 0o111) != 0, "bin/prototype-pg is not executable"
    text = File.read!(@script)

    for name <- @constants do
      assert length(Regex.scan(~r/^readonly #{name}='[^']*'$/m, text)) == 1,
             "constant #{name} is not pinned exactly once"
    end

    assert text =~ ~r/^readonly PG_BIN='#{Regex.escape(@pinned_bin)}'$/m
    assert text =~ ~r/^readonly ROOT='#{Regex.escape(@pinned_root)}'$/m
    assert text =~ ~r/^readonly SOCKET_DIR='#{Regex.escape(@pinned_socket)}'$/m
    assert text =~ ~r/^readonly PORT='5541'$/m
  end

  test "the derived copy differs from the script in exactly the pinned constant lines", ctx do
    assert script_present?(), "bin/prototype-pg does not exist"
    original = @script |> File.read!() |> String.split("\n")
    derived = ctx.script |> File.read!() |> String.split("\n")
    assert length(original) == length(derived)

    changed =
      original
      |> Enum.zip(derived)
      |> Enum.reject(fn {a, b} -> a == b end)
      |> Enum.map(fn {a, _b} -> a |> String.split("=") |> hd() end)

    assert Enum.sort(changed) == Enum.sort(Enum.map(@constants, &"readonly #{&1}"))
  end

  test "source check: no kill, rm, process listing, argv or environment reads" do
    assert script_present?(), "bin/prototype-pg does not exist"

    code =
      @script
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
      |> Enum.join("\n")

    forbidden = [
      ~r/\bkill\b/,
      ~r/\bpkill\b/,
      ~r/\bkillall\b/,
      ~r/\bpgrep\b/,
      ~r/(^|[\s;|&(])rm\s/,
      ~r/(^|[\s;|&(\/])ps\s/,
      ~r/\/proc\b/,
      ~r/\bprintenv\b/,
      ~r/\$\{?HOME\b/,
      ~r/\$\{?USER\b/,
      ~r/\$\{?PATH\b/,
      ~r/-o\s*(args|command)/,
      ~r/lsof\s[^\n]*-p\b/
    ]

    hits = for re <- forbidden, Regex.match?(re, code), do: Regex.source(re)
    assert hits == [], "forbidden constructs in bin/prototype-pg: #{inspect(hits)}"
  end

  # ------------------------------------------------------------------ Q2: the full path

  test "Q2: absent roots → init prepares the socket directory → start → status → owned stop",
       ctx do
    refute File.exists?(ctx.socket)
    refute File.exists?(ctx.root)

    init!(ctx)
    assert File.dir?(ctx.socket) and mode(ctx.socket) == 0o700
    assert File.ls!(ctx.socket) == []
    assert File.dir?(ctx.data) and mode(ctx.data) == 0o700
    assert mode(ctx.root) == 0o700
    assert File.read!(ctx.marker) == expected_marker(ctx)
    assert mode(ctx.marker) == 0o600
    refute started?(ctx), "init must not start the cluster"

    assert_ok(run(ctx, ["start"]), "start")
    assert started?(ctx)
    assert Enum.any?(calls(ctx), &String.starts_with?(&1, "psql ")), "no live identity read"
    assert mode(ctx.log) == 0o600

    status = run(ctx, ["status"])
    assert status.status == 0 and status.out =~ "prototype-pg: status running", inspect(status)

    assert_ok(run(ctx, ["stop"]), "stop")
    assert signalled?(ctx)

    stop_call = Enum.find(calls(ctx), &String.starts_with?(&1, "pg_ctl stop"))
    assert stop_call =~ "-D #{ctx.data}" and stop_call =~ "-m fast"

    stopped = run(ctx, ["status"])
    assert stopped.status == 0 and stopped.out =~ "prototype-pg: status stopped", inspect(stopped)
  end

  test "init writes the logging and connection GUCs before the first start", ctx do
    init!(ctx)
    conf = File.read!(Path.join(ctx.data, "postgresql.conf"))

    for guc <- ["unix_socket_directories = '#{ctx.socket}'" | @gucs] do
      assert conf =~ ~r/^#{Regex.escape(guc)}$/m, "postgresql.conf lacks: #{guc}"
    end

    refute started?(ctx)
  end

  # ------------------------------------------------------------------ init refusals, unaltered

  test "init refuses an existing data path", ctx do
    File.mkdir_p!(ctx.data)
    assert_refused(run(ctx, ["init"]), "data_path_exists")
    refute File.exists?(ctx.marker)
    refute File.exists?(ctx.socket)
    assert File.ls!(ctx.data) == []
  end

  test "init refuses an existing marker with no data path, and never overwrites it", ctx do
    File.mkdir_p!(ctx.root)
    File.write!(ctx.marker, "previous marker\n")
    assert_refused(run(ctx, ["init"]), "marker_exists")
    assert File.read!(ctx.marker) == "previous marker\n"
    refute File.exists?(ctx.data)
    refute File.exists?(ctx.socket)
  end

  test "init refuses a symlinked socket directory, unaltered", ctx do
    target = Path.join(ctx.base, "elsewhere")
    File.mkdir_p!(target)
    File.chmod!(target, 0o700)
    File.ln_s!(target, ctx.socket)

    assert_refused(run(ctx, ["init"]), "socket_dir_not_owned")
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(ctx.socket)
    refute File.exists?(ctx.data)
    refute File.exists?(ctx.marker)
  end

  test "init refuses a wide-mode socket directory, unaltered", ctx do
    File.mkdir_p!(ctx.socket)
    File.chmod!(ctx.socket, 0o755)
    assert_refused(run(ctx, ["init"]), "socket_dir_not_owned")
    assert mode(ctx.socket) == 0o755
    refute File.exists?(ctx.data)
  end

  test "init refuses a foreign-owned socket directory, unaltered", ctx do
    File.mkdir_p!(ctx.socket)
    File.chmod!(ctx.socket, 0o700)
    put_state!(ctx, "foreign", ctx.socket <> "\n")
    assert_refused(run(ctx, ["init"]), "socket_dir_not_owned")
    assert mode(ctx.socket) == 0o700
    refute File.exists?(ctx.data)
  end

  test "init refuses a socket directory holding a residual pair or any other entry", ctx do
    File.mkdir_p!(ctx.socket)
    File.chmod!(ctx.socket, 0o700)
    Enum.each(socket_pair(ctx), &File.write!(&1, ""))

    assert_refused(run(ctx, ["init"]), "socket_dir_not_empty")
    assert Enum.all?(socket_pair(ctx), &File.exists?/1)
    refute File.exists?(ctx.data)

    Enum.each(socket_pair(ctx), &File.rm!/1)
    File.write!(Path.join(ctx.socket, "other"), "")
    assert_refused(run(ctx, ["init"]), "socket_dir_not_empty")
    assert File.exists?(Path.join(ctx.socket, "other"))
  end

  # ------------------------------------------------------------------ owned!/1 before start, status and stop

  test "a stale marker (its identifier differs from pg_controldata) refuses start, status and stop",
       ctx do
    seeded!(ctx)
    File.write!(ctx.marker, expected_marker(ctx, "7400000000000000999"))

    for command <- ["start", "status", "stop"] do
      assert_refused(run(ctx, [command]), "control_mismatch")
    end

    refute started?(ctx)
    refute signalled?(ctx)
  end

  test "a wide-mode, symlinked or extra-key marker refuses", ctx do
    seeded!(ctx)
    good = File.read!(ctx.marker)

    File.chmod!(ctx.marker, 0o644)
    assert_refused(run(ctx, ["start"]), "marker_not_owned")
    File.chmod!(ctx.marker, 0o600)

    File.write!(ctx.marker, String.replace(good, ~s(}\n), ~s(,"extra":1}\n)))
    assert_refused(run(ctx, ["start"]), "marker_invalid")
    File.write!(ctx.marker, good)

    moved = ctx.marker <> ".real"
    File.rename!(ctx.marker, moved)
    File.ln_s!(moved, ctx.marker)
    assert_refused(run(ctx, ["start"]), "marker_not_owned")

    refute started?(ctx)
  end

  test "a marker naming another binary refuses", ctx do
    seeded!(ctx)
    other = String.replace(File.read!(ctx.marker), ctx.bin, "/nix/store/other-postgresql/bin")
    File.write!(ctx.marker, other)
    assert_refused(run(ctx, ["start"]), "binary_mismatch")
    refute started?(ctx)
  end

  test "a wide-mode or symlinked data directory refuses", ctx do
    seeded!(ctx)
    File.chmod!(ctx.data, 0o755)
    assert_refused(run(ctx, ["start"]), "data_dir_not_owned")
    File.chmod!(ctx.data, 0o700)

    moved = ctx.data <> ".real"
    File.rename!(ctx.data, moved)
    File.ln_s!(moved, ctx.data)
    assert_refused(run(ctx, ["start"]), "data_dir_not_owned")
    refute started?(ctx)
  end

  test "Q2: start, status and stop never create a missing socket directory", ctx do
    seeded!(ctx)
    File.rmdir!(ctx.socket)

    for command <- ["start", "status", "stop"] do
      assert_refused(run(ctx, [command]), "socket_dir_not_owned")
      refute File.exists?(ctx.socket), "#{command} created the socket directory"
    end

    refute started?(ctx)
  end

  test "a wide-mode, symlinked or foreign-owned socket directory refuses start", ctx do
    seeded!(ctx)
    File.chmod!(ctx.socket, 0o755)
    assert_refused(run(ctx, ["start"]), "socket_dir_not_owned")
    File.chmod!(ctx.socket, 0o700)

    put_state!(ctx, "foreign", ctx.socket <> "\n")
    assert_refused(run(ctx, ["start"]), "socket_dir_not_owned")
    File.rm!(Path.join(ctx.state, "foreign"))

    File.rmdir!(ctx.socket)
    target = Path.join(ctx.base, "elsewhere")
    File.mkdir_p!(target)
    File.chmod!(target, 0o700)
    File.ln_s!(target, ctx.socket)
    assert_refused(run(ctx, ["start"]), "socket_dir_not_owned")

    refute started?(ctx)
  end

  # ------------------------------------------------------------------ start preconditions

  test "a residual socket pair refuses start and is never removed or adopted", ctx do
    seeded!(ctx)
    Enum.each(socket_pair(ctx), &File.write!(&1, "residual"))
    assert_refused(run(ctx, ["start"]), "socket_pair_present")
    assert Enum.all?(socket_pair(ctx), &(File.read!(&1) == "residual"))
    refute started?(ctx)

    File.rm!(List.last(socket_pair(ctx)))
    assert_refused(run(ctx, ["start"]), "socket_pair_present")
    refute started?(ctx)
  end

  test "a stale postmaster.pid with no server: pg_ctl reports not running, then the pair check applies",
       ctx do
    seeded!(ctx)
    File.write!(Path.join(ctx.data, "postmaster.pid"), "99999\n")
    Enum.each(socket_pair(ctx), &File.write!(&1, ""))
    assert_refused(run(ctx, ["start"]), "socket_pair_present")
    refute started?(ctx)
    assert Enum.any?(calls(ctx), &String.starts_with?(&1, "pg_ctl status"))

    Enum.each(socket_pair(ctx), &File.rm!/1)
    assert_ok(run(ctx, ["start"]), "start")
  end

  test "a TCP listener on 5541 refuses start", ctx do
    seeded!(ctx)

    put_state!(
      ctx,
      "lsof_out",
      "COMMAND PID USER FD TYPE\npostgres 1 x 7u IPv4 TCP *:5541 (LISTEN)\n"
    )

    before = snapshot(ctx)
    assert_refused(run(ctx, ["start"]), "tcp_listener_present")
    refute started?(ctx)
    refute signalled?(ctx)
    assert snapshot(ctx) == before
  end

  test "control: lsof's documented no-match result (exit 1, no output) admits start", ctx do
    seeded!(ctx)
    assert_ok(run(ctx, ["start"]), "start")
    assert started?(ctx)
  end

  # Codex S4 bounded review R1: an unavailable or failed observation is not
  # proof of an empty listener set. Each refuses with a fixed code before
  # pg_ctl start, prints no raw diagnostics, signals nothing and changes no
  # file under the cluster roots.
  @probe_failures [
    {"an error with diagnostics and no listing (exit 1)",
     [lsof_rc: "1", lsof_err: "lsof: WARNING: synthetic-probe-diagnostic\n"]},
    {"another status with empty output (exit 2)", [lsof_rc: "2"]},
    {"an unavailable probe status (exit 126)", [lsof_rc: "126"]},
    {"a not-found probe status (exit 127)", [lsof_rc: "127"]},
    {"death by a signal", [lsof_signal: ""]},
    {"success with an empty listing (exit 0)", [lsof_rc: "0"]},
    {"a listing on a failed status (exit 1)",
     [lsof_rc: "1", lsof_out: "postgres 1 x 7u IPv4 TCP *:5541 (LISTEN)\n"]}
  ]

  for {label, state} <- @probe_failures do
    test "a failed listener probe refuses start before pg_ctl: #{label}", ctx do
      seeded!(ctx)

      for {name, value} <- unquote(state),
          do: put_state!(ctx, Atom.to_string(name), value)

      before = snapshot(ctx)
      result = run(ctx, ["start"])
      assert_refused(result, "listener_probe_failed")
      refute result.out =~ "synthetic-probe-diagnostic"
      refute started?(ctx)
      refute signalled?(ctx)
      assert snapshot(ctx) == before
    end
  end

  test "a probe that cannot be executed refuses start before pg_ctl", ctx do
    seeded!(ctx)
    File.chmod!(Path.join(ctx.bin, "lsof"), 0o644)
    before = snapshot(ctx)
    assert_refused(run(ctx, ["start"]), "lsof_missing")
    refute started?(ctx)
    refute signalled?(ctx)
    assert snapshot(ctx) == before
  end

  test "an already running cluster refuses start", ctx do
    running!(ctx)
    assert_refused(run(ctx, ["start"]), "already_running")
  end

  # ------------------------------------------------------------------ live identity before signalling

  test "a wrong live system identifier refuses status and stop; nothing is signalled", ctx do
    running!(ctx)
    put_state!(ctx, "live_sysid", "7400000000000000777\n")

    assert_refused(run(ctx, ["status"]), "live_identity_mismatch")
    assert_refused(run(ctx, ["stop"]), "live_identity_mismatch")
    refute signalled?(ctx)
  end

  test "a wrong live data directory refuses status and stop; nothing is signalled", ctx do
    running!(ctx)
    put_state!(ctx, "live_datadir", "/some/other/pgdata\n")

    assert_refused(run(ctx, ["status"]), "live_identity_mismatch")
    assert_refused(run(ctx, ["stop"]), "live_identity_mismatch")
    refute signalled?(ctx)
  end

  test "stop refuses when the cluster is not running; nothing is signalled", ctx do
    seeded!(ctx)
    assert_refused(run(ctx, ["stop"]), "not_running")
    refute signalled?(ctx)
  end

  test "an unknown command is a usage refusal", ctx do
    assert script_present?(), "bin/prototype-pg does not exist"
    assert_refused(run(ctx, ["drop"]), "usage")
    assert_refused(run(ctx, []), "usage")
  end

  # ------------------------------------------------------------------ ruling 3: project facts

  test "ruling 3: the doc and the pinned constants agree (5520 ordinary, 5541 prototype socket)" do
    assert File.regular?(@doc_path), "docs/product/d237/prototype-runtime.md does not exist"
    doc = File.read!(@doc_path)

    assert doc =~ "5520" and doc =~ ~r/5520[^\n]*ordinary/i,
           "the doc does not state 5520 as the ordinary service"

    assert doc =~ ~r/5541[^\n]*(socket|prototype)/i,
           "the doc does not state 5541 as the prototype socket endpoint"

    assert doc =~ @pinned_socket and doc =~ @pinned_root
    assert doc =~ "listen_addresses = ''"

    assert script_present?(), "bin/prototype-pg does not exist"
    script = File.read!(@script)

    assert script =~ "readonly PORT='5541'" and
             script =~ "readonly SOCKET_DIR='#{@pinned_socket}'"

    runtime = File.read!(@runtime_exs)

    assert runtime =~ @pinned_socket and runtime =~ "5541",
           "config/runtime.exs has no prototype block with the socket directory and port (S1)"
  end
end
