defmodule SdrAgent.AgentEnv.Boot do
  @moduledoc """
  The agent environment's boot gates (plan
  `claude-c2star-s1-environment-plan-r2.md` sections 4.4 and 6, as corrected
  by `claude-c2star-s1-prb-p5-correction-r1.md`; Codex rulings `c9a6f6c7`
  and the `804340e1` review).

    * `runtime_config!/2` — phase P2, called by `config/runtime.exs` with
      `config_env()` and the OS environment. Unset selector variables give
      `[]` (inert: today's configuration). Otherwise only `agentenv-1` in
      `:dev` is accepted, at a known step, under the lease that step needs;
      the result is `[{app, keyword}]` for `config/2`. It reads only the
      cooperative state files under
      `<HOME>/.local/state/sdr-agent/agent-env/agentenv-1` (ADR-0004
      agent-environment amendment, item 1), never the database.
    * `check_start!/0` — the first line of `SdrAgent.Application.start/2`
      (L3): check mode never starts; bootstrap and provisioning need the
      step task's declaration and refuse a server start.
    * `check_repo_start!/1` — `SdrAgent.Repo.init/2` (L2): a supervised Repo
      start needs the declaration outside run mode; `:runtime` (config
      resolution) always passes.
    * `declare_step!/1` — the guarded step task's declaration, which must be
      the configured step of a bootstrap or provisioning configuration.
    * `children/2` and `oban_config/2` — the supervision tree per mode (L4).

  Every refusal raises a `RuntimeError` whose whole message is
  `"agent environment refused at boot (<reason>)"`: a fixed reason atom and
  never a path, value or nested error.

  Forced in every selected mode: the Repo target `sdr_agent_agentenv` @
  `localhost:5520` with `url`, `socket`, `socket_dir` and `endpoints`
  cleared (no inherited connection setting can take precedence), OTel
  content capture off, and `config :sdr_agent, SdrAgent.AgentEnv` with
  `root`, `mode`, `step`, `nonce` and `database`. Bootstrap and provisioning
  also force the Fake provider and `server: false`; run forces HTTP
  `127.0.0.1:4130`; check mode publishes that HTTP tuple inert, with
  `server: false` (it never starts the application or the Repo).
  """

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.SpendReady
  alias SdrAgent.AgentEnv.State

  @selector "agentenv-1"
  @relative_root ".local/state/sdr-agent/agent-env/agentenv-1"
  @steps %{
    "check" => :check,
    "create" => :create,
    "migrate" => :migrate,
    "seed" => :seed,
    "probe" => :probe,
    "provision" => :provision,
    "run" => :run
  }
  @bootstrap_order [:create, :migrate, :seed, :probe]
  @run_queues [default: 10, research: 20, delivery: 5, reconciliation: 1]
  @run_crons [
    SdrAgent.Audit.AnchorWorker,
    SdrAgent.Outreach.StaleDeliverySweeper,
    SdrAgent.Agents.Witness.ScanWorker,
    SdrAgent.SDR.StaleRunSweeper
  ]
  @restricted [SdrAgentWeb.Telemetry, SdrAgent.Repo, Phoenix.PubSub]

  @type step :: :check | :create | :migrate | :seed | :probe | :provision | :run

  ## P2: the leased configuration

  @doc "Phase P2 (see the moduledoc): `[]` when inert, else the forced configuration."
  @spec runtime_config!(:dev | :test | :prod, %{optional(String.t()) => String.t()}) ::
          [{atom(), keyword()}]
  def runtime_config!(config_env, env) when is_map(env) do
    case select(config_env, env) do
      :inert -> []
      {:ok, mode, step, root} -> leased!(mode, step, root, env)
      {:error, reason} -> refuse!(reason)
    end
  end

  defp select(config_env, env) do
    selector = env["SDR_AGENT_ENV"]

    cond do
      is_nil(selector) and is_nil(env["SDR_AGENT_ENV_STEP"]) and
          is_nil(env["SDR_AGENT_ENV_NONCE"]) ->
        :inert

      is_nil(selector) ->
        {:error, :stray_variables}

      config_env != :dev ->
        {:error, :not_dev}

      selector != @selector ->
        {:error, :unknown_environment}

      true ->
        selected(env)
    end
  end

  defp selected(env) do
    with {:ok, step} <- Map.fetch(@steps, env["SDR_AGENT_ENV_STEP"] || ""),
         {:ok, root} <- root(env) do
      {:ok, mode_of(step), step, root}
    else
      :error -> {:error, :unknown_step}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root(env) do
    case env["HOME"] do
      home when is_binary(home) and home != "" ->
        if Path.type(home) == :absolute,
          do: {:ok, Path.join(Path.expand(home), @relative_root)},
          else: {:error, :root_unavailable}

      _missing ->
        {:error, :root_unavailable}
    end
  end

  defp mode_of(:check), do: :check
  defp mode_of(:provision), do: :provisioning
  defp mode_of(:run), do: :run
  defp mode_of(_bootstrap_step), do: :bootstrap

  defp leased!(:check, step, root, env),
    do: forced(:check, step, root, env["SDR_AGENT_ENV_NONCE"])

  defp leased!(mode, step, root, env) do
    nonce = env["SDR_AGENT_ENV_NONCE"]

    with :ok <- variables(mode, env, root),
         {:ok, lease} <- lease(root, mode, nonce),
         :ok <- target(mode, step, root, lease, env) do
      forced(mode, step, root, nonce)
    else
      {:error, reason} -> refuse!(reason)
    end
  end

  # The environment variables each mode refuses (L1) or requires.
  defp variables(mode, env, _root) when mode in [:bootstrap, :provisioning] do
    cond do
      env["SDR_MODEL_PROVIDER"] not in [nil, "fake"] -> {:error, :provider_refused}
      Map.has_key?(env, "SDR_DEMO_EXCEPTION") -> {:error, :selector_refused}
      Map.has_key?(env, "PHX_SERVER") -> {:error, :phx_server_refused}
      true -> :ok
    end
  end

  defp variables(:run, env, root) do
    cond do
      env["PORT"] not in [nil, Integer.to_string(AgentEnv.http_port())] -> {:error, :port_refused}
      not anchors?(env, root) -> {:error, :anchor_sinks_refused}
      env["SDR_WITNESS_STORE_ROOT"] in [nil, ""] -> {:error, :witness_root_missing}
      true -> :ok
    end
  end

  # The file anchor sink, in a physical directory at or under
  # `<root>/anchors`: an absolute, normalized path (no `.`/`..`, so the
  # sink sees the same path) whose every component from `<root>/anchors`
  # down is a real directory, never a symlink.
  defp anchors?(env, root) do
    anchors = Path.join(root, "anchors")
    dir = env["SDR_ANCHOR_FILE_DIR"]

    env["SDR_ANCHOR_SINKS"] == "file" and is_binary(dir) and Path.type(dir) == :absolute and
      Path.expand(dir) == dir and physical_under?(dir, anchors)
  end

  defp physical_under?(dir, anchors) do
    relative =
      cond do
        dir == anchors ->
          []

        String.starts_with?(dir, anchors <> "/") ->
          dir |> Path.relative_to(anchors) |> Path.split()

        true ->
          nil
      end

    is_list(relative) and
      [anchors | Enum.scan(relative, anchors, &Path.join(&2, &1))]
      |> Enum.all?(&directory?/1)
  end

  defp directory?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  # The lease: present, valid, of the step's mode and carrying the
  # launcher's nonce.
  defp lease(root, mode, nonce) do
    case State.read(root, :lease) do
      :absent -> {:error, :lease_missing}
      {:invalid, _reason} -> {:error, :lease_invalid}
      {:valid, _sha256, lease} -> lease_for(lease, mode, nonce)
    end
  end

  defp lease_for(%{"mode" => lease_mode} = lease, mode, nonce) do
    cond do
      lease_mode != Atom.to_string(mode) -> {:error, :step_mode_mismatch}
      not is_binary(nonce) or lease["nonce"] != nonce -> {:error, :agent_env_lease_mismatch}
      true -> {:ok, lease}
    end
  end

  # The lease's target: the bootstrap history (order and created
  # database), or the bound environment's binding digest.
  defp target(:bootstrap, step, root, lease, _env) do
    with :ok <- bootstrap_order(root, lease["nonce"], step),
         do: created_target(root, lease["nonce"], step)
  end

  defp target(:provisioning, _step, root, lease, _env), do: bound(root, lease)

  defp target(:run, _step, root, lease, env) do
    with :ok <- bound(root, lease),
         :ok <- no_run_receipt(root, lease["nonce"]),
         do: spend_ready(root, lease, env)
  end

  # Every earlier step's receipt valid; this step's and every later one's
  # absent.
  defp bootstrap_order(root, nonce, step) do
    {earlier, [^step | later]} = Enum.split_while(@bootstrap_order, &(&1 != step))

    done? = Enum.all?(earlier, &match?({:valid, _, _}, State.read(root, {:receipt, nonce, &1})))
    open? = Enum.all?([step | later], &(State.read(root, {:receipt, nonce, &1}) == :absent))
    created_ok? = step != :create or State.read(root, :created) == :absent

    if done? and open? and created_ok?, do: :ok, else: {:error, :step_out_of_order}
  end

  defp created_target(_root, _nonce, :create), do: :ok

  defp created_target(root, nonce, _step) do
    database = AgentEnv.database()

    case State.read(root, :created) do
      {:valid, _sha256, %{"database" => ^database, "nonce" => ^nonce}} ->
        :ok

      _other ->
        {:error, :bootstrap_target_mismatch}
    end
  end

  defp bound(root, lease) do
    case State.read(root, :environment) do
      {:valid, binding, _environment} ->
        if lease["target"] == %{"binding_sha256" => binding},
          do: :ok,
          else: {:error, :agent_env_lease_mismatch}

      _absent_or_invalid ->
        {:error, :environment_unbound}
    end
  end

  defp no_run_receipt(root, nonce) do
    if State.read(root, {:run_receipt, nonce}) == :absent,
      do: :ok,
      else: {:error, :run_receipt_exists}
  end

  # P2 for ClaudeCLI (AC6): SpendReady.at_boot/1 must pass. S1 never does.
  defp spend_ready(root, lease, env) do
    if env["SDR_MODEL_PROVIDER"] == "claude_cli" do
      views = %{
        lease: State.read(root, :lease),
        environment: State.read(root, :environment),
        authorization: State.read(root, :authorization),
        claim: State.read(root, :claim),
        nonce: lease["nonce"]
      }

      # A dynamic call: S1's fail-closed body returns one fixed refusal, and
      # the type checker would otherwise reject the :ok branch S2 needs.
      case apply(SpendReady, :at_boot, [views]) do
        :ok -> :ok
        _refused -> {:error, :agent_env_not_spend_ready}
      end
    else
      :ok
    end
  end

  defp forced(mode, step, root, nonce) do
    database = AgentEnv.database()

    agent_env = [root: root, mode: mode, step: step, nonce: nonce, database: database]

    repo = [
      database: database,
      hostname: "localhost",
      port: 5520,
      url: nil,
      socket: nil,
      socket_dir: nil,
      endpoints: nil
    ]

    [
      {:sdr_agent,
       [
         {AgentEnv, agent_env},
         {SdrAgent.Repo, repo},
         {:otel_capture_content, false}
       ] ++ mode_config(mode)}
    ]
  end

  defp mode_config(:run),
    do: [{SdrAgentWeb.Endpoint, [http: [ip: {127, 0, 0, 1}, port: AgentEnv.http_port()]]}]

  defp mode_config(mode) when mode in [:bootstrap, :provisioning],
    do: [
      {:model_provider, SdrAgent.AI.ModelProvider.Fake},
      {SdrAgentWeb.Endpoint, [server: false]}
    ]

  # Check mode (P0, Codex b684dba9 M2): the inert fixed HTTP tuple that
  # Launcher.check/1 reads, never a server; check_start!/0 and the Repo's
  # supervised start still refuse check mode.
  defp mode_config(:check),
    do: [
      {SdrAgentWeb.Endpoint,
       [http: [ip: {127, 0, 0, 1}, port: AgentEnv.http_port()], server: false]}
    ]

  ## P3 gates: the application and the Repo (L2, L3)

  @doc "The first line of `SdrAgent.Application.start/2` (L3)."
  @spec check_start!() :: :ok
  def check_start! do
    case AgentEnv.mode() do
      mode when mode in [:none, :run] ->
        :ok

      :check ->
        refuse!(:undeclared_step)

      _bootstrap_or_provisioning ->
        cond do
          Application.get_env(:phoenix, :serve_endpoints) -> refuse!(:server_refused)
          not declared?() -> refuse!(:undeclared_step)
          true -> :ok
        end
    end
  end

  @doc """
  `SdrAgent.Repo.init/2` (L2): a `:supervisor` start needs the declaration
  in bootstrap and provisioning, and never happens in check mode;
  `:runtime` (configuration resolution) always passes.
  """
  @spec check_repo_start!(:supervisor | :runtime) :: :ok
  def check_repo_start!(:runtime), do: :ok

  def check_repo_start!(:supervisor) do
    case AgentEnv.mode() do
      mode when mode in [:none, :run] -> :ok
      :check -> refuse!(:undeclared_step)
      _bootstrap_or_provisioning -> if declared?(), do: :ok, else: refuse!(:undeclared_step)
    end
  end

  @doc """
  Records the guarded step task's declaration of `step`, which must be the
  configured step of a bootstrap or provisioning configuration; anything
  else refuses (`undeclared_step`). The declaration is recorded as
  `config :sdr_agent, SdrAgent.AgentEnv.Boot, declared: {mode, root, nonce,
  step}` and counts only for that exact configuration.
  """
  @spec declare_step!(:create | :migrate | :seed | :probe | :provision) :: :ok
  def declare_step!(step) when step in [:create, :migrate, :seed, :probe, :provision] do
    if AgentEnv.mode() in [:bootstrap, :provisioning] and configured_step() == step do
      Application.put_env(:sdr_agent, __MODULE__, declared: current_declaration(step))
    else
      refuse!(:undeclared_step)
    end
  end

  @doc false
  # The declared step of the current configuration, or nil (Instance, P3).
  @spec declared_step() :: atom() | nil
  def declared_step do
    step = configured_step()
    if declared?(), do: step
  end

  defp declared? do
    step = configured_step()
    declared = :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:declared)
    is_atom(step) and declared == current_declaration(step)
  end

  defp configured_step, do: Keyword.get(AgentEnv.config(), :step)

  defp current_declaration(step) do
    config = AgentEnv.config()
    {AgentEnv.mode(), Keyword.get(config, :root), Keyword.get(config, :nonce), step}
  end

  ## The supervision tree (L4)

  @doc """
  The supervision children of `mode` from the application's `base` tree:
  `:none` is `base`; bootstrap and provisioning keep only Telemetry, the
  Repo and PubSub, with `{Instance, mode}` after the Repo; run is `base`
  with `{Instance, :run}` after the Repo and Oban's options replaced by
  `oban_config(:run, options)`.
  """
  @spec children(AgentEnv.mode(), list()) :: list()
  def children(:none, base), do: base

  def children(:run, base) do
    base
    |> Enum.map(fn child ->
      case child do
        {Oban, options} -> {Oban, oban_config(:run, options)}
        other -> other
      end
    end)
    |> with_instance(:run)
  end

  def children(mode, base) do
    allowed = Enum.map(SdrAgent.Telemetry.test_children(), &module_of/1) ++ @restricted

    base
    |> Enum.filter(&(module_of(&1) in allowed))
    |> with_instance(mode)
  end

  defp with_instance(children, mode) do
    {before_repo, [repo | after_repo]} =
      Enum.split_while(children, &(module_of(&1) != SdrAgent.Repo))

    before_repo ++ [repo, {SdrAgent.AgentEnv.Instance, mode} | after_repo]
  end

  defp module_of({module, _arg}) when is_atom(module), do: module
  defp module_of(%{start: {module, _function, _args}}), do: module
  defp module_of(module) when is_atom(module), do: module

  @doc """
  Run mode's Oban options: `base` with the queues replaced by exactly
  `default: 10, research: 20, delivery: 5, reconciliation: 1` and the
  plugins by one Cron whose crontab is base's for the anchor, stale
  delivery, witness scan and stale run workers (no `OtsUpgradeWorker`).
  Replaced, never merged; every other option is kept.
  """
  @spec oban_config(:run, keyword()) :: keyword()
  def oban_config(:run, base) do
    crontab =
      for {Oban.Plugins.Cron, options} <- Keyword.get(base, :plugins, []),
          {_schedule, worker} = entry <- Keyword.get(options, :crontab, []),
          worker in @run_crons,
          do: entry

    unless Enum.sort(Enum.map(crontab, &elem(&1, 1))) == Enum.sort(@run_crons) do
      raise ArgumentError, "the run crontab must name each run worker exactly once"
    end

    base
    |> Keyword.put(:plugins, [{Oban.Plugins.Cron, crontab: crontab}])
    |> Keyword.put(:queues, @run_queues)
  end

  @spec refuse!(atom()) :: no_return()
  defp refuse!(reason) when is_atom(reason),
    do: raise("agent environment refused at boot (#{reason})")
end
