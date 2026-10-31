defmodule SdrAgent.AI.ModelProvider.ClaudeCLI.Remote do
  @moduledoc """
  S-B4 (ADR-0024, plan r2): the ClaudeCLI provider when the trusted
  transport is `:remote` (`config :sdr_agent, :model_transport`). The call
  runs on the owner's enrolled Mac worker, never on this host: no local
  server, port, reaper or shim is used or checked.

    * `prepare/2` reads the current live binding's active worker through
      `SdrAgent.Operations.remote_worker_status/1` (the request actor's
      tenant only). No active worker → `{:error, :provider_not_running}`;
      paused intake → `{:error, :provider_held}`; enrolled pins that are not
      exactly one compiled real profile's (profile, model and CLI version)
      → `{:error, :worker_pins_incompatible}`; a request whose stored body
      the remote reservation would refuse, including a worst-case launch
      response over 1048576 bytes (`SdrAgent.Agents.RemoteLaunch`) →
      `{:error, :remote_launch_too_large}`. Each refusal is before any
      reservation, so there is no charge. Otherwise it returns
      `ClaudeCLI.provenance/1` of that profile: provider `:claude_cli`, with
      the same profile, attestation and charge identity as a local call.
    * `complete/2` performs nothing and returns `:remote_dispatched`: the
      reservation already created the invocation's RemoteModelCall, which
      the worker claims and completes. `SdrAgent.AI.ModelProvider` accepts
      that reply from this module only, for an invocation that has a
      RemoteModelCall, and then waits (bounded) for the settler's outcome.
  """
  @behaviour SdrAgent.AI.ModelProvider

  alias SdrAgent.Agents.RemoteCalls
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI

  @impl true
  def prepare(request, _opts) do
    with {:ok, status} <- SdrAgent.Operations.remote_worker_status(request.actor),
         :ok <- available(status),
         {:ok, profile} <- compiled_profile(status),
         :ok <- deliverable(request) do
      {:ok, ClaudeCLI.provenance(profile)}
    end
  end

  @impl true
  def complete(_request, _opts), do: :remote_dispatched

  defp available(%{present?: true, intake: :open}), do: :ok
  defp available(%{present?: true}), do: {:error, :provider_held}
  defp available(_absent), do: {:error, :provider_not_running}

  # The enrolled pins name exactly one compiled real ClaudeCLI profile.
  defp compiled_profile(%{profile_id: id, model_id: model, cli_version: version}) do
    ModelProfiles.real_ids()
    |> Enum.map(&elem(ModelProfiles.fetch_real(&1), 1))
    |> Enum.find(
      &(&1.adapter == ClaudeCLI and Atom.to_string(&1.id) == id and &1.resolved_model == model and
          &1.cli_version == version)
    )
    |> case do
      nil -> {:error, :worker_pins_incompatible}
      profile -> {:ok, profile}
    end
  end

  # The same check the remote reservation applies to the same stored body.
  defp deliverable(request) do
    case RemoteCalls.check_request(ModelProvider.request_body(request)) do
      :ok -> :ok
      {:error, _message} -> {:error, :remote_launch_too_large}
    end
  end
end
