defmodule SdrAgent.Audit.Export do
  @moduledoc "Builds signed JSON audit bundles after a fail-closed access record."

  require Ash.Query

  alias SdrAgent.Audit
  alias SdrAgent.Audit.Anchoring
  alias SdrAgent.Audit.AnchorSinkReceipt
  alias SdrAgent.Audit.AuditExport
  alias SdrAgent.Audit.AuditSigningKey
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Signing

  def build(scope, opts) do
    actor = Keyword.fetch!(opts, :actor)
    output = Keyword.fetch!(opts, :output)

    with {:ok, _access} <-
           Audit.record_access(
             :export,
             "SdrAgent.Audit.AuditEvent",
             scope.scope_ref,
             "audit export",
             actor: actor
           ),
         {:ok, export} <- request(scope, actor),
         {:ok, payloads} <- collect_payloads(actor),
         {:ok, anchor_result} <-
           Anchoring.anchor(
             trigger: :export,
             actor: Keyword.fetch!(opts, :anchor_actor),
             private_key: Keyword.fetch!(opts, :private_key),
             sinks: Keyword.get(opts, :sinks, [])
           ),
         anchor = unwrap_anchor(anchor_result),
         {:ok, events} <- Audit.list_events(actor: actor),
         {:ok, receipts} <- receipts(anchor, actor),
         {:ok, key} <- active_key(),
         {:ok, bundle, digest, signature} <-
           bundle(events, payloads, anchor, receipts, key, Keyword.fetch!(opts, :private_key)),
         :ok <- write_exclusive(output, bundle),
         {:ok, completed} <-
           complete(
             export,
             events,
             %{anchor: anchor, receipts: receipts, key: key},
             %{digest: digest, signature: signature, output: output},
             actor
           ) do
      {:ok, %{export: completed, anchor: anchor, path: output}}
    end
  end

  defp request(scope, actor) do
    attrs =
      Map.merge(scope, %{
        requested_by_type: actor_type(actor),
        requested_by_id: to_string(actor.id)
      })

    AuditExport |> Ash.Changeset.for_create(:request, attrs, actor: actor) |> Ash.create()
  end

  defp complete(export, events, evidence, artifact, actor) do
    attrs = %{
      from_sequence: List.first(events).sequence,
      to_sequence: List.last(events).sequence,
      bundle_sha256: artifact.digest,
      bundle_path: artifact.output,
      signature: artifact.signature,
      key_id: evidence.key.key_id,
      assurance_level: assurance(evidence.receipts),
      anchor_ids: [evidence.anchor.id]
    }

    export |> Ash.Changeset.for_update(:complete, attrs, actor: actor) |> Ash.update()
  end

  defp bundle(events, payloads, anchor, receipts, key, private_key) do
    payload = %{
      format: "sdr-audit-export/1",
      events: Enum.map(events, &event_map/1),
      payloads: payloads,
      anchor: anchor_map(anchor),
      sink_receipts: Enum.map(receipts, &receipt_map/1),
      signing_key: %{
        key_id: key.key_id,
        public_key: Base.encode64(key.public_key),
        status: key.status
      }
    }

    bytes = Canonical.encode!(payload)
    signature = Signing.sign(bytes, private_key)
    wrapper = Jason.encode!(%{payload: Base.encode64(bytes), signature: Base.encode64(signature)})
    {:ok, wrapper, :crypto.hash(:sha256, wrapper), signature}
  end

  defp collect_payloads(actor) do
    with {:ok, payloads} <- Audit.list_payloads(actor: actor) do
      Enum.reduce_while(payloads, {:ok, []}, fn payload, {:ok, acc} ->
        collect_payload(payload, actor, acc)
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    end
  end

  defp collect_payload(payload, actor, acc) do
    case Audit.read_content(payload.sha256, actor: actor, purpose: "audit export") do
      {:ok, content} ->
        item = %{
          sha256: Base.encode16(payload.sha256, case: :lower),
          content_type: payload.content_type,
          content: Base.encode64(content)
        }

        {:cont, {:ok, [item | acc]}}

      error ->
        {:halt, error}
    end
  end

  defp event_map(event) do
    %{
      sequence: event.sequence,
      prev_hash: Base.encode16(event.prev_hash, case: :lower),
      event_hash: Base.encode16(event.event_hash, case: :lower),
      canonical_bytes: Base.encode64(event.canonical_bytes)
    }
  end

  defp anchor_map(anchor) do
    %{
      id: anchor.id,
      from_sequence: anchor.from_sequence,
      to_sequence: anchor.to_sequence,
      head_event_hash: Base.encode16(anchor.head_event_hash, case: :lower),
      anchor_hash: Base.encode16(anchor.anchor_hash, case: :lower),
      statement: Base.encode64(anchor.statement_bytes),
      signature: Base.encode64(anchor.signature),
      key_id: anchor.key_id
    }
  end

  defp receipt_map(receipt) do
    %{
      sink: receipt.sink,
      status: receipt.status,
      receipt: receipt.receipt,
      recorded_at: receipt.recorded_at
    }
  end

  defp receipts(anchor, actor) do
    AnchorSinkReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(anchor_id == ^anchor.id)
    |> Ash.read()
  end

  defp assurance(receipts) do
    cond do
      Enum.any?(receipts, &(&1.sink == :ots and &1.status == :confirmed)) -> :ots_anchored
      Enum.any?(receipts, &(&1.sink == :git and &1.status == :confirmed)) -> :git_anchored
      true -> :signed
    end
  end

  defp active_key do
    AuditSigningKey
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.Query.filter(status == :active)
    |> Ash.read_one()
  end

  defp write_exclusive(path, bytes) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, bytes, [:binary, :exclusive]),
      do: (
        {:error, :eexist} -> {:error, :already_exists}
        result -> result
      )
  end

  defp unwrap_anchor({:existing, anchor}), do: anchor
  defp unwrap_anchor(anchor), do: anchor
  defp actor_type(%{type: type}), do: type
  defp actor_type(%{role: role}), do: role
end
