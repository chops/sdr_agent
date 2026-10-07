defmodule SdrAgent.Audit.Anchoring do
  @moduledoc "Serializes, signs, persists and publishes S11 audit anchors."

  require Ash.Query

  alias SdrAgent.Audit.AnchorStatement
  alias SdrAgent.Audit.AuditAnchor
  alias SdrAgent.Audit.AuditEvent
  alias SdrAgent.Audit.AuditSigningKey
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.Audit.Signing

  @doc "Creates the next anchor, or returns the latest one when the range is empty."
  def anchor(opts) do
    actor = Keyword.fetch!(opts, :actor)
    private_key = Keyword.fetch!(opts, :private_key)
    trigger = Keyword.fetch!(opts, :trigger)

    case Kernel.in_transaction(fn -> create_locked(actor, private_key, trigger, opts) end) do
      {:ok, result} -> publish(result, actor, Keyword.get(opts, :sinks, []))
      error -> error
    end
  end

  defp create_locked(actor, private_key, trigger, opts) do
    tenant_id = actor.tenant_id

    with {:ok, head} <- Kernel.lock_head(tenant_id),
         {:ok, prior} <- latest_anchor(tenant_id) do
      if prior && no_anchorable_events?(tenant_id, prior.to_sequence) do
        {:ok, {:existing, prior}}
      else
        create_anchor(actor, private_key, trigger, opts, head, prior, tenant_id)
      end
    end
  end

  defp no_anchorable_events?(tenant_id, after_sequence) do
    AuditEvent
    |> Ash.Query.for_read(:read, %{}, Kernel.opts(tenant_id))
    |> Ash.Query.filter(tenant_id == ^tenant_id and sequence > ^after_sequence)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!()
    |> Enum.all?(&String.starts_with?(&1.event_type, "audit.anchor."))
  end

  defp create_anchor(actor, private_key, trigger, opts, head, prior, tenant_id) do
    with {:ok, key} <- active_key(),
         {:ok, git_sha} <- git_sha(opts) do
      attrs = %{
        tenant_id: tenant_id,
        anchor_number: if(prior, do: prior.anchor_number + 1, else: 1),
        from_sequence: if(prior, do: prior.to_sequence + 1, else: 1),
        to_sequence: head.last_sequence,
        head_event_hash: head.last_event_hash,
        prior_anchor_id: prior && prior.id,
        prior_anchor_hash: prior && prior.anchor_hash,
        canonicalization_version: Canonical.version(),
        sdr_agent_git_sha: git_sha,
        trigger: trigger,
        key_id: key.key_id,
        key_status_at_signing: key.status
      }

      statement = AnchorStatement.encode!(attrs)

      attrs
      |> Map.merge(%{
        statement_bytes: statement,
        anchor_hash: AnchorStatement.hash(statement),
        signature: Signing.sign(statement, private_key)
      })
      |> then(&Ash.Changeset.for_create(AuditAnchor, :record, &1, actor: actor))
      |> Ash.create()
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

  defp git_sha(opts) do
    case Keyword.fetch(opts, :sdr_agent_git_sha) do
      {:ok, sha} ->
        {:ok, sha}

      :error ->
        case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
          {sha, 0} -> {:ok, String.trim(sha)}
          {_output, status} -> {:error, {:git_sha, status}}
        end
    end
  end

  defp publish({:existing, _} = result, _actor, _sinks), do: {:ok, result}

  defp publish(anchor, _actor, []) when is_struct(anchor, AuditAnchor), do: {:ok, anchor}

  defp publish(anchor, actor, sinks) do
    Enum.reduce_while(sinks, {:ok, anchor}, fn {sink_name, module, sink_opts}, _acc ->
      opts = Keyword.put(sink_opts, :anchor_number, anchor.anchor_number)

      case module.publish(sink_payload(sink_name, anchor), opts) do
        {:ok, receipt} ->
          attrs = %{
            tenant_id: anchor.tenant_id,
            anchor_id: anchor.id,
            sink: sink_name,
            status: receipt.status,
            receipt: json_safe(receipt)
          }

          record_receipt(attrs, actor, anchor)

        error ->
          {:halt, error}
      end
    end)
  end

  defp sink_payload(:ots, anchor), do: anchor.anchor_hash
  defp sink_payload(_sink, anchor), do: anchor.statement_bytes

  @doc "Upgrades the newest pending OTS proof by appending a confirmed receipt."
  def upgrade_ots(anchor, opts) do
    actor = Keyword.fetch!(opts, :actor)
    sink = Keyword.get(opts, :sink, SdrAgent.Audit.AnchorSinks.OpenTimestampsSink)

    with {:ok, receipt} <- pending_ots(anchor, actor),
         {:ok, proof} <- receipt.receipt |> map_value(:proof) |> Base.decode64(),
         {:ok, upgraded} <-
           sink.upgrade(proof, anchor.anchor_hash, Keyword.get(opts, :sink_options, [])) do
      SdrAgent.Audit.AnchorSinkReceipt
      |> Ash.Changeset.for_create(
        :record,
        %{
          tenant_id: anchor.tenant_id,
          anchor_id: anchor.id,
          sink: :ots,
          status: :confirmed,
          receipt: json_safe(upgraded)
        },
        actor: actor
      )
      |> Ash.create()
    end
  end

  defp pending_ots(anchor, actor) do
    SdrAgent.Audit.AnchorSinkReceipt
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(anchor_id == ^anchor.id and sink == :ots and status == :pending)
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :no_pending_ots_proof}
      result -> result
    end
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp record_receipt(attrs, actor, anchor) do
    case SdrAgent.Audit.AnchorSinkReceipt
         |> Ash.Changeset.for_create(:record, attrs, actor: actor)
         |> Ash.create() do
      {:ok, _} -> {:cont, {:ok, anchor}}
      error -> {:halt, error}
    end
  end

  @doc "Verifies statement hash, signature and current signing-key semantics; records access first."
  def verify(anchor, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, _} <-
           SdrAgent.Audit.record_access(
             :record_view,
             inspect(AuditAnchor),
             anchor.id,
             "verify anchor",
             actor: actor
           ),
         {:ok, key} <- key_by_id(anchor.key_id) do
      signature? =
        AnchorStatement.hash(anchor.statement_bytes) == anchor.anchor_hash and
          Signing.verify(anchor.statement_bytes, anchor.signature, key.public_key)

      issues = if key.status == :revoked, do: [:signing_key_revoked], else: []

      {:ok,
       %{
         valid?: signature? and issues == [],
         issues: issues,
         assurance_level: if(signature?, do: :signed, else: :chain_verified)
       }}
    end
  end

  defp key_by_id(key_id) do
    AuditSigningKey
    |> Ash.Query.for_read(:read, %{}, Kernel.opts())
    |> Ash.Query.filter(key_id == ^key_id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :unknown_signing_key}
      result -> result
    end
  end

  defp json_safe(map) do
    Map.new(map, fn
      {key, value} when is_binary(value) -> {key, Base.encode64(value)}
      pair -> pair
    end)
  end
end
