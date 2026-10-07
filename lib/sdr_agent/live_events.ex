defmodule SdrAgent.LiveEvents do
  @moduledoc """
  Commit-time notifications of audit events, for live operator views (S13;
  ADR-0012). The Postgres ledger stays the record; a notification carries no
  content and never changes what is written.

  Failure coupling (ADR-0012, accepted): `notify/1` runs in the append's
  transaction, so if `pg_notify` failed the append would roll back with it.
  The payload is therefore bounded by construction — ids and short,
  safe-charset typed fields only, each dropped (never truncated) when it does
  not fit — so its encoded size stays under `max_payload_bytes/0`, far below
  Postgres' 8000-byte NOTIFY limit, whatever the event's own fields hold.

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
      no content, only `tenant_id`, `sequence`, and — when short and plain
      (`[A-Za-z0-9_.:-]`) — `event_type`, `category`, `subject_resource`,
      `subject_id` and `agent_run_id`; any other value is sent as `nil`.
  """

  alias SdrAgent.Repo

  @channel "sdr_audit_events"
  @max_payload_bytes 512
  @plain ~r/\A[A-Za-z0-9_.:\-]+\z/
  # Field caps (bytes). With the fixed keys and JSON punctuation the encoded
  # payload stays below @max_payload_bytes: no capped field needs escaping.
  @caps %{
    tenant_id: 36,
    event_type: 80,
    category: 24,
    subject_resource: 96,
    subject_id: 64,
    agent_run_id: 36
  }

  @type event :: %{
          tenant_id: String.t(),
          sequence: integer(),
          event_type: String.t() | nil,
          category: String.t() | nil,
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

  @doc "Upper bound of an encoded notification payload, in bytes."
  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc """
  Queues the notification of `event` (an AuditEvent) in the caller's open
  transaction; Postgres delivers it at commit. Returns `:ok` or the query error.
  """
  @spec notify(map()) :: :ok | {:error, term()}
  def notify(event) do
    case Repo.query("SELECT pg_notify($1, $2)", [@channel, payload(event)]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  The encoded notification of `event`: ids and short plain fields only, at
  most `max_payload_bytes/0` bytes. A field that is too long or not plain is
  `null`, never truncated.
  """
  @spec payload(map()) :: String.t()
  def payload(event) do
    fields =
      Map.new(@caps, fn {key, cap} -> {key, plain(Map.get(event, key), cap)} end)
      |> Map.put(:sequence, sequence(Map.get(event, :sequence)))

    encoded = Jason.encode!(fields)

    # Unreachable by construction; kept so a future field can never exceed
    # the bound silently.
    if byte_size(encoded) <= @max_payload_bytes,
      do: encoded,
      else: Jason.encode!(%{tenant_id: fields.tenant_id, sequence: fields.sequence})
  end

  defp plain(value, cap) when is_atom(value) and not is_nil(value),
    do: plain(Atom.to_string(value), cap)

  defp plain(value, cap) when is_binary(value) and byte_size(value) <= cap do
    if Regex.match?(@plain, value), do: value
  end

  defp plain(_value, _cap), do: nil

  defp sequence(n) when is_integer(n) and n >= 0 and n < 1_000_000_000_000_000, do: n
  defp sequence(_n), do: nil

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
      {:ok, %{"tenant_id" => tenant_id} = map} when is_binary(tenant_id) ->
        {:ok,
         %{
           tenant_id: tenant_id,
           sequence: map["sequence"],
           event_type: map["event_type"],
           category: map["category"],
           subject_resource: map["subject_resource"],
           subject_id: map["subject_id"],
           agent_run_id: map["agent_run_id"]
         }}

      _ ->
        :error
    end
  end
end
