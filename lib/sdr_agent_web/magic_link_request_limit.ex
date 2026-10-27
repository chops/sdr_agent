defmodule SdrAgentWeb.MagicLinkRequestLimit do
  @moduledoc """
  Bounds unauthenticated magic-link requests per client before the request
  action runs (Codex M3): at most 5 per client address per fixed 10-minute
  window (`SdrAgent.RateLimiter`: aligned UTC buckets on this node, not a
  rolling cooldown, reset on restart). Over the limit it answers exactly as an
  accepted request does (`SdrAgentWeb.AuthController.link_requested/1`) and
  halts, so nothing is read, minted or sent. The destination and global
  bounds are enforced in the domain, before minting
  (`SdrAgent.Accounts.Preparations.LimitLinkRequests`).

  The client address is the last `X-Forwarded-For` entry only when the
  peer is loopback (the reverse proxy on this host, which sets the header;
  the app listens on 127.0.0.1); a missing or malformed header leaves the
  peer. From any other peer the header is ignored.
  """
  @behaviour Plug

  alias SdrAgent.RateLimiter

  require Logger

  @per_client 5
  @window :timer.minutes(10)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(
        %Plug.Conn{method: "POST", path_info: ["auth", "user", "magic_link", "request"]} = conn,
        _opts
      ) do
    case RateLimiter.hit({:magic_link_client, client_ip(conn)}, @per_client, @window) do
      :ok ->
        conn

      :limited ->
        Logger.warning("magic link request limited (client)")

        conn
        |> SdrAgentWeb.AuthController.link_requested()
        |> Plug.Conn.halt()
    end
  end

  def call(conn, _opts), do: conn

  @doc "The client address of `conn` (see the moduledoc)."
  @spec client_ip(Plug.Conn.t()) :: :inet.ip_address()
  def client_ip(%Plug.Conn{remote_ip: peer} = conn) do
    with true <- loopback?(peer),
         [_ | _] = values <- Plug.Conn.get_req_header(conn, "x-forwarded-for"),
         last = values |> Enum.join(",") |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(last)) do
      ip
    else
      _ -> peer
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_other), do: false
end
