defmodule SdrAgent.Agents.RemoteCallResult do
  @moduledoc """
  The first accepted transcript of a remote call (S-B2; entity/plan r2
  "RemoteCallResult"; Codex review 2bddc465 must_fix 1). Immutable and
  restricted.

  Attributes: `call_id` (the primary key: one result per call; the
  composite `(call_id, tenant_id)` → `remote_model_calls (id, tenant_id)`);
  `id` (equal to `call_id`, the AuditEvent subject); `tenant_id`;
  `transcript` (the raw stream-json bytes, at most 2097152, sensitive:
  never in an AuditEvent after-image); `transcript_sha256` and `byte_size`
  (computed here, never caller input); `received_at`.

  `:store` is reached only from `SdrAgent.Agents.RemoteCalls.complete/5`
  inside the RemoteCalls scope (`SdrAgent.Agents.Checks.RemoteCallsScope`)
  and appends one AuditEvent `remote_call.result_stored` (ids, digest and
  size only). The default read is the domain-private metadata read in the
  RemoteCalls scope (duplicate versus conflict), whose `transcript` field
  stays forbidden in S-B2 (`%Ash.ForbiddenField{}`); every external or
  unscoped read is Forbidden, auditors included. The audit kernel's
  integrity read (`SdrAgent.Audit.Kernel.integrity_opts/1`) is the only
  reader of the bytes under the default action, to hash the stored row.
  S-B3 adds its separate internal settlement read. S-B5's explicit
  `:owner_transcript` read and field policy require RemoteTranscripts'
  exact private process/transaction/actor/call scope. That API revalidates
  the current owner after the audit-head lock and records access before
  returning bytes after commit. Direct named-action reads grant nothing.
  A trigger refuses UPDATE, DELETE and TRUNCATE.
  """
  use Ash.Resource,
    otp_app: :sdr_agent,
    domain: SdrAgent.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SdrAgent.Agents.Checks.HostedTranscriptScope
  alias SdrAgent.Agents.Checks.RemoteCallsScope
  alias SdrAgent.Audit.Checks.IntegrityRead

  @max_bytes 2_097_152

  postgres do
    table "remote_call_results"
    repo SdrAgent.Repo

    references do
      reference :call,
        on_delete: :restrict,
        match_with: [tenant_id: :tenant_id],
        match_type: :full
    end

    check_constraints do
      check_constraint :byte_size, "remote_call_results_byte_size",
        check: "byte_size = octet_length(transcript) AND byte_size <= #{@max_bytes}"
    end

    custom_statements do
      for {name, up_sql, down_sql} <- SdrAgent.Audit.SQL.append_only("remote_call_results") do
        statement name do
          up up_sql
          down down_sql
        end
      end
    end
  end

  field_policies do
    field_policy :transcript do
      authorize_if IntegrityRead
      authorize_if HostedTranscriptScope
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    read :owner_transcript do
      description "Audited owner diagnostics, exact private reader scope only."
      argument :call_id, :uuid
      filter expr(call_id == ^arg(:call_id) and tenant_id == ^actor(:tenant_id))
    end

    create :store do
      description "S-B2: the first accepted transcript of a claimed call."
      accept [:call_id, :transcript]
      change SdrAgent.Agents.RemoteCallResult.Digest
      change SdrAgent.Audit.Changes.SetTenant

      change {SdrAgent.Audit.Changes.AppendEvent,
              event_type: "remote_call.result_stored", category: :domain_change}
    end
  end

  policies do
    policy action(:read) do
      authorize_if RemoteCallsScope
      authorize_if IntegrityRead
    end

    policy action(:owner_transcript) do
      access_type :strict
      authorize_if HostedTranscriptScope
    end

    policy action(:store) do
      authorize_if RemoteCallsScope
    end
  end

  attributes do
    attribute :id, :uuid, allow_nil?: false, writable?: false, public?: true
    attribute :tenant_id, :uuid, allow_nil?: false, writable?: false, public?: true

    attribute :transcript, :binary, allow_nil?: false, sensitive?: true, public?: true

    attribute :transcript_sha256, :binary, allow_nil?: false, writable?: false, public?: true

    attribute :byte_size, :integer,
      allow_nil?: false,
      writable?: false,
      public?: true,
      constraints: [min: 0, max: @max_bytes]

    attribute :received_at, :utc_datetime_usec do
      allow_nil? false
      writable? false
      default &SdrAgent.Clock.utc_now/0
      public? true
    end
  end

  relationships do
    belongs_to :call, SdrAgent.Agents.RemoteModelCall do
      primary_key? true
      allow_nil? false
      attribute_writable? true
      public? true
    end
  end

  @doc "The transcript cap in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes
end

defmodule SdrAgent.Agents.RemoteCallResult.Digest do
  @moduledoc """
  `RemoteCallResult :store` change: `transcript_sha256` and `byte_size` are
  computed from the stored bytes on the server, and `id` is the call's id.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    transcript = Ash.Changeset.get_attribute(changeset, :transcript)

    if is_binary(transcript) do
      changeset
      |> Ash.Changeset.force_change_attribute(
        :id,
        Ash.Changeset.get_attribute(changeset, :call_id)
      )
      |> Ash.Changeset.force_change_attribute(
        :transcript_sha256,
        :crypto.hash(:sha256, transcript)
      )
      |> Ash.Changeset.force_change_attribute(:byte_size, byte_size(transcript))
    else
      changeset
    end
  end
end
