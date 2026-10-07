defmodule SdrAgent.Agents.Changes.Replay do
  @moduledoc """
  Conflict-safe idempotency for Decision creation.

  Before the insert, computes `replay_sha256`: the canonical hash of every
  decision-defining field (run, kind, mode, subject, input refs, the
  canonical inputs hash, rule and model provenance, output pointer,
  outcome, outcome detail, rationale, confidence). The create is an upsert
  on `(tenant_id, idempotency_key)` that never updates, so a concurrent or
  repeated insert of the same key returns the stored row instead of
  failing. After the insert:

    * a freshly inserted row passes through;
    * an existing row with the same fingerprint is an identical replay — it
      is returned unchanged and marked so no second AuditEvent is appended;
    * an existing row with a different fingerprint fails the action with
      `SdrAgent.Agents.Errors.IdempotencyConflict`.

  Must be added after `DecisionRules` (which sets `inputs_sha256`) and
  before `AppendEvent`.
  """
  use Ash.Resource.Change

  alias SdrAgent.Agents.Errors.IdempotencyConflict
  alias SdrAgent.Audit.Canonical

  @fields [
    :agent_run_id,
    :kind,
    :mode,
    :subject_resource,
    :subject_id,
    :input_refs,
    :inputs_sha256,
    :rule_id,
    :rule_version,
    :model_invocation_id,
    :output_pointer,
    :outcome,
    :outcome_detail,
    :rationale,
    :confidence
  ]

  @doc "Fields covered by the replay fingerprint."
  def fields, do: @fields

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&fingerprint/1)
    |> Ash.Changeset.after_action(&check_replay/2)
  end

  defp fingerprint(changeset) do
    value =
      @fields
      |> Map.new(fn field -> {field, Ash.Changeset.get_attribute(changeset, field)} end)
      |> Map.update!(:inputs_sha256, &(&1 && Base.encode16(&1, case: :lower)))
      |> Canonical.sha256()

    Ash.Changeset.force_change_attribute(changeset, :replay_sha256, value)
  end

  defp check_replay(changeset, record) do
    cond do
      record.id == Ash.Changeset.get_attribute(changeset, :id) ->
        {:ok, record}

      record.replay_sha256 == Ash.Changeset.get_attribute(changeset, :replay_sha256) ->
        {:ok, Ash.Resource.put_metadata(record, :sdr_replayed, true)}

      true ->
        {:error,
         IdempotencyConflict.exception(
           idempotency_key: record.idempotency_key,
           existing_id: record.id
         )}
    end
  end
end
