defmodule SdrAgent.Audit.PrototypeApprovalGrant do
  @moduledoc """
  Audit-owned projection of the original delegated grant's two IF-5 fields.

  The authorized action and this internal reader both validate the scope.
  Exactly one same-tenant grant event must name the scoped approval and
  anchor, with matching original actor/argument delegation. Only the mode
  and historical delegation leave this boundary. The lookup and a fixed
  record-view AuditAccess run in one transaction; access-recording failure
  returns no metadata. Existing ambient audit transactions are joined, as
  for receipt Payload reads. No raw ledger record or payload is returned.
  """

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    require Ash.Query

    alias SdrAgent.Audit.AuditEvent
    alias SdrAgent.Audit.Checks.PrototypeApprovalGrantScope
    alias SdrAgent.Audit.Kernel, as: AuditKernel

    @subject "SdrAgent.Outreach.Approval"
    @purpose "d237_prototype_approval_grant"

    @doc false
    def read(%Ash.ActionInput{arguments: %{approval_id: id}, context: context}, actor) do
      if PrototypeApprovalGrantScope.allowed?(actor, id, context) do
        scope = Map.fetch!(context, :sdr_prototype_approval_grant_scope)
        AuditKernel.in_transaction(fn -> lookup(id, actor, scope) end)
      else
        {:error, :forbidden}
      end
    end

    def read(_input, _actor), do: {:error, :forbidden}

    defp lookup(id, actor, scope) do
      tenant_id = scope.tenant_id

      query =
        AuditEvent
        |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
        |> Ash.Query.filter(
          tenant_id == ^tenant_id and event_type == "outreach.approval.granted" and
            subject_resource == ^@subject and subject_id == ^id
        )
        |> Ash.Query.select([:id, :actor_type, :actor_id, :payload])
        |> Ash.Query.limit(2)

      with {:ok, [event]} <- Ash.read(query),
           {:ok, metadata} <- project(event, scope.anchor_id),
           {:ok, _access} <-
             AuditKernel.record_access(
               :record_view,
               "SdrAgent.Audit.AuditEvent",
               event.id,
               @purpose,
               actor
             ) do
        {:ok, metadata}
      else
        _ -> {:error, :not_found}
      end
    end

    defp project(
           %{
             actor_type: :prototype_operator,
             actor_id: delegation,
             payload: %{"arguments" => arguments, "changes" => %{"approver_id" => anchor}}
           },
           anchor
         ) do
      with %{"approval_mode" => "delegated_machine", "delegation_id" => ^delegation} <- arguments,
           true <- is_binary(delegation) and Ecto.UUID.cast(delegation) == {:ok, delegation} do
        {:ok, %{"approval_mode" => "delegated_machine", "delegation_id" => delegation}}
      else
        _ -> {:error, :not_found}
      end
    end

    defp project(_event, _anchor), do: {:error, :not_found}
  else
    @doc false
    def read(_input, _actor), do: {:error, :forbidden}
  end
end
