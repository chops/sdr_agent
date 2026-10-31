defmodule SdrAgent.AI.ModelProvider.ClaudeCLI.Remote do
  @moduledoc """
  S-B4 (ADR-0024, plan r2): the ClaudeCLI provider when the trusted
  transport is `:remote` (`config :sdr_agent, :model_transport`). The call
  runs on the owner's enrolled Mac worker, never on this host: no local
  server, port, reaper or shim is used or checked.

    * `prepare/2` reads the current live binding's active worker through
      `SdrAgent.Operations.remote_worker_status/1` (the request actor's
      tenant only). No active worker → `{:error, :provider_not_running}`;
      paused intake → `{:error, :provider_held}`; no heartbeat in the last
      60 s, or one later than now (S-B6 `availability/1`) →
      `{:error, :provider_offline}`; enrolled pins that are not
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

  In a build without the prototype authority (`:prototype_authority_compiled`
  unset, the production build) there is no live binding and so no worker:
  `prepare/2` always refuses `{:error, :provider_not_running}`.
  """
  @behaviour SdrAgent.AI.ModelProvider

  @prototype_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)
  @impl true
  def complete(_request, _opts), do: :remote_dispatched

  # Compiled only with the prototype authority: only that build has a live
  # binding, so a worker. The production build has none and refuses.
  if @prototype_compiled do
    alias SdrAgent.Agents.RemoteCalls
    alias SdrAgent.AI.ModelProfiles
    alias SdrAgent.AI.ModelProvider
    alias SdrAgent.AI.ModelProvider.ClaudeCLI

    # S-B6: a heartbeat at most this old (inclusive, microseconds) is fresh.
    @freshness_us 60_000_000

    @doc """
    S-B6: whether the actor's current Mac worker can take work now. `:ok`
    only for an active worker with open intake whose `last_seen_at` lies in
    [now - 60 s, now] (server clock, microsecond precision); else
    `{:error, :provider_not_running}` (no active worker),
    `{:error, :provider_held}` (paused intake) or
    `{:error, :provider_offline}` (no heartbeat, older than 60 s or later
    than now). A lock-free point read, never admission evidence: the claim
    rechecks under its own locks. `prepare/2` applies it first.
    """
    def availability(actor) do
      with {:ok, status} <- SdrAgent.Operations.remote_worker_status(actor),
           do: available(status)
    end

    @impl true
    def prepare(request, _opts) do
      with {:ok, status} <- SdrAgent.Operations.remote_worker_status(request.actor),
           :ok <- available(status),
           {:ok, profile} <- compiled_profile(status),
           :ok <- deliverable(request) do
        {:ok, ClaudeCLI.provenance(profile)}
      end
    end

    defp available(%{present?: true, intake: :open, last_seen_at: seen}), do: fresh(seen)
    defp available(%{present?: true}), do: {:error, :provider_held}
    defp available(_absent), do: {:error, :provider_not_running}

    # The inclusive window [now - 60 s, now]; nil or anything else fails
    # closed. DateTime.diff in microseconds keeps sub-millisecond skew.
    defp fresh(%DateTime{} = seen) do
      age = DateTime.diff(SdrAgent.Clock.utc_now(), seen, :microsecond)
      if age >= 0 and age <= @freshness_us, do: :ok, else: {:error, :provider_offline}
    end

    defp fresh(_none), do: {:error, :provider_offline}

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
  else
    @doc "Production build: no live binding, so no worker."
    def availability(_actor), do: {:error, :provider_not_running}

    @impl true
    def prepare(_request, _opts), do: {:error, :provider_not_running}
  end
end
