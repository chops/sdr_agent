defmodule SdrAgent.Repo.Migrations.PreserveKeyRetirement do
  @moduledoc "Preserves a recorded retirement instant during later revocation."
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION audit_signing_keys_lifecycle_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION '% is lifecycle-immutable: % rejected', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF (to_jsonb(NEW) - ARRAY['status', 'retired_at', 'revoked_at', 'revocation_reason', 'updated_at', 'trace_id', 'span_id'])
           IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['status', 'retired_at', 'revoked_at', 'revocation_reason', 'updated_at', 'trace_id', 'span_id']) THEN
        RAISE EXCEPTION '% row %: immutable key material changed', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF NOT ((OLD.status = 'active' AND NEW.status IN ('rotated', 'revoked')) OR
              (OLD.status = 'rotated' AND NEW.status = 'revoked')) THEN
        RAISE EXCEPTION '% row %: invalid status transition', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF NEW.status = 'revoked' AND (NEW.revoked_at IS NULL OR NEW.revocation_reason IS NULL) THEN
        RAISE EXCEPTION '% row %: revocation metadata required', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      IF OLD.retired_at IS NOT NULL AND NEW.retired_at IS DISTINCT FROM OLD.retired_at THEN
        RAISE EXCEPTION '% row %: retirement instant is immutable', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """)
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION audit_signing_keys_lifecycle_guard() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION '% is lifecycle-immutable: % rejected', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF (to_jsonb(NEW) - ARRAY['status', 'retired_at', 'revoked_at', 'revocation_reason', 'updated_at', 'trace_id', 'span_id'])
           IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['status', 'retired_at', 'revoked_at', 'revocation_reason', 'updated_at', 'trace_id', 'span_id']) THEN
        RAISE EXCEPTION '% row %: immutable key material changed', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF NOT ((OLD.status = 'active' AND NEW.status IN ('rotated', 'revoked')) OR
              (OLD.status = 'rotated' AND NEW.status = 'revoked')) THEN
        RAISE EXCEPTION '% row %: invalid status transition', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
      IF NEW.status = 'revoked' AND (NEW.revoked_at IS NULL OR NEW.revocation_reason IS NULL) THEN
        RAISE EXCEPTION '% row %: revocation metadata required', TG_TABLE_NAME, OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """)
  end
end
