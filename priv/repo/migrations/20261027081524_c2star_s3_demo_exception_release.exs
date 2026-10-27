defmodule SdrAgent.Repo.Migrations.C2starS3DemoExceptionRelease do
  @moduledoc """
  C2* slice S3 (ADR-0005 C2* amendment item 8, D-223; ADR-0009 C2*
  record-hash continuity amendment, D-226): the four nullable demo-exception
  columns of the append-only `model_result_releases` (no default, no
  backfill), the `_disposition` and `_reason` lists with `demo_exception` and
  `v4_uncalibrated`, the `_pair` CHECK whose existing branches gain "all four
  exception columns NULL" and whose NULL-safe demo branch is new, and three
  added NULL-safe CHECKs (`_exception_window`, `_exception_basis_sha256`,
  `_exception_basis_shape`). Triggers, FKs, the unique index and every
  existing row are unchanged; an earlier row gets the four columns as SQL
  NULL, so its record hash is unchanged (D-226).

  Generated with `mix ash.codegen c2star_s3_demo_exception_release`;
  reviewed by hand. `down/0` is hand-ordered: drop the three added CHECKs,
  drop the new `_pair`, `_reason` and `_disposition`, re-create the exact
  previous bodies (`20261012214848_r0_07a_result_release.exs`) in their
  original order, then remove the four columns. While any `demo_exception`
  row exists, re-creating `_disposition` fails with `check_violation` and
  the whole `down` rolls back; nothing is dropped with CASCADE.
  """

  use Ecto.Migration

  def up do
    alter table(:model_result_releases) do
      add :exception_policy_id, :text
      add :exception_expires_at, :utc_datetime_usec
      add :exception_basis, :map
      add :exception_basis_sha256, :text
    end

    drop_if_exists constraint(:model_result_releases, :model_result_releases_disposition)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_reason)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_pair)

    create constraint(:model_result_releases, :model_result_releases_disposition,
             check: """
               disposition IN ('released', 'withheld', 'calibration', 'demo_exception')
             """
           )

    create constraint(:model_result_releases, :model_result_releases_reason,
             check: """
               reason IN ('reconciled', 'calibration', 'v4_uncalibrated', 'witness_mismatch', 'witness_missing', 'witness_timeout', 'store_unreadable', 'gate_interrupted')
             """
           )

    create constraint(:model_result_releases, :model_result_releases_pair,
             check: """
               (disposition = 'released' AND reason = 'reconciled' AND wire_witness_link_id IS NOT NULL AND projection_version IS NOT NULL AND method IS NOT NULL AND evidence_sha256 IS NULL AND exception_policy_id IS NULL AND exception_expires_at IS NULL AND exception_basis IS NULL AND exception_basis_sha256 IS NULL) OR (disposition = 'withheld' AND reason IN ('witness_mismatch', 'witness_missing', 'witness_timeout', 'store_unreadable', 'gate_interrupted') AND evidence_sha256 IS NULL AND exception_policy_id IS NULL AND exception_expires_at IS NULL AND exception_basis IS NULL AND exception_basis_sha256 IS NULL) OR (disposition = 'calibration' AND reason = 'calibration' AND evidence_sha256 IS NOT NULL AND exception_policy_id IS NULL AND exception_expires_at IS NULL AND exception_basis IS NULL AND exception_basis_sha256 IS NULL) OR COALESCE((disposition = 'demo_exception' AND reason = 'v4_uncalibrated' AND wire_witness_link_id IS NOT NULL AND projection_version IS NOT NULL AND projection_version = 'claude-message-json/4+prompt-builder/1' AND method IS NOT NULL AND method = 'propagated_id' AND evidence_sha256 IS NULL AND exception_policy_id IS NOT NULL AND exception_expires_at IS NOT NULL AND exception_basis IS NOT NULL AND exception_basis_sha256 IS NOT NULL), false)
             """
           )

    create constraint(:model_result_releases, :model_result_releases_exception_window,
             check: """
               disposition <> 'demo_exception' OR (exception_expires_at IS NOT NULL AND decided_at < exception_expires_at) IS TRUE
             """
           )

    create constraint(:model_result_releases, :model_result_releases_exception_basis_sha256,
             check: """
               exception_basis_sha256 IS NULL OR exception_basis_sha256 ~ '^[0-9a-f]{64}$'
             """
           )

    create constraint(:model_result_releases, :model_result_releases_exception_basis_shape,
             check: """
               disposition <> 'demo_exception' OR (jsonb_typeof(exception_basis) = 'object' AND jsonb_typeof(exception_basis->'policy') = 'object' AND exception_basis->>'schema' = 'c2star-basis/1' AND exception_basis->'policy'->>'id' = exception_policy_id) IS TRUE
             """
           )
  end

  def down do
    drop_if_exists constraint(
                     :model_result_releases,
                     :model_result_releases_exception_basis_shape
                   )

    drop_if_exists constraint(
                     :model_result_releases,
                     :model_result_releases_exception_basis_sha256
                   )

    drop_if_exists constraint(:model_result_releases, :model_result_releases_exception_window)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_pair)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_reason)

    drop_if_exists constraint(:model_result_releases, :model_result_releases_disposition)

    # The exact previous bodies (20261012214848_r0_07a_result_release.exs),
    # in their original order. A demo_exception row makes the first fail.
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

    create constraint(:model_result_releases, :model_result_releases_pair,
             check: """
               (disposition = 'released' AND reason = 'reconciled' AND wire_witness_link_id IS NOT NULL AND projection_version IS NOT NULL AND method IS NOT NULL AND evidence_sha256 IS NULL) OR (disposition = 'withheld' AND reason IN ('witness_mismatch', 'witness_missing', 'witness_timeout', 'store_unreadable', 'gate_interrupted') AND evidence_sha256 IS NULL) OR (disposition = 'calibration' AND reason = 'calibration' AND evidence_sha256 IS NOT NULL)
             """
           )

    alter table(:model_result_releases) do
      remove :exception_basis_sha256
      remove :exception_basis
      remove :exception_expires_at
      remove :exception_policy_id
    end
  end
end
