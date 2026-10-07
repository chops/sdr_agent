defmodule SdrAgent.LiveEvents.Relay do
  @moduledoc """
  Supervised listener (ADR-0012): holds a `Postgrex.Notifications`
  connection that `LISTEN`s on `SdrAgent.LiveEvents.channel/0` and
  re-broadcasts each committed audit event on its tenant's PubSub topic
  (`SdrAgent.LiveEvents.broadcast/1`).

  It connects asynchronously and reconnects on its own, so a database that is
  down at boot or restarts only pauses live refresh; notifications sent while
  it is disconnected are lost, which costs a live view nothing but an update
  (views re-read on navigation). Malformed payloads are ignored.
  """
  use GenServer

  alias SdrAgent.LiveEvents

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    config =
      SdrAgent.Repo.config()
      |> Keyword.drop([:pool, :pool_size, :pool_count, :name])
      |> Keyword.merge(sync_connect: false, auto_reconnect: true)

    {:ok, conn} = Postgrex.Notifications.start_link(config)
    {_status, _ref} = Postgrex.Notifications.listen(conn, LiveEvents.channel())
    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_info({:notification, _conn, _ref, _channel, payload}, state) do
    with {:ok, event} <- LiveEvents.event(payload), do: LiveEvents.broadcast(event)
    {:noreply, state}
  end
end
