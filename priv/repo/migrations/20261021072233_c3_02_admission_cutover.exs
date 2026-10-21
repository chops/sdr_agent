defmodule SdrAgent.Repo.Migrations.C302AdmissionCutover do
  @moduledoc """
  C3-02 G5, the admission cutover (plan r8 sections 10.2 G5, 14 ruling 9
  and 15 item 4; packet section 3 Lead row and section 4.4): the closed
  history index `leads_closed_history_index` (tenant_id, account_id,
  closed_at DESC NULLS LAST, id DESC), the BEFORE INSERT binding trigger
  `leads_admission_binding` and the BEFORE UPDATE trigger
  `leads_identity_immutable`, each with its function. Existing rows are
  neither read nor rewritten; the additive migration (G2) is unchanged.

  Generated with `mix ash.codegen c3_02_admission_cutover` from
  `SdrAgent.Sales.Lead`'s custom index and statements and reviewed: the
  index first, each function before its trigger; `down/0` drops the
  triggers before their functions, then the index.
  """

  use Ecto.Migration

  def up do
    create index(:leads, [:tenant_id, :account_id, "closed_at DESC NULLS LAST", "id DESC"],
             name: "leads_closed_history_index"
           )

    execute("""
    CREATE FUNCTION leads_admission_binding() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.source = 'fixture' AND NEW.admission_id IS NULL THEN
        RETURN NEW;
      END IF;
      IF NEW.source = 'crm' OR NEW.admission_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM lead_admissions a
            WHERE a.id = NEW.admission_id
              AND a.tenant_id = NEW.tenant_id
              AND a.outcome = 'admitted'
              AND a.source_kind = NEW.source
              AND a.referral_from_lead_id IS NOT DISTINCT FROM NEW.referred_from_lead_id) THEN
        RAISE EXCEPTION 'leads: a new lead must be bound to its admitted admission';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER leads_admission_binding BEFORE INSERT ON leads FOR EACH ROW EXECUTE FUNCTION leads_admission_binding()
    """)

    execute("""
    CREATE FUNCTION leads_identity_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.source IS DISTINCT FROM OLD.source
         OR NEW.admission_id IS DISTINCT FROM OLD.admission_id
         OR NEW.referred_from_lead_id IS DISTINCT FROM OLD.referred_from_lead_id
         OR NEW.account_id IS DISTINCT FROM OLD.account_id
         OR NEW.contact_id IS DISTINCT FROM OLD.contact_id THEN
        RAISE EXCEPTION 'leads: source, admission, referrer, account and contact are immutable';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER leads_identity_immutable BEFORE UPDATE ON leads FOR EACH ROW EXECUTE FUNCTION leads_identity_immutable()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER leads_identity_immutable ON leads
    """)

    execute("""
    DROP FUNCTION leads_identity_immutable()
    """)

    execute("""
    DROP TRIGGER leads_admission_binding ON leads
    """)

    execute("""
    DROP FUNCTION leads_admission_binding()
    """)

    drop_if_exists index(
                     :leads,
                     [:tenant_id, :account_id, "closed_at DESC NULLS LAST", "id DESC"],
                     name: "leads_closed_history_index"
                   )
  end
end
