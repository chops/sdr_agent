defmodule SdrAgent.LiveEvents do
  @moduledoc """
  Commit-time notifications of audit events, for live operator views (S13;
  ADR-0012). Diagnostic plumbing only: the Postgres ledger stays the record,
  and nothing here can change or block what is written.

    * `notify/1` — called by `SdrAgent.Audit.Kernel` inside the transaction
      that appends an AuditEvent: `pg_notify` on `channel/0` with the
      event's ids and type. Postgres delivers a notification only when that
      transaction **commits** (never for a rollback), so a listener never
      hears of uncommitted state.
    * `SdrAgent.LiveEvents.Relay` — the supervised listener; it re-broadcasts
      each notification on the tenant's `Phoenix.PubSub` topic as
      `{:sdr_audit_event, event}` (`broadcast/1`).
    * `subscribe/1` — LiveViews subscribe to their scope's tenant topic and
      re-read through the domain APIs with their actor; the message carries
      no content, only `tenant_id`, `sequence`, `event_type`, `category`,
      `subject_resource`, `subject_id` (omitted when longer than 64 bytes)
      and `agent_run_id`.
  """

  alias SdrAgent.Repo

  @channel "sdr_audit_events"
  @max_subject_bytes 64

  @type event :: %{
          tenant_id: String.t(),
          sequence: integer(),
          event_type: String.t(),
          category: String.t(),
          subject_resource: String.t() | nil,
          subject_id: String.t() | nil,
          agent_run_id: String.t() | nil
        }

  @doc "The Postgres notification channel."
  @spec channel() :: String.t()
  def channel, do: @channel

  @doc "The PubSub topic of a tenant's committed audit events."
  @spec topic(String.t()) :: String.t()
  def topic(tenant_id), do: "audit_events:" <> tenant_id

  @doc "Subscribes the caller to `{:sdr_audit_event, event}` messages of `tenant_id`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(tenant_id), do: Phoenix.PubSub.subscribe(SdrAgent.PubSub, topic(tenant_id))

  @doc """
  Queues the notification of `event` (an AuditEvent) in the caller's open
  transaction; Postgres delivers it at commit. Returns `:ok` or the query error.
  """
  @spec notify(map()) :: :ok | {:error, term()}
  def notify(event) do
    payload = %{
      tenant_id: event.tenant_id,
      sequence: event.sequence,
      event_type: event.event_type,
      category: to_string(event.category),
      subject_resource: event.subject_resource,
      subject_id: short(event.subject_id),
      agent_run_id: event.agent_run_id
    }

    case Repo.query("SELECT pg_notify($1, $2)", [@channel, Jason.encode!(payload)]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Broadcasts a decoded notification (`event/1`) on its tenant topic, from
  the calling process (`broadcast_from/4`: never echoed to the caller).
  """
  @spec broadcast(event()) :: :ok | {:error, term()}
  def broadcast(%{tenant_id: tenant_id} = event) when is_binary(tenant_id) do
    Phoenix.PubSub.broadcast_from(
      SdrAgent.PubSub,
      self(),
      topic(tenant_id),
      {:sdr_audit_event, event}
    )
  end

  @doc "Decodes a notification payload into an `t:event/0`, or `:error`."
  @spec event(String.t()) :: {:ok, event()} | :error
  def event(payload) do
    case Jason.decode(payload) do
      {:ok, %{"tenant_id" => tenant_id, "event_type" => type} = map}
      when is_binary(tenant_id) and is_binary(type) ->
        {:ok,
         %{
           tenant_id: tenant_id,
           sequence: map["sequence"],
           event_type: type,
           category: map["category"],
           subject_resource: map["subject_resource"],
           subject_id: map["subject_id"],
           agent_run_id: map["agent_run_id"]
         }}

      _ ->
        :error
    end
  end

  defp short(id) when is_binary(id) and byte_size(id) <= @max_subject_bytes, do: id
  defp short(_id), do: nil
end
