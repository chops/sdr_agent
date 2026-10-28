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

  The scope's tenant must also equal the changeset's own server-derived
  `tenant_id` (set from the actor by `SetTenant`), and `fetch/1` validates
  every member at consumption. It is compiled with a positive branch only
  with the prototype authority (`:prototype_authority_compiled`); the
  production build refuses every request.
  """
  use Ash.Policy.SimpleCheck

  @marker :sdr_prototype_input_scope
  @purposes [:dossier_claims, :dossier_notes, :dossier_excerpts, :seed_provenance]

  @impl true
  def describe(_opts),
    do: "the resolved prototype operator stores exactly the bytes of its import or seed scope"

  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    @impl true
    def match?(
          %SdrAgent.Actor{type: :prototype_operator, id: id, tenant_id: tenant_id} = actor,
          %{subject: %Ash.Changeset{context: context} = changeset},
          _opts
        )
        when is_binary(id) and is_binary(tenant_id) and is_map(context) do
      with {:ok, %{tenant_id: ^tenant_id, delegation_id: ^id, sha256s: sha256s}} <-
             fetch(context),
           ^tenant_id <- Ash.Changeset.get_attribute(changeset, :tenant_id),
           content when is_binary(content) <- Ash.Changeset.get_attribute(changeset, :content),
           true <- :crypto.hash(:sha256, content) in sha256s do
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
    if hashes?(sha256s) do
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

  @doc """
  The well-formed scope in `context`, if any: binary tenant and delegation,
  an approved purpose and a non-empty list of 32-byte hashes only. A forged
  or malformed scope (any other shape or member) is `:error`; it never
  raises.
  """
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(context) when is_map(context) do
    case Map.get(context, @marker) do
      %{tenant_id: tenant_id, delegation_id: delegation_id, purpose: purpose, sha256s: sha256s} =
          scope
      when is_binary(tenant_id) and is_binary(delegation_id) and purpose in @purposes ->
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
