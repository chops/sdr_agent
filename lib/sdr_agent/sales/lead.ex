defmodule SdrAgent.Sales.Lead do
  @moduledoc """
  A contact being worked toward a sales outcome — the unit the SDR agent is
  assigned (S2 row Lead).

  Attributes: `contact_id`, `account_id` (must be the contact's account, and
  active, at create), `owner_user_id`, `source`, `status`, `status_reason`,
  `last_decision_id` (the Agents Decision behind the latest agent
  transition), `assigned_at`, `handed_off_at`, `closed_at`. A contact has at
  most one open lead (partial unique index over the non-terminal states).

  Lifecycle (`transitions/0`):

    * new → assigned (ADM, REV) → researching → qualifying (AGT);
    * qualifying → qualified | disqualified (T) — AGT, and only from inside
      the Research Qualification create (`SdrAgent.Sales.Checks.QualificationContext`);
    * qualified → disqualified (T) and disqualified → qualified — ADM, REV,
      only from inside a human Qualification override that flips the
      outcome (`:disqualify_by_override`, `:requalify_by_override`), so the
      current qualification and the lead never disagree;
    * qualified → in_outreach (AGT) → replied (WHK; sets `handed_off_at`) →
      converted (T) | nurture (T) (ADM, REV). Replied leads are the human
      hand-off queue (`SdrAgent.Sales.list_handoff_queue/1`);
    * any non-terminal state → stopped (T) with a reason (ADM, REV, WHK);
    * researching, qualifying → blocked (AGT, with a reason; the S7 Failure
      side effect is added there) → assigned (ADM `:retry`);
    * disqualified → assigned (ADM `:reopen`).

  Agent transitions require a `decision_id`. Every transition runs on the
  row re-read under `FOR UPDATE` and appends an AuditEvent (`sales.lead.*`)
  with the previous status, the new status, the reason and the decision id.

  Actors: ADM create; SEED (dev/test only) `:seed`; reads for ADM, REV, AUR,
  AGT, WHK, AUD.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Changes.Stamp
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks

  @statuses [
    :new,
    :assigned,
    :researching,
    :qualifying,
    :qualified,
    :disqualified,
    :in_outreach,
    :replied,
    :converted,
    :nurture,
    :stopped,
    :blocked
  ]
  @terminal [:disqualified, :converted, :nurture, :stopped]
  @open @statuses -- @terminal
  @transitions [
    {:assign, [:new], :assigned},
    {:start_research, [:assigned], :researching},
    {:start_qualifying, [:researching], :qualifying},
    {:qualify, [:qualifying], :qualified},
    {:disqualify, [:qualifying], :disqualified},
    {:start_outreach, [:qualified], :in_outreach},
    {:mark_replied, [:in_outreach], :replied},
    {:convert, [:replied], :converted},
    {:nurture, [:replied], :nurture},
    {:stop, @open, :stopped},
    {:block, [:researching, :qualifying], :blocked},
    {:retry, [:blocked], :assigned},
    {:reopen, [:disqualified], :assigned},
    {:disqualify_by_override, [:qualified], :disqualified},
    {:requalify_by_override, [:disqualified], :qualified}
  ]
  @event [category: :domain_change, previous: [:status], links: [decision_id: :last_decision_id]]

  postgres do
    table "leads"
    repo SdrAgent.Repo

    identity_wheres_to_sql unique_open_lead:
                             "status NOT IN ('disqualified', 'converted', 'nurture', 'stopped')"

    references do
      reference :tenant, on_delete: :restrict
      reference :contact, on_delete: :restrict
      reference :account, on_delete: :restrict
      reference :owner, on_delete: :restrict
      reference :last_decision, on_delete: :restrict
    end

    check_constraints do
      check_constraint :trace_id, "leads_trace_ids", check: SdrAgent.Audit.SQL.trace_check()

      check_constraint :status, "leads_status",
        check: SdrAgent.Audit.SQL.one_of("status", @statuses)

      check_constraint :status_reason, "leads_reason_when_stopped_or_blocked",
        check: "status NOT IN ('stopped', 'blocked') OR status_reason IS NOT NULL"
    end
  end

  actions do
    defaults [:read]

    read :handoff_queue do
      description "Replied leads awaiting a human (oldest hand-off first)."
      filter expr(status == :replied)
      prepare build(sort: [handed_off_at: :asc, id: :asc])
    end

    create :create do
      description "ADM: create a new lead for an active account's contact."
      accept [:contact_id, :account_id, :owner_user_id, :source]
      change SdrAgent.Sales.Changes.LeadAccount
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.lead.created", category: :domain_change}
    end

    create :seed do
      description "SEED (dev/test only): create a new lead with a fixture id."
      accept [:id, :contact_id, :account_id, :owner_user_id, :source]
      change SdrAgent.Sales.Changes.LeadAccount
      change SdrAgent.Audit.Changes.SetTenant
      change SdrAgent.Audit.Changes.TraceIds
      change {AppendEvent, event_type: "sales.lead.created", category: :domain_change}
    end

    update :assign do
      description "ADM, REV: new → assigned, optionally with an owner."
      require_atomic? false
      accept [:owner_user_id]
      change get_and_lock_for_update()
      change {Transition, from: [:new], to: :assigned, locked?: true}
      change {Stamp, fields: [:assigned_at]}
      change {AppendEvent, [event_type: "sales.lead.assigned"] ++ @event}
    end

    update :start_research do
      description "AGT: assigned → researching, citing a Decision."
      require_atomic? false
      argument :decision_id, :uuid, allow_nil?: false
      change get_and_lock_for_update()
      change {Transition, from: [:assigned], to: :researching, locked?: true}
      change set_attribute(:last_decision_id, arg(:decision_id))
      change {AppendEvent, [event_type: "sales.lead.research_started"] ++ @event}
    end

    update :start_qualifying do
      description "AGT: researching → qualifying, citing a Decision."
      require_atomic? false
      argument :decision_id, :uuid, allow_nil?: false
      change get_and_lock_for_update()
      change {Transition, from: [:researching], to: :qualifying, locked?: true}
      change set_attribute(:last_decision_id, arg(:decision_id))
      change {AppendEvent, [event_type: "sales.lead.qualifying_started"] ++ @event}
    end

    update :qualify do
      description "AGT, inside the Qualification create only: qualifying → qualified."
      require_atomic? false
      argument :decision_id, :uuid, allow_nil?: false
      change get_and_lock_for_update()
      change {Transition, from: [:qualifying], to: :qualified, locked?: true}
      change set_attribute(:last_decision_id, arg(:decision_id))
      change {AppendEvent, [event_type: "sales.lead.qualified"] ++ @event}
    end

    update :disqualify do
      description "AGT, inside the Qualification create only: qualifying → disqualified (T)."
      require_atomic? false
      argument :decision_id, :uuid, allow_nil?: false
      change get_and_lock_for_update()
      change {Transition, from: [:qualifying], to: :disqualified, locked?: true}
      change set_attribute(:last_decision_id, arg(:decision_id))
      change {Stamp, fields: [:closed_at]}
      change {AppendEvent, [event_type: "sales.lead.disqualified"] ++ @event}
    end

    update :start_outreach do
      description "AGT: qualified → in_outreach, citing a Decision."
      require_atomic? false
      argument :decision_id, :uuid, allow_nil?: false
      change get_and_lock_for_update()
      change {Transition, from: [:qualified], to: :in_outreach, locked?: true}
      change set_attribute(:last_decision_id, arg(:decision_id))
      change {AppendEvent, [event_type: "sales.lead.outreach_started"] ++ @event}
    end

    update :disqualify_by_override do
      description "ADM, REV, inside a human Qualification override only: qualified → disqualified (T)."
      require_atomic? false
      accept [:status_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:qualified], to: :disqualified, locked?: true}
      change {Stamp, fields: [:closed_at]}
      change {AppendEvent, [event_type: "sales.lead.disqualified_by_override"] ++ @event}
    end

    update :requalify_by_override do
      description "ADM, REV, inside a human Qualification override only: disqualified → qualified."
      require_atomic? false
      accept [:status_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:disqualified], to: :qualified, locked?: true}
      change set_attribute(:closed_at, nil)
      change {AppendEvent, [event_type: "sales.lead.requalified_by_override"] ++ @event}
    end

    update :mark_replied do
      description "WHK: in_outreach → replied; the lead enters the hand-off queue."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:in_outreach], to: :replied, locked?: true}
      change {Stamp, fields: [:handed_off_at]}
      change {AppendEvent, [event_type: "sales.lead.replied"] ++ @event}
    end

    update :convert do
      description "ADM, REV: replied → converted (T)."
      require_atomic? false
      accept [:status_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:replied], to: :converted, locked?: true}
      change {Stamp, fields: [:closed_at]}
      change {AppendEvent, [event_type: "sales.lead.converted"] ++ @event}
    end

    update :nurture do
      description "ADM, REV: replied → nurture (T)."
      require_atomic? false
      accept [:status_reason]
      change get_and_lock_for_update()
      change {Transition, from: [:replied], to: :nurture, locked?: true}
      change {Stamp, fields: [:closed_at]}
      change {AppendEvent, [event_type: "sales.lead.nurtured"] ++ @event}
    end

    update :stop do
      description "ADM, REV, WHK: any open state → stopped (T), with a reason."
      require_atomic? false
      accept [:status_reason]
      require_attributes [:status_reason]
      change get_and_lock_for_update()
      change {Transition, from: @open, to: :stopped, locked?: true}
      change {Stamp, fields: [:closed_at]}
      change {AppendEvent, [event_type: "sales.lead.stopped"] ++ @event}
    end

    update :block do
      description "AGT: researching or qualifying → blocked, with a reason and a Decision."
      require_atomic? false
      accept [:status_reason]
      require_attributes [:status_reason]
      argument :decision_id, :uuid, allow_nil?: false
      change get_and_lock_for_update()
      change {Transition, from: [:researching, :qualifying], to: :blocked, locked?: true}
      change set_attribute(:last_decision_id, arg(:decision_id))
      change {AppendEvent, [event_type: "sales.lead.blocked"] ++ @event}
    end

    update :retry do
      description "ADM: blocked → assigned (operator retry)."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:blocked], to: :assigned, locked?: true}
      change set_attribute(:status_reason, nil)
      change {Stamp, fields: [:assigned_at]}
      change {AppendEvent, [event_type: "sales.lead.retried"] ++ @event}
    end

    update :reopen do
      description "ADM: disqualified → assigned."
      require_atomic? false
      change get_and_lock_for_update()
      change {Transition, from: [:disqualified], to: :assigned, locked?: true}
      change set_attribute(:closed_at, nil)
      change {Stamp, fields: [:assigned_at]}
      change {AppendEvent, [event_type: "sales.lead.reopened"] ++ @event}
    end
  end

  policies do
    policy action_type([:create, :update, :destroy, :action]) do
      forbid_if actor_attribute_equals(:role, :auditor)
      authorize_if always()
    end

    policy action([:create, :retry, :reopen]) do
      authorize_if {Checks.ActorRole, roles: [:admin]}
    end

    policy action(:seed) do
      authorize_if Checks.SeedingAllowed
    end

    policy action([:assign, :convert, :nurture]) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action(:stop) do
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action([:start_research, :start_qualifying, :start_outreach, :block]) do
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action([:qualify, :disqualify]) do
      forbid_unless SdrAgent.Sales.Checks.QualificationContext
      authorize_if {Checks.ActorType, types: [:agent_runtime]}
    end

    policy action([:disqualify_by_override, :requalify_by_override]) do
      forbid_unless SdrAgent.Sales.Checks.QualificationContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer]}
    end

    policy action(:mark_replied) do
      authorize_if {Checks.ActorType, types: [:webhook_ingestor]}
    end

    policy action_type(:read) do
      authorize_if Checks.KernelContext
      authorize_if {Checks.ActorRole, roles: [:admin, :reviewer, :auditor]}

      authorize_if {Checks.ActorType,
                    types: [:agent_runtime, :webhook_ingestor, :auditor_cli, :seeder]}
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :source, :atom do
      allow_nil? false
      constraints one_of: [:fixture, :crm, :manual]
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :new
      writable? false
      constraints one_of: @statuses
      public? true
    end

    attribute :status_reason, :string, public?: true
    attribute :assigned_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :handed_off_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :closed_at, :utc_datetime_usec, writable?: false, public?: true
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

    belongs_to :contact, SdrAgent.Sales.Contact do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :account, SdrAgent.Sales.Account do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :owner, SdrAgent.Accounts.User do
      source_attribute :owner_user_id
      attribute_writable? true
      public? true
    end

    belongs_to :last_decision, SdrAgent.Agents.Decision do
      source_attribute :last_decision_id
      attribute_writable? false
      public? true
    end

    has_many :enrollments, SdrAgent.Sales.CampaignEnrollment, public?: true
  end

  identities do
    identity :unique_open_lead, [:tenant_id, :contact_id],
      where: expr(status not in [:disqualified, :converted, :nurture, :stopped])
  end

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions

  @doc false
  def __sdr_audited__, do: true
end
