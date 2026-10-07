defmodule SdrAgent.Operations.Changes.AppendDuplicate do
  @moduledoc """
  WebhookEvent `:receive`: when the upsert found an existing valid event
  with the same provider and external id (marked `:sdr_replayed` by
  `SdrAgent.Research.Changes.MarkExisting`), no row was inserted; this
  appends `webhook.duplicate_ignored` naming the original event and the
  duplicate request's body hash and signed timestamp (S2 WebhookEvent: "A
  duplicate valid event inserts no row: it appends webhook.duplicate_ignored
  referencing the original"). Must come after `MarkExisting`.
  """
  use Ash.Resource.Change

  alias SdrAgent.Audit.Kernel

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, event ->
      if Ash.Resource.get_metadata(event, :sdr_replayed),
        do: append(changeset, event, context.actor),
        else: {:ok, event}
    end)
  end

  defp append(changeset, event, actor) do
    signed_at = Ash.Changeset.get_attribute(changeset, :signed_timestamp)

    attrs = %{
      event_type: "webhook.duplicate_ignored",
      category: :domain_change,
      subject_resource: inspect(changeset.resource),
      subject_id: event.id,
      action: "receive",
      payload: %{
        "external_event_id" => event.external_event_id,
        "duplicate_raw_body_sha256" =>
          changeset |> Ash.Changeset.get_attribute(:raw_body_sha256) |> hex(),
        "duplicate_signed_timestamp" => signed_at && DateTime.to_iso8601(signed_at)
      }
    }

    case Kernel.append(attrs, actor: actor, tenant_id: event.tenant_id) do
      {:ok, _} -> {:ok, event}
      error -> error
    end
  end

  defp hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
  defp hex(_), do: nil
end
