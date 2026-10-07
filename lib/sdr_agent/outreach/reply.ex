defmodule SdrAgent.Outreach.Reply do
  @moduledoc """
  An inbound reply message, matched to its delivery and enrollment when
  possible (S2 row Reply; spec §16).

  Attributes: `webhook_event_id` (unique — one reply per event),
  `message_id` (unique per tenant), `in_reply_to`, `match_status`
  (`matched`, `unmatched`), `delivery_operation_id`, `contact_id`,
  `lead_id`, `enrollment_id` (all set exactly when matched), `from_email`,
  `to_email`, `subject`, `body_text`, `body_sha256` (computed here; the
  text is a Payload), `received_at`.

  `:receive` (WHK) — a matched reply, in the same transaction and
  independent of any classification (`SdrAgent.Outreach.Changes.ApplyReply`):
  the enrollment → replied, its unsent deliveries → cancelled with their
  queued drafts (→ cancelled) and still-granted approvals (→ invalidated),
  its drafts in review → cancelled, and the lead (in outreach) → replied.
  Unmatched replies are stored and surfaced with no side effects.
  `SdrAgent.Outreach.Webhooks` records the `unsubscribe_rule` Decision and
  the `sdr.reply.received` signal in the same transaction.

  APPEND-ONLY (trigger). Reads: ADM, REV, AUR, AGT, WHK, AUD. Audited:
  `outreach.reply.received` plus each side effect.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Checks

  @match [:delivery_operation_id, :contact_id, :lead_id, :enrollment_id]

  postgres do
    table "replies"
    repo SdrAgent.Repo

    references do
      reference :tenant, on_delete: :restrict
      reference :webhook_event, on_delete: :restrict
      reference :delivery_operation, on_delete: :restrict
      reference :contact, on_delete: :restrict
      reference :lead, on_delete: :restrict
      reference :enrollment, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "replies_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :match_status, "replies_match_status",
        check: SdrAgent.Audit.SQL.one_of("match_status", [:matched, :unmatched])

      check_constraint :match_status, "replies_match_columns",
        check:
          "(match_status = 'matched' AND " <>
            Enum.map_join(@match, " AND ", &"#{&1} IS NOT NULL") <>
            ") OR (match_status = 'unmatched' AND " <>
            Enum.map_join(@match, " AND ", &"#{&1} IS NULL") <> ")"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("replies") do
        statement name do
          up up_sql
          down down_sql
        end
      end

      {name, up_sql, down_sql} = SdrAgent.Audit.SQL.payload_fk("replies", :body_sha256)

      statement name do
        up up_sql
        down down_sql
        after_tables ["payloads"]
      end
    end
  end

  actions do
    defaults [:read]

    create :receive do
      description "WHK: store a reply; a matched reply stops its enrollment in the same transaction."

      accept [
        :webhook_event_id,
        :message_id,
        :in_reply_to,
        :from_email,
        :to_email,
        :subject,
        :body_text,
        :received_at | @match
      ]

      change fn changeset, _context ->
        status =
          if Ash.Changeset.get_attribute(changeset, :lead_id), do: :matched, else: :unmatched

        body = Ash.Changeset.get_attribute(changeset, :body_text) || ""

        changeset
        |> Ash.Changeset.force_change_attribute(:match_status, status)
        |> Ash.Changeset.force_change_attribute(:body_sha256, :crypto.hash(:sha256, body))
      end

      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change SdrAgent.Outreach.Changes.ApplyReply

      change {AppendEvent,
              event_type: "outreach.reply.received",
              category: :domain_change,
              links: [correlation_id: :webhook_event_id]}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action(:receive) do
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType, types: [:agent_runtime, :webhook_ingestor, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :message_id, :string, allow_nil?: false, public?: true
    attribute :in_reply_to, :string, public?: true

    attribute :match_status, :atom do
      allow_nil? false
      writable? false
      constraints one_of: [:matched, :unmatched]
      public? true
    end

    attribute :from_email, :ci_string, allow_nil?: false, public?: true
    attribute :to_email, :ci_string, allow_nil?: false, public?: true
    attribute :subject, :string, public?: true, constraints: [trim?: false]
    attribute :body_text, :string, allow_nil?: false, public?: true, constraints: [trim?: false]
    attribute :body_sha256, :binary, allow_nil?: false, writable?: false, public?: true

    attribute :received_at, :utc_datetime_usec do
      allow_nil? false
      default &SdrAgent.Clock.utc_now/0
      public? true
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

    belongs_to :webhook_event, SdrAgent.Operations.WebhookEvent do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :delivery_operation, SdrAgent.Outreach.DeliveryOperation do
      attribute_writable? true
      public? true
    end

    belongs_to :contact, SdrAgent.Sales.Contact do
      attribute_writable? true
      public? true
    end

    belongs_to :lead, SdrAgent.Sales.Lead do
      attribute_writable? true
      public? true
    end

    belongs_to :enrollment, SdrAgent.Sales.CampaignEnrollment do
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_webhook_event, [:webhook_event_id]
    identity :unique_message_id, [:tenant_id, :message_id]
  end

  @doc false
  def __sdr_audited__, do: true
end
