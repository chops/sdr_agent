defmodule SdrAgent.AI.ModelProvider.Runtime do
  @moduledoc """
  The runtime-selected model provider (ADR-0004 runtime-selection
  amendment, Q0.1).

  `config/runtime.exs` reads `SDR_MODEL_PROVIDER` into `config :sdr_agent,
  :model_provider`: the deterministic `Fake` unless the value is
  `claude_cli` in development (refused in test and prod, so tests stay
  hermetic and ClaudeCLI stays personal and local). This module turns that
  choice into:

    * `children/0` — the supervision children: exactly one
      `SdrAgent.AI.ModelProvider.ClaudeCLI` server, registered as
      `ClaudeCLI.server/0`, with the configured `:timeout`, the app's
      pinned CLI `:executable` (`SDR_CLAUDE_CLI_BIN`, R0-02) and the
      `desired_profile/0` (R0-03), when ClaudeCLI is selected; none for the
      Fake. One server serialises every call (concurrency 1, ADR-0004 /
      ADR-0005 C8).
    * `resolve/1` — a run's model options (`:provider`,
      `:provider_options`) with the provider made explicit and, for
      ClaudeCLI, the named server injected — the one validated selection
      used by `SdrAgent.SDR.AgentWorker`, `SdrAgent.SDR.ReplyWorker` and
      the public `SdrAgent.AI.ModelProvider.complete/2`. An absent or
      unhealthy ClaudeCLI is a typed refusal before any reservation:
      `{:error, :provider_not_running}`, `:provider_not_quiescent`
      (admission closed), `:llm_proxy_shim_not_found` or
      `:pinned_cli_unavailable` (no pin, or the pinned build is missing or
      is not the reviewed identity) or `:real_model_staged` (R0-02 staging:
      no ordinary real call until R0-03, C9 and R0-07 land; only a test
      build's injected launcher passes) — never a raise and never a silent
      fallback to the Fake or to `claude` on `PATH`. Per-call init attestation stays
      mandatory; this health check is in addition to it.
    * `status/0` — what the Admin page shows: the configured and the
      effective provider (nil, with the refusal, when calls are refused),
      model alias and resolved id, reviewed CLI version, the configured
      pinned CLI path (`cli_executable`), server state and the last init
      attestation with its time, and the `profile_id` those model fields
      belong to (the running server's, else the desired one). No secret is
      read and no CLI is run.
  """

  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable

  @doc "The selected provider module (`config :sdr_agent, :model_provider`)."
  def provider, do: Application.fetch_env!(:sdr_agent, :model_provider)

  @doc """
  The real profile the app's ClaudeCLI server is started with (R0-03).

  C2 seam: until the persisted `ModelProfileSetting` exists (C2-01), this is
  the registry's default, `:claude_cli_opus`; C2 replaces it with the
  tenant's persisted desired profile. It is deliberately not read from the
  application environment: only the audited in-app switch may choose
  another reviewed profile.
  """
  def desired_profile, do: ModelProfiles.default_real()

  @doc "Supervision children for the selected provider."
  def children do
    case provider() do
      ClaudeCLI ->
        options =
          :sdr_agent
          |> Application.get_env(ClaudeCLI, [])
          |> Keyword.take([:timeout, :executable])
          |> Keyword.put(:name, ClaudeCLI.server())
          |> Keyword.put(:profile, desired_profile())

        [{ClaudeCLI, options}]

      _other ->
        []
    end
  end

  @doc """
  Makes `model`'s provider explicit (default: the selected one) and, for
  ClaudeCLI, injects the named server. Refused (`{:error, reason}`) when
  the ClaudeCLI server it would use is not running, does not admit calls,
  found no `llm-proxy-shim`, has no acceptable pin, or is staged — for a
  named or unnamed server, however it is referenced (name or pid).
  """
  def resolve(model) when is_list(model) do
    model = Keyword.put_new_lazy(model, :provider, &provider/0)

    case model[:provider] do
      ClaudeCLI ->
        options =
          model
          |> Keyword.get(:provider_options, [])
          |> Keyword.put_new(:server, ClaudeCLI.server())

        with :ok <- healthy(options[:server]),
             do: {:ok, Keyword.put(model, :provider_options, options)}

      _other ->
        {:ok, model}
    end
  end

  # Health is read from the server's published status, whatever reference
  # (name, pid, {:global, _}, {:via, _, _}) addresses it: a registered
  # server by its name, an unnamed one by its pid (the status it publishes
  # in its process dictionary). The same admission, launcher, pin and
  # staging checks apply to both; a process that publishes no ClaudeCLI
  # status is refused.
  defp healthy(server) do
    if ClaudeCLI.running?(server) do
      pid = GenServer.whereis(server)
      published_health(registered_name(pid) || pid)
    else
      {:error, :provider_not_running}
    end
  end

  defp published_health(server) do
    admission = ClaudeCLI.admission(server).admission
    attestation = ClaudeCLI.attestation(server)

    cond do
      admission == :not_running -> {:error, :provider_not_running}
      admission != :open -> {:error, :provider_not_quiescent}
      attestation[:command?] == false -> {:error, :llm_proxy_shim_not_found}
      not pinned_cli_present?(attestation) -> {:error, :pinned_cli_unavailable}
      not attestation[:test_launcher?] -> {:error, :real_model_staged}
      true -> :ok
    end
  end

  # Re-checked on every resolution (file metadata only), so a pinned build
  # collected after boot is refused before any reservation. Without a pin
  # only a test build's injected launcher passes.
  defp pinned_cli_present?(%{executable: path}) when is_binary(path),
    do: PinnedExecutable.check(path) == :ok

  defp pinned_cli_present?(attestation), do: attestation[:test_launcher?] == true

  defp registered_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _unnamed_or_gone -> nil
    end
  end

  defp registered_name(_pid), do: nil

  @doc """
  The run `failure_reason` recorded when a worker refuses to run because of
  `reason` (`:provider_not_running`, `:provider_not_quiescent`,
  `:llm_proxy_shim_not_found`, `:pinned_cli_unavailable`,
  `:real_model_staged` or `:unknown_model_provider`); no model call was
  made.
  """
  def refusal_message(:provider_not_running),
    do:
      "model provider claude_cli is not running: no supervised ClaudeCLI server " <>
        "(select it with SDR_MODEL_PROVIDER=claude_cli); no model call was made"

  def refusal_message(:unknown_model_provider),
    do: "unknown model provider named by the job (fake or claude_cli); no model call was made"

  def refusal_message(:provider_not_quiescent),
    do:
      "model provider claude_cli refuses calls until earlier CLI work is confirmed stopped " <>
        "(see Admin); no model call was made"

  def refusal_message(:llm_proxy_shim_not_found),
    do: "model provider claude_cli found no llm-proxy-shim on PATH; no model call was made"

  def refusal_message(:real_model_staged),
    do:
      "model provider claude_cli is staged: real model calls stay unavailable until the " <>
        "reviewed profiles, owner call grants and witness work land (R0-03, C9, R0-07); " <>
        "no model call was made"

  def refusal_message(:pinned_cli_unavailable),
    do:
      "model provider claude_cli refuses calls: the app's pinned Claude CLI is not configured, " <>
        "missing or not the reviewed build (bin/app-claude-cli-root); no model call was made"

  @doc "The selected provider's status for operators (no secrets)."
  def status do
    configured = provider()

    {effective, refusal} =
      case resolve([]) do
        {:ok, model} -> {model[:provider], nil}
        {:error, reason} -> {nil, reason}
      end

    Map.merge(details(configured), %{
      configured: configured,
      effective: effective,
      refusal: refusal
    })
  end

  defp details(configured) do
    case configured do
      ClaudeCLI ->
        profile = ClaudeCLI.profile(ClaudeCLI.server()) || desired_profile()
        provenance = ClaudeCLI.provenance(profile)

        %{
          provider: ClaudeCLI,
          profile_id: profile,
          model_alias: provenance.model_catalog_entry["alias"],
          model_id: provenance.model_id,
          reviewed_version: provenance.provider_version,
          cli_executable:
            :sdr_agent |> Application.get_env(ClaudeCLI, []) |> Keyword.get(:executable),
          server: server_state(),
          attestation: ClaudeCLI.attestation(ClaudeCLI.server())
        }

      module ->
        prepared = prepared(module)

        %{
          provider: module,
          profile_id: prepared[:profile_id],
          model_alias: nil,
          model_id: prepared[:model_id],
          reviewed_version: nil,
          cli_executable: nil,
          server: :not_applicable,
          attestation: %{status: :not_applicable}
        }
    end
  end

  # :blocked while the named server refuses calls until earlier CLI work is
  # confirmed stopped (`ClaudeCLI.admission/1`).
  defp server_state do
    cond do
      not ClaudeCLI.running?(ClaudeCLI.server()) -> :not_running
      ClaudeCLI.admission(ClaudeCLI.server()).admission == :blocked -> :blocked
      true -> :running
    end
  end

  # In-process providers record their fixed provenance without a request.
  defp prepared(module) do
    case module.prepare(%{}, []) do
      {:ok, provenance} when is_map(provenance) -> provenance
      _refused -> %{}
    end
  end
end
