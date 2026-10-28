defmodule SdrAgent.Repo.Migrations.D23706Sources do
  @moduledoc """
  D-237 migration 6 of 7 (interfaces r6 IF-6, entity delta "Account.source,
  Lead.source; ResearchArtifact.provider"): the source value `dossier` of
  `accounts` and `leads`, and the research provider `public_dossier`.

  All three columns are constrained by the resources' Ash `one_of` (no
  database CHECK exists on any of them), so the new values follow from the
  resources and `up/0` changes nothing. `down/0` refuses while any row
  holds a new value (amendment item 6 "Migration": it never deletes or
  rewrites a row).
  """

  use Ecto.Migration

  def up, do: :ok

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM accounts WHERE source = 'dossier')
         OR EXISTS (SELECT 1 FROM leads WHERE source = 'dossier')
         OR EXISTS (SELECT 1 FROM research_artifacts WHERE provider = 'public_dossier') THEN
        RAISE EXCEPTION 'd237_06_sources down refused: a dossier-sourced record exists'
          USING ERRCODE = 'restrict_violation';
      END IF;
    END
    $$
    """)
  end
end
