defmodule SdrAgent.Audit.AnchorWorker do
  @moduledoc "Oban cadence job: anchors after N events or the configured maximum interval."
  use Oban.Worker, queue: :default, max_attempts: 5, unique: [period: 60]

  require Ash.Query

  alias SdrAgent.Audit.Anchoring
  alias SdrAgent.Audit.AuditAnchor
  alias SdrAgent.Audit.Kernel

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, tenant_id} <- Kernel.singleton_tenant_id(),
         {:ok, private_key} <- private_key(),
         {:ok, head} <-
           SdrAgent.Audit.get_chain_head(actor: SdrAgent.Actor.system(:anchorer, tenant_id)),
         {:ok, latest} <- latest_anchor(tenant_id) do
      cond do
        args["force"] == true -> run_anchor(tenant_id, private_key, :interval)
        event_due?(head, latest) -> run_anchor(tenant_id, private_key, :event_count)
        interval_due?(latest) -> run_anchor(tenant_id, private_key, :interval)
        true -> :ok
      end
    end
  end

  defp run_anchor(tenant_id, private_key, trigger) do
    opts = Application.get_env(:sdr_agent, :anchor_sinks, [])

    case Anchoring.anchor(
           trigger: trigger,
           actor: SdrAgent.Actor.system(:anchorer, tenant_id),
           private_key: private_key,
           sinks: opts
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp private_key do
    case System.fetch_env("SDR_AUDIT_ANCHOR_PRIVATE_KEY") do
      {:ok, encoded} -> SdrAgent.Audit.Signing.decode_private_key(encoded)
      :error -> {:error, :audit_anchor_private_key_missing}
    end
  end

  defp latest_anchor(tenant_id) do
    AuditAnchor
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id)
    |> Ash.Query.sort(anchor_number: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
  end

  defp event_due?(head, latest) do
    count = Application.get_env(:sdr_agent, :anchor_event_count, 100)
    head.last_sequence - if(latest, do: latest.to_sequence, else: 0) >= count
  end

  defp interval_due?(nil), do: true

  defp interval_due?(latest) do
    seconds = Application.get_env(:sdr_agent, :anchor_interval_seconds, 900)
    DateTime.diff(SdrAgent.Clock.utc_now(), latest.inserted_at, :second) >= seconds
  end
end
