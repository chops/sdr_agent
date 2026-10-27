defmodule SdrAgent.AgentEnv.Instance do
  @moduledoc """
  The agent environment's leased start gate, phase P3 (plan
  `claude-c2star-s1-environment-plan-r2.md` section 4.5, as corrected by
  `claude-c2star-s1-prb-p5-correction-r1.md` section 2 item 1; Codex
  rulings `c9a6f6c7` and the `804340e1` review, 17-18).

  Supervised immediately after `SdrAgent.Repo` as `{Instance, mode}` with
  the default permanent restart. `init(mode)` runs the P3 checks and returns
  `:ignore`, so no process remains and no `terminate/2` writer exists, or
  `{:stop, reason}`, which aborts the boot (the lease stays: quarantine).
  The supervisor keeps the ignored child's spec, so a restart re-runs the
  checks.

    * **bootstrap:** the step task's declaration exists and is `seed` or
      `probe`; the live database name and oid equal
      `environment.created.json`'s.
    * **provisioning:** the declaration exists (`provision`); the live name
      and oid and the singleton tenant equal `environment.json`'s.
    * **run:** the live name, oid and tenant equal `environment.json`'s; no
      migration is recorded in the database that this build lacks; then
      readiness (the suppression check is the Outreach Store; with ClaudeCLI
      selected, `SpendReady.at_start/1` passes); then no run receipt exists
      for the nonce. Only then does it exclusively create the boot marker
      `instance.<nonce>.boot` (`nonce`, a fresh 32-hex `boot_id`,
      `booted_at`) and put `%{nonce:, boot_id:}` in `:persistent_term`
      `{SdrAgent.AgentEnv.Shutdown, :boot}`. An existing marker refuses
      (`:run_nonce_already_booted`): a nonce boots at most once. A refusal
      writes nothing and changes no file.

  Reasons: `:database_identity_unavailable`, `:database_name_mismatch`,
  `:database_oid_mismatch`, `:tenant_mismatch`, `:environment_unbound`,
  `:bootstrap_target_mismatch`, `:migration_not_in_build`,
  `:undeclared_step`, `:step_mode_mismatch`, `:suppression_check_not_store`,
  `:agent_env_not_spend_ready`, `:run_receipt_exists`,
  `:run_nonce_already_booted`, `:boot_marker_write_failed`,
  `:agent_env_not_configured`.
  """
  use GenServer

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Boot
  alias SdrAgent.AgentEnv.SpendReady
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Repo
  alias SdrAgent.SDR.SuppressionCheck

  @boot_binding {SdrAgent.AgentEnv.Shutdown, :boot}
  @not_in_build "** FILE NOT FOUND **"

  @doc false
  def start_link(mode), do: GenServer.start_link(__MODULE__, mode)

  @impl true
  def init(mode) do
    case check(mode) do
      :ok -> :ignore
      {:error, reason} -> {:stop, reason}
    end
  end

  defp check(:bootstrap) do
    with :ok <- declared([:seed, :probe]),
         {:ok, root} <- root(),
         {:ok, created} <- created(root),
         do: identity(created)
  end

  defp check(:provisioning) do
    with :ok <- declared([:provision]),
         {:ok, root} <- root(),
         {:ok, environment} <- environment(root),
         :ok <- identity(environment),
         do: tenant(environment)
  end

  defp check(:run) do
    with {:ok, root} <- root(),
         {:ok, environment} <- environment(root),
         :ok <- identity(environment),
         :ok <- tenant(environment),
         :ok <- migrations(),
         :ok <- suppression(),
         :ok <- spend_ready(root, environment),
         {:ok, nonce} <- nonce(),
         :ok <- no_run_receipt(root, nonce),
         do: boot(root, nonce)
  end

  defp check(_check_or_other), do: {:error, :undeclared_step}

  # The step task's declaration (Boot.declare_step!/1) of a permitted step.
  defp declared(permitted) do
    case Boot.declared_step() do
      nil -> {:error, :undeclared_step}
      step -> if step in permitted, do: :ok, else: {:error, :step_mode_mismatch}
    end
  end

  defp root do
    case State.root() do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp nonce do
    case Keyword.get(AgentEnv.config(), :nonce) do
      nonce when is_binary(nonce) -> {:ok, nonce}
      _missing -> {:error, :agent_env_not_configured}
    end
  end

  defp created(root) do
    case State.read(root, :created) do
      {:valid, _sha256, data} -> {:ok, data}
      _absent_or_invalid -> {:error, :bootstrap_target_mismatch}
    end
  end

  defp environment(root) do
    case State.read(root, :environment) do
      {:valid, _sha256, data} -> {:ok, data}
      _absent_or_invalid -> {:error, :environment_unbound}
    end
  end

  # The live database's name and then oid against the file's.
  defp identity(%{"database" => database, "database_oid" => oid}) do
    with {:ok, live} <- AgentEnv.live_database_identity() do
      AgentEnv.check_live_binding(%{database: database, database_oid: oid}, live)
    end
  end

  defp tenant(%{"tenant_id" => tenant_id}) do
    case Kernel.singleton_tenant_id() do
      {:ok, ^tenant_id} -> :ok
      _other -> {:error, :tenant_mismatch}
    end
  end

  # No migration recorded in the database that this build lacks. A plain
  # read: no migration lock and no schema_migrations table creation.
  defp migrations do
    statuses =
      Ecto.Migrator.migrations(Repo, Ecto.Migrator.migrations_path(Repo),
        migration_lock: false,
        skip_table_creation: true
      )

    if Enum.any?(statuses, &match?({_status, _version, @not_in_build}, &1)),
      do: {:error, :migration_not_in_build},
      else: :ok
  rescue
    _error -> {:error, :migration_not_in_build}
  end

  defp suppression do
    if SuppressionCheck.impl() == SuppressionCheck.Store,
      do: :ok,
      else: {:error, :suppression_check_not_store}
  end

  defp spend_ready(root, environment) do
    if Runtime.provider() == ClaudeCLI do
      views = %{
        environment: environment,
        authorization: State.read(root, :authorization),
        tenant_id: environment["tenant_id"]
      }

      # A dynamic call: S1's fail-closed body returns one fixed refusal, and
      # the type checker would otherwise reject the :ok branch S2 needs.
      case apply(SpendReady, :at_start, [views]) do
        :ok -> :ok
        _refused -> {:error, :agent_env_not_spend_ready}
      end
    else
      :ok
    end
  end

  defp no_run_receipt(root, nonce) do
    if State.read(root, {:run_receipt, nonce}) == :absent,
      do: :ok,
      else: {:error, :run_receipt_exists}
  end

  # The once-per-nonce boot marker, then the current boot binding.
  defp boot(root, nonce) do
    boot_id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    marker = %{"nonce" => nonce, "boot_id" => boot_id, "booted_at" => DateTime.utc_now()}

    case State.create(root, {:boot, nonce}, marker) do
      {:ok, _sha256} ->
        :persistent_term.put(@boot_binding, %{nonce: nonce, boot_id: boot_id})

      {:error, :exists} ->
        {:error, :run_nonce_already_booted}

      {:error, _reason} ->
        {:error, :boot_marker_write_failed}
    end
  end
end
