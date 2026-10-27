defmodule SdrAgent.Accounts.Preparations.AllowlistedOnly do
  @moduledoc """
  When the hosted sign-in allowlist is enforced
  (`SdrAgent.Accounts.LoginAllowlist.enforced?/0`, prod), restricts a user
  read to users whose email is on `SDR_LOGIN_ALLOWLIST`, read at query
  time; an empty list matches nobody (fail closed). Used by every sign-in
  action, the magic-link request (so no token is minted for anyone else)
  and `get_by_subject` (every session and token resolution). A sign-in it
  empties is refused and audited like any other failure
  (`SdrAgent.Accounts.Preparations.AuditSignIn`). Not enforced, it changes
  nothing.
  """
  use Ash.Resource.Preparation

  alias SdrAgent.Accounts.LoginAllowlist

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    if LoginAllowlist.enforced?() do
      case LoginAllowlist.addresses() do
        [] -> Ash.Query.do_filter(query, false)
        addresses -> Ash.Query.filter(query, email in ^addresses)
      end
    else
      query
    end
  end
end
