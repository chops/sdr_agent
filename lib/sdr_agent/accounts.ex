defmodule SdrAgent.Accounts do
  @moduledoc """
  Accounts bounded context: operator identity and authentication tokens.

  Owns `SdrAgent.Accounts.User` and `SdrAgent.Accounts.Token`. Roles
  (admin, reviewer) and password authentication arrive in slice S5.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  resources do
    resource SdrAgent.Accounts.Token
    resource SdrAgent.Accounts.User
  end
end
