defmodule SdrAgent.Agents.ClaimNonce do
  @moduledoc """
  Nonce-to-call idempotency of the remote claim (S-B2; entity/plan r2
  "ClaimNonce"; r4a C2). Immutable.

  Attributes: `tenant_id`; `worker_id` (the composite `(worker_id,
  tenant_id)` → `mac_workers (id, tenant_id)`); `claim_nonce` (16..128
  characters of `[A-Za-z0-9_-]`); `call_id` (nullable; the composite
  `(call_id, tenant_id)` → `remote_model_calls (id, tenant_id)`, MATCH
  SIMPLE); `created_at`. The primary key is `(worker_id, claim_nonce)`.

  Inserted only in the claim transaction of
  `SdrAgent.Agents.RemoteCalls.claim/3`, with the call it bound or null
  when the claim found no candidate (the nonce is then spent). `call_id` is
  never updated, so a nonce never acquires a different call. `:insert` and
  the reads authorize only inside the RemoteCalls scope
  (`SdrAgent.Agents.Checks.RemoteCallsScope`). No AuditEvent (the bound
  call's `remote_call.claimed` event records the claim). A trigger refuses
  UPDATE, DELETE and TRUNCATE.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.RemoteCallsScope

  @nonce ~r/\A[A-Za-z0-9_-]{16,128}\z/

  postgres do
    table "claim_nonces"
    repo SdrAgent.Repo

    references do
      reference :worker,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :full

      reference :call,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :simple
    end

    check_constraints do
      check_constraint :claim_nonce, "claim_nonces_format",
        check: "claim_nonce ~ '^[A-Za-z0-9_-]{16,128}$'"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("claim_nonces") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  actions do
    defaults [:read]

    create :insert do
      description "S-B2: spends a claim nonce, bound to its call or to none."
      accept [:worker_id, :claim_nonce, :call_id]
      change SdrAgent.Audit.Changes.SetTenant
    end
  end

  policies do
    policy always() do
      authorize_if RemoteCallsScope
    end
  end

  attributes do
    attribute :tenant_id, :uuid, allow_nil?: false, writable?: false, public?: true

    attribute :claim_nonce, :string do
      primary_key? true
      allow_nil? false
      constraints match: @nonce
      public? true
    end

    attribute :created_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :worker, SdrAgent.Operations.MacWorker do
      primary_key? true
      allow_nil? false
      attribute_writable? true
      public? true
    end

    belongs_to :call, SdrAgent.Agents.RemoteModelCall do
      attribute_writable? true
      public? true
    end
  end

  @doc "Whether `nonce` is a well-formed claim nonce."
  @spec valid?(term()) :: boolean()
  def valid?(nonce), do: is_binary(nonce) and nonce =~ @nonce
end
