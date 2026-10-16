defmodule SdrAgent.Repo.Migrations.C202b2bResolutionCheck do
  @moduledoc """
  C2-02b2β GREEN review MF3 (Codex `5e7f066`): the resolution CHECK no
  longer lets a NULL `finished_at` escape it. A resolved switch requires
  `finished_at IS NOT NULL` and `resolved_at IS NOT DISTINCT FROM
  finished_at`; the all-null tuple of an unresolved switch is unchanged.

  Generated with `mix ash.codegen c2_02b2b_resolution_check` and reviewed
  (it replaces the one constraint; the applied migration is not edited).
  """

  use Ecto.Migration

  def up do
    drop_if_exists constraint(:model_profile_switches, :model_profile_switches_resolution)

    create constraint(:model_profile_switches, :model_profile_switches_resolution,
             check: """
               (resolution IS NULL AND resolved_by_id IS NULL AND resolved_at IS NULL AND attestation_id IS NULL AND attested_start_id IS NULL AND attested_generation IS NULL AND attested_lease_kind IS NULL) OR (resolution IS NOT NULL AND resolved_by_id IS NOT NULL AND resolved_at IS NOT NULL AND attestation_id IS NOT NULL AND attested_start_id IS NOT NULL AND attested_generation IS NOT NULL AND attested_lease_kind IS NOT NULL AND resolution = 'owner_attested' AND attested_lease_kind IN ('none', 'survivor', 'dead_holder') AND status = 'failed' AND finished_at IS NOT NULL AND resolved_at IS NOT DISTINCT FROM finished_at AND attested_generation >= server_generation)
             """
           )
  end

  def down do
    drop_if_exists constraint(:model_profile_switches, :model_profile_switches_resolution)

    create constraint(:model_profile_switches, :model_profile_switches_resolution,
             check: """
               (resolution IS NULL AND resolved_by_id IS NULL AND resolved_at IS NULL AND attestation_id IS NULL AND attested_start_id IS NULL AND attested_generation IS NULL AND attested_lease_kind IS NULL) OR (resolution IS NOT NULL AND resolved_by_id IS NOT NULL AND resolved_at IS NOT NULL AND attestation_id IS NOT NULL AND attested_start_id IS NOT NULL AND attested_generation IS NOT NULL AND attested_lease_kind IS NOT NULL AND resolution = 'owner_attested' AND attested_lease_kind IN ('none', 'survivor', 'dead_holder') AND status = 'failed' AND resolved_at = finished_at AND attested_generation >= server_generation)
             """
           )
  end
end
