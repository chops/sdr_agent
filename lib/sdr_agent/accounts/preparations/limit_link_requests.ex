defmodule SdrAgent.Accounts.Preparations.LimitLinkRequests do
  @moduledoc """
  Bounds magic-link requests before anything is minted or sent (Codex M3),
  on `SdrAgent.Accounts.User`'s `:request_magic_link`, ahead of the
  strategy's request preparation: at most 30 requests in total per fixed
  10-minute window and 3 per destination address per fixed 15-minute
  window (`SdrAgent.RateLimiter`: aligned UTC buckets on this node, not a
  rolling cooldown, reset on restart; keyed by the sha256 of the trimmed,
  lowercased address). Every request counts — listed, unknown or malformed — so the
  bound reveals nothing about who exists or is listed. Over a bound the
  query matches nobody: no token is minted, no mail is sent, and the
  caller gets the same empty result; a warning names neither the address
  nor the bound's key. The per-client bound is applied earlier, at the web
  edge (`SdrAgentWeb.MagicLinkRequestLimit`).
  """
  use Ash.Resource.Preparation

  alias SdrAgent.RateLimiter

  require Logger

  @global 30
  @global_window :timer.minutes(10)
  @per_destination 3
  @destination_window :timer.minutes(15)

  @impl true
  def prepare(query, _opts, _context) do
    destination =
      query
      |> Ash.Query.get_argument(:email)
      |> to_string()
      |> String.trim()
      |> String.downcase()

    with {:global, :ok} <- {:global, RateLimiter.hit(:magic_link_global, @global, @global_window)},
         {:destination, :ok} <-
           {:destination,
            RateLimiter.hit(
              {:magic_link_destination, :crypto.hash(:sha256, destination)},
              @per_destination,
              @destination_window
            )} do
      query
    else
      {bound, :limited} ->
        Logger.warning("magic link request limited (#{bound})")
        Ash.Query.do_filter(query, false)
    end
  end
end
