defmodule SdrAgent.Repo.Migrations.R007aResultRelease do
  @moduledoc """
  R0-07 slice A (entity PASS at 1da747a): the append-only
  `model_result_releases` table — one release per invocation, the
  disposition/reason pair check, the evidence digest check, the append-only
  triggers — and its composite FKs keeping the invocation in the release's
  tenant and the link on that invocation, with their target unique keys
  `model_invocations (id, tenant_id)` and `wire_witness_links (id,
  model_invocation_id)`.

  Generated with `mix ash.codegen r0_07a_result_release`; reordered by hand
  so each composite unique key exists before the FK that references it (and
  is dropped after it). No existing row changes; drops are in `down/0` only.
  """

  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE wire_witness_links ADD CONSTRAINT wire_witness_links_id_invocation_key UNIQUE (id, model_invocation_id)
    """)

    execute("""
    ALTER TABLE model_invocations ADD CONSTRAINT model_invocations_id_tenant_key UNIQUE (id, tenant_id)
    """)

    create table(:model_result_releases, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuidv7()"), primary_key: true
      add :disposition, :text, null: false
      add :reason, :text, null: false
      add :projection_version, :text
      add :method, :text
      add :evidence_sha256, :text
      add :decided_at, :utc_datetime_usec, null: false
      add :trace_id, :text, null: false
      add :span_id, :text, null: false

      add :tenant_id,
          references(:tenants,
            column: :id,
            name: "model_result_releases_tenant_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          ),
          null: false

      add :model_invocation_id,
          references(:model_invocations,
            column: :id,
            name: "model_result_releases_model_invocation_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          ),
          null: false
    end

    create unique_index(:model_result_releases, [:model_invocation_id],
             name: "model_result_releases_unique_invocation_index"
           )

    alter table(:model_result_releases) do
      add :wire_witness_link_id,
          references(:wire_witness_links,
            column: :id,
            name: "model_result_releases_wire_witness_link_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :restrict
          )
    end

    create constraint(:model_result_releases, :model_result_releases_trace_ids,
             check: """
               trace_id ~ '^[0-9a-f]{32}$' AND trace_id <> repeat('0', 32) AND span_id ~ '^[0-9a-f]{16}$' AND span_id <> repeat('0', 16)
             """
           )

    create constraint(:model_result_releases, :model_result_releases_disposition,
             check: """
               disposition IN ('released', 'withheld', 'calibration')
             """
           )

    create constraint(:model_result_releases, :model_result_releases_reason,
             check: """
               reason IN ('reconciled', 'calibration', 'witness_mismatch', 'witness_missing', 'witness_timeout', 'store_unreadable', 'gate_interrupted')
             """
           )

    create constraint(:model_result_releases, :model_result_releases_method,
             check: """
               method IS NULL OR method IN ('time_window', 'propagated_id')
             """
           )

    create constraint(:model_result_releases, :model_result_releases_evidence_sha256,
             check: """
               evidence_sha256 IS NULL OR evidence_sha256 ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:model_result_releases, :model_result_releases_pair,
             check: """
               (disposition = 'released' AND reason = 'reconciled' AND wire_witness_link_id IS NOT NULL AND projection_version IS NOT NULL AND method IS NOT NULL AND evidence_sha256 IS NULL) OR (disposition = 'withheld' AND reason IN ('witness_mismatch', 'witness_missing', 'witness_timeout', 'store_unreadable', 'gate_interrupted') AND evidence_sha256 IS NULL) OR (disposition = 'calibration' AND reason = 'calibration' AND evidence_sha256 IS NOT NULL)
             """
           )

    execute("""
    CREATE FUNCTION model_result_releases_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only: % rejected', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER model_result_releases_guard_row BEFORE UPDATE OR DELETE ON model_result_releases FOR EACH ROW EXECUTE FUNCTION model_result_releases_append_only()
    """)

    execute("""
    CREATE TRIGGER model_result_releases_guard_truncate BEFORE TRUNCATE ON model_result_releases FOR EACH STATEMENT EXECUTE FUNCTION model_result_releases_append_only()
    """)

    execute("""
    ALTER TABLE model_result_releases ADD CONSTRAINT model_result_releases_invocation_tenant_fkey FOREIGN KEY (model_invocation_id, tenant_id) REFERENCES model_invocations (id, tenant_id) ON DELETE RESTRICT
    """)

    execute("""
    ALTER TABLE model_result_releases ADD CONSTRAINT model_result_releases_link_invocation_fkey FOREIGN KEY (wire_witness_link_id, model_invocation_id) REFERENCES wire_witness_links (id, model_invocation_id) ON DELETE RESTRICT
    """)
  end

  def down do
    execute("""
    ALTER TABLE model_result_releases DROP CONSTRAINT model_result_releases_link_invocation_fkey
    """)

    execute("""
    ALTER TABLE model_result_releases DROP CONSTRAINT model_result_releases_invocation_tenant_fkey
    """)

    execute("""
    DROP TRIGGER model_result_releases_guard_truncate ON model_result_releases
    """)

    execute("""
    DROP TRIGGER model_result_releases_guard_row ON model_result_releases
    """)

    execute("""
    DROP FUNCTION model_result_releases_append_only()
    """)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_pair)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_evidence_sha256)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_method)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_reason)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_disposition)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_trace_ids)

    drop constraint(:model_result_releases, "model_result_releases_wire_witness_link_id_fkey")

    drop constraint(:model_result_releases, "model_result_releases_model_invocation_id_fkey")

    drop constraint(:model_result_releases, "model_result_releases_tenant_id_fkey")

    alter table(:model_result_releases) do
      remove :wire_witness_link_id
    end

    drop_if_exists unique_index(:model_result_releases, [:model_invocation_id],
                     name: "model_result_releases_unique_invocation_index"
                   )

    drop table(:model_result_releases)

    execute("""
    ALTER TABLE model_invocations DROP CONSTRAINT model_invocations_id_tenant_key
    """)

    execute("""
    ALTER TABLE wire_witness_links DROP CONSTRAINT wire_witness_links_id_invocation_key
    """)
  end
end
