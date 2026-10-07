defmodule SdrAgent.Operations.Changes.Redact do
  @moduledoc """
  Redacts free-text, error-bearing attributes of the record being written
  (`SdrAgent.Operations.Redactor`) before the row and its AuditEvent are
  persisted — e.g. AgentRun `failure_reason` ("redacted detail", S2) and the
  Lead `status_reason` of a block. The operator-attention copy is redacted
  again by Failure; this change keeps the causing record clean too
  (ADR-0001: never persist secret values).

  Option `:fields` — the string attributes to redact.
  """
  use Ash.Resource.Change

  alias SdrAgent.Operations.Redactor

  @impl true
  def change(changeset, opts, _context) do
    Enum.reduce(opts[:fields], changeset, fn field, acc ->
      case Ash.Changeset.get_attribute(acc, field) do
        value when is_binary(value) ->
          Ash.Changeset.force_change_attribute(acc, field, Redactor.redact(value))

        _ ->
          acc
      end
    end)
  end
end
