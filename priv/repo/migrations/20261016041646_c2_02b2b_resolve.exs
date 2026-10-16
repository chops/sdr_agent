defmodule SdrAgent.Repo.Migrations.C202b2bResolve do
  @moduledoc """
  C2-02b2β (`docs/product/r0/c2-02b2b-interface.md`, the entity table): the
  attended resolution of a blocked model profile switch — the seven
  nullable resolution columns, their all-or-none check, the per-tenant
  unique attestation id, the resolver FK and the composite
  `(attested_start_id, tenant_id)` FK to the tenant's own start.

  Generated with `mix ash.codegen c2_02b2b_resolve`, then reviewed: the
  starts' `(id, tenant_id)` unique key is created before the composite FK
  that targets it (and dropped after it).
  """

  use Ecto.Migration

  def up do
    alter table(:model_profile_switches) do
      add :resolution, :text
      add :resolved_at, :utc_datetime_usec
      add :attestation_id, :uuid
      add :attested_generation, :bigint
      add :attested_lease_kind, :text

      add :resolved_by_id,
          references(:users,
            column: :id,
            name: "model_profile_switches_resolved_by_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          )

      add :attested_start_id,
          references(:model_server_starts,
            column: :id,
            name: "model_profile_switches_attested_start_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          )
    end

    create constraint(:model_profile_switches, :model_profile_switches_resolution,
             check: """
               (resolution IS NULL AND resolved_by_id IS NULL AND resolved_at IS NULL AND attestation_id IS NULL AND attested_start_id IS NULL AND attested_generation IS NULL AND attested_lease_kind IS NULL) OR (resolution IS NOT NULL AND resolved_by_id IS NOT NULL AND resolved_at IS NOT NULL AND attestation_id IS NOT NULL AND attested_start_id IS NOT NULL AND attested_generation IS NOT NULL AND attested_lease_kind IS NOT NULL AND resolution = 'owner_attested' AND attested_lease_kind IN ('none', 'survivor', 'dead_holder') AND status = 'failed' AND resolved_at = finished_at AND attested_generation >= server_generation)
             """
           )

    create index(:model_profile_switches, [:tenant_id, :attestation_id],
             name: "model_profile_switches_attestation_index",
             unique: true,
             where: "attestation_id IS NOT NULL"
           )

    execute("""
    ALTER TABLE model_server_starts ADD CONSTRAINT model_server_starts_id_tenant_key UNIQUE (id, tenant_id)
    """)

    execute("""
    ALTER TABLE model_profile_switches ADD CONSTRAINT model_profile_switches_attested_start_tenant_fkey FOREIGN KEY (attested_start_id, tenant_id) REFERENCES model_server_starts (id, tenant_id) ON DELETE RESTRICT
    """)
  end

  def down do
    execute("""
    ALTER TABLE model_profile_switches DROP CONSTRAINT model_profile_switches_attested_start_tenant_fkey
    """)

    execute("""
    ALTER TABLE model_server_starts DROP CONSTRAINT model_server_starts_id_tenant_key
    """)

    drop_if_exists index(:model_profile_switches, [:tenant_id, :attestation_id],
                     name: "model_profile_switches_attestation_index"
                   )

    drop_if_exists constraint(:model_profile_switches, :model_profile_switches_resolution)

    drop constraint(:model_profile_switches, "model_profile_switches_attested_start_id_fkey")

    drop constraint(:model_profile_switches, "model_profile_switches_resolved_by_id_fkey")

    alter table(:model_profile_switches) do
      remove :attested_start_id
      remove :resolved_by_id
      remove :attested_lease_kind
      remove :attested_generation
      remove :attestation_id
      remove :resolved_at
      remove :resolution
    end
  end
end
