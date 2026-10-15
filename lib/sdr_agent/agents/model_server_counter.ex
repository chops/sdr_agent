defmodule SdrAgent.Agents.ModelServerCounter do
  @moduledoc """
  The per-tenant serialization point of model server start allocation
  (C2-02b2α, `docs/product/r0/c2-02b2-interface.md` section 1b): one row
  per tenant (`tenant_id` unique) with `last_generation` (≥ 0), the
  generation of the tenant's latest `SdrAgent.Agents.ModelServerStart`.

  Lifecycle: upserted lazily by `:open` (a conflict leaves the row as it
  is), bumped only by `:bump`, in `allocate`'s transaction under the row's
  `FOR UPDATE`. Start transitions and the switch finalizers take it `FOR
  SHARE` first (`:lock`). Never destroyed.

  Policy: every action runs only in the registered coordinator process as
  `model_runtime` (`SdrAgent.Agents.Checks.CoordinatorProcess`); the kernel
  may read it.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.CoordinatorProcess
  alias SdrAgent.Audit.Checks

  postgres do
    table "model_server_counters"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
    end

    check_constraints do
      check_constraint :last_generation, "model_server_counters_last_generation_non_negative",
        check: "last_generation >= 0"
    end
  end

  actions do
    defaults [:read]

    # The caller adds the lock mode (`FOR UPDATE` or `FOR SHARE`).
    read :lock do
      get? true
      filter expr(tenant_id == ^actor(:tenant_id))
    end

    create :open do
      upsert? true
      upsert_identity :tenant
      upsert_fields []
      change SdrAgent.Audit.Changes.SetTenant
    end

    update :bump do
      require_atomic? false
      accept []
      change atomic_update(:last_generation, expr(last_generation + 1))
    end
  end

  policies do
    policy action(:read) do
      authorize_if Checks.KernelContext
      authorize_if CoordinatorProcess
    end

    policy action([:lock, :open, :bump]) do
      authorize_if CoordinatorProcess
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :last_generation, :integer,
      allow_nil?: false,
      default: 0,
      writable?: false,
      public?: true,
      constraints: [min: 0]

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
    identity :tenant, [:tenant_id]
  end
end
