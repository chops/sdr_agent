defmodule SdrAgent.Agents.RemoteModelCall do
  @moduledoc """
  A charged ClaudeCLI call awaiting the off-host worker (S-B2; entity/plan
  r2 "RemoteModelCall"; plan P1, r4 R1).

  Attributes: `id`; `tenant_id`; `model_invocation_id` (UNIQUE; the
  composite foreign key `(model_invocation_id, tenant_id)` →
  `model_invocations (id, tenant_id)`, RESTRICT); `state`; the frozen launch
  input reference `request_sha256`, `profile_id` and `model_id` (the
  invocation's); `claim_deadline` (`reserved_at + 120 s`); and, once
  claimed, `worker_id` (the composite `(worker_id, tenant_id)` →
  `mac_workers (id, tenant_id)`, MATCH SIMPLE: null until claimed, then the
  same tenant), `claimed_at` and `result_deadline` (`claimed_at + 600 s`).

  Keys: UNIQUE `model_invocation_id`; UNIQUE `(id, tenant_id)` (the target
  of the nonce, result and receipt composites); a partial UNIQUE
  `(worker_id) WHERE state = 'claimed'` (one claimed call per worker).

  Lifecycle (`transitions/0`): pending → claimed (`:claim`), claimed →
  completed (`:complete`), claimed → expired_unknown (`:expire_unknown`);
  pending → expired_unclaimed belongs to the S-B3 settler. Each create and
  transition appends one AuditEvent through the unchanged
  `SdrAgent.Audit.Changes.AppendEvent` (`remote_call.created`,
  `.claimed`, `.completed`, `.expired_unknown`; `:domain_change`) whose
  payload is ids, state, digests and deadlines only.

  `:create` authorizes only inside the reservation-owned scope
  (`SdrAgent.Agents.Checks.RemoteReservationScope`), reached only from
  `SdrAgent.Agents.Changes.CreateRemoteCall` on `ModelInvocation :reserve`;
  reads and transitions only inside the domain-private RemoteCalls scope
  (`SdrAgent.Agents.Checks.RemoteCallsScope`), from
  `SdrAgent.Agents.RemoteCalls`. A trigger
  refuses DELETE, TRUNCATE, any update of a terminal row and any update of a
  column other than `state`, `worker_id`, `claimed_at` and
  `result_deadline`.

  S-B5's explicit `:owner_metadata` read permits only the fresh hosted
  owner, filtered by tenant and invocation run id. It carries no transcript
  bytes and does not change the default private read or any transition.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.RemoteCallsScope
  alias SdrAgent.Agents.Checks.RemoteReservationScope
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Prototype.Checks.OperatorAction

  @states [:pending, :claimed, :completed, :expired_unclaimed, :expired_unknown]
  @terminal ["completed", "expired_unclaimed", "expired_unknown"]
  @mutable ["state", "worker_id", "claimed_at", "result_deadline"]
  @event [category: :domain_change, previous: [:state]]
  @transitions [
    {:claim, [:pending], :claimed},
    {:complete, [:claimed], :completed},
    {:expire_unknown, [:claimed], :expired_unknown}
  ]

  postgres do
    table "remote_model_calls"
    repo SdrAgent.Repo

    references do
      reference :model_invocation,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :full

      reference :worker,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :simple
    end

    check_constraints do
      check_constraint :state, "remote_model_calls_state",
        check: SdrAgent.Audit.SQL.one_of("state", @states)
    end

    custom_indexes do
      index [:worker_id],
        unique: true,
        name: "remote_model_calls_one_claimed_per_worker",
        where: "state = 'claimed'"
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable(
              "remote_model_calls",
              @terminal,
              @mutable,
              "state"
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

    read :owner_metadata do
      description "Explicit current-owner call status for one run, without transcript content."
      argument :run_id, :uuid

      filter expr(
               tenant_id == ^actor(:tenant_id) and model_invocation.agent_run_id == ^arg(:run_id)
             )
    end

    create :create do
      description "S-B2: the reservation's remote call (reservation scope only, inside :reserve)."

      accept [:model_invocation_id, :request_sha256, :profile_id, :model_id, :claim_deadline]

      change SdrAgent.Audit.Changes.SetTenant
      change {AppendEvent, [event_type: "remote_call.created"] ++ @event}
    end

    update :claim do
      description "S-B2: pending → claimed by a worker (RemoteCalls claim)."
      require_atomic? false
      accept [:worker_id, :claimed_at, :result_deadline]
      change {Transition, from: [:pending], to: :claimed, attribute: :state}
      change {AppendEvent, [event_type: "remote_call.claimed"] ++ @event}
    end

    update :complete do
      description "S-B2: claimed → completed with the first accepted result."
      require_atomic? false
      change {Transition, from: [:claimed], to: :completed, attribute: :state}
      change {AppendEvent, [event_type: "remote_call.completed"] ++ @event}
    end

    update :expire_unknown do
      description "S-B2: claimed → expired_unknown at or after the result deadline."
      require_atomic? false
      change {Transition, from: [:claimed], to: :expired_unknown, attribute: :state}
      change {AppendEvent, [event_type: "remote_call.expired_unknown"] ++ @event}
    end
  end

  policies do
    policy action(:create) do
      authorize_if RemoteReservationScope
    end

    policy action(:read) do
      authorize_if RemoteCallsScope
    end

    policy action_type(:update) do
      authorize_if RemoteCallsScope
    end

    policy action(:owner_metadata) do
      access_type :strict
      authorize_if {OperatorAction, action: :transcript_read}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, writable?: false, public?: true

    attribute :state, :atom do
      allow_nil? false
      default :pending
      writable? false
      constraints one_of: @states
      public? true
    end

    attribute :request_sha256, :binary, allow_nil?: false, public?: true
    attribute :profile_id, :atom, allow_nil?: false, public?: true
    attribute :model_id, :string, allow_nil?: false, public?: true
    attribute :claim_deadline, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :claimed_at, :utc_datetime_usec, public?: true
    attribute :result_deadline, :utc_datetime_usec, public?: true
  end

  relationships do
    belongs_to :model_invocation, SdrAgent.Agents.ModelInvocation do
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :worker, SdrAgent.Operations.MacWorker do
      attribute_writable? true
      public? true
    end
  end

  identities do
    identity :unique_model_invocation, [:model_invocation_id]
    identity :unique_id_tenant, [:id, :tenant_id]
  end

  @doc "The call states."
  def states, do: @states

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions
end
