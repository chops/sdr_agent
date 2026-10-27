defmodule SdrAgent.Test.AgentEnvBootFixtures do
  @moduledoc """
  C2* S1 PR-B fixtures for the agent environment's boot, instance and
  shutdown controls (plan `claude-c2star-s1-environment-plan-r2.md`
  sections 4.4-4.5 and 6, as corrected by
  `claude-c2star-s1-prb-p5-correction-r1.md`, Codex PASS `e01021f5`). Like
  `SdrAgent.Test.AgentEnvFixtures`, they use only existing modules, so they
  compile while `SdrAgent.AgentEnv.Boot`, `Instance` and `Shutdown` do not
  exist yet; nothing here calls those modules.

    * `home!/0` — a fake `HOME` under the gitignored `tmp/agent-env-roots`
      whose agent-environment root
      `<home>/.local/state/sdr-agent/agent-env/agentenv-1` (ADR-0004
      agent-environment amendment, item 1) exists as physical 0700
      directories with `state/`, `anchors/` and `evidence/`. Returns
      `%{home, root}`; removed on exit.
    * `agentenv_bound!/2` — the state files of a bound environment for the
      environment's own database `sdr_agent_agentenv` (a fixed oid; no
      database is read: P2 reads files only), with a `:run`,
      `:provisioning` or no lease. Returns `%{nonce, bootstrap_nonce,
      binding_sha256, tenant_id}`.
    * `bootstrap!/2` — the bootstrap history of one bootstrap nonce
      (`environment.pending`, `environment.created.json`, the receipts of
      the steps in `done:`) and its bootstrap lease. The created file names
      the live test database by default (`database:`/`database_oid:`
      override it). Returns `%{nonce, database, database_oid}`.
    * `bootstrap_lease!/2`, `write_boot_marker!/3`, `boot_marker_path/2`,
      `run_receipt_path/2`, `state_files/1`, `read_object!/1`,
      `canonical?/1` — direct state-file writes and reads (canonical
      `sdr-canonical-json/1` bytes, mode 0600).
    * `preserve_app_env!/1`, `put_os_env!/1`, `erase_boot_binding!/0` —
      global state restored on exit (`async: false` tests only).
    * `trace_calls/2` — runs `fun` and returns `{result, calls}`: every
      `{module, function, arity}` call any process made into `module` while
      `fun` ran (an OTP trace session over all processes; the tracer is a
      separate collector process).

  Disclosure: the fixtures write only their own private roots. Nothing here
  is production provisioning evidence.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @environment_id "agentenv-1"
  @agentenv_database "sdr_agent_agentenv"
  @bootstrap_target %{"database" => @agentenv_database, "host" => "localhost", "port" => 5520}
  @relative_root ".local/state/sdr-agent/agent-env/agentenv-1"
  @subdirectories ["state", "anchors", "evidence"]
  @boot_binding {SdrAgent.AgentEnv.Shutdown, :boot}

  ## Roots

  @doc "A fake HOME and its agent-environment root (see the moduledoc)."
  def home! do
    home = Fx.root!("home")
    root = Path.join(home, @relative_root)

    root
    |> ancestors(home)
    |> Enum.each(fn dir ->
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end)

    Enum.each(@subdirectories, fn dir ->
      path = Path.join(root, dir)
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
    end)

    %{home: home, root: root}
  end

  # The directories from `home` (exclusive) down to `root` (inclusive).
  defp ancestors(root, home) do
    root
    |> Path.relative_to(home)
    |> Path.split()
    |> Enum.scan(home, &Path.join(&2, &1))
  end

  ## State files

  @doc """
  The state files of a bound environment of `sdr_agent_agentenv` under
  `root` (no database read). Options: `lease:` (`:run`, default;
  `:provisioning`; `:none`), `database_oid:` (default 424242),
  `tenant_id:` (default: a fresh UUID).
  """
  def agentenv_bound!(root, opts \\ []) do
    bootstrap = Fx.nonce()
    oid = Keyword.get(opts, :database_oid, 424_242)
    tenant_id = Keyword.get_lazy(opts, :tenant_id, &Ecto.UUID.generate/0)

    Fx.write_state!(root, :pending, %{
      "environment_id" => @environment_id,
      "nonce" => bootstrap,
      "started_at" => DateTime.utc_now()
    })

    Fx.write_state!(root, :created, %{
      "database" => @agentenv_database,
      "database_oid" => oid,
      "nonce" => bootstrap
    })

    Enum.each([:create, :migrate, :seed, :probe], fn step ->
      Fx.write_state!(root, {:receipt, bootstrap, step}, receipt(bootstrap, step, tenant_id))
    end)

    binding =
      Fx.write_state!(root, :environment, %{
        "environment_id" => @environment_id,
        "database" => @agentenv_database,
        "database_oid" => oid,
        "tenant_id" => tenant_id,
        "nonce" => bootstrap,
        "created_at" => DateTime.utc_now()
      })

    %{
      nonce: Fx.write_lease!(root, Keyword.get(opts, :lease, :run), binding),
      bootstrap_nonce: bootstrap,
      binding_sha256: binding,
      tenant_id: tenant_id
    }
  end

  @doc """
  The bootstrap history of one fresh bootstrap nonce under `root` and its
  bootstrap lease. Options: `done:` (the steps whose receipts exist;
  default `[:create, :migrate]`), `database:` and `database_oid:` of the
  created file (default: the live test database), `created_nonce:` (the
  created file's nonce; default the bootstrap nonce), `lease:` (default
  true).
  """
  def bootstrap!(root, opts \\ []) do
    nonce = Fx.nonce()
    {database, oid} = created_identity(opts)

    Fx.write_state!(root, :pending, %{
      "environment_id" => @environment_id,
      "nonce" => nonce,
      "started_at" => DateTime.utc_now()
    })

    if :create in Keyword.get(opts, :done, [:create, :migrate]) or
         Keyword.has_key?(opts, :created_nonce) do
      Fx.write_state!(root, :created, %{
        "database" => database,
        "database_oid" => oid,
        "nonce" => Keyword.get(opts, :created_nonce, nonce)
      })
    end

    Enum.each(Keyword.get(opts, :done, [:create, :migrate]), fn step ->
      Fx.write_state!(root, {:receipt, nonce, step}, receipt(nonce, step, nil))
    end)

    if Keyword.get(opts, :lease, true), do: bootstrap_lease!(root, nonce)
    %{nonce: nonce, database: database, database_oid: oid}
  end

  # Both given: no database read (P2 tests run without a sandbox connection).
  defp created_identity(opts) do
    case {Keyword.get(opts, :database), Keyword.get(opts, :database_oid)} do
      {database, oid} when is_binary(database) and is_integer(oid) ->
        {database, oid}

      {database, oid} ->
        {live_database, live_oid} = Fx.live_identity!()
        {database || live_database, oid || live_oid}
    end
  end

  @doc "Writes the bootstrap lease for `nonce` (the fixed bootstrap target, no port)."
  def bootstrap_lease!(root, nonce) do
    Fx.write_state!(root, :lease, %{
      "environment_id" => @environment_id,
      "mode" => "bootstrap",
      "nonce" => nonce,
      "target" => @bootstrap_target,
      "port" => nil,
      "started_at" => DateTime.utc_now()
    })
  end

  defp receipt(nonce, step, tenant_id) do
    base = %{
      "nonce" => nonce,
      "step" => Atom.to_string(step),
      "completed_at" => DateTime.utc_now()
    }

    if step == :probe, do: Map.put(base, "tenant_id", tenant_id), else: base
  end

  @doc "The path of the run boot marker `instance.<nonce>.boot` under `root`."
  def boot_marker_path(root, nonce), do: Path.join([root, "state", "instance.#{nonce}.boot"])

  @doc "The path of the run receipt `instance.<nonce>.exit` under `root`."
  def run_receipt_path(root, nonce), do: Fx.path(root, {:run_receipt, nonce})

  @doc """
  Writes the run boot marker of `nonce` with `boot_id` (closed keys
  `nonce`, `boot_id`, `booted_at`). Returns its lowercase hex SHA-256.
  """
  def write_boot_marker!(root, nonce, boot_id) do
    bytes =
      Canonical.encode!(%{
        "nonce" => nonce,
        "boot_id" => boot_id,
        "booted_at" => DateTime.utc_now()
      })

    file = boot_marker_path(root, nonce)
    File.write!(file, bytes)
    File.chmod!(file, 0o600)
    sha256(bytes)
  end

  @doc "The sorted file names under `<root>/state`."
  def state_files(root), do: root |> Path.join("state") |> File.ls!() |> Enum.sort()

  @doc "The decoded JSON object at `path` (string keys)."
  def read_object!(path), do: path |> File.read!() |> Jason.decode!()

  @doc "Whether `bytes` are exactly the canonical encoding of the JSON object they hold."
  def canonical?(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = data} -> Canonical.encode(data) == {:ok, bytes}
      _other -> false
    end
  end

  @doc "The lowercase hex SHA-256 of the file at `path`."
  def file_sha256!(path), do: path |> File.read!() |> sha256()

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  ## Global state, restored on exit

  @doc """
  Restores the whole `app` environment on exit: keys added during the test
  are deleted and changed keys get their previous values back.
  """
  def preserve_app_env!(app) do
    previous = Application.get_all_env(app)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(app),
          not Keyword.has_key?(previous, key),
          do: Application.delete_env(app, key)

      for {key, value} <- previous, do: Application.put_env(app, key, value)
    end)

    :ok
  end

  @doc """
  Sets (string value) or unsets (`nil`) each OS environment variable for
  the rest of the test; every one is restored on exit.
  """
  def put_os_env!(vars) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn -> Enum.each(previous, fn {name, value} -> set_os_env(name, value) end) end)
    Enum.each(vars, fn {name, value} -> set_os_env(name, value) end)
  end

  defp set_os_env(name, nil), do: System.delete_env(name)
  defp set_os_env(name, value), do: System.put_env(name, value)

  @doc """
  Erases the boot binding (`:persistent_term` `{SdrAgent.AgentEnv.Shutdown,
  :boot}`) now and again on exit.
  """
  def erase_boot_binding! do
    erase = fn -> :persistent_term.erase(@boot_binding) end
    on_exit(erase)
    erase.()
    :ok
  end

  @doc "The current boot binding, or `nil`."
  def boot_binding, do: :persistent_term.get(@boot_binding, nil)

  ## Call traces

  @doc """
  Runs `fun` in the calling process and returns `{result, calls}`: each
  `{module, function, arity}` call into `module` (local calls included) made
  by any process while `fun` ran, in delivery order. `module` must be
  loaded.
  """
  def trace_calls(module, fun) when is_atom(module) and is_function(fun, 0) do
    {:module, ^module} = Code.ensure_loaded(module)
    collector = spawn(fn -> collect_calls([]) end)
    session = :trace.session_create(:c2star_s1_module_calls, collector, [])

    try do
      _ = :trace.function(session, {module, :_, :_}, true, [:local])
      _ = :trace.process(session, :all, true, [:call])
      result = fun.()
      _ = :trace.process(session, :all, false, [:call])
      {result, delivered_calls(session, collector)}
    after
      :trace.session_destroy(session)
      send(collector, :stop)
    end
  end

  defp delivered_calls(session, collector) do
    ref = :trace.delivered(session, :all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5_000 -> raise "C2* S1 fixture: trace delivery was not confirmed"
    end

    send(collector, {:calls, self()})

    receive do
      {:module_calls, calls} -> calls
    after
      5_000 -> raise "C2* S1 fixture: the call collector did not answer"
    end
  end

  defp collect_calls(acc) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        collect_calls([{module, function, length(args)} | acc])

      {:calls, from} ->
        send(from, {:module_calls, Enum.reverse(acc)})

      :stop ->
        :ok
    end
  end
end
