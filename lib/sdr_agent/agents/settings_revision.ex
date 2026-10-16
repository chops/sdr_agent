defmodule SdrAgent.Agents.SettingsRevision do
  @moduledoc """
  One immutable revision of one tenant-wide run setting (C4,
  `docs/product/c4/readiness.md` sections 3.1, 3.2, 3.7, 4 and 12).
  APPEND-ONLY: a database trigger rejects every UPDATE, DELETE and TRUNCATE.

  Attributes: `kind` (`:offering_profile | :booking_link | :writing_guide |
  :research_brief | :operational_limits`), `number` (≥ 1),
  `supersedes_id` (its predecessor of the same tenant and kind; nil for
  revision 1), `raised_fields` (the closed set of limit fields raised above
  the value in effect and confirmed by the admin, sorted; empty unless
  `kind = :operational_limits`), exactly one embedded content attribute
  named by `kind` (`SdrAgent.Agents.RunSettings.OfferingProfile`,
  `BookingLink`, `WritingGuide`, `ResearchBrief`, `OperationalLimits`),
  `content_sha256` (section 3.7, `content_sha256/2`), an optional `note`
  (≤ 200), `created_by_id` and the trace ids. Content attributes and the
  note are `sensitive?`: audit after-images omit them (named under
  `redacted`), Ash errors redact them.

  The chain: each kind has one root; each revision is superseded at most
  once; the current revision of a kind is the one with the highest number.
  The database enforces it with the check and key constraints of section 12
  and a composite self foreign key that keeps a chain inside one tenant
  and kind.

  Action `:create_revision` (`SdrAgent.Agents.create_settings_revision/2`):
  inputs `kind`, `content`, `expected_number` (0 = no revision yet),
  `note`, `confirm_raised`. It locks the current revision `FOR NO KEY
  UPDATE`, refuses a stale `expected_number`, numbers the new revision under
  that lock, refuses a raise whose confirmation is not exactly the raised
  set, hashes the cast content, and appends `settings.revision.created`
  (metadata and hashes only) — `SdrAgent.Agents.Changes.SettingsRevisionChain`.
  Writes: an active human admin only, re-read at the time of the action
  (`SdrAgent.Agents.Checks.CurrentAdmin`); every system actor is refused.
  Reads of rows and of the content and note: admin, reviewer (read-only,
  OQ-6), auditor (audited by the views), `agent_runtime`, `auditor_cli`,
  kernel, each in its own tenant.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.CurrentAdmin
  alias SdrAgent.Agents.RunSettings
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @kinds [:offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits]
  @limit_fields Safeguards.limit_fields()
  @content_fields @kinds ++ [:note]

  postgres do
    table "settings_revisions"
    repo SdrAgent.Repo

    identity_wheres_to_sql one_root_per_kind: "supersedes_id IS NULL",
                           supersedes_once: "supersedes_id IS NOT NULL"

    references do
      reference :tenant, on_delete: :restrict
      reference :created_by, on_delete: :restrict
      # The composite (supersedes_id, tenant_id, kind) foreign key is a
      # custom statement below.
      reference :supersedes, ignore?: true
    end

    check_constraints do
      check_constraint :trace_id, "settings_revisions_trace_ids",
        check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :kind, "settings_revisions_kind",
        check: SdrAgent.Audit.SQL.one_of("kind", @kinds)

      check_constraint :kind, "settings_revisions_content_matches_kind",
        check:
          Enum.map_join(@kinds, " AND ", fn kind ->
            "((kind = '#{kind}') = (#{kind} IS NOT NULL))"
          end)

      check_constraint :number, "settings_revisions_root_number",
        check: "number >= 1 AND ((number = 1) = (supersedes_id IS NULL))"

      check_constraint :raised_fields, "settings_revisions_raised_fields_limits_only",
        check: "kind = 'operational_limits' OR cardinality(raised_fields) = 0"

      check_constraint :raised_fields, "settings_revisions_raised_fields_names",
        check: "raised_fields <@ ARRAY[#{Enum.map_join(@limit_fields, ", ", &"'#{&1}'")}]::text[]"

      check_constraint :content_sha256, "settings_revisions_content_sha256_hex",
        check: "content_sha256 ~ '^[0-9a-f]{64}$'"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("settings_revisions") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      # Target of the self foreign key: a revision supersedes only its own
      # tenant's revision of the same kind.
      statement :settings_revisions_id_tenant_kind_key do
        up "ALTER TABLE settings_revisions ADD CONSTRAINT settings_revisions_id_tenant_kind_key " <>
             "UNIQUE (id, tenant_id, kind)"

        down "ALTER TABLE settings_revisions DROP CONSTRAINT settings_revisions_id_tenant_kind_key"
      end

      # Target of every run settings snapshot slot foreign key: it pins the
      # tenant, the kind and the content hash of the referenced revision.
      statement :settings_revisions_id_tenant_kind_sha_key do
        up "ALTER TABLE settings_revisions ADD CONSTRAINT " <>
             "settings_revisions_id_tenant_kind_sha_key " <>
             "UNIQUE (id, tenant_id, kind, content_sha256)"

        down "ALTER TABLE settings_revisions DROP CONSTRAINT " <>
               "settings_revisions_id_tenant_kind_sha_key"
      end

      statement :settings_revisions_supersedes_fkey do
        up "ALTER TABLE settings_revisions ADD CONSTRAINT settings_revisions_supersedes_fkey " <>
             "FOREIGN KEY (supersedes_id, tenant_id, kind) " <>
             "REFERENCES settings_revisions (id, tenant_id, kind) ON DELETE RESTRICT"

        down "ALTER TABLE settings_revisions DROP CONSTRAINT settings_revisions_supersedes_fkey"
      end
    end
  end

  field_policies do
    # OQ-6: reviewers read settings text, read-only.
    field_policy @content_fields do
      authorize_if Checks.KernelContext
      authorize_if Checks.IntegrityRead
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli, :kernel]}
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :create_revision do
      description """
      ADM: append the next revision of one setting kind, against the
      revision number the admin saw (`expected_number`, 0 for none).
      """

      accept [:kind]
      # `content` and `note` are taken as raw terms and checked by
      # SettingsRevisionChain, so a malformed value never reaches an Ash
      # cast error (whose message and span status would print it).
      argument :content, :term, allow_nil?: false, sensitive?: true
      argument :note, :term, sensitive?: true
      argument :expected_number, :integer, allow_nil?: false, constraints: [min: 0]

      argument :confirm_raised, {:array, :atom},
        allow_nil?: false,
        default: [],
        constraints: [items: [one_of: @limit_fields]]

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change relate_actor(:created_by, allow_nil?: true)
      change SdrAgent.Agents.Changes.SettingsRevisionChain

      change {AppendEvent,
              event_type: "settings.revision.created",
              category: :domain_change,
              arguments: [:expected_number]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if CurrentAdmin
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if Checks.IntegrityRead
      forbid_unless expr(tenant_id == ^actor(:tenant_id))
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}
      authorize_if {Checks.ActorType, types: [:agent_runtime, :auditor_cli, :kernel]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :number, :integer do
      allow_nil? false
      writable? false
      public? true
      constraints min: 1
    end

    attribute :raised_fields, {:array, :atom} do
      allow_nil? false
      writable? false
      default []
      public? true
      constraints items: [one_of: @limit_fields]
    end

    attribute :offering_profile, RunSettings.OfferingProfile do
      writable? false
      public? true
      sensitive? true
    end

    attribute :booking_link, RunSettings.BookingLink do
      writable? false
      public? true
      sensitive? true
    end

    attribute :writing_guide, RunSettings.WritingGuide do
      writable? false
      public? true
      sensitive? true
    end

    attribute :research_brief, RunSettings.ResearchBrief do
      writable? false
      public? true
      sensitive? true
    end

    attribute :operational_limits, RunSettings.OperationalLimits do
      writable? false
      public? true
      sensitive? true
    end

    attribute :content_sha256, :string do
      allow_nil? false
      writable? false
      public? true
    end

    attribute :note, :string do
      public? true
      sensitive? true
      constraints trim?: false, allow_empty?: true
    end

    attribute :trace_id, :string, allow_nil?: false, public?: true
    attribute :span_id, :string, allow_nil?: false, public?: true

    attribute :inserted_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :created_by, SdrAgent.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :supersedes, __MODULE__ do
      attribute_writable? false
      public? true
    end
  end

  identities do
    identity :unique_number, [:tenant_id, :kind, :number]
    identity :one_root_per_kind, [:tenant_id, :kind], where: expr(is_nil(supersedes_id))
    identity :supersedes_once, [:supersedes_id], where: expr(not is_nil(supersedes_id))
  end

  @doc "The five settings kinds."
  def kinds, do: @kinds

  @doc """
  `content_sha256` (section 3.7) of the cast `content` of `kind`: the
  lowercase hex sha256 of the canonical encoding of `{"schema":
  "c4-settings-content/1", "kind": K, "content": C}`, where C is dumped with
  `Ash.Type.dump_to_embedded/3` through this resource's attribute of `kind`.
  """
  @spec content_sha256(atom(), term()) :: String.t()
  def content_sha256(kind, content) when kind in @kinds do
    attribute = Ash.Resource.Info.attribute(__MODULE__, kind)
    {:ok, dumped} = Ash.Type.dump_to_embedded(attribute.type, content, attribute.constraints)

    %{"schema" => "c4-settings-content/1", "kind" => Atom.to_string(kind), "content" => dumped}
    |> Canonical.sha256()
    |> Base.encode16(case: :lower)
  end

  @doc false
  def __sdr_audited__, do: true
end
