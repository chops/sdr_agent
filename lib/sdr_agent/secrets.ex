defmodule SdrAgent.Secrets do
  @moduledoc """
  AshAuthentication secret resolver: supplies the token signing secret from
  application config (`:token_signing_secret`, set from the environment in
  `config/runtime.exs` for production).
  """
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        SdrAgent.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:sdr_agent, :token_signing_secret)
  end
end
