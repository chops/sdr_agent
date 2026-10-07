defmodule SdrAgent.Outreach.Changes.AssessmentRules do
  @moduledoc """
  ReplyAssessment `:record` invariants (S2 "agent ⇒ valid LLM Decision"),
  checked inside the create transaction: the cited Decision is an LLM
  `reply_classification` Decision of the cited run about the cited Reply
  (resource and id), citing the cited invocation at `/classification`; the
  invocation is that run's completed, validated `reply_classification`
  call (schema `sdr.reply_classification`) in the same tenant; and its
  parsed output equals the Decision's outcome and every model-derived
  value of the assessment (classification, sentiment, intent, suggested
  next action, confidence, reason). A forged Decision on a real call, a
  call of another run or purpose, or caller-supplied values the model did
  not produce are refused — nothing is written.

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
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.Reply
  alias SdrAgent.Outreach.Suppression

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      get = &Ash.Changeset.get_attribute(changeset, &1)
      tenant_id = get.(:tenant_id)
      decision = read(Decision, get.(:decision_id), tenant_id)
      invocation = invocation(get.(:model_invocation_id), tenant_id, context.actor)

      cond do
        not valid_decision?(decision, get) ->
          Ash.Changeset.add_error(changeset,
            field: :decision_id,
            message: "must be the run's llm reply_classification decision about this reply"
          )

        not valid_output?(invocation, decision, get) ->
          Ash.Changeset.add_error(changeset,
            field: :model_invocation_id,
            message:
              "must be the run's completed, validated reply_classification call whose output is this assessment"
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
    decision.agent_run_id == get.(:agent_run_id) and
      decision.subject_resource == inspect(Reply) and decision.subject_id == get.(:reply_id) and
      decision.model_invocation_id == get.(:model_invocation_id) and
      decision.output_pointer == "/classification" and
      decision.outcome == to_string(get.(:classification))
  end

  defp valid_decision?(_decision, _get), do: false

  # The call itself: same tenant (read scoped) and run, the reply
  # classification purpose and schema, completed with a validated output —
  # and that output *is* the decision's outcome and every model-derived value
  # of the assessment (nothing is trusted from the caller's attributes).
  defp valid_output?(%ModelInvocation{} = inv, %Decision{} = decision, get) do
    out = inv.parsed_output || %{}

    valid_call?(inv, get) and field(out, :classification) == decision.outcome and
      same_values?(out, get)
  end

  defp valid_output?(_invocation, _decision, _get), do: false

  defp valid_call?(inv, get) do
    inv.agent_run_id == get.(:agent_run_id) and inv.purpose == :reply_classification and
      inv.output_schema_id == "sdr.reply_classification" and
      {inv.status, inv.validation_status} == {:completed, :valid}
  end

  defp same_values?(out, get) do
    Enum.all?([:classification, :sentiment, :suggested_next_action], fn key ->
      field(out, key) == to_string(get.(key))
    end) and field(out, :intent) == get.(:intent) and field(out, :reason) == get.(:reason) and
      same_number?(field(out, :confidence), get.(:confidence))
  end

  defp field(map, key), do: Map.get(map, Atom.to_string(key), Map.get(map, key))

  defp same_number?(a, b) when is_number(a) and is_number(b), do: a == b
  defp same_number?(_a, _b), do: false

  # Invocation metadata through the Agents read policy as the acting agent,
  # scoped to the tenant.
  defp invocation(nil, _tenant_id, _actor), do: nil

  defp invocation(id, tenant_id, actor) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
    |> Ash.read_one!()
  end

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
