# Compiled only with the D-237 prototype authority (config/dev.exs and
# config/test.exs); the production build does not contain this module.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Provisioning do
    @moduledoc """
    The shared identity, locks and replay rule of the one D-237 prototype
    grant (interfaces r6 IF-2 "Provisioning"; closure note r2, Codex
    3e05314f). Used by both `SdrAgent.Agents.provision_prototype_grant/2`
    (the wrapper's replay) and `ModelCallGrant :provision_prototype` (the
    raw action, which never renews), and by the operator's revoke check.

    - `lock_binding/1` locks the singleton binding row (`FOR UPDATE`, a row
      lock; the create-only trigger is not involved) and checks it is still
      exactly the boot snapshot. It is always the first lock.
    - `lookup/1` finds "this binding's grant" from the ORIGINAL
      `model.grant.provisioned` event, never from the mutable name:
      `:none` (no such event in the tenant), `{:one, grant_id, event}` (one
      trusted event, `classify/2`) or `:untrusted` (several events, or one
      whose type, action, subject, argument shape and exact keys, funding
      id, funding entry digest, decision refs, binding, actor, delegation,
      worksheet digest, grant tenant or creator is not exactly this
      binding's). The original
      delegation may be any valid delegation of this binding, not the
      current caller's.
    - `lock_grant/2` then locks that grant row and its allocations (the
      GrantBundle order), returning their CURRENT values;
      `lock_name_conflicts/2` locks, in id order, every other grant of the
      tenant currently named `d237-funding/1` (the ordinary name conflict,
      detected separately).
    - `unchanged?/2` is the replay rule: the current grant is active and
      its terms and allocation definition equal the compiled funding entry
      exactly (consumption is not a term).

    The chain head is locked last, by the append itself.
    """

    import Kernel, except: [binding: 0]

    require Ash.Query

    alias SdrAgent.Agents.ModelCallAllocation
    alias SdrAgent.Agents.ModelCallGrant
    alias SdrAgent.Audit.AuditEvent
    alias SdrAgent.Audit.Kernel, as: AuditKernel
    alias SdrAgent.Operations.PrototypeDatabaseBinding
    alias SdrAgent.Operations.PrototypeDelegation
    alias SdrAgent.Prototype.Authority
    alias SdrAgent.Prototype.Binding

    @funding_id "d237-funding/1"
    @purpose "D-237 prototype funding d237-funding/1 (D-238, D-239, D-243, D-269 additional100)"
    @event_type "model.grant.provisioned"
    @argument_keys Enum.sort(
                     ~w(funding_id funding_entry_sha256 decision_refs budget_worksheet_sha256 delegation_id binding_id)
                   )
    @action "provision_prototype"

    @doc "The grant's fixed name: the funding id."
    @spec name() :: String.t()
    def name, do: @funding_id

    @doc """
    The grant's exact terms from the compiled funding entry: `name`,
    `purpose`, `profile_ids`, `total_attempts`, `per_utc_day_attempts`
    (none), `starts_at`, `expires_at`.
    """
    @spec terms() :: map()
    def terms do
      entry = Authority.funding_entry()

      %{
        name: @funding_id,
        purpose: @purpose,
        profile_ids: entry.profile_ids,
        total_attempts: entry.total_attempts,
        per_utc_day_attempts: nil,
        starts_at: entry.starts_at,
        expires_at: entry.expires_at
      }
    end

    @doc "The entry's allocation set, as `GrantBundle` creates it."
    @spec allocations() :: [map()]
    def allocations do
      blank = Map.new(allocation_fields(), &{&1, nil})

      Enum.map(
        Authority.funding_entry().allocations,
        &Map.merge(blank, Map.take(&1, allocation_fields()))
      )
    end

    @doc "Locks the singleton binding row; `:ok` only if it is still exactly `snapshot`."
    @spec lock_binding(Binding.t()) :: :ok | {:error, :binding_mismatch}
    def lock_binding(%Binding{} = snapshot) do
      PrototypeDatabaseBinding
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(snapshot.tenant_id))
      |> Ash.Query.filter(id == ^snapshot.id)
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read_one()
      |> case do
        {:ok, %PrototypeDatabaseBinding{} = row} ->
          if Authority.snapshot(row) == {:ok, snapshot},
            do: :ok,
            else: {:error, :binding_mismatch}

        _missing_or_error ->
          {:error, :binding_mismatch}
      end
    end

    @doc "This binding's grant by its original provisioned event (see the moduledoc)."
    @spec lookup(Binding.t()) :: :none | {:one, Ecto.UUID.t(), struct()} | :untrusted
    def lookup(%Binding{} = snapshot) do
      AuditEvent
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(snapshot.tenant_id))
      |> Ash.Query.filter(tenant_id == ^snapshot.tenant_id and event_type == ^@event_type)
      |> Ash.Query.limit(2)
      |> Ash.read()
      |> case do
        {:ok, []} -> :none
        {:ok, [event]} -> classify(snapshot, event)
        _ambiguous_or_error -> :untrusted
      end
    end

    @doc """
    The trust decision for one provisioned event: `{:one, grant_id, event}`
    only when it is a `model.grant.provisioned` event of this binding's
    tenant (checked first, before any DB access) whose arguments are a map
    with EXACTLY the recorded keys
    (`funding_id`, `funding_entry_sha256`, `decision_refs`,
    `budget_worksheet_sha256`, `delegation_id`, `binding_id`), each strictly
    typed and equal to this binding's commitments (the compiled funding
    entry's digest and decision refs; Codex 4281bb5c R2), and the event's
    type, action, subject, actor, delegation and grant check out; anything
    else, including a malformed payload or arguments of any other shape, is
    `:untrusted` (R3). It never raises on the event's shape.
    """
    @spec classify(Binding.t(), struct()) :: {:one, Ecto.UUID.t(), struct()} | :untrusted
    # Header guards first (Codex 4ebbce03): the event type and this
    # binding's tenant are part of the head, so a copy of a genuine event
    # with another type or tenant is untrusted before any DB access.
    def classify(
          %Binding{tenant_id: tenant_id} = snapshot,
          %AuditEvent{
            event_type: @event_type,
            tenant_id: tenant_id,
            payload: %{"arguments" => %{} = arguments}
          } = event
        )
        when is_binary(tenant_id) do
      with true <- Enum.sort(Map.keys(arguments)) == @argument_keys,
           true <- original?(snapshot, event, arguments),
           {:ok, grant_id} <- Ecto.UUID.cast(event.subject_id),
           true <- delegation_of_binding?(snapshot, event.actor_id),
           true <- created_by_anchor?(snapshot, grant_id) do
        {:one, grant_id, event}
      else
        _untrusted -> :untrusted
      end
    end

    def classify(_snapshot, _event), do: :untrusted

    defp original?(snapshot, event, arguments),
      do: original_event?(event) and commitments?(snapshot, event, arguments)

    # The event's own header: subject, action and the operator actor.
    defp original_event?(event) do
      event.subject_resource == inspect(ModelCallGrant) and event.action == @action and
        event.actor_type == :prototype_operator and is_binary(event.actor_id)
    end

    # The recorded arguments: exactly this binding's commitments.
    defp commitments?(snapshot, event, arguments) do
      arguments["funding_id"] == @funding_id and
        arguments["funding_entry_sha256"] == Authority.funding_entry_sha256() and
        arguments["decision_refs"] == decision_refs() and
        arguments["binding_id"] == snapshot.id and
        arguments["delegation_id"] == event.actor_id and
        hex64?(arguments["budget_worksheet_sha256"])
    end

    @doc "The compiled funding entry's decision refs, as recorded on the event."
    @spec decision_refs() :: [String.t()]
    def decision_refs, do: Authority.funding_entry().decision_refs

    defp hex64?(value) when is_binary(value), do: value =~ ~r/\A[0-9a-f]{64}\z/
    defp hex64?(_value), do: false

    # Any valid delegation of this binding (tenant, binding, anchor), not
    # necessarily the current caller's: historical provenance, not fresh
    # authorization.
    defp delegation_of_binding?(snapshot, delegation_id) do
      with {:ok, id} <- Ecto.UUID.cast(delegation_id),
           {:ok, %PrototypeDelegation{} = delegation} <-
             PrototypeDelegation
             |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(snapshot.tenant_id))
             |> Ash.Query.filter(id == ^id)
             |> Ash.read_one(),
           {:ok, _actor} <- Authority.resolve_delegation(snapshot, delegation) do
        true
      else
        _other -> false
      end
    end

    defp created_by_anchor?(snapshot, grant_id) do
      case read_grant(snapshot.tenant_id, grant_id) do
        {:ok, %ModelCallGrant{created_by_id: anchor}} -> anchor == snapshot.operator_user_id
        _missing_or_error -> false
      end
    end

    defp read_grant(tenant_id, grant_id) do
      ModelCallGrant
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(tenant_id))
      |> Ash.Query.filter(id == ^grant_id and tenant_id == ^tenant_id)
      |> Ash.read_one()
    end

    @doc """
    Locks the grant row, then its allocations (id order), and returns their
    current values: `{:ok, grant, allocations}`.
    """
    @spec lock_grant(Binding.t(), Ecto.UUID.t()) ::
            {:ok, struct(), [struct()]} | {:error, :grant_exists}
    def lock_grant(%Binding{} = snapshot, grant_id) do
      opts = AuditKernel.opts(snapshot.tenant_id)

      with {:ok, %ModelCallGrant{} = grant} <-
             ModelCallGrant
             |> Ash.Query.for_read(:read, %{}, opts)
             |> Ash.Query.filter(id == ^grant_id and tenant_id == ^snapshot.tenant_id)
             |> Ash.Query.lock("FOR UPDATE")
             |> Ash.read_one(),
           {:ok, allocations} <-
             ModelCallAllocation
             |> Ash.Query.for_read(:read, %{}, opts)
             |> Ash.Query.filter(grant_id == ^grant_id)
             |> Ash.Query.sort(id: :asc)
             |> Ash.Query.lock("FOR UPDATE")
             |> Ash.read() do
        {:ok, grant, allocations}
      else
        _missing_or_error -> {:error, :grant_exists}
      end
    end

    @doc """
    Locks, in id order, every grant of the tenant currently named
    `d237-funding/1` other than `except_id`; `{:ok, ids}`.
    """
    @spec lock_name_conflicts(Binding.t(), Ecto.UUID.t() | nil) ::
            {:ok, [Ecto.UUID.t()]} | {:error, :grant_exists}
    def lock_name_conflicts(%Binding{} = snapshot, except_id) do
      ModelCallGrant
      |> Ash.Query.for_read(:read, %{}, AuditKernel.opts(snapshot.tenant_id))
      |> Ash.Query.filter(tenant_id == ^snapshot.tenant_id and name == ^@funding_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read()
      |> case do
        {:ok, grants} -> {:ok, for(%{id: id} <- grants, id != except_id, do: id)}
        {:error, _error} -> {:error, :grant_exists}
      end
    end

    @doc """
    The replay rule: the CURRENT (locked) grant is active and its terms and
    allocation definition equal the funding entry exactly.
    """
    @spec unchanged?(struct(), [struct()]) :: boolean()
    def unchanged?(%ModelCallGrant{status: :active} = grant, allocations) do
      Map.take(grant, Map.keys(terms())) == terms() and
        Enum.map(allocations, &allocation_definition/1) ==
          Enum.map(allocations(), &Map.merge(&1, %{released_at: nil}))
    end

    def unchanged?(_grant, _allocations), do: false

    defp allocation_definition(allocation),
      do: Map.take(allocation, [:released_at | allocation_fields()])

    defp allocation_fields,
      do: [:key, :applies_to, :profile_id, :attempts, :available_from, :available_until]

    @doc "The original event's recorded worksheet digest."
    @spec digest(struct()) :: String.t() | nil
    def digest(%{payload: %{"arguments" => %{"budget_worksheet_sha256" => digest}}}), do: digest
    def digest(_event), do: nil
  end
end
