defmodule SdrAgent.Test.ResolverRehearsal do
  @moduledoc """
  The R0-05 resolver browser rehearsal (test builds only; run through `mix
  sdr.demo.rehearse_resolver`, owner-run after review). A **synthetic**
  rehearsal: it lets the owner see the blocked-switch resolver
  (`#resolve-blocked`, `#resolution-form`) in a real browser over one real
  stored `:blocked` switch built by `SdrAgent.Test.ResolverRehearsal.Fixture`
  (the reviewed `ResolveHarness.survivor!/1` scenario on the fake CLI). It
  is not runtime cleanup proof and not the R0-06 real-profile trial.

  **The command** (`run/2`) runs its phases in this order; every refusal
  raises (`Mix.Error`, non-zero exit) before the effects that follow it:

    1. checks with no effect: `plan/1` (build, environment, Repo, target
       database, port, email), `check_idle/1` (no SdrAgent application,
       Repo, endpoint or profile tree already runs in this VM), the port is
       free, `check_storage/2` (the target must be **absent**), the built
       assets, then the typed password;
    2. the VM-local configuration (`apply!/1`);
    3. the exclusive `CREATE DATABASE` (`check_created/2`: any collision,
       e.g. a database that appeared after the check, is refused and never
       adopted, migrated or written);
    4. the migrations, only after the connected database (`SELECT
       current_database()`) is the target and holds no `schema_migrations`;
    5. the app start, then `verify_started/1` (the connected database again,
       Oban `testing: :manual`, the Fake provider, no ClaudeCLI server);
    6. the admin and the fixture; then **only if** every counter equals its
       baseline and no launch was admitted, the report and the console;
    7. `STOP` + Enter, or the end of terminal input, stops the fixture; the
       stop is always run once a fixture exists (also after a report, IO or
       counter failure), and the command fails unless the stop is clean, the
       final counters equal the baseline and no launch was admitted. A
       failure names the original error and any cleanup problem.

  There is no reuse path: an existing target database is never touched (use
  a new `MIX_TEST_PARTITION`), and nothing is ever dropped or reset.
  Ctrl-C and SIGTERM end the VM without the stop: such a run is interrupted
  and unknown, not clean-stop evidence.

  **Guards.** `MIX_ENV=test` with the ClaudeCLI test seams; no
  `DATABASE_URL`, no `SDR_CLAUDE_CLI_BIN`, `SDR_MODEL_PROVIDER` unset or
  `fake`; the Repo on the local devenv Postgres (5520, no `:url`); the target
  is exactly the configured `sdr_agent_test<partition>` plus `_rehearsal`,
  lowercase letters, digits and `_` only, at most 63 bytes (PostgreSQL's
  identifier limit, so it is never truncated into another name), never a
  dev, calibration or demo name; a loopback port, free, never 4120 (dev),
  4122 (demo smoke) or 4124 (calibration console).

  **The admin and its password.** The ordinary first-admin bootstrap; the
  owner signs in through the ordinary sign-in page. The password must be a
  fresh synthetic one (never a reused credential), typed without echo (at
  least 16 characters). It is held in this VM's memory (IO and
  authentication) and stored only as its bcrypt hash; it is never in the
  report, a log line, argv, the environment or a stored row in plaintext,
  and a bootstrap refusal names only the error's type. The endpoint's
  `secret_key_base` and the token signing secret are random per run, in
  memory only.

  **Subprocesses.** The report's `git` commands run with
  `SdrAgent.ChildEnv.cmd([])` (no inherited secret or other name beyond the
  base allowlist).
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.Repo
  alias SdrAgent.Test.ResolverRehearsal.Fixture

  @ip {127, 0, 0, 1}
  @db_port 5520
  @default_port 4123
  @default_email "rehearsal-admin@example.test"
  @local_hosts ["localhost", "127.0.0.1"]
  @refused_ports %{
    4120 => "the owner's dev server port",
    4122 => "the demo smoke server port",
    4124 => "the calibration console port"
  }
  @refused_databases ~w(sdr_agent_dev sdr_agent_calibration sdr_agent_prod sdr_agent)
  @database ~r/\Asdr_agent_test[a-z0-9_]*_rehearsal\z/
  @max_identifier 63
  @min_password 16
  @switches [port: :integer, email: :string]
  @label "SYNTHETIC R0-05 RESOLVER REHEARSAL (fake CLI, test build; not runtime cleanup " <>
           "proof, not the R0-06 trial)"

  @doc "The label printed on every report block."
  def label, do: @label

  ## The command (`mix sdr.demo.rehearse_resolver`)

  @doc """
  The owner-run command (see the moduledoc for the phase order). `deps` are
  the effects, in a map with every key of `deps/0`; tests pass stubs.
  Returns `:ok` after a clean stop; every other outcome raises `Mix.Error`.
  """
  def run(argv, deps \\ deps()) do
    plan = ok!(plan(deps.config.(argv)))
    ok!(check_idle(deps.running.()))
    ok!(deps.port_free.(plan.port))
    ok!(check_storage(plan, deps.storage_status.(plan.repo)))
    ok!(deps.assets.())

    deps.info.(
      "#{@label}\nfixture admin #{plan.email}; database #{plan.database}; port #{plan.port}"
    )

    password = ok!(check_password(deps.read_password.()))

    deps.apply.(plan)
    ok!(check_created(plan, deps.create.(plan)))
    ok!(deps.migrate.(plan))
    deps.start_app.()
    ok!(deps.verify_started.(plan))

    ctx = deps.create_admin.(plan.email, password)
    session = deps.start_fixture.(ctx)
    serve(plan, session, deps)
  end

  @doc "The real effects of `run/2`."
  def deps do
    %{
      config: &current/1,
      running: &running/0,
      port_free: &check_port_free/1,
      storage_status: fn repo -> Repo.__adapter__().storage_status(repo) end,
      assets: &SdrAgent.CalibrationConsole.check_assets/0,
      read_password: fn -> read_password(:standard_io, &raw_input/1) end,
      apply: &apply!/1,
      create: &create/1,
      migrate: &migrate/1,
      start_app: fn -> Mix.Task.run("app.start") end,
      verify_started: &verify_started/1,
      create_admin: &Fixture.create_admin!/2,
      start_fixture: &Fixture.start!/1,
      report: &report/2,
      await_stop: fn -> await_stop(:stdio) end,
      stop_fixture: &Fixture.stop/1,
      counters: &Fixture.counters/0,
      info: &info/1
    }
  end

  # Once a fixture exists its stop always runs; the command then fails
  # unless everything is confirmed.
  defp serve(plan, session, deps) do
    result =
      guarded(fn ->
        ok!(check_no_calls(session.before, session.after, session.launches, "after the build"))
        Enum.each(deps.report.(plan, session), deps.info)
        deps.info.(instructions(plan, session))
        deps.await_stop.()
      end)

    outcome =
      case guarded(fn -> deps.stop_fixture.(session) end) do
        {:ok, outcome} -> outcome
        {:error, why} -> %{problems: ["the stop itself failed: #{why}"], launches: nil}
      end

    final = guarded(deps.counters)
    finish!(plan, session, result, outcome, final, deps)
  end

  @doc false
  def finish!(plan, session, result, outcome, final, deps) do
    problems =
      result_problems(result) ++
        Enum.map(outcome.problems, &"cleanup unconfirmed: #{&1}") ++
        final_problems(session.before, final, outcome.launches)

    stop_reason =
      case result do
        {:ok, reason} -> reason
        {:error, _} -> :failed
      end

    guarded(fn ->
      deps.info.("#{@label}\nstopped (#{inspect(stop_reason)}): #{inspect(outcome)}")
      deps.info.("counters at stop: #{inspect(final)}")
      deps.info.("database #{plan.database} kept (never dropped)")
    end)

    case problems do
      [] ->
        deps.info.("clean stop: every owned process joined, counters unchanged, 0 launches")
        :ok

      _ ->
        Mix.raise(
          "rehearsal FAILED (not clean-stop evidence; database kept): " <>
            Enum.join(problems, "; ")
        )
    end
  end

  defp result_problems({:ok, _reason}), do: []
  defp result_problems({:error, why}), do: ["the rehearsal failed: #{why}"]

  defp final_problems(before, {:ok, counters}, launches) do
    case check_no_calls(before, counters, launches, "at stop") do
      :ok -> []
      {:error, why} -> [why]
    end
  end

  defp final_problems(_before, {:error, why}, _launches),
    do: ["the final counters are unreadable: #{why}"]

  @doc """
  `:ok` when `counters` equal the `before` baseline and the recorder counted
  zero launch admissions; otherwise the refusal (an unavailable recorder,
  `nil`, is a refusal).
  """
  def check_no_calls(before, counters, launches, moment) do
    cond do
      counters != before ->
        {:error, "counters changed #{moment}: #{inspect(before)} -> #{inspect(counters)}"}

      launches != 0 ->
        {:error, "launch admissions #{moment}: #{inspect(launches)} (expected 0)"}

      true ->
        :ok
    end
  end

  # `{:ok, value}` or `{:error, message}` for any raise, exit or throw.
  defp guarded(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:error, Fixture.describe(kind, reason)}
  end

  defp ok!({:ok, value}), do: value
  defp ok!(:ok), do: :ok
  defp ok!({:error, reason}), do: Mix.raise("mix sdr.demo.rehearse_resolver refuses: #{reason}")

  defp info(line), do: Mix.shell().info(line)

  @doc """
  Reads the password from `device` without echo (OTP's `io:get_password/1`,
  an Erlang device name such as `:standard_io`, run through `hide`); nil
  when nothing could be read (no terminal, raw mode refused, end of input).
  """
  def read_password(device, hide \\ fn read -> read.() end) do
    IO.write(
      "Type a fresh synthetic password for the fixture admin (16+ characters, not echoed): "
    )

    case hide.(fn -> :io.get_password(device) end) do
      line when is_list(line) -> List.to_string(line)
      line when is_binary(line) -> line
      _other -> nil
    end
  after
    IO.write("\n")
  end

  @doc """
  Runs `read` with standard input in raw mode, which `io:get_password/1`
  needs under `mix` (`-noshell` starts cooked, and cooked input refuses it
  with `{:error, :enotsup}`), then restores cooked mode for the `STOP`
  line. `{:error, reason}` when raw mode is unavailable (no terminal).
  """
  def raw_input(read) do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok ->
        try do
          read.()
        after
          :shell.start_interactive({:noshell, :cooked})
        end

      error ->
        error
    end
  end

  @doc """
  Waits for a line `STOP` on `device`: `:stop`, or `:eof` when its input
  ends or fails (the fixture is then stopped the same way).
  """
  def await_stop(device) do
    case IO.gets(device, "") do
      line when is_binary(line) ->
        if String.trim(line) == "STOP", do: :stop, else: await_stop(device)

      _eof_or_error ->
        :eof
    end
  end

  ## Effects (real)

  @doc "What already runs in this VM that the rehearsal must not reconfigure."
  def running do
    [
      {List.keymember?(Application.started_applications(), :sdr_agent, 0), "the sdr_agent app"},
      {is_pid(Process.whereis(Repo)), "SdrAgent.Repo"},
      {is_pid(Process.whereis(SdrAgentWeb.Endpoint)), "SdrAgentWeb.Endpoint"},
      {is_pid(Process.whereis(ProfileSupervisor)), "a model profile tree"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @doc false
  # The plan's configuration, for this VM only, before the app starts:
  # the rehearsal database on an ordinary pool, the loopback listener
  # (`Mix.Tasks.Sdr.Demo.Serve.endpoint/2`, HTTP/2 off), random in-memory
  # session and token secrets, Oban `testing: :manual`, the Fake provider.
  def apply!(plan) do
    Application.put_env(:sdr_agent, Repo, plan.repo)
    endpoint = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])

    Application.put_env(
      :sdr_agent,
      SdrAgentWeb.Endpoint,
      endpoint
      |> Keyword.delete(:https)
      |> Mix.Tasks.Sdr.Demo.Serve.endpoint(plan.port)
      |> Keyword.put(:secret_key_base, random_secret())
    )

    Application.put_env(:sdr_agent, :token_signing_secret, random_secret())
    oban = Application.get_env(:sdr_agent, Oban, [])
    Application.put_env(:sdr_agent, Oban, Keyword.put(oban, :testing, :manual))
    Application.put_env(:sdr_agent, :model_provider, Fake)
    Application.put_env(:sdr_agent, SdrAgentWeb.LiveRefresh, debounce_ms: 250)
  end

  defp random_secret, do: 48 |> :crypto.strong_rand_bytes() |> Base.encode64()

  # The exclusive create, only when the configuration the adapter will use
  # names exactly the plan's target.
  defp create(plan) do
    config = Repo.config()

    if Keyword.take(config, [:hostname, :port, :database]) ==
         Keyword.take(plan.repo, [:hostname, :port, :database]),
       do: Repo.__adapter__().storage_up(config),
       else: {:error, "the Repo configuration does not name #{plan.database}"}
  end

  # Migrations only on the connected target, and only while it is fresh.
  defp migrate(plan) do
    migrated =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        with :ok <- check_connected(plan, connected(repo)),
             :ok <- check_fresh(fresh?(repo)) do
          Ecto.Migrator.run(repo, :up, all: true)
          :ok
        end
      end)

    case migrated do
      {:ok, result, _apps} -> result
      {:error, reason} -> {:error, "could not start the Repo to migrate: #{inspect(reason)}"}
    end
  end

  defp connected(repo), do: repo.query!("SELECT current_database()").rows |> hd() |> hd()

  defp fresh?(repo),
    do: repo.query!("SELECT to_regclass('public.schema_migrations') IS NULL").rows == [[true]]

  defp verify_started(plan) do
    checks = [
      {connected(Repo) == plan.database, "the connected database is not #{plan.database}"},
      {Oban.config().testing == :manual, "Oban is not in testing: :manual"},
      {Application.get_env(:sdr_agent, :model_provider) == Fake, "the provider is not the Fake"},
      {is_nil(Process.whereis(ProfileSupervisor)), "a model profile tree runs"},
      {not ClaudeCLI.running?(ClaudeCLI.server()), "a ClaudeCLI server runs"}
    ]

    case for({false, why} <- checks, do: why) do
      [] -> :ok
      failures -> {:error, "after start: " <> Enum.join(failures, "; ")}
    end
  end

  defp instructions(plan, session) do
    """

    Open http://127.0.0.1:#{plan.port}/sign-in, sign in as #{plan.email}, open /admin.
    The blocked switch is #{session.switch.id}; its exact confirmation is
    STOPPED #{session.switch.id}
    Owner checks (synthetic rehearsal): open the resolver (#resolve-blocked); a focused
    mismatch clears the input; fresh typing persists; a later mismatch clears it again;
    the exact text submits under the same review; record only what you actually observe
    of the disabled and submitting states (uncertain is not induced).
    Type STOP and Enter here for the clean stop (end of input stops it too).
    Ctrl-C or SIGTERM end the VM without it: that run is interrupted, not clean-stop evidence.
    """
  end

  ## The plan and the guards (pure)

  @doc """
  The build's current configuration and the task's `argv`, as `plan/1`
  reads them.
  """
  def current(argv) do
    %{
      mix_env: Mix.env(),
      test_seams?: Application.get_env(:sdr_agent, :claude_cli_test_seams, false) == true,
      model_provider: Application.get_env(:sdr_agent, :model_provider),
      repo: Application.get_env(:sdr_agent, Repo, []),
      env:
        Map.new(~w(DATABASE_URL SDR_MODEL_PROVIDER SDR_CLAUDE_CLI_BIN), &{&1, System.get_env(&1)}),
      argv: argv
    }
  end

  @doc "The rehearsal's plan from `config` (see `current/1`), or the refusal."
  def plan(config) do
    with :ok <- check_build(config),
         :ok <- check_env(config.env),
         :ok <- check_provider(config.model_provider),
         {:ok, opts} <- parse(config.argv),
         {:ok, database} <- check_repo(config.repo),
         {:ok, port} <- check_port(Keyword.get(opts, :port, @default_port)),
         {:ok, email} <- check_email(Keyword.get(opts, :email, @default_email)) do
      {:ok,
       %{
         database: database,
         repo:
           config.repo
           |> Keyword.delete(:url)
           |> Keyword.merge(database: database, pool: DBConnection.ConnectionPool, pool_size: 5),
         ip: @ip,
         port: port,
         email: email
       }}
    end
  end

  defp check_build(%{mix_env: :test, test_seams?: true}), do: :ok

  defp check_build(%{mix_env: env}),
    do: {:error, "the rehearsal runs only the test-seam build (MIX_ENV=test); this is #{env}"}

  defp check_env(env) do
    cond do
      present?(env["DATABASE_URL"]) ->
        {:error, "DATABASE_URL is set; the rehearsal uses only its own _rehearsal database"}

      present?(env["SDR_CLAUDE_CLI_BIN"]) ->
        {:error, "SDR_CLAUDE_CLI_BIN is set; the rehearsal never names a real CLI (unset it)"}

      env["SDR_MODEL_PROVIDER"] not in [nil, "", "fake"] ->
        {:error,
         "SDR_MODEL_PROVIDER=#{env["SDR_MODEL_PROVIDER"]}: unset it (the rehearsal " <>
           "starts with the Fake and runs only the fake CLI)"}

      true ->
        :ok
    end
  end

  defp present?(value), do: value not in [nil, ""]

  defp check_provider(Fake), do: :ok

  defp check_provider(other),
    do: {:error, "the app must start with the Fake provider (is #{inspect(other)})"}

  defp parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> {:ok, opts}
      {_opts, args, invalid} -> {:error, "unknown arguments: #{inspect(args ++ invalid)}"}
    end
  end

  defp check_repo(repo) do
    cond do
      present?(repo[:url]) ->
        {:error, "a Repo :url is configured; the rehearsal needs the local devenv Postgres"}

      repo[:hostname] not in @local_hosts ->
        {:error, "database host #{repo[:hostname] || "?"} is not local"}

      repo[:port] != @db_port ->
        {:error, "database port #{repo[:port] || "?"} is not the devenv Postgres port 5520"}

      true ->
        check_base(repo[:database])
    end
  end

  defp check_base(base) when is_binary(base) do
    if String.starts_with?(base, "sdr_agent_test"),
      do: check_database(base <> "_rehearsal"),
      else: {:error, "the configured database #{base} is not a sdr_agent_test<partition> one"}
  end

  defp check_base(_base), do: {:error, "no sdr_agent_test<partition> database is configured"}

  @doc """
  The target name's own check: at most 63 bytes (never truncated by
  PostgreSQL into another name), `sdr_agent_test`, lowercase letters, digits
  and `_`, then `_rehearsal`; never a dev, calibration or demo name.
  """
  def check_database(database) do
    cond do
      byte_size(database) > @max_identifier ->
        {:error,
         "#{byte_size(database)}-byte database name: PostgreSQL identifiers have at most " <>
           "#{@max_identifier} bytes (use a shorter MIX_TEST_PARTITION)"}

      database in @refused_databases ->
        {:error, "refusing the database #{database}"}

      not Regex.match?(@database, database) ->
        {:error,
         "#{inspect(database)} is not sdr_agent_test<partition>_rehearsal " <>
           "(lowercase letters, digits and _ only)"}

      String.contains?(database, ["calibration", "_demo", "_dev"]) ->
        {:error, "refusing #{database}: it names a calibration, demo or dev database"}

      true ->
        {:ok, database}
    end
  end

  defp check_port(port) when is_integer(port) and port >= 1024 and port <= 65_535 do
    case Map.fetch(@refused_ports, port) do
      {:ok, what} -> {:error, "refusing port #{port}: #{what}"}
      :error -> {:ok, port}
    end
  end

  defp check_port(port), do: {:error, "port #{inspect(port)} is not between 1024 and 65535"}

  defp check_email(email) do
    if Regex.match?(~r/\A[a-z0-9.+_-]+@[a-z0-9.-]+\.test\z/, email),
      do: {:ok, email},
      else: {:error, "the fixture admin's email must be a lowercase synthetic *.test address"}
  end

  @doc "`:ok` when nothing in `running` (see `running/0`) runs, else the refusal."
  def check_idle([]), do: :ok

  def check_idle(running),
    do:
      {:error,
       "already running in this VM: #{Enum.join(running, ", ")}; the rehearsal is a " <>
         "standalone command, never a reconfiguration of a running app"}

  @doc """
  The target must be absent (`storage_status/1` `:down`): `{:ok, :create}`;
  an existing target is refused and left untouched; nothing is ever dropped
  or reset.
  """
  def check_storage(%{database: db}, status) do
    case status do
      :down ->
        {:ok, :create}

      :up ->
        {:error,
         "#{db} already exists; it is left untouched (never adopted, migrated, dropped or " <>
           "reset). Use a new MIX_TEST_PARTITION"}

      {:error, reason} ->
        {:error, "could not check #{db}: #{inspect(reason)}"}
    end
  end

  @doc """
  The exclusive create's result: `:ok` only for a database this command
  created; a collision (`{:error, :already_up}`) or any error is refused and
  the database is not adopted.
  """
  def check_created(_plan, :ok), do: :ok

  def check_created(%{database: db}, {:error, :already_up}),
    do: {:error, "#{db} appeared before its create; it is not adopted and left untouched"}

  def check_created(%{database: db}, {:error, reason}),
    do: {:error, "could not create #{db}: #{inspect(reason)}"}

  @doc "`:ok` when the connected database is the plan's target."
  def check_connected(%{database: db}, db), do: :ok

  def check_connected(%{database: db}, other),
    do: {:error, "connected to #{inspect(other)}, not #{db}; nothing migrated"}

  @doc "`:ok` for a database with no migrations table (freshly created)."
  def check_fresh(true), do: :ok

  def check_fresh(false),
    do: {:error, "the target already has a schema_migrations table; nothing migrated"}

  @doc "`:ok` when nothing listens on loopback `port` and it can be bound, else the refusal."
  def check_port_free(port) do
    case :gen_tcp.connect(@ip, port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, "port #{port} is already in use (lsof -nP -iTCP:#{port} -sTCP:LISTEN)"}

      {:error, _} ->
        case :gen_tcp.listen(port, ip: @ip) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            :ok

          {:error, reason} ->
            {:error, "port #{port} cannot be bound on 127.0.0.1 (#{inspect(reason)})"}
        end
    end
  end

  @doc "Validates a typed password (its text never appears in any message)."
  def check_password(line) when is_binary(line) do
    password = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    cond do
      String.trim(password) == "" -> {:error, "the password is empty"}
      String.length(password) < @min_password -> {:error, "the password must have 16+ characters"}
      true -> {:ok, password}
    end
  end

  def check_password(_eof), do: {:error, "no password was typed"}

  ## Report

  @doc "The report lines for `session` (no secret: identities and counts only)."
  def report(plan, session) do
    {sha, dirty} = code_sha()

    [
      @label,
      "code: #{sha}#{if dirty, do: " (worktree has uncommitted changes)", else: ""}",
      "database: #{plan.database} on localhost:#{@db_port}; console http://127.0.0.1:#{plan.port}",
      "admin: #{plan.email} (password typed by you; never in this report)",
      "tenant: #{session.tenant_id}",
      "switch: #{session.switch.id} #{session.switch.from_profile_id} -> " <>
        "#{session.switch.to_profile_id}, status #{session.switch.status}, " <>
        "reason #{session.switch.failure_reason}",
      "starts: #{inspect(session.starts)}",
      "boots: #{session.first.boot_id} -> #{session.status.boot_id} " <>
        "(hold #{session.status.hold}, generation #{session.status.generation})",
      "fixture processes: tree #{inspect(session.tree)}, coordinator " <>
        "#{inspect(session.coordinator)}, server #{inspect(session.server)}, reaper " <>
        "#{inspect(session.reaper)}",
      "launcher: #{System.find_executable("elixir")} #{Fixture.fake_script()} ready " <>
        "(test launcher, fake CLI)",
      "counters before: #{inspect(session.before)}",
      "counters after:  #{inspect(session.after)}",
      "unchanged: #{session.before == session.after}; completion launch admissions: " <>
        "#{session.launches} (each would be refused)"
    ]
  end

  @doc """
  The checked-out commit and whether the worktree has uncommitted changes;
  both `git` children get `SdrAgent.ChildEnv.cmd([])`.
  """
  def code_sha do
    {sha, 0} =
      System.cmd("git", ["rev-parse", "HEAD"],
        stderr_to_stdout: true,
        env: SdrAgent.ChildEnv.cmd([])
      )

    {status, 0} =
      System.cmd("git", ["status", "--porcelain"],
        stderr_to_stdout: true,
        env: SdrAgent.ChildEnv.cmd([])
      )

    {String.trim(sha), String.trim(status) != ""}
  end
end
