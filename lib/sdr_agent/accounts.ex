defmodule SdrAgent.Accounts do
  use Ash.Domain,
    otp_app: :sdr_agent

  resources do
    resource SdrAgent.Accounts.Token
    resource SdrAgent.Accounts.User
  end
end
