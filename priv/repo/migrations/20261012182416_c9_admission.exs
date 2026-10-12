defmodule SdrAgent.Repo.Migrations.C9Admission do
  @moduledoc """
  C9 admission (R0 readiness packet): the real-model ledger columns of
  `model_invocations` (`ledger_generation`, default 1 so every existing row
  stays generation 1; `profile_id`, `grant_id`, `allocation_id`, all
  nullable), the cutover check constraint, and the composite FKs keeping an
  invocation's allocation within its grant and its grant within its tenant.

  Generated with `mix ash.codegen c9_admission`; reordered by hand so each
  composite unique key exists before the FK that references it (and is
  dropped after it). Existing rows keep their values; drops are in `down/0`
  only.
  """

  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE model_call_allocations ADD CONSTRAINT model_call_allocations_id_grant_key UNIQUE (id, grant_id)
    """)

    execute("""
    ALTER TABLE model_call_grants ADD CONSTRAINT model_call_grants_id_tenant_key UNIQUE (id, tenant_id)
    """)

    alter table(:model_invocations) do
      add :ledger_generation, :bigint, null: false, default: 1
      add :profile_id, :text

      add :grant_id,
          references(:model_call_grants,
            column: :id,
            name: "model_invocations_grant_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          )

      add :allocation_id,
          references(:model_call_allocations,
            column: :id,
            name: "model_invocations_allocation_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          )
    end

    create constraint(:model_invocations, :model_invocations_real_call_charged,
             check: """
               ledger_generation = 1 OR provider <> 'claude_cli' OR (profile_id IS NOT NULL AND grant_id IS NOT NULL AND allocation_id IS NOT NULL)
             """
           )

    execute("""
    ALTER TABLE model_invocations ADD CONSTRAINT model_invocations_grant_tenant_fkey FOREIGN KEY (grant_id, tenant_id) REFERENCES model_call_grants (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE model_invocations ADD CONSTRAINT model_invocations_allocation_grant_fkey FOREIGN KEY (allocation_id, grant_id) REFERENCES model_call_allocations (id, grant_id) ON DELETE RESTRICT
    """)
  end

  def down do
    execute("""
    ALTER TABLE model_invocations DROP CONSTRAINT model_invocations_allocation_grant_fkey
    """)

    execute("""
    ALTER TABLE model_invocations DROP CONSTRAINT model_invocations_grant_tenant_fkey
    """)

    drop_if_exists constraint(:model_invocations, :model_invocations_real_call_charged)

    drop constraint(:model_invocations, "model_invocations_allocation_id_fkey")

    drop constraint(:model_invocations, "model_invocations_grant_id_fkey")

    alter table(:model_invocations) do
      remove :allocation_id
      remove :grant_id
      remove :profile_id
      remove :ledger_generation
    end

    execute("""
    ALTER TABLE model_call_allocations DROP CONSTRAINT model_call_allocations_id_grant_key
    """)

    execute("""
    ALTER TABLE model_call_grants DROP CONSTRAINT model_call_grants_id_tenant_key
    """)
  end
end
