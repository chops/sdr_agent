defmodule SdrAgent.Test.PostgresLogSinkCanaries do
  @moduledoc """
  5b sink test client (plan r2 sections 5.3, 5.4 and 7, as amended by r3–r6
  and R6-1): the Postgrex canaries and the audit shim, driven only by
  `test/postgres_log_settings/sink-test.sh` through
  `test/postgres_log_settings/sink_canaries.exs`.

  It never starts `:sdr_agent` or its Repo. It connects only over the
  manifest's owned unix socket directory (`socket_dir` plus `port`), to a
  database in the manifest's allowlist, and proves the server identity
  (data directory, config file, socket directory, port, a UDS connection,
  the backend's parent being the verified postmaster, the postmaster start
  time) before any mutation. It refuses ambient `PG*`/`DATABASE_URL`
  configuration. It never prints a message, an error struct or a marker:
  results are written to a private JSON file as SQLSTATE codes, severities
  and routines only.

  Modes (`--mode`): `prepare`, `canaries`, `audit`, `a_ext_setup`,
  `identity`, `db_exists`. Exit status: 0 ok, 2 refusal, 3 hold, 4 fail.
  """

  alias SdrAgent.Test.PostgresLogAudit, as: Audit
  alias SdrAgent.Test.PostgresLogContract, as: Contract

  @ambient ~w(PGHOST PGPORT PGDATA PGUSER PGDATABASE PGPASSWORD PGSERVICE PGSERVICEFILE
              PGSYSCONFDIR PGPASSFILE DATABASE_URL PC_SOCKET_PATH)
  @forbidden_ports [5520, 4120]

  @p_deltas %{
    "log_error_verbosity" => {"default", ""},
    "log_min_error_statement" => {"error", ""},
    "log_parameter_max_length" => {"-1", "B"},
    "log_parameter_max_length_on_error" => {"-1", "B"},
    "log_min_duration_statement" => {"100", "ms"}
  }
  @a_deltas %{"shared_preload_libraries" => {"auto_explain", ""}}

  defmodule Shim do
    @moduledoc """
    The audit's `repo` argument: `query!/2` over the one pinned Postgrex
    connection of the calling process, so all five inventory sources come
    from one backend (plan r2 5.4).
    """

    @doc "Runs `sql` on the pinned connection."
    def query!(sql, params), do: Postgrex.query!(Process.get(:sink_conn), sql, params)
  end

  defmodule Halt do
    @moduledoc "A controlled stop with an exit status and a reason (no marker text)."
    defexception [:status, :reason]

    @impl true
    def message(%{status: status, reason: reason}), do: "#{status}: #{reason}"
  end

  @doc "Entry point: parses `argv`, runs one mode, writes the result file and halts."
  def main(argv) do
    silence_logger()
    opts = parse(argv)
    out = Map.fetch!(opts, "out")

    {status, result} =
      try do
        guard_environment!()
        manifest = read_json!(Map.fetch!(opts, "manifest"))
        {0, run_mode(Map.fetch!(opts, "mode"), manifest, opts)}
      rescue
        e in Halt -> {e.status, %{"halt" => e.reason}}
        # Never the exception message: it can carry a marker.
        e -> {3, %{"halt" => "unexpected #{inspect(e.__struct__)}"}}
      end

    write_private!(out, Map.put(result, "status", status))
    System.halt(status)
  end

  # -- guards ----------------------------------------------------------------

  defp silence_logger do
    Logger.configure(level: :none)
    _ = :logger.remove_handler(:default)
    :ok
  end

  defp guard_environment! do
    present = Enum.filter(@ambient, &System.get_env/1)
    if present != [], do: halt!(2, "ambient environment present: #{Enum.join(present, ",")}")

    if Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :sdr_agent end),
      do: halt!(2, ":sdr_agent is started")

    if Process.whereis(SdrAgent.Repo), do: halt!(2, "SdrAgent.Repo is registered")
    {:ok, _} = Application.ensure_all_started(:postgrex)
    :ok
  end

  defp halt!(status, reason), do: raise(Halt, status: status, reason: reason)

  # -- modes -------------------------------------------------------------------

  defp run_mode("identity", m, opts) do
    with_conn(m, "postgres", fn conn -> %{"identity" => identity!(conn, m, opts, "postgres")} end)
  end

  defp run_mode("prepare", m, opts) do
    creates = opts |> Map.get("create", "") |> String.split(",", trim: true)
    Enum.each(creates, &allowed_db!(m, &1))

    created =
      with_conn(m, "postgres", fn conn ->
        id = identity!(conn, m, opts, "postgres")
        listener_reproof!(opts)
        Enum.each(creates, fn db -> Postgrex.query!(conn, ~s(CREATE DATABASE "#{db}"), []) end)
        %{"identity" => id, "created" => creates}
      end)

    tables =
      case Map.get(opts, "canary_db") do
        nil -> nil
        db -> with_conn(m, db, fn conn -> create_canary_tables!(conn, m, opts, db) end)
      end

    Map.put(created, "canary_tables", tables)
  end

  defp run_mode("canaries", m, opts) do
    db = Map.fetch!(opts, "db")
    markers = Map.fetch!(read_json!(Map.fetch!(opts, "markers")), "markers")

    results =
      with_conn(m, db, fn conn ->
        _ = identity!(conn, m, opts, db)

        [c1(conn, markers), c2(conn, markers), c3(conn, markers), c4(conn, markers)] ++
          [c5(conn, markers), c6(conn, markers), c7(conn, markers)]
      end)

    results = results ++ [c8(m, markers)]
    failed = Enum.reject(results, & &1["ok"])

    if failed != [],
      do: halt!(4, "canary outcome mismatch: #{Enum.map_join(failed, ",", & &1["kind"])}")

    %{"canaries" => results}
  end

  defp run_mode("a_ext_setup", m, opts) do
    with_conn(m, "a_ext", fn conn ->
      _ = identity!(conn, m, opts, "a_ext")
      Postgrex.query!(conn, "CREATE EXTENSION pg_stat_statements", [])
      %{"a_ext" => "pg_stat_statements created"}
    end)
  end

  defp run_mode("audit", m, opts) do
    db = Map.fetch!(opts, "db")
    expect = Map.fetch!(opts, "expect")

    with_conn(m, db, fn conn ->
      _ = identity!(conn, m, opts, db)
      if expect == "p_load", do: Postgrex.query!(conn, "LOAD 'auto_explain'", [])
      Process.put(:sink_conn, conn)
      inv = Audit.inventory(Shim)
      cls = Audit.classify(inv)
      problems = audit_expectation(expect, inv, cls)

      if problems != [],
        do: halt!(4, "audit expectation #{expect} failed: #{Enum.join(problems, "; ")}")

      %{"audit" => expect, "sources" => jsonable(cls.sources), "verdict" => cls.verdict}
    end)
  end

  defp run_mode("db_exists", m, opts) do
    name = Map.fetch!(opts, "name")

    with_conn(m, "postgres", fn conn ->
      _ = identity!(conn, m, opts, "postgres")

      %{rows: [[n]]} =
        Postgrex.query!(conn, "SELECT count(*) FROM pg_database WHERE datname = $1", [name])

      %{"exists" => n > 0}
    end)
  end

  defp run_mode(other, _m, _opts), do: halt!(64, "unknown mode #{other}")

  # -- connection --------------------------------------------------------------

  defp conn_opts(m, db) do
    port = Map.fetch!(m, "port")
    if port in @forbidden_ports, do: halt!(2, "forbidden port")

    [
      socket_dir: Map.fetch!(m, "pg_socket_dir"),
      port: port,
      database: db,
      username: get_in(m, ["launch_env", "USER"]),
      pool_size: 1,
      backoff_type: :stop,
      show_sensitive_data_on_connection_error: false
    ]
  end

  defp allowed_db!(m, db) do
    if db in Map.fetch!(m, "db_allow"), do: :ok, else: halt!(2, "database not in allowlist")
  end

  defp with_conn(m, db, fun) do
    allowed_db!(m, db)
    {:ok, conn} = Postgrex.start_link(conn_opts(m, db))

    try do
      fun.(conn)
    after
      GenServer.stop(conn, :normal, 10_000)
    end
  end

  # -- identity (r2 5.3 as amended by r3 1.3) ---------------------------------

  @identity_sql """
  SELECT current_setting('data_directory'), current_setting('config_file'),
         current_setting('unix_socket_directories'), current_setting('port'),
         inet_server_addr() IS NULL, pg_backend_pid(),
         extract(epoch FROM pg_postmaster_start_time())::float8,
         (pg_control_system()).system_identifier::text, current_database()
  """

  defp identity!(conn, m, opts, db) do
    [[ddir, cfile, sdir, port, uds?, bpid, start, sysid, cdb]] =
      case Postgrex.query(conn, @identity_sql, []) do
        {:ok, %{rows: rows}} -> rows
        {:error, _} -> halt!(3, "identity query failed")
      end

    checks = [
      {"data_directory", ddir == m["pgdata"]},
      {"config_file", cfile == m["pgdata"] <> "/postgresql.conf"},
      {"unix_socket_directories", sdir == m["pg_socket_dir"]},
      {"port", port == Integer.to_string(m["port"])},
      {"uds_connection", uds? == true},
      {"current_database", cdb == db},
      {"backend_parent", backend_parent(bpid) == Map.fetch!(opts, "postmaster_pid")},
      {"postmaster_start", start_close?(start, Map.fetch!(opts, "postmaster_birth_us"))}
    ]

    bad = for {name, false} <- checks, do: name
    if bad != [], do: halt!(2, "identity mismatch: #{Enum.join(bad, ",")}")
    sysid_check!(opts, sysid)
    settings_check!(conn, m)

    %{
      "system_identifier" => sysid,
      "backend_pid" => bpid,
      "checks" => Enum.map(checks, &elem(&1, 0))
    }
  end

  defp backend_parent(pid) do
    case System.cmd("/bin/ps", ["-o", "ppid=", "-p", Integer.to_string(pid)],
           env: [{"LC_ALL", "C"}]
         ) do
      {out, 0} -> String.trim(out)
      _ -> halt!(3, "cannot read backend parent")
    end
  end

  defp start_close?(start, birth_us) do
    birth = String.to_integer(birth_us) / 1_000_000
    abs(start - birth) <= 2.0
  end

  defp sysid_check!(opts, sysid) do
    case Map.get(opts, "sysid_file") do
      nil -> :ok
      path -> sysid_compare!(path, File.exists?(path), sysid)
    end
  end

  defp sysid_compare!(path, false, sysid), do: write_private_text!(path, sysid)

  defp sysid_compare!(path, true, sysid) do
    if String.trim(File.read!(path)) != sysid,
      do: halt!(2, "system identifier changed"),
      else: :ok
  end

  defp settings_check!(conn, m) do
    names = Contract.names() ++ Map.keys(@p_deltas)
    expected = expected_settings(Map.fetch!(m, "kind"))

    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT name, setting, coalesce(unit, ''), source, pending_restart, coalesce(sourcefile, '') " <>
          "FROM pg_settings WHERE name = ANY($1)",
        [Enum.uniq(names)]
      )

    conf = Map.fetch!(m, "pgdata") <> "/postgresql.conf"

    bad =
      for [name, setting, unit, source, pending, sourcefile] <- rows,
          want = Map.get(expected, name),
          want != nil,
          not ({setting, unit} == want and source == "configuration file" and not pending and
                 sourcefile == conf),
          do: name

    if bad != [], do: halt!(2, "settings not as reviewed: #{Enum.join(bad, ",")}")
    :ok
  end

  defp expected_settings(kind) do
    base = Contract.effective()

    case kind do
      "P" -> Map.merge(base, @p_deltas)
      "A" -> Map.merge(base, @a_deltas)
      _ -> base
    end
  end

  defp listener_reproof!(opts) do
    py = Map.fetch!(opts, "py")
    watch = Map.fetch!(opts, "watch")

    args = [
      "-I",
      watch,
      "listener-proof",
      "--manifest",
      Map.fetch!(opts, "manifest"),
      "--state",
      Map.fetch!(opts, "state")
    ]

    case System.cmd(py, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      _ -> halt!(3, "listener re-proof failed before mutation")
    end
  end

  defp create_canary_tables!(conn, m, opts, db) do
    _ = identity!(conn, m, opts, db)
    Postgrex.query!(conn, "CREATE TABLE cu (k text PRIMARY KEY)", [])
    Postgrex.query!(conn, "CREATE TABLE cc (v text CHECK (v = 'x'))", [])
    Postgrex.query!(conn, "CREATE TABLE cz (v int)", [])
    Postgrex.query!(conn, "INSERT INTO cz VALUES (0)", [])
    %{"db" => db}
  end

  # -- canaries (r2 7.2) ------------------------------------------------------

  defp c1(conn, mk) do
    first = Postgrex.query(conn, "INSERT INTO cu VALUES (md5($1))", [mk["S_u"]])
    second = Postgrex.query(conn, "INSERT INTO cu VALUES (md5($1))", [mk["S_u"]])

    case first do
      {:ok, _} -> expect_error("C1", second, :unique_violation, "ERROR")
      _ -> %{"kind" => "C1", "ok" => false, "why" => "first insert failed"}
    end
  end

  defp c2(conn, mk),
    do:
      expect_error(
        "C2",
        Postgrex.query(conn, "INSERT INTO cc VALUES (md5($1))", [mk["S_c"]]),
        :check_violation,
        "ERROR"
      )

  defp c3(conn, mk),
    do:
      expect_error(
        "C3",
        Postgrex.query(conn, "SELECT 1/0, '#{hex!(mk["L"])}'", []),
        :division_by_zero,
        "ERROR"
      )

  defp c4(conn, mk),
    do:
      expect_error(
        "C4",
        Postgrex.query(conn, "SELECT ($1::text)::int", [mk["E"]]),
        :invalid_text_representation,
        "ERROR"
      )

  defp c5(conn, mk),
    do:
      expect_error(
        "C5",
        Postgrex.query(conn, "SELECT $1::text, 1/v FROM cz", [mk["Q"]]),
        :division_by_zero,
        "ERROR"
      )

  defp c6(conn, mk), do: slow("C6", conn, "SELECT pg_sleep(0.3), '#{hex!(mk["T"])}'", [], mk["T"])
  defp c7(conn, mk), do: slow("C7", conn, "SELECT pg_sleep(0.3), $1::text", [mk["D"]], mk["D"])

  defp slow(kind, conn, sql, params, marker) do
    t0 = System.monotonic_time(:millisecond)
    res = Postgrex.query(conn, sql, params)
    elapsed = System.monotonic_time(:millisecond) - t0

    case res do
      {:ok, %{rows: [[_, ^marker]]}} ->
        %{"kind" => kind, "ok" => elapsed >= 300, "elapsed_ms" => elapsed}

      _ ->
        %{"kind" => kind, "ok" => false, "why" => "unexpected result shape"}
    end
  end

  # C8: a FATAL at connection time. `Postgrex.Protocol.connect/1` returns the
  # server's ErrorResponse directly ([A]: proven at P-E1, where F must reach
  # the collector; a client API mismatch fails closed).
  defp c8(m, mk) do
    opts =
      m
      |> conn_opts_unchecked(hex!(mk["F"]))
      |> Keyword.put_new(:types, Postgrex.DefaultTypes)

    result =
      try do
        Postgrex.Protocol.connect(opts)
      rescue
        _ -> :client_api_unavailable
      end

    case result do
      {:error, %Postgrex.Error{postgres: %{code: :invalid_catalog_name} = pg}} ->
        %{
          "kind" => "C8",
          "ok" => pg[:severity] == "FATAL",
          "code" => "3D000",
          "severity" => pg[:severity],
          "routine" => pg[:routine],
          "server_origin" => true
        }

      _ ->
        %{"kind" => "C8", "ok" => false, "why" => "no server FATAL 3D000"}
    end
  end

  defp conn_opts_unchecked(m, db) do
    m |> conn_opts("postgres") |> Keyword.put(:database, db)
  end

  defp expect_error(kind, {:error, %Postgrex.Error{postgres: %{code: code} = pg}}, want, severity) do
    %{
      "kind" => kind,
      "ok" => code == want and pg[:severity] == severity,
      "code" => pg[:pg_code],
      "severity" => pg[:severity],
      "routine" => pg[:routine],
      "server_origin" => true
    }
  end

  defp expect_error(kind, _other, _want, _severity),
    do: %{
      "kind" => kind,
      "ok" => false,
      "why" => "no server-origin error",
      "server_origin" => false
    }

  defp hex!(value) do
    if is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{32}\z/),
      do: value,
      else: halt!(2, "marker is not 32 lowercase hex")
  end

  # -- audit expectations (r2 7.3, r3 3.4) ------------------------------------

  defp audit_expectation("pass", _inv, cls) do
    bad = for {k, v} <- cls.sources, v != {:pass, []}, do: Atom.to_string(k)

    if cls.verdict == :pass and bad == [],
      do: [],
      else: ["not all sources pass: #{Enum.join(bad, ",")}"]
  end

  defp audit_expectation("p_load", inv, cls) do
    s = cls.sources

    []
    |> need(auto_explain_loaded?(s.loaded_modules), "loaded_modules")
    |> need(s.preloads == {:pass, []} and preloads_empty?(inv), "preloads")
    |> need(s.extensions == {:pass, []}, "extensions")
    |> need(auto_explain_gucs?(s.dotted_gucs), "dotted_gucs")
    |> need(s.dynamic_library_path == {:pass, []}, "dynamic_library_path")
  end

  defp audit_expectation(expect, _inv, cls) when expect in ["a_ext", "a_plain"] do
    s = cls.sources

    ext_ok =
      if expect == "a_ext",
        do: match?({:fail, [{{"pg_stat_statements", _}, :logging}]}, s.extensions),
        else: s.extensions == {:pass, []}

    []
    |> need(ext_ok, "extensions")
    |> need(
      match?({:fail, [{{"shared_preload_libraries", "auto_explain"}, :logging}]}, s.preloads),
      "preloads"
    )
    |> need(auto_explain_loaded?(s.loaded_modules), "loaded_modules")
    |> need(auto_explain_gucs?(s.dotted_gucs), "dotted_gucs")
    |> need(s.dynamic_library_path == {:pass, []}, "dynamic_library_path")
  end

  defp audit_expectation(other, _inv, _cls), do: ["unknown expectation #{other}"]

  defp need(acc, true, _name), do: acc
  defp need(acc, false, name), do: acc ++ [name]

  defp auto_explain_loaded?(
         {:fail, [{{"auto_explain", _version, "auto_explain.dylib"}, :logging}]}
       ),
       do: true

  defp auto_explain_loaded?(_), do: false

  defp auto_explain_gucs?({:fail, findings}) when findings != [] do
    Enum.all?(findings, fn {name, reason} ->
      reason == :logging and String.starts_with?(name, "auto_explain.")
    end)
  end

  defp auto_explain_gucs?(_), do: false

  defp preloads_empty?(%{preloads: %{} = p}), do: Enum.all?(Map.values(p), &(&1 == ""))
  defp preloads_empty?(_), do: false

  # -- io ----------------------------------------------------------------------

  defp parse(argv), do: parse(argv, %{})
  defp parse([], acc), do: acc

  defp parse(["--" <> key, value | rest], acc),
    do: parse(rest, Map.put(acc, String.replace(key, "-", "_"), value))

  defp parse(_other, _acc), do: halt!(64, "usage")

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp write_private!(path, map), do: write_private_text!(path, Jason.encode!(jsonable(map)))

  defp write_private_text!(path, text) do
    {:ok, io} = :file.open(String.to_charlist(path), [:write, :exclusive, :binary])
    :ok = :file.write(io, text)
    :ok = :file.close(io)
    File.chmod!(path, 0o600)
  end

  defp jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> jsonable()
  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(%{__struct__: _} = s), do: inspect(s.__struct__)
  defp jsonable(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  defp jsonable(x), do: x
end
