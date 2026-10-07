defmodule SdrAgent.Operations.Changes.ResolveAttention do
  @moduledoc """
  Change for an action that clears a condition needing a human (S2:
  "Resolving the causing condition … resolves its Failure with a system
  note"): after the write, in the same transaction, resolves every open or
  acknowledged Failure whose subject is the cleared record, as the acting
  actor (an operator retry records the operator as resolver).

  Options:

    * `:subject_resource` — the subject's resource name (default: this
      resource);
    * `:subject_field` — record field holding the subject id (default `:id`;
      e.g. `:retry_of_id` for an AgentRun retry, whose subject is the prior
      run);
    * `:note` — note prefix; the written record's id is appended.
  """
  use Ash.Resource.Change

  alias SdrAgent.Operations.Attention

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      subject_resource = opts[:subject_resource] || inspect(changeset.resource)
      subject_id = Map.fetch!(record, opts[:subject_field] || :id)
      note = "#{opts[:note]} #{record.id}"

      case Attention.resolve_subject(
             subject_resource,
             subject_id,
             record.tenant_id,
             note,
             context.actor
           ) do
        {:ok, _resolved} -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
