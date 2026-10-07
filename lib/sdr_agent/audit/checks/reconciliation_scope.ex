defmodule SdrAgent.Audit.Checks.ReconciliationScope do
  @moduledoc """
  Policy check for `SdrAgent.Audit.Payload` `:read_reconciliation_content`
  (S12 supplementary Payload ruling S1–S3, ADR-0005 S12 amendment).

  Passes only when all hold:

    * the actor is the reconciler system actor (`%SdrAgent.Actor{type:
      :reconciler}`) with a tenant;
    * the action carries the private scope returned by `context/1`, built by
      `SdrAgent.Agents.read_reconciliation_payloads/2` from the
      authoritative ModelInvocation it re-read in the actor's tenant;
    * the scope's tenant is the actor's tenant;
    * the requested `sha256` is one of the scope's (that invocation's
      request/response payload hashes).

  Like `SdrAgent.Sales.Checks.QualificationContext`, the marker lives in the
  lower domain so Agents may set it; no public domain function accepts a
  caller-supplied scope. `purpose/1` is the fixed access purpose.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_reconciliation_scope

  @impl true
  def describe(_opts),
    do: "reconciler reads a payload hash of the invocation in its Agents-built scope"

  @impl true
  def match?(
        %SdrAgent.Actor{type: :reconciler, tenant_id: tenant_id},
        %{subject: %Ash.ActionInput{context: context, arguments: arguments}},
        _opts
      )
      when is_binary(tenant_id) and is_map(context) do
    case fetch(context) do
      {:ok, %{tenant_id: ^tenant_id, sha256s: sha256s}} ->
        Map.get(arguments, :sha256) in sha256s

      _ ->
        false
    end
  end

  def match?(_actor, _context, _opts), do: false

  @doc """
  The private context for one invocation: `tenant_id`, `model_invocation_id`
  and its payload `sha256s` (nil entries, e.g. no response yet, are dropped).
  """
  def context(%{tenant_id: tenant_id, model_invocation_id: invocation_id, sha256s: sha256s})
      when is_binary(tenant_id) and is_binary(invocation_id) and is_list(sha256s) do
    hashes = Enum.filter(sha256s, &(is_binary(&1) and byte_size(&1) == 32))

    %{
      @marker => %{
        tenant_id: tenant_id,
        model_invocation_id: invocation_id,
        sha256s: Enum.uniq(hashes)
      }
    }
  end

  @doc "The well-formed scope in `context`, if any."
  def fetch(context) when is_map(context) do
    case Map.get(context, @marker) do
      %{tenant_id: tenant_id, model_invocation_id: invocation_id, sha256s: sha256s} = scope
      when is_binary(tenant_id) and is_binary(invocation_id) and is_list(sha256s) ->
        {:ok, scope}

      _ ->
        :error
    end
  end

  def fetch(_context), do: :error

  @doc "The fixed AuditAccess purpose of a scoped read (S2)."
  def purpose(%{model_invocation_id: invocation_id}),
    do: "wire_witness_reconciliation:#{invocation_id}"
end
