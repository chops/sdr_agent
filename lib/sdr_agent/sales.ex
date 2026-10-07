defmodule SdrAgent.Sales do
  @moduledoc """
  Sales bounded context (S2): who is targeted, against which profile, and
  through which program.

  Resources: `IcpDefinition` (+ embedded `IcpCriteria`), `Account`,
  `Contact`, `Lead`, `Campaign`, `Sequence`, `SequenceStep`,
  `CampaignEnrollment`. Sales sits above Audit, Accounts, Operations and
  Agents (it holds FKs to tenants, users and decisions) and below Research
  and Outreach, which it never calls. All data is synthetic: account
  domains, contact emails and sender addresses must be reserved names
  (`SdrAgent.Sales.Synthetic`).

  Public API (every function takes `actor:`; writes run through
  `SdrAgent.Audit.Guard`, so refused auditor mutations are audited):

    * creates — `create_icp_definition/2`, `new_icp_version/3`,
      `create_account/2`, `create_contact/2`, `create_sequence/2`,
      `add_sequence_step/3`, `create_campaign/2`, `create_lead/2`,
      `enroll_lead/2`;
    * seeding (SEED, dev/test only) — `seed_icp_definition/2`,
      `seed_account/2`, `seed_contact/2`, `seed_sequence/2`,
      `seed_sequence_step/2`, `seed_campaign/2`, `seed_lead/2`;
    * `advance_enrollment/3` (DLV, REC, SCH) — the S8 step advancement;
    * `update/4` — any update or lifecycle action of a Sales record (e.g.
      `update(lead, :start_research, %{decision_id: id}, actor: agt)`); each
      resource's `transitions/0` lists its lifecycle actions;
    * reads (tenant-scoped) — `fetch/3`, `list_records/2`,
      `list_handoff_queue/1`.
  """
  use Ash.Domain,
    otp_app: :sdr_agent

  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Sales.Account
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.CampaignEnrollment
  alias SdrAgent.Sales.Contact
  alias SdrAgent.Sales.IcpDefinition
  alias SdrAgent.Sales.Lead
  alias SdrAgent.Sales.Sequence
  alias SdrAgent.Sales.SequenceStep

  resources do
    resource SdrAgent.Sales.IcpDefinition
    resource SdrAgent.Sales.Account
    resource SdrAgent.Sales.Contact
    resource SdrAgent.Sales.Lead
    resource SdrAgent.Sales.Campaign
    resource SdrAgent.Sales.Sequence
    resource SdrAgent.Sales.SequenceStep
    resource SdrAgent.Sales.CampaignEnrollment
  end

  @doc "ADM: creates a draft ICP (`name`, `description`, `criteria`)."
  def create_icp_definition(attrs, opts),
    do: GuardedCall.create(IcpDefinition, :create, attrs, opts)

  @doc "SEED: creates an ICP with a fixture `id`."
  def seed_icp_definition(attrs, opts), do: GuardedCall.create(IcpDefinition, :seed, attrs, opts)

  @doc "ADM: starts the next draft version of `icp` (optionally with new `criteria`)."
  def new_icp_version(icp, attrs, opts) do
    attrs = Map.put(Map.new(attrs), :icp_definition_id, icp.id)
    GuardedCall.create(IcpDefinition, :new_version, attrs, Keyword.put(opts, :subject_id, icp.id))
  end

  @doc "ADM: creates an account under a reserved domain."
  def create_account(attrs, opts), do: GuardedCall.create(Account, :create, attrs, opts)

  @doc "SEED: creates an account with a fixture `id`."
  def seed_account(attrs, opts), do: GuardedCall.create(Account, :seed, attrs, opts)

  @doc "ADM: creates a contact with a reserved email."
  def create_contact(attrs, opts), do: GuardedCall.create(Contact, :create, attrs, opts)

  @doc "SEED: creates a contact with a fixture `id`."
  def seed_contact(attrs, opts), do: GuardedCall.create(Contact, :seed, attrs, opts)

  @doc "ADM: creates a draft sequence."
  def create_sequence(attrs, opts), do: GuardedCall.create(Sequence, :create, attrs, opts)

  @doc "SEED: creates a sequence with a fixture `id`."
  def seed_sequence(attrs, opts), do: GuardedCall.create(Sequence, :seed, attrs, opts)

  @doc "ADM: adds a step to a draft `sequence`."
  def add_sequence_step(sequence, attrs, opts) do
    attrs = Map.put(Map.new(attrs), :sequence_id, sequence.id)
    GuardedCall.create(SequenceStep, :add, attrs, Keyword.put(opts, :subject_id, sequence.id))
  end

  @doc "SEED: adds a step with a fixture `id` to a draft sequence (`sequence_id`)."
  def seed_sequence_step(attrs, opts), do: GuardedCall.create(SequenceStep, :seed, attrs, opts)

  @doc "ADM: creates a draft campaign."
  def create_campaign(attrs, opts), do: GuardedCall.create(Campaign, :create, attrs, opts)

  @doc "SEED: creates a draft campaign with a fixture `id`."
  def seed_campaign(attrs, opts), do: GuardedCall.create(Campaign, :seed, attrs, opts)

  @doc "ADM: creates a new lead (`contact_id`, `account_id`, `source`, `owner_user_id`)."
  def create_lead(attrs, opts), do: GuardedCall.create(Lead, :create, attrs, opts)

  @doc "SEED: creates a new lead with a fixture `id`."
  def seed_lead(attrs, opts), do: GuardedCall.create(Lead, :seed, attrs, opts)

  @doc "AGT: enrolls a qualified lead in an active campaign (`campaign_id`, `lead_id`)."
  def enroll_lead(attrs, opts), do: GuardedCall.create(CampaignEnrollment, :enroll, attrs, opts)

  @doc """
  DLV, REC, SCH: after the message of `step_position` was accepted at
  `accepted_at`, moves the enrollment to that step and schedules the next
  one in the campaign time zone (`:advance_step`), or completes it after the
  last step (`:complete`).
  """
  def advance_enrollment(enrollment, %{step_position: position} = attrs, opts) do
    action =
      if SdrAgent.Sales.Changes.AdvanceStep.last_step?(enrollment.campaign_id, position),
        do: :complete,
        else: :advance_step

    GuardedCall.update(enrollment, action, attrs, opts)
  end

  @doc "Runs update or lifecycle `action` on a Sales `record` with `attrs`."
  def update(record, action, attrs, opts), do: GuardedCall.update(record, action, attrs, opts)

  @doc "Reads one Sales record of `resource` by id in the actor's tenant."
  def fetch(resource, id, opts), do: GuardedCall.get(resource, id, opts)

  @doc "Lists `resource` records in the actor's tenant (`filter:`, `sort:` options)."
  def list_records(resource, opts), do: GuardedCall.list(resource, opts)

  @doc """
  The human hand-off queue: leads in `replied`, oldest hand-off first.
  (Ordering by reply assessment — "interested first" — needs Outreach data
  and is composed above Outreach, S9/S10.)
  """
  def list_handoff_queue(opts) do
    opts
    |> Keyword.put(:action, :handoff_queue)
    |> then(&GuardedCall.read_query(Lead, &1))
    |> Ash.read()
  end
end
