defmodule SdrAgentWeb.LiveRefresh do
  @moduledoc """
  Live refresh for console views (S13; ADR-0012). On the connected mount a
  view calls `attach/2` with its own reload function: it subscribes to the
  scope's tenant topic of committed audit events (`SdrAgent.LiveEvents`)
  and, when a relevant event arrives, re-runs that function — which re-reads
  everything through the public domain APIs with `actor: scope.user`
  (socket state is treated as stale; the event itself carries no data).

    * Bursts are coalesced: one reload per `debounce_ms` window
      (`config :sdr_agent, SdrAgentWeb.LiveRefresh, debounce_ms:`; default
      250, 0 reloads at once).
    * `access` and `auth` events are ignored: they change no domain data, and
      an auditor's reload itself records an AuditAccess, so reacting to
      access events would loop.
    * The reload runs the view's normal audited read path, so an auditor's
      refreshed view is recorded like any other view of it.
    * The operator is re-validated **when the reload fires** (also after a
      debounce), with `SdrAgentWeb.LiveUserAuth.revalidate/1`, exactly as for
      events and navigation: the reload runs as the freshly read user (a
      demoted operator reads with its new role, audited if now an auditor);
      a disabled or revoked operator is signed out, and a role-restricted
      view redirects, without loading anything.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias SdrAgent.LiveEvents
  alias SdrAgentWeb.LiveUserAuth

  @ignored ["access", "auth"]
  @pending :live_refresh_pending?

  @doc """
  Subscribes a connected view to its tenant's events and reloads it with
  `refresh` (`socket -> socket`) when one is relevant. A no-op on the
  disconnected render.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                               Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def attach(socket, refresh) when is_function(refresh, 1) do
    if connected?(socket) do
      :ok = LiveEvents.subscribe(socket.assigns.current_scope.user.tenant_id)

      socket
      |> assign(@pending, false)
      |> attach_hook(:live_refresh, :handle_info, &handle_info(&1, &2, refresh))
    else
      socket
    end
  end

  @doc "Whether an event can change what a console view shows."
  @spec relevant?(map()) :: boolean()
  def relevant?(%{category: category}), do: category not in @ignored
  def relevant?(_event), do: false

  defp handle_info({:sdr_audit_event, event}, socket, refresh) do
    cond do
      not relevant?(event) -> {:halt, socket}
      socket.assigns[@pending] -> {:halt, socket}
      debounce_ms() == 0 -> {:halt, fire(socket, refresh)}
      true -> {:halt, schedule(socket)}
    end
  end

  defp handle_info(:live_refresh, socket, refresh),
    do: {:halt, socket |> assign(@pending, false) |> fire(refresh)}

  defp handle_info(_message, socket, _refresh), do: {:cont, socket}

  # Re-validate at firing time; load only for a still-valid operator.
  defp fire(socket, refresh) do
    case LiveUserAuth.revalidate(socket) do
      {:ok, socket} -> refresh.(socket)
      {:error, redirected} -> redirected
    end
  end

  defp schedule(socket) do
    Process.send_after(self(), :live_refresh, debounce_ms())
    assign(socket, @pending, true)
  end

  defp debounce_ms do
    :sdr_agent |> Application.get_env(__MODULE__, []) |> Keyword.get(:debounce_ms, 250)
  end
end
