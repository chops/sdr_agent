defmodule SdrAgentWeb.LiveViewMountLog do
  @moduledoc """
  Replaces `Phoenix.LiveView.Logger`'s connected-mount line (Codex M2).
  The stock handler logs the LiveView session unfiltered at the view's log
  level (`:debug`), and a signed-in operator's session carries the bearer
  `user_token`. This handler logs the same `MOUNT` line with both the
  parameters and the session passed through `Phoenix.Logger.filter_values/1`
  (`config :phoenix, :filter_parameters`: `token` covers `user_token` and
  `_csrf_token`). `install/0` (application start) detaches only the stock
  mount-start handler and attaches this one; LiveView's other lifecycle
  lines (parameters only, already filtered) are unchanged.
  """

  require Logger

  @event [:phoenix, :live_view, :mount, :start]
  @id {__MODULE__, :mount_start}

  @doc "Swaps the stock mount-start handler for this one (idempotent)."
  @spec install() :: :ok
  def install do
    _ = :telemetry.detach({Phoenix.LiveView.Logger, @event})
    _ = :telemetry.detach(@id)
    :ok = :telemetry.attach(@id, @event, &__MODULE__.mount_start/4, %{})
  end

  @doc false
  def mount_start(
        _event,
        _measurements,
        %{socket: socket, params: params, session: session},
        _config
      ) do
    level = Map.fetch!(socket.view.__live__(), :log)

    if level && Phoenix.LiveView.connected?(socket) do
      Logger.log(level, fn ->
        [
          "MOUNT ",
          inspect(socket.view),
          ?\n,
          "  Parameters: ",
          inspect(Phoenix.Logger.filter_values(params)),
          ?\n,
          "  Session: ",
          inspect(Phoenix.Logger.filter_values(session))
        ]
      end)
    end

    :ok
  end
end
