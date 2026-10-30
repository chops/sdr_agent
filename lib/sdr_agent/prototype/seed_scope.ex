# Prototype-only trusted process scope; never compiled in production.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.SeedScope do
    @moduledoc """
    The registered, transaction-bound authority for one D-268 seed run.

    `run/3` resolves the live actor inside the caller's transaction, opens
    one process-registered scope and removes it on every callback exit.
    `bind/3` rechecks that actor before any privileged member read. It
    binds the five stored members in order, requiring one authoritative
    creation event with this run's fresh correlation UUID, this actor and
    the provenance digest. The profile's revision-1 note supplies its
    digest; the step and campaign must reference the already bound rows.

    Opening and per-member transaction-local markers bind facts to the
    current transaction/savepoint lifetime. No early chain-head lock or
    row-version metadata is used. This helper does not roll earlier
    writes back on refusal: Seed owns the whole enclosing transaction.
    Registry equality is a trusted in-process convention, not protection
    against arbitrary privileged server code. No ref, marker or captured
    state is logged. No public domain API accepts a caller-built scope.
    """

    require Ash.Query

    alias SdrAgent.Actor
    alias SdrAgent.Agents.SettingsRevision
    alias SdrAgent.Audit.AuditEvent
    alias SdrAgent.Audit.Kernel
    alias SdrAgent.Prototype.Authority
    alias SdrAgent.Repo
    alias SdrAgent.Sales.Campaign
    alias SdrAgent.Sales.IcpDefinition
    alias SdrAgent.Sales.Sequence
    alias SdrAgent.Sales.SequenceStep

    @enforce_keys [:ref, :actor, :tenant_id, :delegation_id, :digest, :run_id, :xact_id, :marker]
    defstruct [
      :ref,
      :actor,
      :tenant_id,
      :delegation_id,
      :digest,
      :run_id,
      :xact_id,
      :marker,
      members: %{}
    ]

    @type t :: %__MODULE__{}
    @registry {__MODULE__, :registry}
    @order [:offering_profile, :icp_definition, :sequence, :sequence_step, :campaign]
    @kinds %{
      offering_profile: {SettingsRevision, "settings.revision.created"},
      icp_definition: {IcpDefinition, "sales.icp_definition.created"},
      sequence: {Sequence, "sales.sequence.created"},
      sequence_step: {SequenceStep, "sales.sequence_step.created"},
      campaign: {Campaign, "sales.campaign.created"}
    }
    @activated %{IcpDefinition => :icp_definition, Sequence => :sequence, Campaign => :campaign}

    @doc "Runs the callback in one registered scope; the caller owns its transaction."
    @spec run(Actor.t(), map(), (reference() -> term())) :: term()
    def run(actor, %{digest: digest}, fun) when is_function(fun, 1) do
      with :ok <- runnable(actor, digest) do
        ref = make_ref()
        marker = new_marker()
        Repo.query!("SELECT set_config($1, '1', true)", [marker])
        %{rows: [[xact_id]]} = Repo.query!("SELECT pg_current_xact_id()::text", [])

        register(%__MODULE__{
          ref: ref,
          actor: actor,
          tenant_id: actor.tenant_id,
          delegation_id: actor.id,
          digest: digest,
          run_id: Ecto.UUID.generate(),
          xact_id: xact_id,
          marker: marker
        })

        try do
          fun.(ref)
        after
          unregister(ref)
        end
      end
    end

    def run(_actor, _opts, _fun), do: {:error, :scope_refused}

    @doc "Binds one stored member in order; refusal never rolls back the caller."
    @spec bind(term(), atom(), term()) :: t() | {:error, :scope_refused}
    def bind(ref, kind, %{id: id}) when is_reference(ref) and is_binary(id) do
      with %__MODULE__{} = scope <- fetch(ref),
           true <- Authority.operator?(scope.actor),
           true <- live?(scope),
           true <- next_kind(scope) == kind,
           {:ok, {resource, event_type}} <- Map.fetch(@kinds, kind),
           {:ok, %{tenant_id: tenant_id} = stored} <- read_row(resource, id, scope.tenant_id),
           true <- tenant_id == scope.tenant_id,
           true <- related?(scope, kind, stored),
           true <- created_here?(scope, resource, event_type, id, kind),
           true <- live?(scope) do
        marker = new_marker()
        Repo.query!("SELECT set_config($1, '1', true)", [marker])
        bound = %{scope | members: Map.put(scope.members, kind, %{id: id, marker: marker})}
        register(bound)
        bound
      else
        _refused -> {:error, :scope_refused}
      end
    end

    def bind(_ref, _kind, _record), do: {:error, :scope_refused}

    @doc "The calling process's registered scope, or nil; no liveness is inferred."
    @spec fetch(term()) :: t() | nil
    def fetch(ref) when is_reference(ref), do: Map.get(registry(), ref)
    def fetch(_ref), do: nil

    @doc "The registered run correlation UUID for seed action contexts, or nil."
    @spec fetch_run_id(term()) :: Ecto.UUID.t() | nil
    def fetch_run_id(ref) do
      case fetch(ref) do
        %__MODULE__{run_id: run_id} -> run_id
        nil -> nil
      end
    end

    @doc """
    Validates only a complete, live registered scope's exact member and
    kind for an activation. The actor resolves freshly before the one
    marker-state query. This does not itself grant a resource policy.
    """
    @spec valid?(term(), term(), term()) :: boolean()
    def valid?(
          %__MODULE__{ref: ref} = scope,
          %Ash.Changeset{action: %{name: :activate}, data: %{id: id, tenant_id: tenant_id}} =
            changeset,
          actor
        )
        when is_reference(ref) do
      with %__MODULE__{} = registered <- fetch(ref),
           true <- registered == scope,
           true <- actor == registered.actor and Authority.operator?(actor),
           true <- next_kind(registered) == nil,
           {:ok, kind} <- Map.fetch(@activated, changeset.resource),
           %{id: ^id} <- Map.get(registered.members, kind),
           true <- tenant_id == registered.tenant_id do
        live?(registered)
      else
        _refused -> false
      end
    end

    def valid?(_scope, _changeset, _actor), do: false

    defp runnable(actor, digest) do
      cond do
        not Repo.in_transaction?() ->
          {:error, :not_in_transaction}

        registry() != %{} ->
          {:error, :already_registered}

        not (is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)) ->
          {:error, :invalid_digest}

        not Authority.operator?(actor) ->
          {:error, :forbidden}

        true ->
          :ok
      end
    end

    defp next_kind(scope), do: Enum.find(@order, &(not Map.has_key?(scope.members, &1)))
    defp member_id(scope, kind), do: Map.fetch!(scope.members, kind).id

    defp related?(scope, :offering_profile, revision),
      do:
        revision.kind == :offering_profile and revision.number == 1 and
          revision.note == "d237 seed provenance sha256:" <> scope.digest

    defp related?(_scope, kind, row) when kind in [:icp_definition, :sequence],
      do: row.status == :draft

    defp related?(scope, :sequence_step, row), do: row.sequence_id == member_id(scope, :sequence)

    defp related?(scope, :campaign, row),
      do:
        row.status == :draft and row.icp_definition_id == member_id(scope, :icp_definition) and
          row.sequence_id == member_id(scope, :sequence)

    defp read_row(resource, id, tenant_id) do
      resource
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
      |> Ash.read_one()
    end

    defp created_here?(scope, resource, event_type, id, kind) do
      expected = %{
        subject_resource: inspect(resource),
        action: "seed_prototype",
        actor_type: :prototype_operator,
        actor_id: scope.delegation_id,
        correlation_id: scope.run_id
      }

      AuditEvent
      |> Ash.Query.for_read(:read, %{}, Kernel.opts(scope.tenant_id))
      |> Ash.Query.filter(
        tenant_id == ^scope.tenant_id and event_type == ^event_type and subject_id == ^id
      )
      |> Ash.Query.limit(2)
      |> Ash.read()
      |> case do
        {:ok, [event]} ->
          Map.take(event, Map.keys(expected)) == expected and digest?(scope, event, kind)

        _none_many_or_error ->
          false
      end
    end

    defp digest?(_scope, _event, :offering_profile), do: true

    defp digest?(scope, event, _kind),
      do: get_in(event.payload, ["arguments", "seed_provenance_sha256"]) == scope.digest

    defp live?(scope) do
      if Repo.in_transaction?() do
        markers = [scope.marker | Enum.map(Map.values(scope.members), & &1.marker)]
        settings = Enum.map_join(1..length(markers), ", ", &"current_setting($#{&1}, true)")

        case Repo.query("SELECT pg_current_xact_id()::text, " <> settings, markers) do
          {:ok, %{rows: [[id | values]]}} ->
            id == scope.xact_id and Enum.all?(values, &(&1 == "1"))

          _error ->
            false
        end
      else
        false
      end
    end

    defp new_marker,
      do: "sdr_seed_scope.c" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    defp registry, do: Process.get(@registry, %{})
    defp register(scope), do: Process.put(@registry, Map.put(registry(), scope.ref, scope))

    defp unregister(ref) do
      case Map.delete(registry(), ref) do
        empty when empty == %{} -> Process.delete(@registry)
        rest -> Process.put(@registry, rest)
      end
    end
  end
end
