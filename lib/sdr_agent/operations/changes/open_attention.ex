defmodule SdrAgent.Operations.Changes.OpenAttention do
  @moduledoc """
  Update change for a transition that needs a human (S2 "Operator
  attention"): before the row is written, inside the action's transaction,
  opens a Failure whose subject is the record being updated, and optionally
  stores its id on the record. If the Failure cannot be written the
  transition fails with it — there is never one without the other.

  Options:

    * `:class` — a Failure class, or `{:arg, name}` to read it from an
      action argument;
    * `:severity` — `:warning` or `:critical`;
    * `:message` — `{module, function}` called with the changeset, returning
      the (unredacted) message; the Failure action redacts it;
    * `:field` — attribute set to the Failure id (e.g. `:attention_failure_id`);
    * `:operation_field` — record attribute holding the Operation the record
      belongs to (e.g. AgentRun `:operation_id`), copied to the Failure so the
      Operation can link this Failure when it fails for the same condition;
    * `:system_only?` — open only when the actor is a system actor (S2:
      "cancelled by a system actor").
  """
  use Ash.Resource.Change

  alias SdrAgent.Operations.Attention

  @impl true
  def change(changeset, opts, context) do
    if opts[:system_only?] && !match?(%SdrAgent.Actor{}, context.actor),
      do: changeset,
      else: Ash.Changeset.before_action(changeset, &maybe_open(&1, opts, context.actor))
  end

  defp maybe_open(%{valid?: true} = changeset, opts, actor), do: open(changeset, opts, actor)
  defp maybe_open(changeset, _opts, _actor), do: changeset

  defp open(changeset, opts, actor) do
    {module, function} = opts[:message]
    record = changeset.data

    attrs = %{
      subject_resource: inspect(changeset.resource),
      subject_id: record.id,
      class: class(changeset, opts[:class]),
      severity: opts[:severity],
      message: apply(module, function, [changeset]),
      retryable: true,
      operation_id: opts[:operation_field] && Map.get(record, opts[:operation_field])
    }

    case Attention.open(attrs, actor) do
      {:ok, failure} ->
        if opts[:field],
          do: Ash.Changeset.force_change_attribute(changeset, opts[:field], failure.id),
          else: changeset

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp class(changeset, {:arg, name}), do: Ash.Changeset.get_argument(changeset, name)
  defp class(_changeset, class), do: class
end
