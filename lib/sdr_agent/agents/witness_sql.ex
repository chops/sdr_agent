defmodule SdrAgent.Agents.WitnessSQL do
  @moduledoc """
  Database statements backing `SdrAgent.Agents.WireWitnessLink` lineage
  (S12 C3/C4), used by the resource's `custom_statements` so `mix
  ash.codegen` generates and checks them.
  """

  @doc """
  Database lineage statements `{name, up, down}`: a unique index on
  `(tenant_id, model_invocation_id, proxy_record_ref, id)` and a composite
  foreign key from `(…, supersedes_id)` to it, so a successor belongs to its
  predecessor's exchange; and a `BEFORE INSERT` trigger refusing a successor
  of a `mismatch` row under the same `evidence.projection_version` (C3).
  """
  def lineage do
    [
      {:wire_witness_links_subject_index,
       "CREATE UNIQUE INDEX wire_witness_links_subject_id_index ON wire_witness_links " <>
         "(tenant_id, model_invocation_id, proxy_record_ref, id)",
       "DROP INDEX wire_witness_links_subject_id_index"},
      {:wire_witness_links_same_subject_fkey,
       "ALTER TABLE wire_witness_links ADD CONSTRAINT wire_witness_links_same_subject_fkey " <>
         "FOREIGN KEY (tenant_id, model_invocation_id, proxy_record_ref, supersedes_id) " <>
         "REFERENCES wire_witness_links (tenant_id, model_invocation_id, proxy_record_ref, id) " <>
         "ON DELETE RESTRICT",
       "ALTER TABLE wire_witness_links DROP CONSTRAINT wire_witness_links_same_subject_fkey"},
      {:wire_witness_links_mismatch_function,
       """
       CREATE FUNCTION wire_witness_links_mismatch_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
       DECLARE
         previous wire_witness_links%ROWTYPE;
       BEGIN
         IF NEW.supersedes_id IS NULL THEN
           RETURN NEW;
         END IF;
         SELECT * INTO previous FROM wire_witness_links WHERE id = NEW.supersedes_id;
         IF previous.link_status = 'mismatch' AND
            (NEW.evidence ->> 'projection_version') IS NOT DISTINCT FROM
            (previous.evidence ->> 'projection_version') THEN
           RAISE EXCEPTION 'wire witness mismatch % can only be superseded under a different projection version', previous.id
             USING ERRCODE = 'check_violation';
         END IF;
         RETURN NEW;
       END;
       $$
       """, "DROP FUNCTION wire_witness_links_mismatch_lineage()"},
      {:wire_witness_links_mismatch_trigger,
       "CREATE TRIGGER wire_witness_links_mismatch_lineage BEFORE INSERT ON wire_witness_links " <>
         "FOR EACH ROW EXECUTE FUNCTION wire_witness_links_mismatch_lineage()",
       "DROP TRIGGER wire_witness_links_mismatch_lineage ON wire_witness_links"}
    ]
  end
end
