defmodule SdrAgent.Operations.HostedOwner do
  @moduledoc """
  The hosted human authority of one activated prototype relocation (ADR-0024).

  A reviewer User is bound to its tenant, immutable database binding and
  activation. Exactly one owner may be active per binding. Disable is terminal
  and is coupled by HostedOwners to disabling the user and revoking all tokens.
  Tenant-scoped User/Binding FKs and the (relocation_id,binding_id) FK exclude
  cross-tenant or cross-binding authority. Enrollment and disable write their
  audit commitments through the unchanged same-transaction AppendEvent change.

  Only Operations.HostedOwners creates the transaction/process-bound scope
  for mutations. Kernel reads and the live owner's own read are allowed;
  the auditor and a role/id supplied without live authority are denied.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks.KernelContext
  alias SdrAgent.Operations.Checks.HostedOwnerAccess
  alias SdrAgent.Operations.Checks.HostedOwnerWriteScope

  postgres do
    table "hosted_owners"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :user, on_delete: :restrict, match_with: [tenant_id: :tenant_id]
      reference :binding, on_delete: :restrict, match_with: [tenant_id: :tenant_id]

      reference :relocation,
        on_delete: :restrict,
        match_with: [binding_id: :binding_id],
        name: "hosted_owners_relocation_id_fkey"
    end

    custom_indexes do
      index [:binding_id],
        unique: true,
        name: "hosted_owners_one_active",
        where: "status = 'active'"
    end

    check_constraints do
      check_constraint :status, "hosted_owners_status", check: "status IN ('active', 'disabled')"

      check_constraint :disabled_at, "hosted_owners_disable_instant",
        check: "(status = 'disabled') = (disabled_at IS NOT NULL)"
    end

    custom_statements do
      statement :hosted_owners_guard_function do
        up """
        CREATE FUNCTION hosted_owners_guard() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF TG_OP <> 'UPDATE' THEN
            RAISE EXCEPTION 'hosted owner history cannot be removed' USING ERRCODE = 'restrict_violation';
          END IF;
          IF OLD.status <> 'active' OR NEW.status <> 'disabled'
             OR NEW.disabled_at IS NULL
             OR (to_jsonb(NEW) - 'status' - 'disabled_at') IS DISTINCT FROM
                (to_jsonb(OLD) - 'status' - 'disabled_at') THEN
            RAISE EXCEPTION 'hosted owner permits terminal disable only' USING ERRCODE = 'restrict_violation';
          END IF;
          RETURN NEW;
        END;
        $$
        """

        down "DROP FUNCTION hosted_owners_guard()"
      end

      statement :hosted_owners_guard_row do
        up "CREATE TRIGGER hosted_owners_guard_row BEFORE UPDATE OR DELETE ON hosted_owners FOR EACH ROW EXECUTE FUNCTION hosted_owners_guard()"
        down "DROP TRIGGER hosted_owners_guard_row ON hosted_owners"
      end

      statement :hosted_owners_guard_truncate do
        up "CREATE TRIGGER hosted_owners_guard_truncate BEFORE TRUNCATE ON hosted_owners FOR EACH STATEMENT EXECUTE FUNCTION hosted_owners_guard()"
        down "DROP TRIGGER hosted_owners_guard_truncate ON hosted_owners"
      end
    end
  end

  actions do
    defaults [:read]

    create :enrol do
      accept [:user_id, :binding_id, :relocation_id]
      change SdrAgent.Audit.Changes.SetTenant

      change {AppendEvent,
              event_type: "operations.hosted_owner.enrolled", category: :domain_change}
    end

    update :disable do
      require_atomic? false
      accept []
      change set_attribute(:status, :disabled)
      change set_attribute(:disabled_at, &SdrAgent.Clock.utc_now/0)

      change {AppendEvent,
              event_type: "operations.hosted_owner.disabled",
              category: :domain_change,
              previous: [:status]}
    end
  end

  policies do
    policy action_type([:create, :update]) do
      authorize_if HostedOwnerWriteScope
    end

    policy action_type(:read) do
      access_type :strict
      authorize_if KernelContext
      authorize_if HostedOwnerAccess
    end

    policy action_type(:read) do
      authorize_if KernelContext
      authorize_if expr(user_id == ^actor(:id) and tenant_id == ^actor(:tenant_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :disabled]],
      public?: true

    attribute :enrolled_at, :utc_datetime_usec,
      allow_nil?: false,
      writable?: false,
      default: &SdrAgent.Clock.utc_now/0,
      public?: true

    attribute :disabled_at, :utc_datetime_usec, writable?: false, public?: true
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant, allow_nil?: false, public?: true
    belongs_to :user, SdrAgent.Accounts.User, allow_nil?: false, public?: true

    belongs_to :binding, SdrAgent.Operations.PrototypeDatabaseBinding,
      allow_nil?: false,
      public?: true

    belongs_to :relocation, SdrAgent.Prototype.Relocation, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_user, [:user_id]
  end
end
