defmodule SdrAgent.Repo.Migrations.C2starS2DelegatedGrants do
  @moduledoc """
  C2* S2 delegated grants (ADR-0004 agent-environment item 9): the grant's
  provenance columns, nullable user ids, the provisioning, digest and
  two-shape provenance CHECKs, and the partial unique index on
  `(tenant_id, delegated_authorization_id)`. Existing rows take
  `provisioning = 'owner_form'` and satisfy the CHECKs.

  Generated with `mix ash.codegen c2star_s2_delegated_grants`; reviewed by
  hand. The down is hand-ordered and runs in one transaction: restoring
  NOT NULL on the user ids fails while any delegated row exists (its
  `created_by_id` is NULL), so the whole down rolls back. No CASCADE.
  """

  use Ecto.Migration

  def up do
    alter table(:model_call_grants) do
      add :provisioning, :text, null: false, default: "owner_form"
      add :delegated_authorization_id, :text
      add :delegated_authorization_sha256, :text
      modify :created_by_id, :uuid, null: true
      modify :updated_by_id, :uuid, null: true
    end

    create unique_index(:model_call_grants, [:tenant_id, :delegated_authorization_id],
             name: "model_call_grants_unique_delegated_authorization_index",
             where: "(delegated_authorization_id IS NOT NULL)"
           )

    create constraint(:model_call_grants, :model_call_grants_provisioning,
             check: """
               provisioning IN ('owner_form', 'delegated')
             """
           )

    create constraint(:model_call_grants, :model_call_grants_delegated_sha256,
             check: """
               delegated_authorization_sha256 IS NULL OR delegated_authorization_sha256 ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:model_call_grants, :model_call_grants_provenance,
             check: """
               COALESCE((provisioning = 'owner_form' AND created_by_id IS NOT NULL AND updated_by_id IS NOT NULL AND delegated_authorization_id IS NULL AND delegated_authorization_sha256 IS NULL) OR (provisioning = 'delegated' AND created_by_id IS NULL AND delegated_authorization_id IS NOT NULL AND delegated_authorization_sha256 IS NOT NULL AND (updated_by_id IS NULL OR status = 'revoked')), false)
             """
           )
  end

  def down do
    drop index(:model_call_grants, [:tenant_id, :delegated_authorization_id],
           name: "model_call_grants_unique_delegated_authorization_index"
         )

    drop constraint(:model_call_grants, :model_call_grants_provenance)
    drop constraint(:model_call_grants, :model_call_grants_delegated_sha256)
    drop constraint(:model_call_grants, :model_call_grants_provisioning)

    alter table(:model_call_grants) do
      modify :created_by_id, :uuid, null: false
      modify :updated_by_id, :uuid, null: false
    end

    alter table(:model_call_grants) do
      remove :delegated_authorization_sha256
      remove :delegated_authorization_id
      remove :provisioning
    end
  end
end
