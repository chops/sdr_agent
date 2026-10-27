defmodule SdrAgent.Accounts.Senders.MagicLink do
  @moduledoc """
  Mails the sign-in link of `SdrAgent.Accounts.User`'s `:magic_link`
  strategy (the hosted owner's passwordless sign-in) through
  `SdrAgent.Mailer`. It is the only module that sends through that mailer;
  outreach never does (ADR-0001: outreach delivers through the capture
  adapter only).

  It sends only when all of these hold, and otherwise sends nothing and
  logs a warning that names neither the address nor the token:

    * the recipient is an existing user (registration is disabled, so a
      bare email is refused; the strategy's request action already matches
      only active users);
    * the user's lowercased email is on `SDR_LOGIN_ALLOWLIST`, a
      comma-separated list read at every request (empty or unset: nobody);
    * `SDR_MAIL_FROM` names the sender address.

  Requests are bounded before any token is minted, per client
  (`SdrAgentWeb.MagicLinkRequestLimit`) and per destination and in total
  (`SdrAgent.Accounts.Preparations.LimitLinkRequests`); where the hosted
  allowlist is enforced, an unlisted user is never minted a token
  (`SdrAgent.Accounts.Preparations.AllowlistedOnly`). A failed delivery is
  logged the same way. The link opens the confirmation page
  (`/magic_link/:token`, the endpoint's public URL), whose button signs
  the user in once.
  """
  use AshAuthentication.Sender
  use SdrAgentWeb, :verified_routes

  import Swoosh.Email

  alias SdrAgent.Accounts.LoginAllowlist
  alias SdrAgent.Mailer

  require Logger

  @impl true
  def send(%SdrAgent.Accounts.User{email: email}, token, _opts) when is_binary(token) do
    address = to_string(email)

    cond do
      not LoginAllowlist.listed?(address) ->
        refuse("the recipient is not on SDR_LOGIN_ALLOWLIST")

      sender() == nil ->
        refuse("SDR_MAIL_FROM is not set")

      true ->
        deliver(address, sender(), token)
    end
  end

  def send(_not_a_user, _token, _opts), do: refuse("no such user (registration is disabled)")

  defp sender do
    case System.get_env("SDR_MAIL_FROM") do
      value when value in [nil, ""] -> nil
      value -> String.trim(value)
    end
  end

  defp deliver(address, sender, token) do
    link = url(~p"/magic_link/#{token}")

    email =
      new()
      |> to(address)
      |> from(sender)
      |> subject("Your SDR Agent sign-in link")
      |> text_body("""
      Sign in to SDR Agent with this link (it works once, for 10 minutes):

      #{link}

      If you did not ask to sign in, ignore this email.
      """)
      |> html_body("""
      <p>Sign in to SDR Agent with this link (it works once, for 10 minutes):</p>
      <p><a href="#{link}">Sign in to SDR Agent</a></p>
      <p>If you did not ask to sign in, ignore this email.</p>
      """)

    case safe_deliver(email) do
      {:ok, _receipt} ->
        Logger.info("magic link sent")
        :ok

      {:error, _reason} ->
        Logger.warning("magic link delivery failed")
        :ok
    end
  end

  # The mailer adapter's errors and exits may carry the request (address,
  # link); only the fact of the failure is reported.
  defp safe_deliver(email) do
    Mailer.deliver(email)
  rescue
    _exception -> {:error, :raised}
  catch
    _kind, _reason -> {:error, :exited}
  end

  defp refuse(reason) do
    Logger.warning("magic link refused: #{reason}")
    :ok
  end
end
