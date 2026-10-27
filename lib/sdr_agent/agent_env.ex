defmodule SdrAgent.AgentEnv do
  @moduledoc """
  The attested agent environment `agentenv-1` (ADR-0004 agent-environment
  amendment; ADR-0005 C2* amendment item 2; plan
  `claude-c2star-s1-environment-plan-r2.md` section 4.1): its fixed
  identity, the selected mode, and the plain database-identity reads the
  operation snapshot's consumers compare against its bound environment.

  The configuration is `config :sdr_agent, SdrAgent.AgentEnv, root:, mode:,
  step:, nonce:, database:`. Only `config/runtime.exs` (S1 PR-B) and the
  `async: false` test fixtures write it. Without it `mode/0` is `:none`:
  every snapshot entry runs its body unchanged, nothing is observed or
  emitted, and no check consults a snapshot (the owner's instance, dev and
  prod today). A configuration that is not a keyword list or names an
  unknown mode raises on read, so it can never be taken for "inert".

  `live_database_identity/0` is a plain read (no lock clause, no file I/O),
  callable inside a transaction and under the chain head (R4).
  `check_live_binding/2` and `check_tenant/2` are pure comparisons.
  """

  alias SdrAgent.Repo

  @environment_id "agentenv-1"
  @database "sdr_agent_agentenv"
  @http_port 4130
  @environment_end ~U[2026-11-01 06:00:00.000000Z]
  @modes [:check, :bootstrap, :provisioning, :run]
  @identity_sql "SELECT current_database()::text, d.oid::bigint FROM pg_database d " <>
                  "WHERE d.datname = current_database()"

  @type mode :: :none | :check | :bootstrap | :provisioning | :run

  @doc "The environment's identifier."
  @spec environment_id() :: String.t()
  def environment_id, do: @environment_id

  @doc "The environment's database name."
  @spec database() :: String.t()
  def database, do: @database

  @doc "The environment's HTTP port in run mode."
  @spec http_port() :: 4130
  def http_port, do: @http_port

  @doc "The environment's end: no authority at or after this instant (exclusive)."
  @spec environment_end() :: DateTime.t()
  def environment_end, do: @environment_end

  @doc "The configured mode, or `:none` when there is no configuration (inert)."
  @spec mode() :: mode()
  def mode do
    case config() do
      [] -> :none
      config -> configured_mode(Keyword.get(config, :mode))
    end
  end

  defp configured_mode(mode) when mode in @modes, do: mode

  defp configured_mode(_mode),
    do: raise(ArgumentError, "the SdrAgent.AgentEnv configuration names no valid mode")

  @doc "Whether an agent environment is configured (`mode/0` is not `:none`)."
  @spec configured?() :: boolean()
  def configured?, do: mode() != :none

  @doc false
  # The configuration keyword (`[]` when unset); read by State and the
  # operation snapshot only.
  @spec config() :: keyword()
  def config do
    case Application.get_env(:sdr_agent, __MODULE__) do
      nil ->
        []

      config when is_list(config) ->
        config

      _other ->
        raise ArgumentError, "the SdrAgent.AgentEnv configuration is not a keyword list"
    end
  end

  @doc """
  The live database's name and oid, by a plain read; any failure denies
  (`{:error, :database_identity_unavailable}`).
  """
  @spec live_database_identity() ::
          {:ok, %{database: String.t(), database_oid: pos_integer()}}
          | {:error, :database_identity_unavailable}
  def live_database_identity do
    case Repo.query(@identity_sql, []) do
      {:ok, %{rows: [[name, oid]]}} when is_binary(name) and is_integer(oid) and oid > 0 ->
        {:ok, %{database: name, database_oid: oid}}

      _other ->
        {:error, :database_identity_unavailable}
    end
  rescue
    _error -> {:error, :database_identity_unavailable}
  catch
    :exit, _reason -> {:error, :database_identity_unavailable}
  end

  @doc """
  `:ok` when the live `identity` (`live_database_identity/0`) has the bound
  `environment`'s database name and then its oid; each mismatch has its own
  reason.
  """
  @spec check_live_binding(map(), map()) ::
          :ok | {:error, :database_name_mismatch | :database_oid_mismatch}
  def check_live_binding(%{database: database, database_oid: oid}, %{
        database: live_database,
        database_oid: live_oid
      })
      when is_binary(database) and database == live_database do
    if is_integer(oid) and oid == live_oid, do: :ok, else: {:error, :database_oid_mismatch}
  end

  def check_live_binding(_environment, _identity), do: {:error, :database_name_mismatch}

  @doc "`:ok` when `tenant_id` is the bound `environment`'s tenant."
  @spec check_tenant(map(), String.t()) :: :ok | {:error, :tenant_mismatch}
  def check_tenant(%{tenant_id: tenant_id}, tenant_id) when is_binary(tenant_id), do: :ok
  def check_tenant(_environment, _tenant_id), do: {:error, :tenant_mismatch}
end
