defmodule SdrAgent.Operations.MacWorker do
  @moduledoc """
  The off-host executor of remote ClaudeCLI calls (S-B2; entity/plan r2
  "MacWorker"; ADR-0024 remote transport).

  Attributes: `id`; `tenant_id` (the enrolling kernel actor's); `binding_id`
  (the `SdrAgent.Operations.PrototypeDatabaseBinding`, by the composite
  foreign key `(binding_id, tenant_id)` → `prototype_database_bindings (id,
  tenant_id)`, RESTRICT); `token_sha256` (the SHA-256 of the worker's
  32-byte token, UNIQUE, sensitive: never in an AuditEvent after-image);
  `status` `:active` or `:disabled` (active → disabled is terminal);
  `intake` `:open` or `:paused` (the wire names); `profile_pins`, exactly the
  four string keys `profile_id`, `model_id`, `cli_version` and
  `executable_sha256`, frozen at enrolment; `enrolled_at`, `disabled_at`
  and `last_seen_at`.

  Keys: UNIQUE `token_sha256`; UNIQUE `(id, tenant_id)`, the composite
  foreign-key target of the remote-call rows; a partial UNIQUE
  `(binding_id) WHERE status = 'active'` (one active worker per binding).

  Actions:

    * `:enrol`, `:disable`, `:set_intake` — the ordinary console uses a
      kernel request carrying the
      `SdrAgent.Prototype.Checks.KernelMarker` `:mac_worker` marker;
      prototype runtime requires the fresh hosted owner and the exact
      current tenant/binding. Updates lock and reread the worker, then
      revalidate after the audit head lock shared with owner disable.
      No owner/User/run/call locks are introduced. `:enrol` generates the
      32 random token bytes, stores only their SHA-256 and returns the token
      once as the created record's `:token` metadata. `:set_intake` and
      `:disable` require an active worker. Each appends one AuditEvent
      (`mac_worker.enrolled`, `mac_worker.intake_set`,
      `mac_worker.disabled`; category `:domain_change`) through
      `SdrAgent.Audit.Changes.AppendEvent`. The partial unique index refuses
      a second active worker, without silent replacement. Pause closes new
      intake only, leaving an already-claimed call's completion/expiry path.
    * `:touch_last_seen` — internal: only inside the RemoteCalls scope
      (`SdrAgent.Agents.Checks.RemoteCallsScope`; the heartbeat), writes
      `last_seen_at` only.
    * default reads — the audit kernel or the RemoteCalls scope. The
      explicit `:owner_read` action additionally permits the current hosted
      owner's tenant/binding rows, without any one-time enrollment token.

  A trigger refuses DELETE, TRUNCATE, any update of a disabled row and any
  update of a column other than `status`, `intake`, `disabled_at` and
  `last_seen_at`.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.RemoteCallsScope
  alias SdrAgent.Audit.Changes.AppendEvent
  alias SdrAgent.Audit.Changes.Stamp
  alias SdrAgent.Audit.Changes.Transition
  alias SdrAgent.Audit.Checks
  alias SdrAgent.Operations.Changes.RecheckMacWorkerControl
  alias SdrAgent.Operations.Checks.MacWorkerControl
  alias SdrAgent.Operations.Checks.OwnerWorkerBinding
  alias SdrAgent.Prototype.Checks.OperatorAction

  @pin_keys ~w(profile_id model_id cli_version executable_sha256)
  @transitions [{:disable, [:active], :disabled}]

  postgres do
    table "mac_workers"
    repo SdrAgent.Repo

    references do
      reference :binding,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :full
    end

    check_constraints do
      check_constraint :status, "mac_workers_status",
        check: SdrAgent.Audit.SQL.one_of("status", ~w(active disabled))

      check_constraint :intake, "mac_workers_intake",
        check: SdrAgent.Audit.SQL.one_of("intake", ~w(open paused))

      check_constraint :token_sha256, "mac_workers_token_sha256_size",
        check: "octet_length(token_sha256) = 32"
    end

    custom_indexes do
      index [:binding_id],
        unique: true,
        name: "mac_workers_one_active_per_binding",
        where: "status = 'active'"
    end

    custom_statements do
      for {name, up_sql, down_sql} <-
            SdrAgent.Audit.SQL.terminal_immutable(
              "mac_workers",
              ["disabled"],
              ["status", "intake", "disabled_at", "last_seen_at"]
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

    read :owner_read do
      description "Current hosted owner's worker metadata, exact tenant and binding only."
    end

    create :enrol do
      description "S-B2: owner-run enrolment; returns the one-time token as metadata."
      accept [:binding_id, :profile_pins]
      validate {SdrAgent.Operations.MacWorker.ValidatePins, keys: @pin_keys}
      change SdrAgent.Operations.MacWorker.IssueToken
      change SdrAgent.Audit.Changes.SetTenant
      change RecheckMacWorkerControl

      change {AppendEvent, event_type: "mac_worker.enrolled", category: :domain_change}
    end

    update :disable do
      description "S-B2: owner-run; active → disabled (terminal)."
      require_atomic? false
      change get_and_lock_for_update()
      change RecheckMacWorkerControl
      change {Transition, from: [:active], to: :disabled, locked?: true}
      change {Stamp, fields: [:disabled_at]}

      change {AppendEvent,
              event_type: "mac_worker.disabled", category: :domain_change, previous: [:status]}
    end

    update :set_intake do
      description "S-B2: owner-run; opens or pauses an active worker's intake."
      require_atomic? false
      accept [:intake]
      change get_and_lock_for_update()
      change RecheckMacWorkerControl
      validate attribute_equals(:status, :active), before_action?: true

      change {AppendEvent,
              event_type: "mac_worker.intake_set", category: :domain_change, previous: [:intake]}
    end

    update :touch_last_seen do
      description "S-B2: internal (RemoteCalls heartbeat); writes last_seen_at only."
      require_atomic? false
      change {Stamp, fields: [:last_seen_at]}
    end
  end

  policies do
    policy action(:read) do
      authorize_if Checks.KernelContext
      authorize_if RemoteCallsScope
    end

    policy action(:owner_read) do
      access_type :strict
      authorize_if {OperatorAction, action: :mac_worker_control}
    end

    policy action(:owner_read) do
      authorize_if OwnerWorkerBinding
    end

    policy action([:enrol, :disable, :set_intake]) do
      authorize_if MacWorkerControl
    end

    policy action(:touch_last_seen) do
      authorize_if RemoteCallsScope
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, writable?: false, public?: true

    attribute :token_sha256, :binary,
      allow_nil?: false,
      writable?: false,
      sensitive?: true,
      public?: true

    attribute :status, :atom do
      allow_nil? false
      default :active
      writable? false
      constraints one_of: [:active, :disabled]
      public? true
    end

    attribute :intake, :atom do
      allow_nil? false
      default :open
      constraints one_of: [:open, :paused]
      public? true
    end

    attribute :profile_pins, :map, allow_nil?: false, public?: true

    attribute :enrolled_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end

    attribute :disabled_at, :utc_datetime_usec, writable?: false, public?: true
    attribute :last_seen_at, :utc_datetime_usec, writable?: false, public?: true
  end

  relationships do
    belongs_to :binding, SdrAgent.Operations.PrototypeDatabaseBinding do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_token_sha256, [:token_sha256]
    identity :unique_id_tenant, [:id, :tenant_id]
  end

  @doc "The four enrolled pin keys."
  @spec pin_keys() :: [String.t()]
  def pin_keys, do: @pin_keys

  @doc "Declared lifecycle transitions `{action, from, to}` (ADR-0010)."
  def transitions, do: @transitions
end

defmodule SdrAgent.Operations.MacWorker.ValidatePins do
  @moduledoc """
  `:enrol` validation: `profile_pins` is a map with exactly the four string
  keys of `SdrAgent.Operations.MacWorker.pin_keys/0`, each a non-empty
  string; `profile_id` names a real model profile whose `resolved_model` is
  `model_id`, and `executable_sha256` is lowercase hex SHA-256.
  """
  use Ash.Resource.Validation

  alias SdrAgent.AI.ModelProfiles

  @impl true
  def validate(changeset, opts, _context) do
    pins = Ash.Changeset.get_attribute(changeset, :profile_pins)

    if valid?(pins, opts[:keys]),
      do: :ok,
      else: {:error, field: :profile_pins, message: "are not the four enrolled pins"}
  end

  defp valid?(pins, keys) when is_map(pins) do
    Enum.sort(Map.keys(pins)) == Enum.sort(keys) and
      Enum.all?(pins, fn {_key, value} -> is_binary(value) and value != "" end) and
      pins["executable_sha256"] =~ ~r/\A[0-9a-f]{64}\z/ and
      real_profile?(pins["profile_id"], pins["model_id"])
  end

  defp valid?(_pins, _keys), do: false

  defp real_profile?(profile_id, model_id) do
    Enum.any?(ModelProfiles.real_ids(), fn id ->
      Atom.to_string(id) == profile_id and
        match?({:ok, %{resolved_model: ^model_id}}, ModelProfiles.fetch_real(id))
    end)
  end
end

defmodule SdrAgent.Operations.MacWorker.IssueToken do
  @moduledoc """
  `:enrol` change: generates the worker's 32 random token bytes, sets
  `token_sha256` to their SHA-256 and, after the insert, returns the token
  once as the created record's `:token` metadata. The token itself is never
  stored.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    token = :crypto.strong_rand_bytes(32)

    changeset
    |> Ash.Changeset.force_change_attribute(:token_sha256, :crypto.hash(:sha256, token))
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :token, token)}
    end)
  end
end
