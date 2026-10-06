defmodule SdrAgent.Accounts.User do
  @moduledoc """
  An operator who signs in to the SDR console.

  Currently an id-only AshAuthentication subject with stored, required tokens
  and log-out-everywhere. Exposes the default `:read` and `:get_by_subject`
  (JWT subject lookup); only AshAuthentication interactions are authorized.
  Password strategy and roles are added in slice S5.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource SdrAgent.Accounts.Token
      signing_secret SdrAgent.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end
  end

  postgres do
    table "users"
    repo SdrAgent.Repo
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
