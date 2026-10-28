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

  `fetch/1` validates every member at consumption and never raises. The
  positive branch exists only with the prototype authority
  (`:prototype_authority_compiled`); the production build refuses every
  request.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_prototype_review_scope

  @impl true
  def describe(_opts),
    do: "the resolved prototype operator reads the rendered payload of its review scope"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @impl true
    def match?(
          %SdrAgent.Actor{type: :prototype_operator, id: id, tenant_id: tenant_id} = actor,
          %{subject: %Ash.ActionInput{context: context, arguments: arguments}},
          _opts
        )
        when is_binary(id) and is_binary(tenant_id) and is_map(context) do
      with {:ok, %{tenant_id: ^tenant_id, delegation_id: ^id, sha256s: sha256s}} <-
             fetch(context),
           true <- Map.get(arguments, :sha256) in sha256s do
        SdrAgent.Prototype.Authority.operator?(actor)
      else
        _refused -> false
      end
    end

    def match?(_actor, _authorizer, _opts), do: false
  else
    @impl true
    def match?(_actor, _authorizer, _opts), do: false
  end

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
    if hashes?(sha256s) do
      %{@marker => %{scope | sha256s: Enum.uniq(sha256s)}}
    else
      raise ArgumentError, "a prototype review scope needs one or more 32-byte sha256s"
    end
  end

  def context(_other), do: raise(ArgumentError, "not a prototype review scope")

  @doc """
  The well-formed scope in `context`, if any: binary tenant and delegation
  and a non-empty proper list of 32-byte hashes only. A forged or malformed
  scope (any other shape or member) is `:error`; it never raises.
  """
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(context) when is_map(context) do
    case Map.get(context, @marker) do
      %{tenant_id: tenant_id, delegation_id: delegation_id, sha256s: sha256s} = scope
      when is_binary(tenant_id) and is_binary(delegation_id) ->
        if hashes?(sha256s), do: {:ok, scope}, else: :error

      _other ->
        :error
    end
  end

  def fetch(_context), do: :error

  # A non-empty PROPER list of 32-byte binaries. Anything else, an improper
  # tail included, is false; it never raises (Codex 6ccaa32f R1).
  defp hashes?([_ | _] = sha256s), do: all_hashes?(sha256s)
  defp hashes?(_other), do: false

  defp all_hashes?([]), do: true

  defp all_hashes?([sha256 | rest]) when is_binary(sha256) and byte_size(sha256) == 32,
    do: all_hashes?(rest)

  defp all_hashes?(_improper_or_invalid), do: false
end
