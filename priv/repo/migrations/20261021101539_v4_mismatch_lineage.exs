defmodule SdrAgent.Repo.Migrations.V4MismatchLineage do
  @moduledoc """
  Projection v4 mismatch-head lineage (ADR-0005 response-layout amendment
  item 6, D-182; witness response-block plan r5 section 6.5).

  Replaces the body of `wire_witness_links_mismatch_lineage()` with
  `CREATE OR REPLACE FUNCTION`: the existing C3 check is kept unchanged, and
  a successor of a `mismatch` row whose `evidence.projection_version` is
  `claude-message-json/4+prompt-builder/1` is refused (`check_violation`).
  `down` restores the exact previous body the same way; it never drops the
  function, which the existing trigger depends on. The trigger itself is not
  touched, and the original `20261007175954_s12b_wire_witness.exs` is never
  edited.

  Both bodies are frozen literals here; this migration never calls
  `SdrAgent.Agents.WitnessSQL` or any other current-code helper. Written by
  hand: the resource snapshot was regenerated with `--snapshots-only`.
  """
  use Ecto.Migration

  @v4_body """
  CREATE OR REPLACE FUNCTION wire_witness_links_mismatch_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
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
    IF previous.link_status = 'mismatch' AND
       (NEW.evidence ->> 'projection_version') = 'claude-message-json/4+prompt-builder/1' THEN
      RAISE EXCEPTION 'wire witness mismatch % is never superseded by a projection v4 link', previous.id
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END;
  $$
  """

  # The exact body installed by 20261007175954_s12b_wire_witness.exs.
  @previous_body """
  CREATE OR REPLACE FUNCTION wire_witness_links_mismatch_lineage() RETURNS trigger LANGUAGE plpgsql AS $$
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
  """

  def up, do: execute(@v4_body)

  def down, do: execute(@previous_body)
end
