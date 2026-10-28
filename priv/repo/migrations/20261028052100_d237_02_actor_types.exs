defmodule SdrAgent.Repo.Migrations.D23702ActorTypes do
  @moduledoc """
  D-237 migration 2 of 7 (interfaces r6 IF-2 phase 1, IF-3): the actor type
  `prototype_operator` of `audit_events` and `audit_accesses`.

  Both columns are constrained by the resources' Ash `one_of` over
  `SdrAgent.Actor.types/0` (no database CHECK exists on either column), so
  the new type follows from `SdrAgent.Actor` and `up/0` changes nothing.
  `down/0` refuses while any event or access records the new type
  (amendment item 6 "Migration": it never deletes or rewrites a row).
  """

  use Ecto.Migration

  def up, do: :ok

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM audit_events WHERE actor_type = 'prototype_operator')
         OR EXISTS (SELECT 1 FROM audit_accesses WHERE actor_type = 'prototype_operator') THEN
        RAISE EXCEPTION 'd237_02_actor_types down refused: a prototype_operator record exists'
          USING ERRCODE = 'restrict_violation';
      END IF;
    END
    $$
    """)
  end
end
