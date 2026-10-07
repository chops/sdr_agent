defmodule SdrAgent.Outreach.Approval do
  @moduledoc """
  A human review verdict; when granted, the capability to send exactly one
  immutable revision to exactly one recipient (S2 row Approval; spec §15).

  Attributes: `draft_id`, `draft_revision_id`, `revision_content_sha256`,
  `recipient_contact_id`, `recipient_email` (snapshot of the contact's
  current email), `campaign_id`, `approver_id`, `approver_authored_revision`,
  `verdict` (`:approved` | `:rejected`), `reason` (required when rejected),
  `status`, `decided_at`, `revoked_at`, `revoked_by_id`,
  `invalidated_reason`. At most one granted or consumed approval per draft
  (partial unique index).

  Actions (`SdrAgent.Outreach.Changes.BindApproval` binds the fields under
  a row lock on the draft):

    * `:approve` (ADM, REV; guarded) — only for the draft's *current*
      revision with the exact content hash the reviewer saw, and for the
      recipient email the reviewer saw (`recipient_email`, required, equal
      ignoring case to the locked contact's current email), while the draft
      is pending review, for an active, unsuppressed contact of an open
      campaign; the approver may have authored the revision (recorded).
      The grant moves the draft to `queued` and inserts the pending
      DeliveryOperation and its delivery job (outbox) in the same
      transaction;
    * `:reject` (ADM, REV; guarded) — a rejected verdict with a reason;
      the draft → rejected (T);
    * `:revoke` (ADM, REV; guarded) — granted → revoked (T), only while its
      delivery is still pending (the delivery is cancelled first); the draft
      returns to pending review. After the claim the approval is consumed
      and only the delivery can be stopped (`cancel_retry`);
    * `:consume` (DLV) — granted → consumed (T), in the delivery's first
      claim;
    * `:invalidate` (inside another Outreach action only, e.g. a
      suppression) — granted → invalidated (T) with a reason.

  System actors and auditors can never approve. Binding columns never
  change, and terminal approvals never change at all (trigger; only
  `status`, `revoked_at`, `revoked_by_id`, `invalidated_reason` and
  `updated_at` are mutable while granted). The grant's audit event records
  the revision's author (user or agent run) and the hashes of its diffs.
  Reads: ADM, REV, AUR, AGT, DLV, WHK, AUD. Every write appends an
  AuditEvent (`outreach.approval.*`).
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Outreach,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Stamp
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Outreach.Changes
  alias SdrAgent.Outreach.Checks.InternalWrite

  @statuses [:granted, :consumed, :rejected, :revoked, :invalidated]
  @invalidated_reasons [:newer_revision, :recipient_changed, :suppressed, :campaign_closed]
  @transitions [
    {:consume, [:granted], :consumed},
    {:revoke, [:granted], :revoked},
    {:invalidate, [:granted], :invalidated}
  ]
  @bound [:draft_revision_id, :revision_author, :diff_hashes]
  @event [category: :domain_change, previous: [:status]]

  postgres do
    table "approvals"
    repo SdrAgent.Repo

    identity_wheres_to_sql one_live_per_draft: "status IN ('granted', 'consumed')"

    references do
      reference :tenant, on_delete: :restrict
      reference :draft, on_delete: :restrict
      reference :draft_revision, on_delete: :restrict
      reference :recipient_contact, on_delete: :restrict
      reference :campaign, on_delete: :restrict
      reference :approver, on_delete: :restrict
      reference :revoked_by, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "approvals_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "approvals_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :verdict, "approvals_verdict_status",
        check:
          "(verdict = 'approved' AND status IN ('granted', 'consumed', 'revoked', 'invalidated')) OR " <>
            "(verdict = 'rejected' AND status = 'rejected' AND reason IS NOT NULL)"

      check_constraint :revision_content_sha256, "approvals_revision_sha256_length",
        check: "octet_length(revision_content_sha256) = 32"

      check_constraint :invalidated_reason, "approvals_invalidated_reason",
        check: "(status = 'invalidated') = (invalidated_reason IS NOT NULL)"
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable(
              "approvals",
              [:consumed, :rejected, :revoked, :invalidated],
              [:status, :revoked_at, :revoked_by_id, :invalidated_reason, :updated_at]
            ) do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :approve do
      description "ADM, REV: grant the draft's current revision (id + content hash) to its recipient."
      accept [:draft_id]
      argument :draft_revision_id, :uuid, allow_nil?: false
      argument :content_sha256, :string, allow_nil?: false

      # The recipient email the reviewer saw (review #17 MF1); compared to
      # the locked contact's email by BindApproval. Never a fallback.
      argument :recipient_email, :ci_string, allow_nil?: false
      argument :revision_author, :map
      argument :diff_hashes, :map
      change SdrAgent.Audit.Changes.SetTenant
      change {Changes.ActorUser, field: :approver_id}
      change {Changes.BindApproval, verdict: :approved}
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "outreach.approval.granted", category: :domain_change, arguments: @bound}

      change {Changes.MoveDraft, action: :queue}
      change Changes.RequestDelivery
    end

    create :reject do
      description "ADM, REV: reject the draft's current revision with a reason; the draft ends."
      accept [:draft_id, :reason]
      require_attributes [:reason]
      argument :draft_revision_id, :uuid, allow_nil?: false
      argument :content_sha256, :string, allow_nil?: false
      # Optional: a rejection authorizes nothing, so it is not compared.
      argument :recipient_email, :ci_string
      argument :revision_author, :map
      argument :diff_hashes, :map
      change SdrAgent.Audit.Changes.SetTenant
      change {Changes.ActorUser, field: :approver_id}
      change {Changes.BindApproval, verdict: :rejected}
      change SdrAgent.Audit.Changes.TraceIds

      change {AppendEvent,
              event_type: "outreach.approval.rejected",
              category: :domain_change,
              arguments: @bound}

      change {Changes.MoveDraft, action: :reject, reason: :reason}
    end

    update :revoke do
      description "ADM, REV: granted → revoked (T); the draft returns to review."
      require_atomic? false
      change Changes.LockDraftFirst
      change Changes.CancelPendingDelivery
      change get_and_lock_for_update()
      change {Transition, from: [:granted], to: :revoked, locked?: true}
      change {Stamp, fields: [:revoked_at]}
      change {Changes.ActorUser, field: :revoked_by_id}
      change {AppendEvent, [event_type: "outreach.approval.revoked"] ++ @event}
      change {Changes.MoveDraft, action: :unqueue}
    end

    update :consume do
      description "DLV, in the delivery's first claim: granted → consumed (T)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:granted], to: :consumed, locked?: true}
      change {AppendEvent, [event_type: "outreach.approval.consumed"] ++ @event}
    end

    update :invalidate do
      description "Inside another Outreach action only: granted → invalidated (T) with a reason."
      require_atomic? false
      accept [:invalidated_reason]
      require_attributes [:invalidated_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:granted], to: :invalidated, locked?: true}
      change {AppendEvent, [event_type: "outreach.approval.invalidated"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:approve, :reject, :revoke]) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action(:invalidate) do
      authorize_if InternalWrite
    end

    policy action(:consume) do
      authorize_if {Checks.ActorType, types: [:delivery_worker]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [:agent_runtime, :delivery_worker, :webhook_ingestor, :auditor_cli]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :revision_content_sha256, :binary,
      allow_nil?: false,
      writable?: false,
      public?: true

    attribute :recipient_email, :ci_string, allow_nil?: false, writable?: false, public?: true

    attribute :approver_authored_revision, :boolean do
      allow_nil? false
      writable? false
      public? true
    end

    attribute :verdict, :atom do
      allow_nil? false
      writable? false
      constraints one_of: [:approved, :rejected]
      public? true
    end

    attribute :reason, :string, public?: true

    attribute :status, :atom do
      allow_nil? false
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :decided_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec, writable?: false, public?: true

    attribute :invalidated_reason, :atom do
      constraints one_of: @invalidated_reasons
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

    attribute :updated_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      update_default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :tenant, SdrAgent.Audit.Tenant do
      allow_nil? false
      public? true
    end

    belongs_to :draft, SdrAgent.Outreach.Draft do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :draft_revision, SdrAgent.Outreach.DraftRevision do
      allow_nil? false
      attribute_writable? false
      public? true
    end

    belongs_to :recipient_contact, SdrAgent.Sales.Contact do
      allow_nil? false
      attribute_writable? false
      public? true
    end

    belongs_to :campaign, SdrAgent.Sales.Campaign do
      allow_nil? false
      attribute_writable? false
      public? true
    end

    belongs_to :approver, SdrAgent.Accounts.User do
      allow_nil? false
      attribute_writable? false
      public? true
    end

    belongs_to :revoked_by, SdrAgent.Accounts.User do
      attribute_writable? false
      public? true
    end
  end

  identities do
    identity :one_live_per_draft, [:draft_id], where: expr(status in [:granted, :consumed])
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
