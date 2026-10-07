defmodule SdrAgent.Agents.Changes.WitnessLineage do
  @moduledoc """
  Create-time rules of `SdrAgent.Agents.WireWitnessLink` (S12 R1, C3–C5),
  checked inside the action transaction:

    1. `evidence` is normalized and validated by
       `SdrAgent.Agents.WitnessEvidence` (C5); raw digests are 32 bytes.
    2. The parent ModelInvocation is re-read **in the row's tenant** and
       locked `FOR UPDATE`, serialising every link write of one invocation
       (lock order: invocation row, then the audit chain head). It must be a
       terminal `:claude_cli` invocation — no witness claim is made for the
       Fake provider or an in-flight call.
    3. Lineage per exchange `(tenant, invocation, proxy_record_ref)`: the
       first row supersedes nothing; every later row supersedes exactly the
       current head of that exchange and states `supersede_reason`; a
       `mismatch` head may only be superseded under a different
       `projection_version` (C3). The partial unique indexes, the
       same-subject composite foreign key and the insert trigger back these
       up in the database.

  The parent's `agent_run_id` is put in the changeset context
  (`:wire_witness_agent_run_id`) for the audit event's run correlation.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.Audit.Kernel

  @terminal [:completed, :failed, :unknown]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> validate_evidence()
    |> validate_digests()
    |> Ash.Changeset.before_action(&check_parent_and_lineage/1)
  end

  defp validate_evidence(changeset) do
    case WitnessEvidence.validate(Ash.Changeset.get_attribute(changeset, :evidence)) do
      {:ok, evidence} -> Ash.Changeset.force_change_attribute(changeset, :evidence, evidence)
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :evidence, message: message)
    end
  end

  defp validate_digests(changeset) do
    Enum.reduce([:proxy_request_sha256, :proxy_response_sha256], changeset, fn field, acc ->
      case Ash.Changeset.get_attribute(acc, field) do
        nil -> acc
        digest when is_binary(digest) and byte_size(digest) == 32 -> acc
        _ -> Ash.Changeset.add_error(acc, field: field, message: "must be 32 bytes")
      end
    end)
  end

  defp check_parent_and_lineage(changeset) do
    get = &Ash.Changeset.get_attribute(changeset, &1)
    tenant_id = get.(:tenant_id)

    case lock_parent(tenant_id, get.(:model_invocation_id)) do
      nil ->
        invalid(changeset, :model_invocation_id, "is not a model invocation of this tenant")

      %{provider: provider} when provider != :claude_cli ->
        invalid(changeset, :model_invocation_id, "only ClaudeCLI invocations are witnessed")

      %{status: status} when status not in @terminal ->
        invalid(changeset, :model_invocation_id, "must be terminal before it is linked")

      invocation ->
        changeset
        |> Ash.Changeset.set_context(%{wire_witness_agent_run_id: invocation.agent_run_id})
        |> check_lineage(tenant_id, get)
    end
  end

  defp check_lineage(changeset, tenant_id, get) do
    head =
      current(changeset.resource, tenant_id, get.(:model_invocation_id), get.(:proxy_record_ref))

    supersedes_id = get.(:supersedes_id)
    evidence = get.(:evidence) || %{}

    case {head, supersedes_id} do
      {nil, nil} ->
        changeset

      {nil, _} ->
        invalid(changeset, :supersedes_id, "the first link of an exchange cannot supersede")

      {%{id: id} = head, id} ->
        check_successor(changeset, head, evidence)

      {_head, _} ->
        invalid(changeset, :supersedes_id, "must supersede the current link of this exchange")
    end
  end

  defp check_successor(changeset, head, evidence) do
    cond do
      not Map.has_key?(evidence, "supersede_reason") ->
        invalid(changeset, :evidence, "a successor must state supersede_reason")

      head.link_status == :mismatch and
          Map.get(evidence, "projection_version") ==
            Map.get(head.evidence || %{}, "projection_version") ->
        invalid(
          changeset,
          :supersedes_id,
          "a mismatch is superseded only under a different projection version"
        )

      true ->
        changeset
    end
  end

  defp lock_parent(tenant_id, invocation_id)
       when is_binary(tenant_id) and is_binary(invocation_id) do
    ModelInvocation
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(id == ^invocation_id and tenant_id == ^tenant_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end

  defp lock_parent(_tenant_id, _invocation_id), do: nil

  defp current(resource, tenant_id, invocation_id, ref) do
    resource
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(
      tenant_id == ^tenant_id and model_invocation_id == ^invocation_id and
        proxy_record_ref == ^ref and not exists(successors, true)
    )
    |> Ash.read_one!()
  end

  defp invalid(changeset, field, message),
    do: Ash.Changeset.add_error(changeset, field: field, message: message)
end
