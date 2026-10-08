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
      ClaudeCLI, the named server injected. When that server is not running
      the result is `{:error, :provider_not_running}`: never a raise and
      never a silent fallback to the Fake.
    * `status/0` — what the Admin page shows: provider, model alias and
      resolved id, reviewed CLI version, server state and the last init
      attestation. No secret is read.
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
  ClaudeCLI, injects the named server; `{:error, :provider_not_running}`
  when the ClaudeCLI server it would use is not running.
  """
  def resolve(model) when is_list(model) do
    model = Keyword.put_new_lazy(model, :provider, &provider/0)

    case model[:provider] do
      ClaudeCLI ->
        options =
          model
          |> Keyword.get(:provider_options, [])
          |> Keyword.put_new(:server, ClaudeCLI.server())

        if ClaudeCLI.running?(options[:server]),
          do: {:ok, Keyword.put(model, :provider_options, options)},
          else: {:error, :provider_not_running}

      _other ->
        {:ok, model}
    end
  end

  @doc "The selected provider's status for operators (no secrets)."
  def status do
    case provider() do
      ClaudeCLI ->
        provenance = ClaudeCLI.provenance()

        %{
          provider: ClaudeCLI,
          model_alias: provenance.model_catalog_entry["alias"],
          model_id: provenance.model_id,
          reviewed_version: provenance.provider_version,
          server: if(ClaudeCLI.running?(ClaudeCLI.server()), do: :running, else: :not_running),
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

  # In-process providers record their fixed provenance without a request.
  defp model_id(module) do
    case module.prepare(%{}, []) do
      {:ok, %{model_id: model_id}} -> model_id
      _refused -> nil
    end
  end
end
