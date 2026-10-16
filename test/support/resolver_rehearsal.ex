defmodule SdrAgent.Test.ResolverRehearsal do
  @moduledoc """
  The R0-05 resolver browser rehearsal (test builds only; run through `mix
  sdr.demo.rehearse_resolver`, owner-run after review). A **synthetic**
  rehearsal: it lets the owner see the blocked-switch resolver
  (`#resolve-blocked`, `#resolution-form`) in a real browser over one real
  stored `:blocked` switch. It is not runtime cleanup proof and not the
  R0-06 real-profile trial.

  **The fixture** is `SdrAgent.Test.ResolveHarness.survivor!/1` adapted
  without ExUnit: the profile tree (non-manual) with the harness's fake CLI
  (`test/support/fake_claude_cli.exs` under `elixir`, `test_launcher:
  true`); a real switch request through `Coordinator.request_switch/2`; the
  switch worker paused at the b2α `:drained` stage; a kill of only this
  driver's coordinator; the next boot re-holds and adopts the old server and
  blocks the switch (`coordinator_restarted`). Nothing is written raw: no
  SQL write, no resource struct write, no forged status, no lease release.

  **Guards** (`plan/1`, `check_storage/2`, `check_launcher/2`): `MIX_ENV=test`
  with the ClaudeCLI test seams; no `DATABASE_URL`, no `SDR_CLAUDE_CLI_BIN`,
  the Fake as `SDR_MODEL_PROVIDER`; the Repo on the local devenv Postgres
  (5520, no `:url`); the database is exactly the configured
  `sdr_agent_test<partition>` plus `_rehearsal` (never the dev, calibration
  or suite database); a loopback port, free, never 4120 (dev), 4122 (demo
  smoke) or 4124 (calibration console). An existing target database is
  refused unless `--existing-database` names it exactly, and then only while
  it holds no users, settings, starts or switches. Nothing is ever dropped
  or reset. The launcher is checked to be the fake one before any fault.

  **No calls.** Every launch admission goes to a driver-owned recorder that
  refuses it (`{:error, :rehearsal_no_calls}`), so even an unexpected
  completion would be refused before its launch; the report shows the
  recorder's count with the read-only row counts of invocations, grants,
  allocations, releases, witness links, tool invocations, agent runs and
  Oban jobs before and after. Oban runs `testing: :manual` (no queue, no
  plugin, no job executes).

  **The admin** is the ordinary first-admin bootstrap
  (`SdrAgent.Accounts.bootstrap_admin/2`) in the fresh tenant; the owner
  signs in through the ordinary sign-in page. The password is typed by the
  owner without echo (at least 16 characters) and is never printed, logged
  or written. The endpoint's `secret_key_base` and the token signing secret
  are random per run, in memory only.
  """

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.ProfileSupervisor
  alias SdrAgent.Repo
  alias SdrAgent.Test.LaunchAdmission
  alias SdrAgent.Test.ResolveHarness

  @fake Path.expand("fake_claude_cli.exs", __DIR__)
  @stage [:sdr_agent, :model_coordinator, :stage]
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
  @database ~r/\Asdr_agent_test[A-Za-z0-9_]*_rehearsal\z/
  @min_password 16
  @refusal {:error, :rehearsal_no_calls}
  @counted ~w(model_invocations model_call_grants model_call_allocations model_result_releases
              wire_witness_links tool_invocations agent_runs oban_jobs)
  @fixture_tables ~w(users model_profile_settings model_server_starts model_profile_switches)
  @switches [port: :integer, email: :string, existing_database: :string]
  @label "SYNTHETIC R0-05 RESOLVER REHEARSAL (fake CLI, test build; not runtime cleanup " <>
           "proof, not the R0-06 trial)"

  @doc "The label printed on every report line block."
  def label, do: @label

  @doc "The fake CLI script every fixture server runs (the harness's)."
  def fake_script, do: @fake

  ## The command (`mix sdr.demo.rehearse_resolver`)

  @doc """
  The owner-run command: plan and guards, the password (typed, not echoed),
  the database (created and migrated when absent; never dropped or reset),
  the app, the admin, the fixture and its report, then the console until
  `STOP` is typed, then the stop report. Every refusal raises
  before any effect it guards. The database is kept.
  """
  def run(argv) do
    plan = ok!(plan(current(argv)))
    ok!(check_port_free(plan.port))
    mode = ok!(check_storage(plan, Repo.__adapter__().storage_status(plan.repo)))
    ok!(SdrAgent.CalibrationConsole.check_assets())
    info("#{@label}\nfixture admin #{plan.email}; database #{plan.database}; port #{plan.port}")
    password = ok!(check_password(read_password()))

    apply!(plan)
    ensure_storage!(mode)
    Mix.Task.run("app.start")
    verify_started!(plan)
    if mode == :existing, do: require_empty!(plan)

    ctx = create_admin!(plan.email, password)
    session = start!(ctx)
    Enum.each(report(plan, session), &info/1)
    info(instructions(plan, session))
    await_stop()
    stopped = stop(session)
    info("#{@label}\nstopped: #{inspect(stopped)}")
    info("counters at stop: #{inspect(counters())}")
    info("database #{plan.database} kept (never dropped)")
  end

  defp ok!({:ok, value}), do: value
  defp ok!(:ok), do: :ok
  defp ok!({:error, reason}), do: Mix.raise("mix sdr.demo.rehearse_resolver refuses: #{reason}")

  defp info(line), do: Mix.shell().info(line)

  # OTP's no-echo terminal read; the password never reaches any message.
  defp read_password do
    IO.write("Type a password for the fixture admin (16+ characters, not echoed): ")

    case :io.get_password() do
      line when is_list(line) -> List.to_string(line)
      _other -> nil
    end
  after
    IO.write("\n")
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

  defp ensure_storage!(mode) do
    config = Repo.config()

    if mode == :create do
      :ok = Repo.__adapter__().storage_up(config)
    end

    {:ok, _, _} = Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true))
    :ok
  end

  defp verify_started!(plan) do
    checks = [
      {Repo.config()[:database] == plan.database, "the Repo does not serve #{plan.database}"},
      {Oban.config().testing == :manual, "Oban is not in testing: :manual"},
      {Application.get_env(:sdr_agent, :model_provider) == Fake, "the provider is not the Fake"},
      {is_nil(Process.whereis(ProfileSupervisor)), "a model profile tree runs"},
      {not ClaudeCLI.running?(ClaudeCLI.server()), "a ClaudeCLI server runs"}
    ]

    case for({false, why} <- checks, do: why) do
      [] -> :ok
      failures -> Mix.raise("rehearsal refuses after start: " <> Enum.join(failures, "; "))
    end
  end

  defp require_empty!(plan) do
    counts = fixture_counts()

    Enum.all?(counts, fn {_table, count} -> count == 0 end) ||
      Mix.raise(
        "--existing-database #{plan.database} already holds a fixture (#{inspect(counts)}); " <>
          "it is kept as is: use a new MIX_TEST_PARTITION"
      )
  end

  defp instructions(plan, session) do
    """

    Open http://127.0.0.1:#{plan.port}/sign-in, sign in as #{plan.email}, open /admin.
    The blocked switch is #{session.switch.id}; its exact confirmation is
    STOPPED #{session.switch.id}
    Owner checks (synthetic rehearsal): open the resolver (#resolve-blocked); a focused
    mismatch clears the input; fresh typing persists; a later mismatch clears it again;
    the exact text submits under the same review; disabled and submitting states are honest.
    Type STOP and Enter here for the clean stop. Ctrl-C or SIGTERM end the VM without it.
    """
  end

  # Waits for a typed STOP (end of input keeps serving). SIGTERM is not
  # trapped: the VM's default graceful stop applies, without this join.
  defp await_stop do
    me = self()
    reader = spawn_link(fn -> read_stop(me) end)

    receive do
      :rehearsal_stop -> :ok
    end

    Process.unlink(reader)
    Process.exit(reader, :kill)
  end

  defp read_stop(parent) do
    case IO.gets("") do
      line when is_binary(line) ->
        if String.trim(line) == "STOP", do: send(parent, :rehearsal_stop), else: read_stop(parent)

      _eof ->
        :ok
    end
  end

  ## The plan (pure)

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
         email: email,
         existing_database: opts[:existing_database]
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
    base = repo[:database]

    cond do
      present?(repo[:url]) ->
        {:error, "a Repo :url is configured; the rehearsal needs the local devenv Postgres"}

      repo[:hostname] not in @local_hosts ->
        {:error, "database host #{repo[:hostname] || "?"} is not local"}

      repo[:port] != @db_port ->
        {:error, "database port #{repo[:port] || "?"} is not the devenv Postgres port 5520"}

      true ->
        check_base(base)
    end
  end

  defp check_base(base) when is_binary(base) do
    if String.starts_with?(base, "sdr_agent_test"),
      do: check_database(base <> "_rehearsal"),
      else: {:error, "the configured database #{base} is not a sdr_agent_test<partition> one"}
  end

  defp check_base(_base), do: {:error, "no sdr_agent_test<partition> database is configured"}

  defp check_database(database) do
    cond do
      database in @refused_databases ->
        {:error, "refusing the database #{database}"}

      not Regex.match?(@database, database) ->
        {:error, "#{database} is not a sdr_agent_test<partition>_rehearsal database"}

      String.contains?(database, ["calibration", "_demo"]) ->
        {:error, "refusing #{database}: it names a calibration or demo database"}

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

  @doc """
  Whether the plan may use the database in `status` (the Repo adapter's
  `storage_status/1`): `{:ok, :create}` when absent (and not named by
  `--existing-database`), `{:ok, :existing}` when present and named exactly,
  otherwise the refusal. Nothing is ever dropped or reset.
  """
  def check_storage(%{database: db, existing_database: existing}, status) do
    case {status, existing} do
      {:down, nil} ->
        {:ok, :create}

      {:up, ^db} ->
        {:ok, :existing}

      {:up, nil} ->
        {:error,
         "#{db} already exists; it is never dropped or reset. Use a new MIX_TEST_PARTITION, " <>
           "or pass --existing-database #{db} to use it (only while it holds no fixture)"}

      {_status, ^db} ->
        {:error, "--existing-database #{db}: it does not exist"}

      {_status, other} when is_binary(other) ->
        {:error, "--existing-database #{other} does not name the target database #{db}"}

      {{:error, reason}, _} ->
        {:error, "could not check #{db}: #{inspect(reason)}"}
    end
  end

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

  @doc "Validates a typed password (never echoed in any message)."
  def check_password(line) when is_binary(line) do
    password = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    cond do
      String.trim(password) == "" -> {:error, "the password is empty"}
      String.length(password) < @min_password -> {:error, "the password must have 16+ characters"}
      true -> {:ok, password}
    end
  end

  def check_password(_eof), do: {:error, "no password was typed"}

  @doc """
  The fake-launcher check, before any fault: `state` is the running server's
  state (`:sys.get_state/1`), `attestation` its `ClaudeCLI.attestation/1`.
  The command must be this build's `elixir` running exactly the harness's
  fake CLI script in `ready` mode, under the test launcher, with no pinned
  executable, no real CLI binary configured and every admission to the
  driver's refusing recorder.
  """
  def check_launcher(state, attestation, admission) do
    elixir = System.find_executable("elixir")

    checks = [
      {is_binary(elixir) and state.command == elixir, "the command is not this build's elixir"},
      {state.command_args == [@fake, "ready"], "the arguments are not the fake CLI script"},
      {File.regular?(@fake), "the fake CLI script is missing"},
      {state.test_launcher == true, "the server is not under the test launcher"},
      {is_nil(state.executable), "a pinned CLI executable is set"},
      {state.launch_admission == admission, "launch admission is not the driver's recorder"},
      {Map.get(attestation, :test_launcher?) == true, "the attestation is not a test launcher"},
      {is_nil(Map.get(attestation, :executable)), "the attestation names an executable"},
      {is_nil(System.get_env("SDR_CLAUDE_CLI_BIN")), "SDR_CLAUDE_CLI_BIN is set"}
    ]

    case for({false, why} <- checks, do: why) do
      [] -> :ok
      failures -> {:error, "not the fake launcher: " <> Enum.join(failures, "; ")}
    end
  end

  ## Counters (read-only)

  @doc "Read-only row counts of every call, charge and witness table, plus Oban jobs."
  def counters do
    Map.new(@counted, &{&1, Repo.aggregate(&1, :count)})
  end

  @doc "Read-only row counts of the fixture tables (an existing database must have none)."
  def fixture_counts, do: Map.new(@fixture_tables, &{&1, Repo.aggregate(&1, :count)})

  ## The admin

  @doc """
  The singleton tenant (bootstrapped if absent) and its first admin,
  through `Accounts.bootstrap_admin/2` (refused when the tenant has users).
  """
  def create_admin!(email, password) do
    {:ok, tenant} = SdrAgent.Audit.bootstrap(slug: "rehearsal", name: "Resolver Rehearsal")

    attrs = %{
      email: email,
      display_name: "Rehearsal Admin (synthetic)",
      password: password,
      password_confirmation: password
    }

    case Accounts.bootstrap_admin(attrs) do
      {:ok, admin} -> %{tenant: tenant, admin: admin}
      {:error, error} -> raise "first-admin bootstrap refused: #{Exception.message(error)}"
    end
  end

  ## The fixture (ResolveHarness.survivor!/1 without ExUnit)

  @doc """
  Builds the blocked switch for `ctx` (`%{admin, tenant}`) and returns the
  session (`stop/1` it). Sets the app's model provider to ClaudeCLI for this
  VM (restored by `stop/1`), starts the driver-owned profile tree linked to
  the caller, checks the fake launcher, then induces the restart at the
  `:drained` barrier. Any failure stops what it started and raises.
  """
  def start!(ctx) do
    if Process.whereis(ProfileSupervisor), do: fail!("a profile tree is already running")
    if ClaudeCLI.running?(ClaudeCLI.server()), do: fail!("a ClaudeCLI server is already running")
    before = counters()
    recorder = spawn(fn -> sink(0) end)
    {:ok, paused} = Agent.start(fn -> [] end)
    admission = LaunchAdmission.recording(recorder, @refusal)
    previous = Application.fetch_env!(:sdr_agent, :model_provider)

    session = %{
      recorder: recorder,
      paused: paused,
      handler: "r005-rehearsal-#{System.unique_integer([:positive])}",
      admission: admission,
      previous_provider: previous,
      tree: nil,
      before: before
    }

    try do
      build!(session, ctx)
    rescue
      exception ->
        stop(%{session | tree: owned_tree()})
        reraise exception, __STACKTRACE__
    end
  end

  # The registered profile tree, only when this process started (is linked
  # to) it: a failed build stops its own tree and nothing else.
  defp owned_tree do
    tree = Process.whereis(ProfileSupervisor)
    {:links, links} = Process.info(self(), :links)
    if is_pid(tree) and tree in links, do: tree
  end

  # The recorder: counts every admission (each answered with the refusal,
  # so the launch never happens) and answers `launches/1`.
  defp sink(count) do
    receive do
      {:launch_admission, _id, _profile, _opts} ->
        sink(count + 1)

      {:count, from, ref} ->
        send(from, {ref, count})
        sink(count)

      :stop ->
        :ok
    end
  end

  @doc "The recorder's admission count (nil when it no longer runs)."
  def launches(recorder) do
    ref = Process.monitor(recorder)
    send(recorder, {:count, self(), ref})

    receive do
      {^ref, count} ->
        Process.demonitor(ref, [:flush])
        count

      {:DOWN, ^ref, :process, _, _} ->
        nil
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        nil
    end
  end

  defp build!(session, ctx) do
    Application.put_env(:sdr_agent, :model_provider, ClaudeCLI)
    admission = session.admission

    server = fn _profile_id ->
      [
        command: System.find_executable("elixir"),
        test_launcher: true,
        launch_admission: admission,
        command_args: [@fake, "ready"]
      ]
    end

    {:ok, tree} = ProfileSupervisor.start_link(server: server)
    session = %{session | tree: tree}
    first = await_status!(&(&1.hold == :released), "the first server never released")
    server_pid = Process.whereis(ClaudeCLI.server()) || fail!("no first server runs")

    with {:error, why} <-
           check_launcher(
             :sys.get_state(server_pid),
             ClaudeCLI.attestation(server_pid),
             admission
           ),
         do: fail!(why)

    blocked = induce!(session, ctx, first)
    survivor!(session, ctx, blocked, first)
  end

  defp induce!(session, ctx, first) do
    attach_pause!(session)
    switch = request_switch!(ctx)

    worker =
      receive do
        {:stage_paused, :drained, worker} -> worker
      after
        20_000 -> fail!("the switch worker never paused at :drained")
      end

    :telemetry.detach(session.handler)
    coordinator = Process.whereis(Coordinator)
    check_owned!(session.tree, coordinator, worker)

    match?(%{status: :pending}, switch!(ctx, switch.id)) ||
      fail!("the switch is not pending at the barrier: #{inspect(switch!(ctx, switch.id))}")

    first.boot_id == Coordinator.status().boot_id || fail!("the coordinator rebooted early")
    kill!(coordinator)
    blocked = await_switch!(ctx, switch.id, :blocked)

    blocked.failure_reason =~ "coordinator_restarted" ||
      fail!("blocked for #{inspect(blocked.failure_reason)}, not coordinator_restarted")

    blocked
  end

  defp survivor!(session, ctx, blocked, first) do
    status =
      await_status!(
        &(&1.boot_id != first.boot_id and &1.hold == :held and &1.generation == 2),
        "the next boot never re-held generation 2"
      )

    :sys.get_state(Coordinator, 30_000)
    for pid <- Agent.get(session.paused, & &1), do: send(pid, :continue)
    server = Process.whereis(ClaudeCLI.server()) || fail!("no surviving server")
    reaper = ClaudeCLI.reaper(server)

    checks = [
      is_pid(reaper) and Process.alive?(reaper),
      Reaper.lease(ClaudeCLI.server()) == {:held, reaper},
      ClaudeCLI.admission(server).admission == :open,
      ClaudeCLI.held?(server)
    ]

    Enum.all?(checks) || fail!("the survivor differs from the fixture: #{inspect(checks)}")

    Map.merge(session, %{
      switch: blocked,
      first: first,
      status: status,
      server: server,
      reaper: reaper,
      coordinator: Process.whereis(Coordinator),
      starts: starts!(ctx),
      after: counters(),
      launches: launches(session.recorder),
      tenant_id: ctx.tenant.id
    })
  end

  defp attach_pause!(session) do
    :ok =
      :telemetry.attach(
        session.handler,
        @stage,
        &ResolveHarness.stage_handler/4,
        %{parent: self(), stage: :drained, paused: session.paused}
      )
  end

  defp request_switch!(ctx) do
    {:ok, setting} = Agents.get_profile_setting(actor: ctx.admin)

    {desired, revision} =
      if setting, do: {setting.desired_profile_id, setting.revision}, else: {:claude_cli_opus, 1}

    to = if desired == :claude_cli_opus, do: :claude_cli_sonnet, else: :claude_cli_opus

    case Coordinator.request_switch(%{to_profile_id: to, expected_revision: revision},
           actor: ctx.admin
         ) do
      {:ok, switch} -> switch
      other -> fail!("the switch request was refused: #{inspect(other)}")
    end
  end

  # The coordinator is this driver's tree's child, and the paused worker is
  # that tree's operation supervisor's child: nothing else is killed.
  defp check_owned!(tree, coordinator, worker) do
    children = Supervisor.which_children(tree)
    ours = for {Coordinator, pid, _, _} <- children, do: pid
    workers = Task.Supervisor.children(SdrAgent.AI.ModelProvider.OperationSupervisor)

    (is_pid(coordinator) and ours == [coordinator]) ||
      fail!("the registered coordinator is not this driver's tree's")

    worker in workers || fail!("the paused worker is not this tree's switch worker")
  end

  defp kill!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> fail!("the coordinator did not exit")
    end
  end

  @doc "The tenant's switch `id` as stored (read as the admin)."
  def switch!(ctx, id) do
    {:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)
    Enum.find(switches, &(&1.id == id))
  end

  @doc "The tenant's starts as `{generation, id, profile_id, status}`."
  def starts!(ctx) do
    {:ok, starts} = Agents.list_server_starts(actor: ctx.admin)

    starts
    |> Enum.sort_by(& &1.generation)
    |> Enum.map(&{&1.generation, &1.id, &1.profile_id, &1.status})
  end

  defp await_switch!(ctx, id, status) do
    await!(fn -> match?(%{status: ^status}, switch!(ctx, id)) end, 20_000, fn ->
      "the switch never reached #{status}; last #{inspect(switch!(ctx, id))}"
    end)

    switch!(ctx, id)
  end

  defp await_status!(predicate, message) do
    await!(
      fn ->
        status = Coordinator.status()
        is_map(status) and predicate.(status)
      end,
      15_000,
      fn -> "#{message}; last #{inspect(Coordinator.status())}" end
    )

    Coordinator.status()
  end

  defp await!(fun, timeout, message) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline, message)
  end

  defp poll(fun, deadline, message) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        fail!(message.())

      true ->
        Process.sleep(20)
        poll(fun, deadline, message)
    end
  end

  defp fail!(message), do: raise("rehearsal fixture: #{message}")

  ## Stop

  @doc """
  Stops and joins everything the session started (idempotent): releases
  any paused worker, detaches the barrier, stops the driver's profile tree
  (its coordinator, the surviving server and its reaper), restores the model
  provider and stops the recorder. Never releases a lease and never touches
  the database. Returns what it observed.
  """
  def stop(session) do
    :telemetry.detach(session.handler)
    for pid <- safe(fn -> Agent.get(session.paused, & &1) end, []), do: send(pid, :continue)
    server = Map.get(session, :server)
    reaper = Map.get(session, :reaper)

    if is_pid(session.tree) and Process.alive?(session.tree) do
      # Unlinked first: the caller is not taken down by the tree's exit.
      Process.unlink(session.tree)
      safe(fn -> Supervisor.stop(session.tree, :normal, 30_000) end, :ok)
    end

    for pid <- [server, reaper], is_pid(pid), do: join(pid, 10_000)
    Application.put_env(:sdr_agent, :model_provider, session.previous_provider)
    launches = launches(session.recorder)
    send(session.recorder, :stop)
    safe(fn -> Agent.stop(session.paused) end, :ok)

    %{
      tree_alive?: is_pid(session.tree) and Process.alive?(session.tree),
      server_alive?: is_pid(server) and Process.alive?(server),
      reaper_alive?: is_pid(reaper) and Process.alive?(reaper),
      named_server: Process.whereis(ClaudeCLI.server()),
      lease: Reaper.lease(ClaudeCLI.server()),
      launches: launches
    }
  end

  defp join(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> Process.demonitor(ref, [:flush])
    end
  end

  defp safe(fun, default) do
    fun.()
  catch
    :exit, _ -> default
  end

  ## Report

  @doc "The report lines for `session` (no secret: identities and counts only)."
  def report(plan, session) do
    {sha, dirty} = code_sha()

    [
      @label,
      "code: #{sha}#{if dirty, do: " (worktree has uncommitted changes)", else: ""}",
      "database: #{plan.database} on localhost:#{@db_port}; console http://127.0.0.1:#{plan.port}",
      "admin: #{plan.email} (password typed by you, never shown or stored)",
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
      "launcher: #{System.find_executable("elixir")} #{@fake} ready (test launcher, fake CLI)",
      "counters before: #{inspect(session.before)}",
      "counters after:  #{inspect(session.after)}",
      "unchanged: #{session.before == session.after}; completion launch admissions: " <>
        "#{session.launches} (each would be refused)"
    ]
  end

  @doc "The checked-out commit and whether the worktree has uncommitted changes."
  def code_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)
    {status, 0} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)
    {String.trim(sha), String.trim(status) != ""}
  end
end
