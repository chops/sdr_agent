defmodule SdrAgent.Agents.ModelProfileSetting do
  @moduledoc """
  The tenant's persisted desired real model profile (C2-02a; R0 readiness
  section 2; `docs/product/r0/c2-02a-interface.md`). One row per tenant.

  Attributes: `desired_profile_id` (a reviewed real profile, never `:fake`;
  default `:claude_cli_opus`) and `revision` (≥ 1, bumped by every applied
  switch). Before the first row exists the default applies: `:claude_cli_opus`,
  revision 1.

  It has no direct write action. Its two internal actions run only inside
  their `SdrAgent.Agents.Checks.ProfileSwitchContext` phase, opened by
  `SdrAgent.Agents.ProfileSwitches`:

    * `:initialize` — phase `:initialize` (a switch request, a current human
      admin): an upsert on the unique tenant identity that never overwrites
      a row on conflict. The request generates the id, to tell whether its
      transaction inserted the row; it appends no event of its own;
    * `:apply_switch` — phase `:apply` (`complete`, `model_runtime`):
      `desired_profile_id := to`, `revision + 1`, guarded on the stored rows
      (`SdrAgent.Agents.Changes.ApplyProfileSwitch`).

  Reads: admin, auditor (audited by the domain read), `agent_runtime`,
  kernel. `model_runtime` reads and locks it only through
  `:lock_for_transition`, in phase `:transition`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.ApplyProfileSwitch
  alias SdrAgent.Agents.Checks.ProfileSwitchContext
  alias SdrAgent.Agents.Preparations.TransitionLock
  alias SdrAgent.Audit.Checks

  @real_profiles SdrAgent.AI.ModelProfiles.real_ids()

  postgres do
    table "model_profile_settings"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :desired_profile_id, "model_profile_settings_real_profile",
        check: SdrAgent.Audit.SQL.one_of("desired_profile_id", @real_profiles)

      check_constraint :revision, "model_profile_settings_revision_positive",
        check: "revision >= 1"
    end
  end

  actions do
    defaults [:read]

    read :lock_for_transition do
      get? true
      argument :switch_id, :uuid, allow_nil?: false
      filter expr(tenant_id == ^actor(:tenant_id))
      prepare {TransitionLock, row: :setting}
    end

    create :initialize do
      accept [:id, :tenant_id]
      upsert? true
      upsert_identity :unique_tenant
      upsert_fields [:tenant_id]
    end

    update :apply_switch do
      require_atomic? false
      accept []
      argument :switch_id, :uuid, allow_nil?: false
      change ApplyProfileSwitch
    end
  end

  policies do
    policy action(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    # Strict: refused as Forbidden outside its phase, never read as empty.
    policy action(:lock_for_transition) do
      access_type :strict
      authorize_if {ProfileSwitchContext, phase: :transition, target: :switch_id}
    end

    policy action(:initialize) do
      authorize_if {ProfileSwitchContext, phase: :initialize, action: :request, target: :tenant}
    end

    policy action(:apply_switch) do
      authorize_if {ProfileSwitchContext, phase: :apply, action: :complete, target: :switch_id}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :desired_profile_id, :atom do
      allow_nil? false
      writable? false
      default SdrAgent.AI.ModelProfiles.default_real()
      public? true
      constraints one_of: @real_profiles
    end

    attribute :revision, :integer do
      allow_nil? false
      writable? false
      default 1
      public? true
      constraints min: 1
    end

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
    belongs_to :tenant, SdrAgent.Audit.Tenant,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true
  end

  identities do
    identity :unique_tenant, [:tenant_id]
  end
end
