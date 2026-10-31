defmodule SdrAgent.Prototype.Relocation do
  @moduledoc """
  One single-writer move of the prototype database (ADR-0024 decision 1;
  plan R2 "Entities"): an APPEND-ONLY row naming the move's source and
  destination. The binding row is never edited; new spending authority
  comes only from this chain (`SdrAgent.Prototype.CurrentAuthority`).

  Attributes: `id`; `binding_id` (the singleton
  `SdrAgent.Operations.PrototypeDatabaseBinding`, N:1, RESTRICT);
  `relocation_seq` (positive); `from_identity` and `to_identity`, each an
  identity map `%{database:, database_oid:, system_identifier:}` read back
  with those atom keys. Relationship: `events`
  (`SdrAgent.Prototype.RelocationEvent`, by `position`).

  Keys: UNIQUE `(binding_id, relocation_seq)`.

  `:create` (owner-run only) accepts the four attributes. Authorization:
  only a kernel request carrying the `SdrAgent.Prototype.Checks.KernelMarker`
  `:relocation` marker passes; every other caller is `Ash.Error.Forbidden`.
  Inside the action's transaction it takes the tenant's chain-head lock
  (`SdrAgent.Audit.Kernel.lock_head/1`, serializing chain writes), then
  requires the binding of the actor's tenant, `relocation_seq` equal to
  the chain's next one (`CurrentAuthority.next_seq/1`: 1 first, then the
  highest plus one), `from_identity` equal to the current authority and
  `to_identity` different from it; any other input is `Ash.Error.Invalid`
  and writes nothing. In the same transaction it appends one AuditEvent
  `prototype.relocation.created` (`SdrAgent.Audit.Changes.AppendEvent`); a
  failed append rolls the row back. Prototype runtime refuses the action
  for every actor (`SdrAgent.Prototype.Checks.PrototypeRuntime`,
  `Ash.Error.Forbidden`). UPDATE, DELETE and TRUNCATE are refused by a
  trigger. Reads: the audit kernel.

  `chain/2` reads a binding's chain in the `CurrentAuthority` shape: one
  read of the relocations and, for a nonempty chain, one of their events
  by `position` (each plain event map carries it);
  in a test-seam build each read carries its own live-read fault label
  (`{:relocation_chain, :relocations}`, `{:relocation_chain, :events}`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias SdrAgent.Audit.Checks
  alias SdrAgent.Audit.Kernel, as: AuditKernel

  @authority_compiled Application.compile_env(:sdr_agent, :prototype_authority_compiled, false)
  @test_seams Application.compile_env(:sdr_agent, :prototype_test_seams, false)
  @chain_seams @authority_compiled == true and @test_seams == true

  @identity_constraints [
    fields: [
      database: [type: :string, allow_nil?: false],
      database_oid: [type: :integer, allow_nil?: false, constraints: [min: 1]],
      system_identifier: [type: :integer, allow_nil?: false]
    ]
  ]

  postgres do
    table "prototype_relocations"
    repo SdrAgent.Repo

    references do
      reference :binding, on_delete: :restrict
    end

    check_constraints do
      check_constraint :relocation_seq, "prototype_relocations_seq_positive",
        check: "relocation_seq > 0"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("prototype_relocations") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    # Owner-run only (the `:relocation` kernel marker); the order and
    # identity rules run after authorization, under the head lock.
    create :create do
      description "ADR-0024: one owner-run relocation of the prototype binding."
      accept [:binding_id, :relocation_seq, :from_identity, :to_identity]
      change SdrAgent.Prototype.Changes.RelocationChain

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "prototype.relocation.created", category: :domain_change}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Checks.KernelContext
    end

    policy action(:create) do
      forbid_if SdrAgent.Prototype.Checks.PrototypeRuntime
      authorize_if {SdrAgent.Prototype.Checks.KernelMarker, marker: :relocation}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :relocation_seq, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :from_identity, :map,
      allow_nil?: false,
      public?: true,
      constraints: @identity_constraints

    attribute :to_identity, :map,
      allow_nil?: false,
      public?: true,
      constraints: @identity_constraints
  end

  relationships do
    belongs_to :binding, SdrAgent.Operations.PrototypeDatabaseBinding do
      allow_nil? false
      public? true
    end

    has_many :events, SdrAgent.Prototype.RelocationEvent do
      destination_attribute :relocation_id
      sort position: :asc
      public? true
    end
  end

  identities do
    identity :unique_binding_seq, [:binding_id, :relocation_seq]
    identity :unique_id_binding, [:id, :binding_id]
  end

  @doc """
  The relocation chain of `binding_id` as plain kernel reads, in the
  `SdrAgent.Prototype.CurrentAuthority` shape; a read error is returned.
  """
  @spec chain(Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, SdrAgent.Prototype.CurrentAuthority.chain()} | {:error, term()}
  def chain(binding_id, tenant_id) do
    opts = AuditKernel.opts(tenant_id)

    with {:ok, relocations} <- relocations(binding_id, opts),
         {:ok, events} <- events(Enum.map(relocations, & &1.id), opts) do
      by_relocation = Enum.group_by(events, & &1.relocation_id)
      {:ok, Enum.map(relocations, &plain(&1, Map.get(by_relocation, &1.id, [])))}
    end
  end

  defp relocations(binding_id, opts) do
    chain_read(:relocations, fn ->
      __MODULE__
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(binding_id == ^binding_id)
      |> Ash.read()
    end)
  end

  defp events([], _opts), do: {:ok, []}

  defp events(ids, opts) do
    chain_read(:events, fn ->
      SdrAgent.Prototype.RelocationEvent
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(relocation_id in ^ids)
      |> Ash.Query.sort(position: :asc)
      |> Ash.read()
    end)
  end

  # The two chain reads. In a test-seam build of the prototype authority
  # each consults `SdrAgent.Prototype.Authority.TestSeam.claim_live_fault/1`
  # at its own label (`{:relocation_chain, :relocations}`,
  # `{:relocation_chain, :events}`) immediately before its real read, with
  # S1's live-read semantics: `:returned_error` replaces the result,
  # `:raise` raises in its place, `:abort` runs one tagged real
  # `SELECT 1 / 0` and then the real read. Any other build is the plain read.
  if @chain_seams do
    defp chain_read(read, real) do
      stage = {:relocation_chain, read}

      case SdrAgent.Prototype.Authority.TestSeam.claim_live_fault(stage) do
        nil ->
          real.()

        :returned_error ->
          {:error, Ash.Error.Unknown.UnknownError.exception(error: "test seam: live-stage fault")}

        :raise ->
          raise ArgumentError, "test seam: live-stage fault"

        :abort ->
          _ = SdrAgent.Repo.query("SELECT 1 / 0", [], telemetry_options: [d237_live_fault: stage])
          real.()
      end
    end
  else
    defp chain_read(_read, real), do: real.()
  end

  defp plain(relocation, events) do
    %{
      relocation_seq: relocation.relocation_seq,
      from_identity: relocation.from_identity,
      to_identity: relocation.to_identity,
      events: Enum.map(events, &%{kind: &1.kind, identity: &1.identity, position: &1.position})
    }
  end
end
