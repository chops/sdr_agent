defmodule SdrAgent.Audit.Checks.PrototypeApprovalGrantScope do
  @moduledoc """
  Confines S4's two-field historical approval-grant projection.

  Output builds the private scope only after reading an approved Approval
  whose approver is the binding anchor. Consumption checks the exact
  approval argument, tenant, current delegation and anchor and re-resolves
  the live operator. This grants neither event-row nor Payload reads.
  Ordinary production builds have no positive branch.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the live operator reads only its scoped approval's grant metadata"

  @impl true
  def match?(actor, %{subject: %Ash.ActionInput{arguments: arguments, context: context}}, _opts),
    do: allowed?(actor, Map.get(arguments, :approval_id), context)

  def match?(_actor, _authorizer, _opts), do: false

  @doc "Revalidates the scope at policy and internal consumption; never accepts an actor struct alone."
  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @marker :sdr_prototype_approval_grant_scope
    @fields [:anchor_id, :approval_id, :delegation_id, :tenant_id]

    def allowed?(%SdrAgent.Actor{type: :prototype_operator} = actor, approval_id, context)
        when is_map(context) do
      with %{
             tenant_id: tenant,
             delegation_id: delegation,
             approval_id: ^approval_id,
             anchor_id: anchor
           } = scope <- Map.get(context, @marker),
           true <- Enum.sort(Map.keys(scope)) == @fields,
           true <- Enum.all?(Map.values(scope), &uuid?/1),
           true <- actor.tenant_id == tenant and actor.id == delegation,
           {:ok, %{tenant_id: ^tenant, operator_user_id: ^anchor}} <-
             SdrAgent.Prototype.binding(),
           {:ok, ^actor} <- SdrAgent.Prototype.operator_actor(delegation) do
        true
      else
        _ -> false
      end
    end

    def allowed?(_actor, _approval_id, _context), do: false

    defp uuid?(id) when is_binary(id), do: Ecto.UUID.cast(id) == {:ok, id}
    defp uuid?(_id), do: false
  else
    def allowed?(_actor, _approval_id, _context), do: false
  end
end
