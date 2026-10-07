defmodule SdrAgent.Outreach.Changes.AssessmentRules do
  @moduledoc """
  ReplyAssessment `:record` invariants (S2 "agent ⇒ valid LLM Decision"),
  checked inside the create transaction: the cited Decision is an LLM
  `reply_classification` Decision of the cited run, about the cited reply,
  citing the cited model invocation, whose outcome is the classification.

  A classification of `unsubscribe` then ensures the recipient's
  `unsubscribe_reply` Suppression (S2 "classification unsubscribe ⇒ ensure a
  Suppression exists (create if missing)"): created as the agent through
  Suppression `:from_classification` *before* this row and its event are
  written, so the suppression's row locks precede this transaction's first
  append (S8 lock order). The model can only add a suppression — an
  existing one is returned unchanged — and only for a matched reply.
  Internal invariant reads; nothing read here is returned to the caller.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.Decision
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.Reply
  alias SdrAgent.Outreach.Suppression

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      get = &Ash.Changeset.get_attribute(changeset, &1)
      tenant_id = get.(:tenant_id)
      decision = read(Decision, get.(:decision_id), tenant_id)

      cond do
        not valid_decision?(decision, get) ->
          Ash.Changeset.add_error(changeset,
            field: :decision_id,
            message: "must be the run's llm reply_classification decision about this reply"
          )

        get.(:classification) == :unsubscribe ->
          ensure_suppression(
            changeset,
            read(Reply, get.(:reply_id), tenant_id),
            decision,
            context
          )

        true ->
          changeset
      end
    end)
  end

  defp valid_decision?(%Decision{kind: :reply_classification, mode: :llm} = decision, get) do
    decision.agent_run_id == get.(:agent_run_id) and decision.subject_id == get.(:reply_id) and
      decision.model_invocation_id == get.(:model_invocation_id) and
      decision.outcome == to_string(get.(:classification))
  end

  defp valid_decision?(_decision, _get), do: false

  defp ensure_suppression(changeset, %Reply{match_status: :matched} = reply, decision, context) do
    delivery = read(DeliveryOperation, reply.delivery_operation_id, reply.tenant_id)

    Suppression
    |> Ash.Changeset.for_create(
      :from_classification,
      %{
        scope: :email,
        value: to_string(delivery.recipient_email),
        decision_id: decision.id,
        reply_id: reply.id
      },
      actor: context.actor
    )
    |> Ash.create(return_notifications?: true)
    |> case do
      {:ok, _suppression, notifications} -> {changeset, %{notifications: notifications}}
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp ensure_suppression(changeset, _reply, _decision, _context), do: changeset

  defp read(_resource, nil, _tenant_id), do: nil

  defp read(resource, id, tenant_id) do
    resource
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one!(authorize?: false)
  end
end
