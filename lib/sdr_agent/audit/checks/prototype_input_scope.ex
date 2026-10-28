defmodule SdrAgent.Audit.Checks.PrototypeInputScope do
  @moduledoc """
  Policy check for `SdrAgent.Audit.Payload` `:store_prototype_input`
  (interfaces r6 "Operator payload and content paths", must-fix R4; the
  precedent is `SdrAgent.Audit.Checks.ReconciliationScope`).

  Contract: it passes only when ALL hold:

    * the actor is a `%SdrAgent.Actor{type: :prototype_operator}`;
    * the changeset carries the private scope built by `context/1`, which
      only the D-237 import and seed functions (S3) build, after they have
      resolved the operator actor;
    * the scope's `tenant_id` is the actor's tenant and its `delegation_id`
      is the actor's id;
    * its `purpose` is one of `purposes/0`;
    * the sha256 of the content being stored is one of the scope's
      `sha256s` (the exact hashes the function computed from the bytes it is
      about to store);
    * the live resolver `SdrAgent.Prototype.operator_actor/1`, re-run on the
      actor's id, returns exactly that actor.

  An `Actor` struct alone, or a caller-supplied hash set alone, is never
  authority. No public domain function accepts a caller-built scope.

  RED stage (D-237 S1 item 4): DENY-ONLY. `match?/3` refuses every request;
  `context/1`, `fetch/1` and `purposes/0` are the contract.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_prototype_input_scope
  @purposes [:dossier_claims, :dossier_notes, :dossier_excerpts, :seed_provenance]

  @impl true
  def describe(_opts),
    do: "the resolved prototype operator stores exactly the bytes of its import or seed scope"

  @impl true
  def match?(_actor, _authorizer, _opts), do: red(false)

  @doc "The approved purposes of a prototype input."
  @spec purposes() :: [atom()]
  def purposes, do: @purposes

  @doc """
  The private context for one store: `tenant_id`, `delegation_id`, `purpose`
  (one of `purposes/0`) and the 32-byte `sha256s` of the bytes about to be
  stored. Any other input raises `ArgumentError`.
  """
  @spec context(map()) :: map()
  def context(%{
        tenant_id: tenant_id,
        delegation_id: delegation_id,
        purpose: purpose,
        sha256s: sha256s
      })
      when is_binary(tenant_id) and is_binary(delegation_id) and purpose in @purposes and
             is_list(sha256s) do
    if sha256s != [] and Enum.all?(sha256s, &(is_binary(&1) and byte_size(&1) == 32)) do
      %{
        @marker => %{
          tenant_id: tenant_id,
          delegation_id: delegation_id,
          purpose: purpose,
          sha256s: Enum.uniq(sha256s)
        }
      }
    else
      raise ArgumentError, "a prototype input scope needs one or more 32-byte sha256s"
    end
  end

  def context(_other), do: raise(ArgumentError, "not a prototype input scope")

  @doc "The well-formed scope in `context`, if any."
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(context) when is_map(context) do
    case Map.get(context, @marker) do
      %{tenant_id: tenant_id, delegation_id: delegation_id, purpose: purpose, sha256s: sha256s} =
          scope
      when is_binary(tenant_id) and is_binary(delegation_id) and purpose in @purposes and
             is_list(sha256s) ->
        {:ok, scope}

      _other ->
        :error
    end
  end

  def fetch(_context), do: :error

  # RED stub result, typed dynamic(); nothing sets the key (ruling e).
  defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
end
