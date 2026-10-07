defmodule SdrAgent.Audit.Export do
  @moduledoc "Builds signed JSON audit bundles after a fail-closed access record."

  require Ash.Query

  alias SdrAgent.Audit
  alias SdrAgent.Audit.Anchoring
  alias SdrAgent.Audit.AnchorSinkReceipt
  alias SdrAgent.Audit.AuditAnchor
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
         {:ok, export} <- request(scope, actor) do
      finish(do_build(export, scope, output, actor, opts), export, actor)
    end
  end

  defp finish({:ok, _} = result, _export, _actor), do: result

  defp finish({:error, reason} = error, export, actor) do
    case fail(export, reason, actor) do
      {:ok, _} -> error
      {:error, failure} -> {:error, {:export_and_terminalization_failed, reason, failure}}
    end
  end

  defp do_build(export, scope, output, actor, opts) do
    with {:ok, output} <- safe_output(output, Keyword.get(opts, :output_root, File.cwd!())),
         {:ok, anchor_result} <-
           Anchoring.anchor(
             trigger: :export,
             actor: Keyword.fetch!(opts, :anchor_actor),
             private_key: Keyword.fetch!(opts, :private_key),
             sinks: Keyword.get(opts, :sinks, [])
           ),
         anchor = unwrap_anchor(anchor_result),
         {:ok, all_events} <- Audit.list_events(actor: actor),
         {:ok, events} <- select_events(all_events, scope),
         {:ok, payloads} <- collect_payloads(events, actor),
         {:ok, anchors} <- anchors(anchor, actor),
         {:ok, receipts} <- receipts(anchors, actor),
         {:ok, key} <- active_key(),
         {:ok, bundle, digest, signature} <-
           bundle(
             %{
               scope: scope,
               events: events,
               chain_index: Enum.map(all_events, &chain_entry/1),
               payloads: payloads,
               anchor: anchor,
               anchors: anchors,
               receipts: receipts,
               key: key
             },
             Keyword.fetch!(opts, :private_key)
           ),
         {:ok, completed} <-
           persist_bundle(
             export,
             events,
             %{anchors: anchors, receipts: receipts, key: key},
             %{bundle: bundle, digest: digest, signature: signature, output: output},
             actor
           ) do
      {:ok, %{export: completed, anchor: anchor, path: output}}
    end
  end

  defp persist_bundle(export, events, evidence, artifact, actor) do
    with :ok <- write_exclusive(artifact.output, artifact.bundle) do
      case complete(export, events, evidence, artifact, actor) do
        {:ok, _} = result ->
          result

        error ->
          File.rm(artifact.output)
          error
      end
    end
  end

  defp fail(export, reason, actor) do
    export
    |> Ash.Changeset.for_update(:fail, %{failure_reason: inspect(reason, limit: 10)},
      actor: actor
    )
    |> Ash.update()
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
    current_anchor_id = List.last(evidence.anchors).id
    current_receipts = Enum.filter(evidence.receipts, &(&1.anchor_id == current_anchor_id))

    attrs = %{
      from_sequence: List.first(events).sequence,
      to_sequence: List.last(events).sequence,
      bundle_sha256: artifact.digest,
      bundle_path: artifact.output,
      signature: artifact.signature,
      key_id: evidence.key.key_id,
      assurance_level: assurance(current_receipts),
      anchor_ids: Enum.map(evidence.anchors, & &1.id)
    }

    export |> Ash.Changeset.for_update(:complete, attrs, actor: actor) |> Ash.update()
  end

  defp bundle(data, private_key) do
    if Signing.matches?(private_key, data.key.public_key) do
      build_bundle(data, private_key)
    else
      {:error, :private_key_does_not_match_active_key}
    end
  end

  defp build_bundle(data, private_key) do
    payload = %{
      format: "sdr-audit-export/1",
      scope: data.scope,
      events: Enum.map(data.events, &event_map/1),
      chain_index: data.chain_index,
      payloads: data.payloads,
      anchor: anchor_map(data.anchor),
      anchors: Enum.map(data.anchors, &anchor_map/1),
      sink_receipts: Enum.map(data.receipts, &receipt_map/1),
      signing_key: %{
        key_id: data.key.key_id,
        public_key: Base.encode64(data.key.public_key),
        status: data.key.status,
        revoked_at: data.key.revoked_at
      }
    }

    bytes = Canonical.encode!(payload)
    signature = Signing.sign(bytes, private_key)
    wrapper = Jason.encode!(%{payload: Base.encode64(bytes), signature: Base.encode64(signature)})
    {:ok, wrapper, :crypto.hash(:sha256, wrapper), signature}
  end

  defp collect_payloads(events, actor) do
    referenced = referenced_payload_hashes(events)

    with {:ok, payloads} <- Audit.list_payloads(actor: actor) do
      payloads
      |> Enum.filter(&(Base.encode16(&1.sha256, case: :lower) in referenced))
      |> Enum.reduce_while({:ok, []}, fn payload, {:ok, acc} ->
        collect_payload(payload, actor, acc)
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    end
  end

  defp referenced_payload_hashes(events) do
    events
    |> Enum.flat_map(fn event -> collect_hashes(event.payload) end)
    |> MapSet.new()
  end

  defp collect_hashes(value) when is_map(value),
    do: Enum.flat_map(value, fn {key, item} -> collect_hashes(key) ++ collect_hashes(item) end)

  defp collect_hashes(value) when is_list(value), do: Enum.flat_map(value, &collect_hashes/1)

  defp collect_hashes(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, value), do: [String.downcase(value)], else: []
  end

  defp collect_hashes(_), do: []

  defp select_events(events, %{scope: :sequence_range, scope_ref: ref}) do
    with [from, to] <- String.split(ref, ":", parts: 2),
         {from, ""} when from >= 1 <- Integer.parse(from),
         {:ok, to} <- parse_to(to, events),
         true <- to >= from do
      nonempty(events, &(&1.sequence >= from and &1.sequence <= to))
    else
      _ -> {:error, :invalid_sequence_range}
    end
  end

  defp select_events(events, %{scope: :agent_run, scope_ref: ref}),
    do: nonempty(events, &(to_string(&1.agent_run_id) == ref))

  defp select_events(events, %{scope: scope, scope_ref: ref}) when scope in [:lead, :draft],
    do: nonempty(events, &(&1.subject_id == ref and subject_scope?(&1.subject_resource, scope)))

  defp select_events(_events, _scope), do: {:error, :invalid_export_scope}

  defp parse_to("latest", events), do: {:ok, List.last(events).sequence}

  defp parse_to(value, _events) do
    case Integer.parse(value) do
      {number, ""} when number >= 1 -> {:ok, number}
      _ -> {:error, :invalid_sequence_range}
    end
  end

  defp nonempty(events, predicate) do
    case Enum.filter(events, predicate) do
      [] -> {:error, :empty_export_scope}
      selected -> {:ok, selected}
    end
  end

  defp subject_scope?(resource, scope) when is_binary(resource) do
    resource |> String.downcase() |> String.ends_with?(Atom.to_string(scope))
  end

  defp subject_scope?(_, _), do: false

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

  defp chain_entry(event) do
    %{
      sequence: event.sequence,
      prev_hash: Base.encode16(event.prev_hash, case: :lower),
      event_hash: Base.encode16(event.event_hash, case: :lower)
    }
  end

  defp anchor_map(anchor) do
    %{
      id: anchor.id,
      tenant_id: anchor.tenant_id,
      anchor_number: anchor.anchor_number,
      from_sequence: anchor.from_sequence,
      to_sequence: anchor.to_sequence,
      head_event_hash: Base.encode16(anchor.head_event_hash, case: :lower),
      prior_anchor_hash:
        anchor.prior_anchor_hash && Base.encode16(anchor.prior_anchor_hash, case: :lower),
      anchor_hash: Base.encode16(anchor.anchor_hash, case: :lower),
      statement: Base.encode64(anchor.statement_bytes),
      signature: Base.encode64(anchor.signature),
      key_id: anchor.key_id,
      key_status_at_signing: anchor.key_status_at_signing,
      canonicalization_version: anchor.canonicalization_version,
      sdr_agent_git_sha: anchor.sdr_agent_git_sha,
      trigger: anchor.trigger,
      inserted_at: anchor.inserted_at
    }
  end

  defp receipt_map(receipt) do
    %{
      anchor_id: receipt.anchor_id,
      sink: receipt.sink,
      status: receipt.status,
      receipt: receipt.receipt,
      recorded_at: receipt.recorded_at
    }
  end

  defp receipts(anchors, actor) do
    ids = Enum.map(anchors, & &1.id)

    AnchorSinkReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(anchor_id in ^ids)
    |> Ash.read()
  end

  defp anchors(anchor, actor) do
    AuditAnchor
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(tenant_id == ^anchor.tenant_id and anchor_number <= ^anchor.anchor_number)
    |> Ash.Query.sort(anchor_number: :asc)
    |> Ash.read()
  end

  defp assurance(receipts) do
    cond do
      Enum.any?(receipts, &confirmed_ots?/1) -> :ots_anchored
      Enum.any?(receipts, &confirmed_git?/1) -> :git_anchored
      true -> :signed
    end
  end

  defp confirmed_ots?(receipt) do
    receipt.sink == :ots and receipt.status == :confirmed and
      receipt_value(receipt.receipt, :bitcoin_attested) == true
  end

  defp confirmed_git?(receipt) do
    receipt.sink == :git and receipt.status == :confirmed and
      receipt_value(receipt.receipt, :repository) ==
        "git@github.com:chops/sdr_agent-audit-anchors.git" and
      sha1?(receipt_value(receipt.receipt, :commit_id)) and
      sha1?(receipt_value(receipt.receipt, :blob_id))
  end

  defp receipt_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp sha1?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)

  defp active_key do
    AuditSigningKey
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.Query.filter(status == :active)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :no_active_signing_key}
      result -> result
    end
  end

  defp write_exclusive(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      result = with :ok <- File.chmod(path, 0o600), do: IO.binwrite(io, bytes)
      File.close(io)
      if result != :ok, do: File.rm(path)
      result
    else
      {:error, :eexist} -> {:error, :already_exists}
      error -> error
    end
  end

  defp safe_output(path, root) do
    root = Path.expand(root)
    path = Path.expand(path, root)

    if path != root and String.starts_with?(path, root <> "/") and no_symlinks?(path, root),
      do: {:ok, path},
      else: {:error, :output_outside_allowed_root}
  end

  defp no_symlinks?(root, root), do: true

  defp no_symlinks?(path, root) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> false
      {:ok, _} -> no_symlinks?(Path.dirname(path), root)
      {:error, :enoent} -> no_symlinks?(Path.dirname(path), root)
      _ -> false
    end
  end

  defp unwrap_anchor({:existing, anchor}), do: anchor
  defp unwrap_anchor(anchor), do: anchor
  defp actor_type(%{type: type}), do: type
  defp actor_type(%{role: role}), do: role
end
