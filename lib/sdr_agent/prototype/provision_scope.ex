# Compiled only with the D-237 prototype authority (config/dev.exs and
# config/test.exs); the production build does not contain these modules.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ProvisionScope do
    @moduledoc """
    The registered, transaction-bound scope of the D-237 operator's one
    allocation write (Codex 4281bb5c R1; design note r2, Codex e006f70a and
    17a870c0), in the reviewed `SdrAgent.Agents.ReleaseDecision.Prelocked`
    pattern. `ModelCallGrant :provision_prototype` establishes it; it
    authorizes exactly one `ModelCallAllocation :create`, the entry's
    planned allocation of the bound grant, by the bound operator.

    - `establish/2` (only inside a transaction, only when no scope is
      registered in the calling process): a fresh transaction-local marker
      (`set_config(<unique name>, '1', true)`, reverted by PostgreSQL when a
      savepoint holding it rolls back), the top-level transaction id, and
      the full struct registered under the caller's `ref` in the calling
      process. Returns the struct, or `{:error, reason}`.
    - `bind_grant/2`: once, the inserted grant (this tenant, created by the
      anchor, the exact `Provisioning.terms/0`, revision 1) into the
      registered entry; returns the updated struct.
    - `fetch/1`: the registered entry for `ref` (the forwarding source).
    - `valid?/3`: PURE. True only for the struct equal field for field to
      the registered entry of its `ref` in this process, inside the same
      transaction with its marker set, unconsumed, with a bound grant, the
      exact bound operator as the actor and a `ModelCallAllocation :create`
      changeset whose grant, revision and allocation fields equal the
      planned write. A missing or malformed scope is false before any SQL.
    - `consume/3`: `valid?/3` again, then marks the entry consumed (once);
      `:ok` or `:refused`. A consumed scope stays spent.
    - `release/1`: unregisters the entry.

    This is a trusted in-process convention (like Prelocked and the kernel
    marker): it proves nothing against server code that registers its own
    scope. No ref or marker is logged.
    """

    alias SdrAgent.Actor
    alias SdrAgent.Agents.ModelCallAllocation
    alias SdrAgent.Agents.ModelCallGrant
    alias SdrAgent.Prototype.Provisioning
    alias SdrAgent.Repo

    @enforce_keys [:ref, :tenant_id, :binding_id, :delegation_id, :anchor_id, :planned]
    defstruct [
      :ref,
      :tenant_id,
      :binding_id,
      :delegation_id,
      :anchor_id,
      :planned,
      :grant_id,
      :grant_revision,
      :xact_id,
      :marker,
      consumed?: false
    ]

    @type t :: %__MODULE__{}

    @registry {__MODULE__, :registry}
    @allocation_fields [
      :key,
      :applies_to,
      :profile_id,
      :attempts,
      :available_from,
      :available_until
    ]

    @doc "Establishes and registers a scope for `ref`; see the moduledoc."
    @spec establish(reference(), map()) :: t() | {:error, atom()}
    def establish(ref, %{
          tenant_id: tenant_id,
          binding_id: binding_id,
          delegation_id: delegation_id,
          anchor_id: anchor_id,
          planned: [%{} | _] = planned
        })
        when is_reference(ref) do
      cond do
        not Repo.in_transaction?() ->
          {:error, :not_in_transaction}

        registry() != %{} ->
          {:error, :scope_exists}

        true ->
          marker =
            "sdr_provision_scope.s" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

          Repo.query!("SELECT set_config($1, '1', true)", [marker])
          {xact_id, "1"} = transaction_state(marker)

          scope = %__MODULE__{
            ref: ref,
            tenant_id: tenant_id,
            binding_id: binding_id,
            delegation_id: delegation_id,
            anchor_id: anchor_id,
            planned: planned,
            xact_id: xact_id,
            marker: marker
          }

          register(scope)
          scope
      end
    end

    def establish(_ref, _bindings), do: {:error, :scope_refused}

    @doc "Binds the inserted grant into the registered scope, once; returns the updated struct."
    @spec bind_grant(reference(), struct()) :: t() | {:error, :scope_refused}
    def bind_grant(ref, %ModelCallGrant{} = grant) when is_reference(ref) do
      with %__MODULE__{grant_id: nil} = scope <- Map.get(registry(), ref),
           true <- live?(scope),
           true <- grant.tenant_id == scope.tenant_id,
           true <- grant.created_by_id == scope.anchor_id,
           true <- grant.revision == 1,
           true <- Map.take(grant, Map.keys(Provisioning.terms())) == Provisioning.terms() do
        bound = %{scope | grant_id: grant.id, grant_revision: grant.revision}
        register(bound)
        bound
      else
        _refused -> {:error, :scope_refused}
      end
    end

    def bind_grant(_ref, _grant), do: {:error, :scope_refused}

    @doc "The registered scope for `ref` in the calling process, or nil."
    @spec fetch(term()) :: t() | nil
    def fetch(ref) when is_reference(ref), do: Map.get(registry(), ref)
    def fetch(_ref), do: nil

    @doc "PURE verification of `scope` for an allocation create; see the moduledoc."
    @spec valid?(term(), term(), term()) :: boolean()
    def valid?(%__MODULE__{ref: ref} = scope, %Ash.Changeset{} = changeset, actor)
        when is_reference(ref) do
      with %__MODULE__{consumed?: false} = registered <- Map.get(registry(), ref),
           true <- registered == scope,
           true <- is_binary(registered.grant_id),
           true <- actor == bound_actor(registered),
           true <- changeset.resource == ModelCallAllocation,
           true <- changeset.action.name == :create,
           true <- written(changeset) == planned_write(registered) do
        live?(registered)
      else
        _refused -> false
      end
    end

    def valid?(_scope, _changeset, _actor), do: false

    @doc "Re-verifies and consumes the scope once; `:ok` or `:refused`."
    @spec consume(term(), term(), term()) :: :ok | :refused
    def consume(%__MODULE__{} = scope, changeset, actor) do
      if valid?(scope, changeset, actor) do
        register(%{scope | consumed?: true})
        :ok
      else
        :refused
      end
    end

    def consume(_scope, _changeset, _actor), do: :refused

    @doc "Unregisters the scope for `ref` in the calling process."
    @spec release(term()) :: :ok
    def release(ref) do
      case Map.delete(registry(), ref) do
        empty when empty == %{} -> Process.delete(@registry)
        rest -> Process.put(@registry, rest)
      end

      :ok
    end

    defp bound_actor(scope),
      do: %Actor{type: :prototype_operator, id: scope.delegation_id, tenant_id: scope.tenant_id}

    defp written(changeset) do
      Map.new([:grant_id, :grant_revision | @allocation_fields], fn field ->
        {field, Ash.Changeset.get_attribute(changeset, field)}
      end)
    end

    defp planned_write(%__MODULE__{planned: [planned]} = scope) do
      planned
      |> Map.take(@allocation_fields)
      |> Map.merge(%{grant_id: scope.grant_id, grant_revision: scope.grant_revision})
    end

    defp planned_write(_scope), do: :none

    defp live?(scope) do
      Repo.in_transaction?() and transaction_state(scope.marker) == {scope.xact_id, "1"}
    end

    # The current top-level transaction id and the marker, in one query (no
    # lock clause). An aborted transaction or a missing marker never matches.
    defp transaction_state(marker) do
      %{rows: [[id, value]]} =
        Repo.query!("SELECT pg_current_xact_id()::text, current_setting($1, true)", [marker])

      {id, value}
    rescue
      _aborted -> {nil, nil}
    end

    defp registry, do: Process.get(@registry, %{})
    defp register(scope), do: Process.put(@registry, Map.put(registry(), scope.ref, scope))
  end

  if Application.compile_env(:sdr_agent, :prototype_test_seams, false) do
    defmodule SdrAgent.Prototype.ProvisionScope.TestSeam do
      @moduledoc """
      Test-build-only view of the calling process's ProvisionScope registry
      (the cleanup observations of Codex e006f70a D2). Not compiled in dev
      or prod builds.
      """

      @doc "The number of scopes registered in the calling process."
      @spec registered() :: non_neg_integer()
      def registered,
        do: map_size(Process.get({SdrAgent.Prototype.ProvisionScope, :registry}, %{}))
    end
  end
end
