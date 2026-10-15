defmodule SdrAgent.CalibrationConsole do
  @moduledoc """
  The configuration of the R0-07 calibration console (readiness packet §3),
  served by `bin/calibration-console` through `mix sdr.calibration.console`.

  The console is the test-seam build (`MIX_ENV=test`, `:claude_cli_test_seams`)
  serving the fixed, persistent `sdr_agent_calibration` database, so the
  owner can bootstrap their admin account, sign in and create the single
  G-R0 grant on `/admin`. It is not the demo smoke server (`bin/demo --test
  serve`, `sdr_agent_test…_demo`) and shares nothing with it.

  `plan/1` derives the only configuration it serves with from the build's
  own configuration, or refuses:

    * **Database.** Always `sdr_agent_calibration` (`database/0`): the test
      config's `sdr_agent_test<partition>` name is replaced, never used. A
      Repo `:url` (it would override the name), a non-local host or a port
      other than the devenv Postgres 5520 is refused. The SQL sandbox pool
      is replaced by an ordinary pool of 5 connections.
    * **Listener.** Always loopback `127.0.0.1:4124` (`bind/0`): whatever
      `PORT` or address the configuration names is replaced; `:https` is
      dropped.
    * **Secrets.** The endpoint `secret_key_base` and the token signing
      secret are the per-machine values of
      `SdrAgent.CalibrationConsole.Secrets` (a 0600 file outside the
      repository), never the build's checked-in test values, which are
      public: a plan without them, or with a checked-in value, is refused.
    * **No model server.** Only the deterministic Fake provider is accepted,
      so `SdrAgent.AI.ModelProvider.Runtime.children/0` starts no ClaudeCLI
      server, and Oban stays in `testing: :manual` (jobs are never
      executed), so no agent run can start.

    * **Witness store and result wait (R0-07f).** The only new input is
      `SDR_WITNESS_STORE_ROOT`, read by `current/1`: the witness proxy's
      store root. A present value must have no control character and pass
      `SdrAgent.Agents.Witness.Store.validate_root/1` unchanged (nothing is
      created or repaired), or every command is refused; an absent one plans
      `nil`, and `require/2` then refuses `calibrate` and every
      `calibrate-recover ID` (the other commands need no capture). The
      plan's `result_gate` is `ResultGate`'s own ceiling and default poll
      (120 s, 1 s), never the test build's lowered wait.

  `apply!/2` puts the plan into the application environment (for this VM
  only), including the Witness root and wait (`apply_capture!/1`), `ensure_storage!/0` creates the database if it is absent and runs
  pending migrations — there is no drop, reset or seed — and
  `verify_started!/1` re-checks, after start, that the Repo serves the fixed
  database, that the Witness root and wait are still the plan's, and that
  no ClaudeCLI server is running.
  """

  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.Witness
  alias SdrAgent.Agents.Witness.Store
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.AI.ModelProvider.Runtime

  @database "sdr_agent_calibration"
  @ip {127, 0, 0, 1}
  @port 4124
  @db_port 5520
  @local_hosts ["localhost", "127.0.0.1"]
  @witness_variable "SDR_WITNESS_STORE_ROOT"
  @result_gate [wait_ms: 120_000, poll_ms: 1_000]

  @typedoc "What `plan/1` reads: the build's environment and configuration."
  @type config :: %{
          required(:mix_env) => atom(),
          required(:test_seams?) => boolean(),
          required(:model_provider) => module(),
          required(:repo) => keyword(),
          required(:endpoint) => keyword(),
          required(:oban) => keyword(),
          optional(:token_signing_secret) => String.t() | nil,
          optional(:secrets) => SdrAgent.CalibrationConsole.Secrets.t(),
          optional(:witness_store_root) => String.t() | nil,
          optional(:witness) => keyword()
        }

  @typedoc "The configuration the console serves with (it holds the secrets: never print it)."
  @type plan :: %{
          repo: keyword(),
          endpoint: keyword(),
          oban: keyword(),
          token_signing_secret: String.t(),
          model_provider: module(),
          model_server: :none,
          witness: %{store_root: String.t() | nil},
          witness_env: keyword(),
          result_gate: keyword()
        }

  @typedoc "A console command, for `require/2`."
  @type command ::
          :check
          | :serve
          | :bootstrap_admin
          | {:calibrate, atom()}
          | {:recover, String.t() | nil}

  @doc "The only database the console serves."
  def database, do: @database

  @doc "The only address and port the console listens on."
  def bind, do: {@ip, @port}

  @doc "The build's current configuration, as `plan/1` reads it."
  @spec current(atom()) :: config()
  def current(mix_env) do
    %{
      mix_env: mix_env,
      test_seams?: Application.get_env(:sdr_agent, :claude_cli_test_seams, false) == true,
      model_provider: Application.get_env(:sdr_agent, :model_provider),
      repo: Application.get_env(:sdr_agent, SdrAgent.Repo, []),
      endpoint: Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, []),
      oban: Application.get_env(:sdr_agent, Oban, []),
      token_signing_secret: Application.get_env(:sdr_agent, :token_signing_secret),
      witness_store_root: System.get_env(@witness_variable),
      witness: Application.get_env(:sdr_agent, Witness, [])
    }
  end

  @doc "The console's configuration derived from `config`, or the refusal."
  @spec plan(config()) :: {:ok, plan()} | {:error, String.t()}
  def plan(config) do
    with :ok <- check_build(config),
         :ok <- check_repo(config.repo),
         :ok <- check_provider(config.model_provider),
         {:ok, secrets} <- check_secrets(config),
         {:ok, root} <- check_witness_root(Map.get(config, :witness_store_root)) do
      {:ok,
       %{
         repo: repo(config.repo),
         endpoint:
           Keyword.put(endpoint(config.endpoint), :secret_key_base, secrets.secret_key_base),
         token_signing_secret: secrets.token_signing_secret,
         oban: Keyword.put(config.oban, :testing, :manual),
         model_provider: Fake,
         model_server: :none,
         witness: %{store_root: root},
         witness_env: Map.get(config, :witness, []),
         result_gate: @result_gate
       }}
    end
  end

  @doc """
  Whether `command` may run under `plan`: `calibrate` and every
  `calibrate-recover ID` need the witness store root (the call's evidence
  and sent recovery read it); `check`, `serve`, `bootstrap-admin` and
  `calibrate-recover --release-aborted` (`{:recover, nil}`) do not. Returns
  `:ok` or `{:error, message}`.
  """
  @spec require(plan(), command()) :: :ok | {:error, String.t()}
  def require(%{witness: %{store_root: root}}, command)
      when command in [:check, :serve, :bootstrap_admin] or command == {:recover, nil} or
             is_binary(root),
      do: :ok

  def require(_plan, {kind, _arg}) when kind in [:calibrate, :recover] do
    {:error,
     "#{@witness_variable} is not set: calibrate and calibrate-recover ID need the witness " <>
       "proxy's store root"}
  end

  # An explicitly supplied root must be exactly a trusted directory: no
  # control character (it is printed on a machine-read line), then the
  # store's own check. Absent is allowed; nothing is created or repaired.
  defp check_witness_root(nil), do: {:ok, nil}

  defp check_witness_root(root) when is_binary(root) do
    if String.match?(root, ~r/[\x00-\x1F\x7F]/) do
      witness_refusal(root, "it contains a control character")
    else
      case Store.validate_root(root) do
        {:ok, ^root} -> {:ok, root}
        {:error, reason} -> witness_refusal(root, reason)
      end
    end
  end

  defp witness_refusal(root, reason) do
    {:error,
     "#{@witness_variable}=#{inspect(root)} is not a trusted witness store root " <>
       "(#{reason}); unset it, or name the witness proxy's store directory"}
  end

  defp check_build(%{mix_env: :test, test_seams?: true}), do: :ok

  defp check_build(%{mix_env: env}) do
    {:error,
     "the calibration console runs only the test-seam build (MIX_ENV=test) with " <>
       ":claude_cli_test_seams; this is MIX_ENV=#{env}"}
  end

  defp check_repo(repo) do
    host = repo[:hostname]
    port = repo[:port]

    cond do
      repo[:url] not in [nil, ""] ->
        {:error,
         "a Repo :url is configured; the calibration console serves only #{@database} " <>
           "on the local devenv Postgres"}

      host not in @local_hosts ->
        {:error, "database host #{host || "?"} is not local"}

      port != @db_port ->
        {:error, "database port #{port || "?"} is not the devenv Postgres port #{@db_port}"}

      true ->
        :ok
    end
  end

  defp check_provider(Fake), do: :ok

  defp check_provider(other) do
    {:error,
     "the calibration console starts no model server: the model provider must be the " <>
       "Fake (is #{inspect(other)}); unset SDR_MODEL_PROVIDER"}
  end

  # The build's own (checked-in, public) values, as configured and as this
  # VM's application environment holds them before `apply!/2`.
  defp check_secrets(%{secrets: %{secret_key_base: base, token_signing_secret: token}} = config)
       when is_binary(base) and is_binary(token) do
    checked_in =
      Enum.reject(
        [
          config.endpoint[:secret_key_base],
          Map.get(config, :token_signing_secret),
          Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])[:secret_key_base],
          Application.get_env(:sdr_agent, :token_signing_secret)
        ],
        &is_nil/1
      )

    if base in checked_in or token in checked_in do
      {:error,
       "the calibration console never serves with the checked-in test secrets; " <>
         "check #{SdrAgent.CalibrationConsole.Secrets.default_path()}"}
    else
      {:ok, %{secret_key_base: base, token_signing_secret: token}}
    end
  end

  defp check_secrets(_config) do
    {:error,
     "the calibration console has no per-machine secrets " <>
       "(#{SdrAgent.CalibrationConsole.Secrets.default_path()})"}
  end

  defp repo(repo) do
    repo
    |> Keyword.delete(:url)
    |> Keyword.merge(database: @database, pool: DBConnection.ConnectionPool, pool_size: 5)
  end

  defp endpoint(endpoint) do
    endpoint
    |> Keyword.delete(:https)
    |> Keyword.merge(
      server: true,
      http: [ip: @ip, port: @port],
      url: [host: "127.0.0.1", port: @port],
      check_origin: ["//127.0.0.1:#{@port}", "//localhost:#{@port}"]
    )
  end

  @doc """
  The plan as one line, checked by `bin/calibration-console` before it
  serves: database, database host and port, bind address and port, model
  provider and model server.
  """
  @spec plan_line(plan()) :: String.t()
  def plan_line(plan) do
    {a, b, c, d} = plan.endpoint[:http][:ip]

    Enum.join(
      [
        "SDR_CALIBRATION_CONSOLE",
        plan.repo[:database],
        plan.repo[:hostname],
        plan.repo[:port],
        "#{a}.#{b}.#{c}.#{d}",
        plan.endpoint[:http][:port],
        inspect(plan.model_provider),
        plan.model_server
      ],
      " "
    )
  end

  @doc """
  The witness line `check` prints after the plan line:
  `SDR_CALIBRATION_WITNESS set <root>` (the root verbatim; `plan/1` refuses
  any control character, so it is one line) or `SDR_CALIBRATION_WITNESS
  unset`.
  """
  @spec witness_line(plan()) :: String.t()
  def witness_line(%{witness: %{store_root: nil}}), do: "SDR_CALIBRATION_WITNESS unset"
  def witness_line(%{witness: %{store_root: root}}), do: "SDR_CALIBRATION_WITNESS set " <> root

  @doc """
  Puts `plan` into this VM's application environment, before the app
  starts. `serve: true` also activates `SdrAgentWeb.CalibrationConsole`
  (sign-in and `/admin` only); otherwise the endpoint does not listen.
  """
  @spec apply!(plan(), keyword()) :: :ok
  def apply!(plan, opts) do
    serve? = Keyword.fetch!(opts, :serve)

    Application.put_env(:sdr_agent, SdrAgent.Repo, plan.repo)
    Application.put_env(:sdr_agent, Oban, plan.oban)
    Application.put_env(:sdr_agent, :model_provider, plan.model_provider)
    Application.put_env(:sdr_agent, :token_signing_secret, plan.token_signing_secret)

    Application.put_env(
      :sdr_agent,
      SdrAgentWeb.Endpoint,
      Keyword.put(plan.endpoint, :server, serve?)
    )

    if serve?, do: Application.put_env(:sdr_agent, SdrAgentWeb.CalibrationConsole, active: true)
    apply_capture!(plan)

    endpoint = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])

    (endpoint[:secret_key_base] == plan.endpoint[:secret_key_base] and
       Application.get_env(:sdr_agent, :token_signing_secret) == plan.token_signing_secret) ||
      raise "the console's secrets were not applied"

    verify_applied!()
  end

  @doc """
  Puts the plan's witness root (the build's `Witness` configuration with
  only `store_root` replaced, so the shipped allowlist stays as built) and
  its result wait into this VM, then verifies them against the plan.
  Called by `apply!/2`.
  """
  @spec apply_capture!(plan()) :: :ok
  def apply_capture!(plan) do
    Application.put_env(
      :sdr_agent,
      Witness,
      Keyword.put(plan.witness_env, :store_root, plan.witness.store_root)
    )

    Application.put_env(:sdr_agent, ResultGate, plan.result_gate)
    verify_capture!(plan)
  end

  # Against the values the plan carries, never a second environment read.
  defp verify_capture!(plan) do
    witness = Application.get_env(:sdr_agent, Witness, [])
    gate = Application.get_env(:sdr_agent, ResultGate, [])

    Witness.store_root() == plan.witness.store_root ||
      raise "the witness store root is not the plan's"

    Witness.reconciled_methods() == [] || raise "the shipped witness allowlist is not empty"
    witness[:allow_method_override] == true || raise "the calibration method override is off"

    (ResultGate.wait_ms() == plan.result_gate[:wait_ms] and
       gate[:poll_ms] == plan.result_gate[:poll_ms]) ||
      raise "the result wait is not the plan's"

    :ok
  end

  defp verify_applied! do
    database = Keyword.fetch!(SdrAgent.Repo.config(), :database)
    database == @database || raise "the Repo would serve #{database}, not #{@database}"
    Runtime.children() == [] || raise "the model provider would start a model server"
    :ok
  end

  @doc """
  Creates `sdr_agent_calibration` if it does not exist and runs pending
  migrations. Never drops, resets or seeds it. Run after `apply!/2` and
  before the app starts.
  """
  @spec ensure_storage!() :: :ok
  def ensure_storage! do
    verify_applied!()
    config = SdrAgent.Repo.config()

    case SdrAgent.Repo.__adapter__().storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "could not create #{@database}: #{inspect(reason)}"
    end

    {:ok, _, _} =
      Ecto.Migrator.with_repo(SdrAgent.Repo, &Ecto.Migrator.run(&1, :up, all: true))

    :ok
  end

  @doc """
  `serve` refuses to start without the built LiveView bundle and stylesheet
  in `static_dir` (default: this app's `priv/static`): the sign-in and admin
  pages are LiveViews and would render but never respond. Nothing is built
  here; the owner runs `mix assets.build`.
  """
  @spec check_assets(Path.t()) :: :ok | {:error, String.t()}
  def check_assets(static_dir \\ Application.app_dir(:sdr_agent, "priv/static")) do
    case Enum.reject(
           ["assets/js/app.js", "assets/css/app.css"],
           &File.regular?(Path.join(static_dir, &1))
         ) do
      [] ->
        :ok

      [missing | _] ->
        {:error,
         "#{Path.join(static_dir, missing)} is missing: the console's pages would not respond; " <>
           "build the assets first (mix assets.build)"}
    end
  end

  @doc """
  After start: the Repo serves `sdr_agent_calibration`, the Witness root
  and result wait are still `plan`'s, and no ClaudeCLI server runs.
  """
  @spec verify_started!(plan()) :: :ok
  def verify_started!(plan) do
    verify_applied!()
    verify_capture!(plan)
    ClaudeCLI.running?(ClaudeCLI.server()) && raise "a ClaudeCLI model server is running"
    :ok
  end
end
