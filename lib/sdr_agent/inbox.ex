defmodule SdrAgent.Inbox do
  @moduledoc """
  Stateless Home metadata projection (ADR-0015, C1-02). A freshly validated
  human session reads two fixed source-owned, SQL-bounded producers and
  three exact scalar metrics. Partial reads remain explicit; no error
  becomes zero or a stale capability. Bodies, model output and Payloads
  are not read. Auditor views get one bounded post-read audit append.

  `refresh/2` accepts a user-token string and only `limit: 1..50` and an
  opaque `cursor:`. Actor/tenant are never request options. Test faults
  exist only in compile-time test-seam builds. This module has no process,
  persistence or command authority; source actions remain authoritative.
  Capabilities are advisory metadata, not approval/delivery promises. Edit
  and retry remain blocked while their atomic C1-03 adapters are absent.
  """

  alias SdrAgent.Accounts
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Clock
  alias SdrAgent.Inbox.AuditRef
  alias SdrAgent.Inbox.Cursor
  alias SdrAgent.Operations
  alias SdrAgent.Outreach
  alias SdrAgent.ReadDeadline

  @test_seams Application.compile_env(:sdr_agent, :claude_cli_test_seams, false)
  @metrics [:pending_email_drafts, :live_failures, :local_captures_this_week]

  @doc "Read a new bounded, authorized page; authentication precedes all request validation."
  def refresh(token, opts \\ []) do
    with {:ok, actor} <- session(token),
         :ok <- options(opts),
         {:ok, secret} <- signing_secret(),
         {:ok, cursor} <- Cursor.decode(Keyword.get(opts, :cursor), actor, secret) do
      observed = Clock.utc_now()
      window = week(observed)
      fault = Keyword.get(opts, :test_fault)
      drafts = read(:draft_list, fault, fn -> Outreach.list_inbox_drafts(actor, cursor) end)

      failures =
        read(:failure_list, fault, fn -> Operations.list_inbox_failures(actor, cursor) end)

      counts = %{
        pending_email_drafts:
          read(:pending_email_drafts, fault, fn -> Outreach.count_inbox_drafts(actor: actor) end),
        live_failures:
          read(:live_failures, fault, fn -> Operations.count_inbox_failures(actor: actor) end),
        local_captures_this_week:
          read(:local_captures_this_week, fault, fn ->
            Outreach.count_inbox_captures(window, actor: actor)
          end)
      }

      page = page(actor, opts, observed, window, drafts, failures, counts, secret)
      audit_page(page, actor, fault, secret)
    end
  end

  defp session(token) do
    case Accounts.current_operator(token) do
      {:ok, actor} -> {:ok, actor}
      :error -> {:error, :forbidden}
    end
  end

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:limit, :cursor, :test_fault])) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         is_integer(Keyword.get(opts, :limit, 50)) and Keyword.get(opts, :limit, 50) in 1..50 do
      fault_option(opts)
    else
      {:error, :invalid_input}
    end
  end

  defp options(_), do: {:error, :invalid_input}

  if @test_seams do
    defp fault_option(opts) do
      if not Keyword.has_key?(opts, :test_fault) or
           Keyword.get(opts, :test_fault) in SdrAgent.Inbox.TestFaults.selectors(),
         do: :ok,
         else: {:error, :invalid_input}
    end

    defp source_call(source, fault, fun), do: SdrAgent.Inbox.TestFaults.run(fault, source, fun)
  else
    defp fault_option(opts) do
      if Keyword.has_key?(opts, :test_fault), do: {:error, :invalid_input}, else: :ok
    end

    defp source_call(_source, _fault, fun), do: fun.()
  end

  defp read(source, fault, fun) do
    case source_call(source, fault, fun) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, ReadDeadline.classify(error)}
      _ -> {:error, :producer_error}
    end
  rescue
    error -> {:error, ReadDeadline.classify(error)}
  catch
    _kind, _reason -> {:error, :producer_error}
  end

  defp page(actor, opts, observed, window, drafts, failures, counts, secret) do
    rows =
      Enum.map(values(drafts), &draft_item(&1, actor, observed, secret)) ++
        Enum.map(values(failures), &failure_item(&1, actor, observed, secret))

    sorted = Enum.sort_by(rows, & &1.sort_key)
    limit = Keyword.get(opts, :limit, 50)
    items = Enum.take(sorted, limit)
    next = if length(sorted) > limit, do: Cursor.encode(actor, List.last(items).sort_key, secret)
    results = %{draft_list: drafts, failure_list: failures} |> Map.merge(counts)

    errors =
      for {source, {:error, reason}} <- Enum.sort(results),
          do: %{source: source, reason: reason}

    totals =
      Map.new(@metrics, fn metric ->
        result = metric_result(metric, counts[metric], drafts, failures)
        {metric, total(metric, result, actor, window, secret)}
      end)

    %{
      items: items,
      totals: totals,
      next_cursor: next,
      observed_at: observed,
      completeness: if(errors == [], do: :complete, else: :partial),
      errors: errors
    }
  end

  defp values({:ok, rows}), do: rows
  defp values({:error, _}), do: []

  defp metric_result(:pending_email_drafts, _, {:error, _} = error, _), do: error
  defp metric_result(:live_failures, _, _, {:error, _} = error), do: error
  defp metric_result(_, count, _, _), do: count

  defp total(metric, result, actor, window, secret) do
    base = %{
      metric: metric,
      observed_at: Clock.utc_now(),
      scope_fingerprint: scope_fingerprint(actor, secret)
    }

    base =
      if metric == :local_captures_this_week,
        do: Map.merge(base, Map.put(window, :timezone, "America/Denver")),
        else: base

    case result do
      {:ok, value} when is_integer(value) and value >= 0 ->
        Map.merge(base, %{status: :ready, value: value, reason: nil})

      {:error, reason} ->
        Map.merge(base, %{status: :unavailable, value: nil, reason: reason})
    end
  end

  defp draft_item(
         %{
           draft: draft,
           revision: rev,
           contact: contact,
           campaign: campaign,
           suppression_refs: suppression_refs
         },
         actor,
         now,
         secret
       ) do
    producer = :outreach_drafts
    kind = :draft_review
    identity = {actor.tenant_id, producer, kind, draft.id, :email}

    facts = {
      draft.status,
      rev.id,
      hex(rev.content_sha256),
      contact.id,
      to_string(contact.email),
      contact.status,
      campaign.status,
      suppression_refs
    }

    block =
      cond do
        actor.role == :auditor -> :actor_not_permitted
        contact.status != :active -> :recipient_inactive
        suppression_refs != [] -> :recipient_suppressed
        campaign.status in [:completed, :archived] -> :campaign_closed
        true -> nil
      end

    %{
      id: fingerprint({:item, identity}, secret),
      kind: kind,
      producer: producer,
      subject_ref: %{resource: "SdrAgent.Outreach.Draft", id: draft.id},
      revision_ref: %{
        id: rev.id,
        number: rev.revision_number,
        content_sha256: hex(rev.content_sha256)
      },
      channel: :email,
      recipient_binding: %{id: contact.id, email: to_string(contact.email)},
      freshness_token: fingerprint({:freshness, identity, facts}, secret),
      observed_at: now,
      summary: String.slice(rev.subject, 0, 200),
      actions: [
        action(:inspect, "Inspect", nil, %{resource: "SdrAgent.Outreach.Draft", id: draft.id}),
        action(:edit_draft, "Edit", actor_block(actor) || :guard_not_available),
        action(:approve_capture, "Approve for capture", block),
        action(:reject_draft, "Reject", actor_block(actor))
      ],
      blocked_reasons: if(block, do: [block], else: []),
      sort_key: Cursor.key(1, draft.inserted_at, Atom.to_string(producer), draft.id)
    }
  end

  defp failure_item(failure, actor, now, secret) do
    producer = :operations_failures
    kind = :failure_attention
    identity = {actor.tenant_id, producer, kind, failure.id, nil}

    facts =
      Map.take(failure, [
        :status,
        :acknowledged_at,
        :resolved_at,
        :class,
        :severity,
        :subject_resource,
        :subject_id,
        :operation_id,
        :retryable
      ])

    retry =
      if failure.subject_resource == "SdrAgent.Agents.AgentRun",
        do: [action(:retry_run, "Review run recovery", :guard_not_available)],
        else: []

    %{
      id: fingerprint({:item, identity}, secret),
      kind: kind,
      producer: producer,
      subject_ref: %{resource: "SdrAgent.Operations.Failure", id: failure.id},
      revision_ref: nil,
      channel: nil,
      recipient_binding: nil,
      freshness_token: fingerprint({:freshness, identity, facts}, secret),
      observed_at: now,
      summary: String.slice(failure.message, 0, 240),
      actions:
        [
          action(:inspect, "Inspect", nil, %{
            resource: "SdrAgent.Operations.Failure",
            id: failure.id
          }),
          action(:acknowledge_failure, "Acknowledge", acknowledgment_block(failure, actor)),
          action(:resolve_failure, "Resolve with note", actor_block(actor))
        ] ++ retry,
      blocked_reasons: if(retry == [], do: [], else: [:guard_not_available]),
      sort_key:
        Cursor.key(
          if(failure.severity == :critical, do: 0, else: 1),
          failure.occurred_at,
          Atom.to_string(producer),
          failure.id
        )
    }
  end

  defp action(id, label, block, target \\ nil) do
    %{
      action_id: id,
      label: label,
      availability: if(block, do: :blocked, else: :enabled),
      blocked_reason: block,
      target_ref: target
    }
  end

  defp actor_block(%{role: :auditor}), do: :actor_not_permitted
  defp actor_block(_), do: nil
  defp acknowledgment_block(%{status: :acknowledged}, _), do: :guard_not_available
  defp acknowledgment_block(_, actor), do: actor_block(actor)

  defp audit_page(page, %{role: :auditor} = actor, fault, secret) do
    reference = %{
      version: "c1-inbox-view/1",
      scope: scope_fingerprint(actor, secret),
      shown: Enum.map(page.items, &%{producer: &1.producer, id: &1.subject_ref.id}),
      metrics:
        Enum.map(@metrics, fn metric ->
          page.totals[metric] |> Map.delete(:observed_at)
        end)
    }

    with {:ok, encoded} <- AuditRef.encode(reference),
         {:ok, _} <-
           read(:audit_append, fault, fn -> append_access(actor, encoded) end) do
      {:ok, page}
    else
      _ -> {:error, :audit_unavailable}
    end
  end

  defp audit_page(page, _, _, _), do: {:ok, page}

  defp append_access(actor, encoded) do
    ReadDeadline.run([actor: actor], fn _ ->
      Audit.record_access(:record_view, "SdrAgent.Inbox", encoded, "Home metadata refresh",
        actor: actor
      )
    end)
  end

  defp week(now) do
    local = DateTime.shift_zone!(now, "America/Denver", Tz.TimeZoneDatabase)
    monday = local |> DateTime.to_date() |> Date.beginning_of_week(:monday)

    %{
      week_start_utc: monday_boundary(monday),
      next_week_start_utc: monday_boundary(Date.add(monday, 7))
    }
  end

  defp monday_boundary(date) do
    date
    |> DateTime.new!(~T[00:00:00.000000], "America/Denver", Tz.TimeZoneDatabase)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp scope_fingerprint(actor, secret), do: fingerprint({:scope, Cursor.scope(actor)}, secret)

  # A configuration key, not a runtime call into the web endpoint. Resolve
  # once per authenticated request and share it with cursor + freshness.
  defp signing_secret do
    config = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])

    case config[:secret_key_base] do
      secret when is_binary(secret) and byte_size(secret) >= 20 -> {:ok, secret}
      _ -> {:error, :producer_error}
    end
  end

  defp fingerprint(term, secret) do
    :crypto.mac(:hmac, :sha256, secret, Canonical.encode!({"c1-inbox/1", term})) |> hex()
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
