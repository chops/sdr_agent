defmodule SdrAgent.AgentEnv.Bootstrap do
  @moduledoc """
  The agent environment's guarded bootstrap effects (plan
  `claude-c2star-s1-environment-plan-r2.md` section 5.4, OQ 2/3, T-V9;
  ADR-0004 agent-environment amendment item 3 steps 1-8; Codex rulings
  `b684dba9` Q4 and the `31b72fea` review), called only by `mix
  sdr.agent_env`. Each validates first and acts only then; a refusal is a
  fixed reason atom and writes nothing.

    * `preflight/0` — in check mode, the root classifies `:fresh`
      (`:not_fresh`), the Repo configuration is exactly the bootstrap
      target (`:bootstrap_target_mismatch`), and ecto_sql's read-only
      `storage_status/1` for `sdr_agent_agentenv`, connecting only to the
      maintenance database `postgres`, is `:down` (`:database_exists`,
      `:storage_status_unavailable`). It never connects to an application
      database.
    * `step/1` — after `Boot.declare_step!/1` of the configured step
      (`:undeclared_step`), under the bootstrap lease of the configured
      nonce (`:lease_missing`, `:lease_invalid`, `:step_mode_mismatch`,
      `:agent_env_lease_mismatch`) and in the bootstrap order
      (`:step_out_of_order`):
      `create` needs the Repo target exactly `sdr_agent_agentenv` @
      `localhost:5520` (`:bootstrap_target_mismatch`), then `storage_up`
      (`:already_up` is `:database_exists`: quarantine, never a re-create),
      the created database's oid, `environment.created.json` and the
      receipt; `migrate`, `seed` and `probe` need `environment.created.json`
      of the nonce and then the live database's name and oid to be its
      (`:database_name_mismatch`, `:database_oid_mismatch`), then the
      migrator (`Ecto.Migrator.run(repo, :up, all: true)`), the demo seed
      (`mix sdr.demo.seed`) or the singleton tenant read, then the receipt
      (`probe` with `tenant_id`). No reset, drop, adoption or reclaim exists.
    * `publish/0` — in check mode, under the held bootstrap lease of the
      configured nonce with all four receipts (`:receipts_missing`),
      exclusively creates `environment.json` from `environment.created.json`
      and the probe's tenant (`:exists` if already published) and returns
      `{:ok, binding_sha256}`.

  Production builds export exactly `preflight/0`, `step/1` and `publish/0`,
  whose effects are fixed (ecto_sql's storage functions, `Ecto.Migrator`,
  the demo seed task and the plain database reads): no configuration
  selects them. Test-seam builds only (`config :sdr_agent,
  :claude_cli_test_seams, true`, compile time) also export `preflight/1`,
  `step/2` and `publish/1`, whose `adapter:` gives a stand-in for every
  effect (`repo_config`, `storage_status`, `storage_up`, `database_oid`,
  `live_identity`, `migrate`, `seed`, `tenant_id`; all eight, never a
  mixture with the real ones) and run them in the caller.
  """

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Boot
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Audit.Kernel, as: AuditKernel
  alias SdrAgent.Repo

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @steps [:create, :migrate, :seed, :probe]
  @maintenance_database "postgres"
  @connection_overrides [:url, :socket, :socket_dir, :endpoints]

  @type step :: :create | :migrate | :seed | :probe

  @doc "The bootstrap preflight (see the moduledoc)."
  @spec preflight() :: :ok | {:error, atom()}
  def preflight, do: preflight_with(production())

  @doc "One guarded bootstrap step (see the moduledoc)."
  @spec step(step()) :: :ok | {:error, atom()}
  def step(step) when step in @steps, do: step_with(step, production(), &session/2)

  @doc "Publishes `environment.json` (see the moduledoc)."
  @spec publish() :: {:ok, String.t()} | {:error, atom()}
  def publish, do: publish_with()

  if @test_seams do
    @adapter_keys [
      :database_oid,
      :live_identity,
      :migrate,
      :repo_config,
      :seed,
      :storage_status,
      :storage_up,
      :tenant_id
    ]

    @doc false
    # Test-seam builds only (see the moduledoc).
    def preflight(seams) when is_list(seams), do: preflight_with(adapter!(seams))

    @doc false
    # Test-seam builds only (see the moduledoc).
    def step(step, seams) when step in @steps and is_list(seams),
      do: step_with(step, adapter!(seams), fn _step, fun -> fun.() end)

    @doc false
    # Test-seam builds only (see the moduledoc); publish has no effect seam.
    def publish(seams) when is_list(seams) do
      _adapter = adapter!(seams)
      publish_with()
    end

    defp adapter!(seams) do
      adapter = Keyword.fetch!(seams, :adapter)

      unless is_map(adapter) and adapter |> Map.keys() |> Enum.sort() == @adapter_keys do
        raise ArgumentError, "the bootstrap adapter must give exactly every effect"
      end

      adapter
    end
  end

  ## Preflight

  defp preflight_with(adapter) do
    with :ok <- mode(:check),
         {:ok, root} <- State.root(),
         :ok <- fresh(root),
         {:ok, config} <- target_config(adapter) do
      config
      |> Keyword.merge(database: AgentEnv.database(), maintenance_database: @maintenance_database)
      |> storage_status(adapter)
    end
  end

  defp fresh(root) do
    if State.classify(root, :unknown) == :fresh, do: :ok, else: {:error, :not_fresh}
  end

  defp storage_status(config, adapter) do
    case guarded(fn -> adapter.storage_status.(config) end) do
      :down -> :ok
      :up -> {:error, :database_exists}
      _unclear -> {:error, :storage_status_unavailable}
    end
  end

  ## Steps

  defp step_with(step, adapter, session) do
    with :ok <- mode(:bootstrap),
         :ok <- declared(step),
         {:ok, root} <- State.root(),
         {:ok, nonce} <- leased(root),
         :ok <- in_order(root, nonce, step),
         {:ok, target} <- step_target(step, root, nonce, adapter) do
      session.(step, fn -> act(step, root, nonce, target, adapter) end)
    end
  end

  defp declared(step) do
    if Boot.declared_step() == step, do: :ok, else: {:error, :undeclared_step}
  end

  # The held bootstrap lease of the configured nonce.
  defp leased(root) do
    nonce = Keyword.get(AgentEnv.config(), :nonce)

    case State.read(root, :lease) do
      {:valid, _sha256, %{"mode" => "bootstrap", "nonce" => ^nonce}} when is_binary(nonce) ->
        {:ok, nonce}

      {:valid, _sha256, %{"mode" => "bootstrap"}} ->
        {:error, :agent_env_lease_mismatch}

      {:valid, _sha256, _other_mode} ->
        {:error, :step_mode_mismatch}

      :absent ->
        {:error, :lease_missing}

      {:invalid, _reason} ->
        {:error, :lease_invalid}
    end
  end

  # Every earlier step's receipt valid; this step's and every later one's
  # absent (and, for create, no created file).
  defp in_order(root, nonce, step) do
    {earlier, [^step | later]} = Enum.split_while(@steps, &(&1 != step))

    done? = Enum.all?(earlier, &match?({:valid, _, _}, State.read(root, {:receipt, nonce, &1})))
    open? = Enum.all?([step | later], &(State.read(root, {:receipt, nonce, &1}) == :absent))
    created_ok? = step != :create or State.read(root, :created) == :absent

    if done? and open? and created_ok?, do: :ok, else: {:error, :step_out_of_order}
  end

  defp step_target(:create, _root, _nonce, adapter), do: target_config(adapter)

  defp step_target(_step, root, nonce, _adapter), do: created(root, nonce)

  # environment.created.json of the nonce, for the agent environment's database.
  defp created(root, nonce) do
    database = AgentEnv.database()

    case State.read(root, :created) do
      {:valid, _sha256, %{"database" => ^database, "nonce" => ^nonce} = created} -> {:ok, created}
      _other -> {:error, :bootstrap_target_mismatch}
    end
  end

  defp act(:create, root, nonce, config, adapter) do
    case guarded(fn -> adapter.storage_up.(config) end) do
      :ok ->
        with {:ok, oid} <- created_oid(adapter, config),
             :ok <- write(root, :created, created_file(oid, nonce)) do
          receipt(root, nonce, :create, %{})
        end

      {:error, :already_up} ->
        {:error, :database_exists}

      _failed ->
        {:error, :storage_up_failed}
    end
  end

  defp act(step, root, nonce, created, adapter) do
    with :ok <- live(adapter, created),
         {:ok, extra} <- effect(step, adapter) do
      receipt(root, nonce, step, extra)
    end
  end

  defp created_file(oid, nonce),
    do: %{"database" => AgentEnv.database(), "database_oid" => oid, "nonce" => nonce}

  defp created_oid(adapter, config) do
    case guarded(fn -> adapter.database_oid.(config) end) do
      {:ok, oid} when is_integer(oid) and oid > 0 -> {:ok, oid}
      _unavailable -> {:error, :database_identity_unavailable}
    end
  end

  # The live database is the created one: its name, then its oid.
  defp live(adapter, %{"database" => database, "database_oid" => oid}) do
    case guarded(adapter.live_identity) do
      {:ok, %{database: _name, database_oid: _oid} = identity} ->
        AgentEnv.check_live_binding(%{database: database, database_oid: oid}, identity)

      _unavailable ->
        {:error, :database_identity_unavailable}
    end
  end

  defp effect(:migrate, adapter), do: done(guarded(adapter.migrate), %{}, :migrate_failed)
  defp effect(:seed, adapter), do: done(guarded(adapter.seed), %{}, :seed_failed)

  defp effect(:probe, adapter) do
    case guarded(adapter.tenant_id) do
      {:ok, tenant_id} when is_binary(tenant_id) -> {:ok, %{"tenant_id" => tenant_id}}
      _unavailable -> {:error, :tenant_unavailable}
    end
  end

  defp done(:ok, extra, _reason), do: {:ok, extra}
  defp done(_failed, _extra, reason), do: {:error, reason}

  defp receipt(root, nonce, step, extra) do
    data =
      Map.merge(
        %{"nonce" => nonce, "step" => Atom.to_string(step), "completed_at" => DateTime.utc_now()},
        extra
      )

    write(root, {:receipt, nonce, step}, data)
  end

  defp write(root, name, data) do
    case State.create(root, name, data) do
      {:ok, _sha256} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Publish

  defp publish_with do
    with :ok <- mode(:check),
         {:ok, root} <- State.root(),
         {:ok, nonce} <- leased(root),
         :ok <- receipts(root, nonce),
         {:ok, created} <- created(root, nonce),
         {:ok, tenant_id} <- probe_tenant(root, nonce) do
      State.create(root, :environment, %{
        "environment_id" => AgentEnv.environment_id(),
        "database" => created["database"],
        "database_oid" => created["database_oid"],
        "tenant_id" => tenant_id,
        "nonce" => nonce,
        "created_at" => DateTime.utc_now()
      })
    end
  end

  defp receipts(root, nonce) do
    if Enum.all?(@steps, &match?({:valid, _, _}, State.read(root, {:receipt, nonce, &1}))),
      do: :ok,
      else: {:error, :receipts_missing}
  end

  defp probe_tenant(root, nonce) do
    {:valid, _sha256, %{"tenant_id" => tenant_id}} = State.read(root, {:receipt, nonce, :probe})
    {:ok, tenant_id}
  end

  ## Shared checks

  defp mode(mode) do
    if AgentEnv.mode() == mode, do: :ok, else: {:error, :step_mode_mismatch}
  end

  # The Repo configuration is exactly the bootstrap target.
  defp target_config(adapter) do
    config = guarded(adapter.repo_config)

    target? =
      Keyword.keyword?(config) and Keyword.get(config, :database) == AgentEnv.database() and
        Keyword.get(config, :hostname) == "localhost" and Keyword.get(config, :port) == 5520 and
        Enum.all?(@connection_overrides, &is_nil(Keyword.get(config, &1)))

    if target?, do: {:ok, config}, else: {:error, :bootstrap_target_mismatch}
  end

  # Runs one effect; an exception or exit is a failure, never re-raised with
  # its (possibly sensitive) detail.
  defp guarded(fun) do
    fun.()
  rescue
    _error -> {:error, :effect_failed}
  catch
    :exit, _reason -> {:error, :effect_failed}
  end

  ## The production effects (fixed; never selectable)

  defp production do
    %{
      repo_config: fn -> Repo.config() end,
      storage_status: fn config -> Repo.__adapter__().storage_status(config) end,
      storage_up: fn config -> Repo.__adapter__().storage_up(config) end,
      database_oid: fn _config -> with_repo(&created_database_oid/0) end,
      live_identity: &AgentEnv.live_database_identity/0,
      migrate: &migrate/0,
      seed: &seed/0,
      tenant_id: &AuditKernel.singleton_tenant_id/0
    }
  end

  # The production session of a step: create needs none (storage_up has its
  # own connection, the oid read starts the Repo); migrate runs under a
  # started Repo; seed and probe under the started application, whose
  # Instance (bootstrap) checks the declaration and the created database.
  defp session(:create, fun), do: fun.()
  defp session(:migrate, fun), do: with_repo(fun)

  defp session(step, fun) when step in [:seed, :probe] do
    Mix.Task.run("app.start")
    fun.()
  end

  defp with_repo(fun) do
    case Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end) do
      {:ok, result, _started} -> result
      {:error, _reason} -> {:error, :repo_unavailable}
    end
  end

  defp created_database_oid do
    database = AgentEnv.database()

    case AgentEnv.live_database_identity() do
      {:ok, %{database: ^database, database_oid: oid}} -> {:ok, oid}
      _other -> {:error, :database_identity_unavailable}
    end
  end

  defp migrate do
    _versions = Ecto.Migrator.run(Repo, :up, all: true)
    :ok
  end

  defp seed do
    Mix.Task.run("sdr.demo.seed")
    :ok
  end
end
