defmodule SdrAgent.Prototype.RelocationEvent do
  @moduledoc """
  One step of a `SdrAgent.Prototype.Relocation` (ADR-0024 decision 1; plan
  R2 "Entities"): an APPEND-ONLY row.

  Attributes: `id`; `relocation_id` (RESTRICT); `kind`, exactly one of
  `kinds/0`; `identity`, the live database identity
  `%{database:, database_oid:, system_identifier:}` at the write, read by
  the action itself and never caller input; `position`, the serialized
  append ordinal (positive, never caller input: set under the head lock to
  the count of recorded events plus one, so it starts at 1 and is gap-free
  over committed appends); `recorded_at`, set after the lock and
  informational only (read order is `position`); and `recorded_by`, the
  writer (`"kernel:relocation"`).

  `:append` (owner-run only) accepts `relocation_id` and `kind`.
  Authorization: only a kernel request carrying the
  `SdrAgent.Prototype.Checks.KernelMarker` `:relocation` marker passes;
  every other caller is `Ash.Error.Forbidden`. Inside the action's
  transaction it takes the tenant's chain-head lock (so a `fenced` append
  serializes against every spending writer, plan R2 "Final fence
  serialization") and then requires, against the relocation's recorded
  events:

  - order: planned → writers_stopped → fenced → restored → activated; one
    event of each kind; `aborted` only after `planned` and while `fenced`
    is not recorded (corrective r3b M2: a source cannot prove locally that
    no restored copy exists; the fork-safe post-fence abort is S-B1b,
    INCOMPLETE);
    `destination_disabled` only after `restored`; nothing after `aborted`
    or `activated`, and no `activated` after `destination_disabled`;
  - identity: source kinds (planned, writers_stopped, fenced, aborted) at
    the relocation's `from_identity`, destination kinds (restored,
    activated, destination_disabled) at its `to_identity`.

  Any other append is `Ash.Error.Invalid` and writes nothing. Keys: UNIQUE
  `(relocation_id, position)`; a unique partial index allows at most one
  `activated` row per relocation. In the same transaction the action
  appends one AuditEvent `prototype.relocation.event_appended`
  (`SdrAgent.Audit.Changes.AppendEvent`); a failed append rolls the row
  back. Prototype runtime refuses the action for every actor
  (`SdrAgent.Prototype.Checks.PrototypeRuntime`, `Ash.Error.Forbidden`).
  UPDATE, DELETE and TRUNCATE are refused by a trigger. Reads: the audit kernel.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Checks

  @kinds [
    :planned,
    :writers_stopped,
    :fenced,
    :restored,
    :activated,
    :destination_disabled,
    :aborted
  ]

  # The identity map, as on `SdrAgent.Prototype.Relocation`.
  @identity_constraints [
    fields: [
      database: [type: :string, allow_nil?: false],
      database_oid: [type: :integer, allow_nil?: false, constraints: [min: 1]],
      system_identifier: [type: :integer, allow_nil?: false]
    ]
  ]

  postgres do
    table "prototype_relocation_events"
    repo SdrAgent.Repo

    references do
      reference :relocation, on_delete: :restrict
    end

    custom_indexes do
      index [:relocation_id],
        unique: true,
        name: "prototype_relocation_events_one_activated",
        where: "kind = 'activated'"
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.append_only("prototype_relocation_events") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    # Owner-run only (the `:relocation` kernel marker); the identity is read
    # here, and the order and identity rules run after authorization, under
    # the head lock.
    create :append do
      description "ADR-0024: one owner-run relocation step."
      accept [:relocation_id, :kind]
      change SdrAgent.Prototype.Changes.RelocationAppend

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "prototype.relocation.event_appended", category: :domain_change}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Checks.KernelContext
    end

    policy action(:append) do
      forbid_if SdrAgent.Prototype.Checks.PrototypeRuntime
      authorize_if {SdrAgent.Prototype.Checks.KernelMarker, marker: :relocation}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom, allow_nil?: false, public?: true, constraints: [one_of: @kinds]

    attribute :identity, :map,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: @identity_constraints

    attribute :position, :integer,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min: 1]

    attribute :recorded_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :recorded_by, :string, allow_nil?: false, writable?: false, public?: true
  end

  relationships do
    belongs_to :relocation, SdrAgent.Prototype.Relocation do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_relocation_position, [:relocation_id, :position]
  end

  @doc "The seven event kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds
end
