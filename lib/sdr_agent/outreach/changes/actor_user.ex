defmodule SdrAgent.Outreach.Changes.ActorUser do
  @moduledoc """
  Sets attribute `:field` to the acting human operator's id (e.g. a manual
  suppression's `created_by_user_id`, an approval's `approver_id`). The
  action's policy admits only human operators, so the actor is a User; any
  other actor leaves the attribute unset and the row's own constraints
  refuse it.

  D-237 scope (interfaces r6 IF-3 "ActorUser scope"): only with the option
  `prototype_anchor: true` (set on Approval `:approve`, `:reject` and
  `:revoke` only) AND an actor that `SdrAgent.Prototype.operator?/1`
  resolves live is the field forced to the binding's anchor user
  (`operator_user_id`). The anchor is a foreign-key value only; the actor
  and the events stay the delegation. Without the option (a manual
  suppression, for example), or for a forged operator struct or an
  operator outside prototype runtime, the field stays unset as before.
  That clause is compiled only with the prototype authority
  (`:prototype_authority_compiled`); the production build has none.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    case user_id(opts, Map.get(context, :actor)) do
      nil -> changeset
      id -> Ash.Changeset.force_change_attribute(changeset, opts[:field], id)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp user_id(_opts, %SdrAgent.Accounts.User{id: id}), do: id

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    # The live resolver on every call; the anchor comes from the binding.
    defp user_id(opts, %SdrAgent.Actor{type: :prototype_operator} = actor) do
      with true <- Keyword.get(opts, :prototype_anchor) == true,
           true <- SdrAgent.Prototype.operator?(actor),
           {:ok, %SdrAgent.Prototype.Binding{operator_user_id: id}} when is_binary(id) <-
             SdrAgent.Prototype.binding() do
        id
      else
        _ -> nil
      end
    end
  end

  defp user_id(_opts, _actor), do: nil
end
