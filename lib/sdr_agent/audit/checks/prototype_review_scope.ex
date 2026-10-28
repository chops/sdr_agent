defmodule SdrAgent.Audit.Checks.PrototypeReviewScope do
  @moduledoc """
  Policy check for `SdrAgent.Audit.Payload` `:read_prototype_review_content`
  (interfaces r6 "Operator payload and content paths", must-fix R4; the
  precedent is `SdrAgent.Audit.Checks.ReconciliationScope`).

  Contract: it passes only when ALL hold:

    * the actor is an `%SdrAgent.Actor{type: :prototype_operator}`;
    * the action carries the private scope built by `context/1`, which only
      `SdrAgent.Prototype.Output` (S4) builds, from the authoritative
      `DeliveryReceipt` it re-read in the binding's tenant;
    * the scope's `tenant_id` is the actor's tenant and its `delegation_id`
      the actor's id;
    * the requested `sha256` is one of the scope's `sha256s` (exactly that
      receipt's `rendered_sha256`);
    * the live resolver `SdrAgent.Prototype.operator_actor/1`, re-run on the
      actor's id, returns exactly that actor.

  `purpose/0` is the fixed AuditAccess purpose of a scoped read.

  RED stage (D-237 S1 item 5): DENY-ONLY. `match?/3` refuses every request;
  `context/1`, `fetch/1` and `purpose/0` are the contract.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_prototype_review_scope

  @impl true
  def describe(_opts),
    do: "the resolved prototype operator reads the rendered payload of its review scope"

  @impl true
  def match?(_actor, _authorizer, _opts), do: red(false)

  @doc "The fixed AuditAccess purpose of a scoped review read."
  @spec purpose() :: String.t()
  def purpose, do: "d237_prototype_review"

  @doc """
  The private context for one read: `tenant_id`, `delegation_id` and the
  32-byte `sha256s` (one receipt's `rendered_sha256`). Any other input
  raises `ArgumentError`.
  """
  @spec context(map()) :: map()
  def context(%{tenant_id: tenant_id, delegation_id: delegation_id, sha256s: sha256s} = scope)
      when is_binary(tenant_id) and is_binary(delegation_id) and is_list(sha256s) do
    if sha256s != [] and Enum.all?(sha256s, &(is_binary(&1) and byte_size(&1) == 32)) do
      %{@marker => %{scope | sha256s: Enum.uniq(sha256s)}}
    else
      raise ArgumentError, "a prototype review scope needs one or more 32-byte sha256s"
    end
  end

  def context(_other), do: raise(ArgumentError, "not a prototype review scope")

  @doc "The well-formed scope in `context`, if any."
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(context) when is_map(context) do
    case Map.get(context, @marker) do
      %{tenant_id: tenant_id, delegation_id: delegation_id, sha256s: sha256s} = scope
      when is_binary(tenant_id) and is_binary(delegation_id) and is_list(sha256s) ->
        {:ok, scope}

      _other ->
        :error
    end
  end

  def fetch(_context), do: :error

  # RED stub result, typed dynamic(); nothing sets the key (ruling e).
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
