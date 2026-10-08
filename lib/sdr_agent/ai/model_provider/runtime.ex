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
      `ClaudeCLI.server/0`, with the configured `:timeout`, when ClaudeCLI
      is selected; none for the Fake. One server serialises every call
      (concurrency 1, ADR-0004 / ADR-0005 C8).
    * `resolve/1` — a run's model options (`:provider`,
      `:provider_options`) with the provider made explicit and, for
      ClaudeCLI, the named server injected — the one validated selection
      used by `SdrAgent.SDR.AgentWorker`, `SdrAgent.SDR.ReplyWorker` and
      the public `SdrAgent.AI.ModelProvider.complete/2`. An absent or
      unhealthy ClaudeCLI is a typed refusal before any reservation:
      `{:error, :provider_not_running}`, `:provider_not_quiescent`
      (admission closed) or `:llm_proxy_shim_not_found` — never a raise and
      never a silent fallback to the Fake. Per-call init attestation stays
      mandatory; this health check is in addition to it.
    * `status/0` — what the Admin page shows: the configured and the
      effective provider (nil, with the refusal, when calls are refused),
      model alias and resolved id, reviewed CLI version, server state and
      the last init attestation with its time. No secret is read.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI

  @doc "The selected provider module (`config :sdr_agent, :model_provider`)."
  def provider, do: Application.fetch_env!(:sdr_agent, :model_provider)

  @doc "Supervision children for the selected provider."
  def children do
    case provider() do
      ClaudeCLI ->
        options =
          :sdr_agent
          |> Application.get_env(ClaudeCLI, [])
          |> Keyword.take([:timeout])
          |> Keyword.put(:name, ClaudeCLI.server())

        [{ClaudeCLI, options}]

      _other ->
        []
    end
  end

  @doc """
  Makes `model`'s provider explicit (default: the selected one) and, for
  ClaudeCLI, injects the named server. Refused (`{:error, reason}`) when
  the ClaudeCLI server it would use is not running, does not admit calls,
  or found no `llm-proxy-shim` (the last two are known only for a named
  server).
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

  defp healthy(server) do
    cond do
      not ClaudeCLI.running?(server) -> {:error, :provider_not_running}
      not is_atom(server) -> :ok
      ClaudeCLI.admission(server).admission != :open -> {:error, :provider_not_quiescent}
      ClaudeCLI.attestation(server)[:command?] == false -> {:error, :llm_proxy_shim_not_found}
      true -> :ok
    end
  end

  @doc """
  The run `failure_reason` recorded when a worker refuses to run because of
  `reason` (`:provider_not_running`, `:provider_not_quiescent`,
  `:llm_proxy_shim_not_found` or `:unknown_model_provider`); no model call
  was made.
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
        provenance = ClaudeCLI.provenance()

        %{
          provider: ClaudeCLI,
          model_alias: provenance.model_catalog_entry["alias"],
          model_id: provenance.model_id,
          reviewed_version: provenance.provider_version,
          server: server_state(),
          attestation: ClaudeCLI.attestation(ClaudeCLI.server())
        }

      module ->
        %{
          provider: module,
          model_alias: nil,
          model_id: model_id(module),
          reviewed_version: nil,
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
  defp model_id(module) do
    case module.prepare(%{}, []) do
      {:ok, %{model_id: model_id}} -> model_id
      _refused -> nil
    end
  end
end
