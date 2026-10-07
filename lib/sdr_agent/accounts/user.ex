defmodule SdrAgent.Accounts.User do
  @moduledoc """
  An operator who signs in to the SDR console (S2 row User; ADR-0009
  "Roles and actors").

  Attributes: `email` (ci_string, globally unique — the sign-in identity),
  `hashed_password` (bcrypt, sensitive), `role` (`:admin`, `:reviewer`,
  `:auditor`; default reviewer), `status` (`:active`, `:disabled`),
  `display_name`, `tenant_id` (set from the creating actor, immutable),
  `inserted_at`/`updated_at`. The id stays the generated UUIDv4.

  Authentication: the AshAuthentication password strategy with registration,
  reset, confirmation and sign-in tokens disabled — users are created only
  by an admin (`:create_user`) or, in dev/test, the seeder (`:seed`). Only
  active users sign in (`:sign_in_with_password`) or resolve from a session
  (`:get_by_subject`); every sign-in attempt is audited
  (`auth.sign_in.succeeded` / `auth.sign_in.failed`, the latter anonymous
  with only the email's sha256).

  Actions and actors:

    * `:create_user` — ADM (guarded); `:seed` — SEED in dev/test only;
    * `:change_role`, `:change_status` — ADM (guarded); the last active
      admin can be neither demoted nor disabled; disabling revokes all of the
      user's tokens;
    * `:change_password` — ADM or REV, own user, with the current password;
    * `:set_password` — ADM, for another user (the only way an auditor's
      password changes);
    * password changes revoke all of the user's tokens (log-out-everywhere).

  Auditors (AUR) mutate nothing, including their own password. Reads: any
  user reads itself; ADM and AUR read all users, but AUR sees only
  `display_name` and `role` of others (field policies), and no operator read
  returns a password hash (`SdrAgent.Accounts.Preparations.HidePasswordHash`). Users are never
  destroyed. Every write appends an AuditEvent (`user.*`); the password hash
  is redacted from event payloads.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication],
    # Intentional: the primary read hides password hashes from operators,
    # including when users are loaded as relationships.
    primary_read_warning?: false

  alias AshAuthentication.Strategy.Password
  alias SdrAgent.Accounts.Checks.IsSelf
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @roles [:admin, :reviewer, :auditor]
  @statuses [:active, :disabled]

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

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider
        registration_enabled? false
        sign_in_tokens_enabled? false
      end
    end
  end

  postgres do
    table "users"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :role, "users_role", check: SdrAgent.Audit.SQL.one_of("role", @roles)

      check_constraint :status, "users_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)
    end
  end

  field_policies do
    # AUR labels timeline actors: display_name and role only (S2 auditor contract).
    field_policy [:email, :status, :tenant_id, :inserted_at, :updated_at] do
      authorize_if AshAuthentication.Checks.AshAuthenticationInteraction
      authorize_if Checks.KernelContext
      authorize_if IsSelf
      authorize_if {Checks.ActorRole, roles: [:admin]}
      authorize_if {Checks.ActorType, types: [:seeder]}
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    read :read do
      primary? true
      # Operators never receive password hashes (the hash must stay a private
      # attribute for AshAuthentication, so a field policy cannot hide it).
      prepare SdrAgent.Accounts.Preparations.HidePasswordHash
    end

    read :get_by_subject do
      description "Get an active user by the subject claim in a JWT (session lookup)."
      argument :subject, :string, allow_nil?: false
      get? true
      filter expr(status == :active)
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :sign_in_with_password do
      description "Sign in an active user with email and password; every attempt is audited."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      filter expr(status == :active)
      prepare Password.SignInPreparation
      prepare SdrAgent.Accounts.Preparations.AuditSignIn

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    create :create_user do
      description "ADM: create an operator with a role and an initial password."
      accept [:email, :display_name, :role]

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true
      validate confirm(:password, :password_confirmation)
      change {Password.HashPasswordChange, strategy_name: :password}
      change SdrAgent.Audit.Changes.SetTenant
      change {AppendEvent, event_type: "user.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create an operator with a fixture id."
      accept [:id, :email, :display_name, :role]

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true
      validate confirm(:password, :password_confirmation)
      change {Password.HashPasswordChange, strategy_name: :password}
      change SdrAgent.Audit.Changes.SetTenant
      change {AppendEvent, event_type: "user.created", category: :domain_change}
    end

    update :change_role do
      description "ADM: change a user's role; the last active admin keeps the admin role."
      require_atomic? false
      accept [:role]
      change SdrAgent.Accounts.Changes.KeepAnActiveAdmin

      change {AppendEvent,
              event_type: "user.role_changed", category: :domain_change, previous: [:role]}
    end

    update :change_status do
      description "ADM: enable or disable a user; disabling revokes all of its sessions."
      require_atomic? false
      accept [:status]
      change SdrAgent.Accounts.Changes.KeepAnActiveAdmin

      change AshAuthentication.AddOn.LogOutEverywhere.OnPasswordChange,
        where: [attribute_equals(:status, :disabled)]

      change {AppendEvent,
              event_type: "user.status_changed", category: :domain_change, previous: [:status]}
    end

    update :change_password do
      description "ADM, REV: change one's own password with the current one; revokes sessions."
      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false
      change get_and_lock_for_update()
      validate confirm(:password, :password_confirmation)

      validate {Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      change {Password.HashPasswordChange, strategy_name: :password}
      # Explicit: the add-on's global hook keys on `changing(:hashed_password)`,
      # which is evaluated before the hash is set.
      change AshAuthentication.AddOn.LogOutEverywhere.OnPasswordChange
      change {AppendEvent, event_type: "user.password_changed", category: :domain_change}
    end

    update :set_password do
      description "ADM: set another user's password (the only way an auditor's changes)."
      require_atomic? false
      accept []

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false
      change get_and_lock_for_update()
      validate confirm(:password, :password_confirmation)
      change {Password.HashPasswordChange, strategy_name: :password}
      # Explicit: the add-on's global hook keys on `changing(:hashed_password)`,
      # which is evaluated before the hash is set.
      change AshAuthentication.AddOn.LogOutEverywhere.OnPasswordChange
      change {AppendEvent, event_type: "user.password_changed", category: :domain_change}
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create_user, :change_role, :change_status, :log_out_everywhere]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:seed) do
      authorize_if Checks.SeedingAllowed
    end

    policy action(:change_password) do
      forbid_unless {Checks.ActorRole, roles: [:admin, :reviewer]}
      authorize_if IsSelf
    end

    policy action(:set_password) do
      forbid_if IsSelf
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if IsSelf
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:seeder]}
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :role, :atom do
      allow_nil? false
      default :reviewer
      constraints one_of: @roles
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :active
      constraints one_of: @statuses
      public? true
    end

    attribute :display_name, :string, allow_nil?: false, public?: true

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :updated_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      update_default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_email, [:email]
  end

  @doc "Human roles (ADR-0009)."
  def roles, do: @roles

  @doc false
  def __sdr_audited__, do: true
end
