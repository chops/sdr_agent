defmodule SdrAgent.Outreach.Inbox do
  @moduledoc """
  Source-owned Home reads: SQL-bounded Draft metadata and scalar authorized
  Draft/capture counts. Missing required context is an error, never reduced
  successful membership. Bodies/model outputs are not selected. The current
  synthetic-only boundary and immutable result-release gate remain closed.
  """

  import Ash.Expr, only: [expr: 1]

  require Ash.Query

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Audit.GuardedCall
  alias SdrAgent.Outreach.DeliveryOperation
  alias SdrAgent.Outreach.Draft
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Outreach.Suppression
  alias SdrAgent.Outreach.SuppressionMatch
  alias SdrAgent.ReadDeadline
  alias SdrAgent.Sales.Campaign
  alias SdrAgent.Sales.Contact
  alias SdrAgent.Sales.SequenceStep
  alias SdrAgent.Sales.Synthetic

  @draft_fields [
    :id,
    :tenant_id,
    :status,
    :inserted_at,
    :current_revision_id,
    :recipient_contact_id,
    :campaign_id,
    :sequence_step_id,
    :enrollment_id,
    :lead_id
  ]
  @revision_fields [
    :id,
    :tenant_id,
    :draft_id,
    :revision_number,
    :content_sha256,
    :subject,
    :risk_flags,
    :author_type,
    :model_invocation_id,
    :ai_baseline_revision_id
  ]
  @label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  # SQL equivalent of Synthetic.reserved_email?/1: bounded valid domain
  # labels and the same reserved suffixes. List metadata checks use the
  # existing Elixir guard as well; no real-data enable setting is invented.
  @reserved_email "^[^[:space:]@]+@(?=.{1,253}$)(?:(?:#{@label}\\.)*example\\.(?:com|net|org)|(?:#{@label}\\.)+(?:test|example|invalid))$"

  @doc "At most 51 policy-authorized email Drafts with bounded selected context."
  def list(actor, cursor) do
    with :ok <- ReadDeadline.operator(actor),
         {:ok, drafts} <-
           actor
           |> base()
           |> Ash.Query.select(@draft_fields)
           |> after_cursor(cursor)
           |> Ash.Query.sort(inserted_at: :asc, id: :asc)
           |> Ash.Query.limit(51)
           |> Ash.Query.load(context_loads(actor))
           |> Ash.read() do
      with {:ok, suppressions} <- suppressions(drafts, actor) do
        project(drafts, actor, suppressions)
      end
    end
  end

  @doc "One aggregate statement checks exact pending membership, integrity and withholding."
  def count_drafts(opts) do
    ReadDeadline.run(opts, fn timeout ->
      actor = Keyword.fetch!(opts, :actor)
      %{invalid: invalid, withheld: withheld} = count_guards(actor)

      actor
      |> base()
      |> Ash.aggregate(
        [
          {:total, :count},
          {:invalid, :sum,
           expr: expr(if(^invalid, do: 1, else: 0)), expr_type: :integer, default: 0},
          {:withheld, :sum,
           expr: expr(if(^withheld, do: 1, else: 0)), expr_type: :integer, default: 0}
        ],
        timeout: timeout,
        authorize?: true,
        authorize_fields?: true
      )
      |> count_result()
    end)
  end

  @doc "Pure metadata guard expressions, shared by the count and its protected-field inventory."
  def count_guards(actor) do
    %{invalid: invalid_context(actor.tenant_id), withheld: withheld_context(actor)}
  end

  @doc "Committed logical capture operations in a validated half-open UTC local-week window."
  def count_captures(window, opts) do
    with :ok <- window(window) do
      ReadDeadline.run(opts, fn timeout ->
        %{week_start_utc: first, next_week_start_utc: last} = window

        DeliveryOperation
        |> GuardedCall.read_query(actor: Keyword.fetch!(opts, :actor))
        |> Ash.Query.filter(
          provider == :capture and accepted_at >= ^first and accepted_at < ^last
        )
        |> Ash.count(timeout: timeout)
      end)
    end
  end

  defp base(actor) do
    Draft
    |> GuardedCall.read_query(actor: actor, action: :review_queue)
    |> Ash.Query.unset(:sort)
    |> Ash.Query.filter(
      not exists(sequence_step, true) or exists(sequence_step, channel == :email)
    )
  end

  defp invalid_context(tenant_id) do
    current_model = missing_model([:current_revision], tenant_id)
    baseline_model = missing_model([:current_revision, :ai_baseline_revision], tenant_id)
    baseline = invalid_baseline(tenant_id)

    expr(
      not exists(current_revision, draft_id == parent(id) and tenant_id == ^tenant_id) or
        not exists(recipient_contact, tenant_id == ^tenant_id) or
        not exists(campaign, tenant_id == ^tenant_id) or
        not exists(sequence_step, tenant_id == ^tenant_id) or
        ^baseline or
        ^current_model or ^baseline_model
    )
  end

  defp invalid_baseline(tenant_id) do
    expr(
      exists(
        current_revision,
        not is_nil(ai_baseline_revision_id) and
          not exists(
            ai_baseline_revision,
            draft_id == parent(draft_id) and tenant_id == ^tenant_id
          )
      )
    )
  end

  defp missing_model(path, tenant_id) do
    expr(
      exists(
        ^path,
        not is_nil(model_invocation_id) and
          not exists(model_invocation, tenant_id == ^tenant_id)
      )
    )
  end

  defp withheld_context(actor) do
    current = gated_model([:current_revision, :model_invocation], actor)
    baseline = gated_model([:current_revision, :ai_baseline_revision, :model_invocation], actor)

    expr(
      exists(recipient_contact, not fragment("?::text ~* ?", email, ^@reserved_email)) or
        ^current or ^baseline
    )
  end

  # Reviewer has no ModelResultRelease read policy. Conservatively withhold
  # gated output rather than making a kernel read or extending that policy.
  defp gated_model(path, %{role: :reviewer}) do
    expr(exists(^path, ledger_generation == 2 and provider == :claude_cli))
  end

  defp gated_model(path, actor) do
    tenant_id = actor.tenant_id

    expr(
      exists(
        ^path,
        ledger_generation == 2 and provider == :claude_cli and
          not exists(result_release, tenant_id == ^tenant_id and disposition == :released)
      )
    )
  end

  defp count_result({:ok, %{invalid: n}}) when n > 0, do: {:error, :producer_error}
  defp count_result({:ok, %{withheld: n}}) when n > 0, do: {:error, :withheld}
  defp count_result({:ok, %{total: total}}), do: {:ok, total}
  defp count_result(error), do: error

  defp context_loads(actor) do
    revision =
      DraftRevision
      |> selected(@revision_fields, actor)
      |> Ash.Query.load(
        model_invocation: invocation(actor),
        ai_baseline_revision:
          DraftRevision
          |> selected([:id, :tenant_id, :draft_id, :model_invocation_id], actor)
          |> Ash.Query.load(model_invocation: invocation(actor))
      )

    [
      current_revision: revision,
      recipient_contact: selected(Contact, [:id, :tenant_id, :email, :status], actor),
      campaign: selected(Campaign, [:id, :tenant_id, :status], actor),
      sequence_step: selected(SequenceStep, [:id, :tenant_id, :channel], actor)
    ]
  end

  defp invocation(actor) do
    query = selected(ModelInvocation, [:id, :tenant_id, :ledger_generation, :provider], actor)

    if actor.role == :reviewer do
      query
    else
      Ash.Query.load(query,
        result_release:
          selected(
            ModelResultRelease,
            [:id, :tenant_id, :disposition, :model_invocation_id],
            actor
          )
      )
    end
  end

  defp selected(resource, fields, actor) do
    resource |> GuardedCall.read_query(actor: actor) |> Ash.Query.select(fields)
  end

  # Each of the <=51 candidates supplies at most an exact email and domain.
  # Suppression's unique (tenant, scope, value) identity bounds this one join
  # to <=102 rows. The actor's current source read policy still applies.
  defp suppressions([], _actor), do: {:ok, []}

  defp suppressions(drafts, actor) do
    emails =
      for %{recipient_contact: %Contact{email: email}} <- drafts,
          do: SuppressionMatch.normalize(email)

    Suppression
    |> selected([:id, :scope, :value], actor)
    |> Ash.Query.filter(^SuppressionMatch.batch_filter(Enum.uniq(emails)))
    |> Ash.Query.limit(102)
    |> Ash.read()
  end

  defp project(drafts, actor, suppressions) do
    Enum.reduce_while(drafts, {:ok, []}, fn draft, {:ok, acc} ->
      case context(draft, actor) do
        {:ok, row} ->
          refs = suppression_refs(row.contact, suppressions)
          {:cont, {:ok, [Map.put(row, :suppression_refs, refs) | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp suppression_refs(contact, suppressions) do
    suppressions
    |> Enum.filter(&SuppressionMatch.covers?(&1, contact.email))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp context(draft, actor) do
    with %DraftRevision{draft_id: id} = revision <- draft.current_revision,
         true <- id == draft.id or {:error, :producer_error},
         %Contact{} = contact <- draft.recipient_contact,
         %Campaign{} = campaign <- draft.campaign,
         %SequenceStep{channel: :email} <- draft.sequence_step,
         true <- Synthetic.reserved_email?(to_string(contact.email)),
         :ok <- model_reference(revision, actor),
         :ok <- baseline_visible(revision, actor) do
      {:ok, %{draft: draft, revision: revision, contact: contact, campaign: campaign}}
    else
      false -> {:error, :withheld}
      {:error, _} = error -> error
      _ -> {:error, :producer_error}
    end
  end

  defp baseline_visible(%{ai_baseline_revision_id: nil, ai_baseline_revision: nil}, _), do: :ok

  defp baseline_visible(
         %{
           draft_id: draft_id,
           ai_baseline_revision_id: id,
           ai_baseline_revision: %DraftRevision{id: id, draft_id: draft_id} = baseline
         },
         actor
       ),
       do: model_reference(baseline, actor)

  defp baseline_visible(_, _), do: {:error, :producer_error}

  defp model_reference(%{model_invocation_id: nil, model_invocation: nil}, _), do: :ok

  defp model_reference(
         %{model_invocation_id: id, model_invocation: %ModelInvocation{id: id} = inv},
         actor
       ),
       do: model_visible(inv, actor)

  defp model_reference(_, _), do: {:error, :producer_error}

  defp model_visible(%ModelInvocation{ledger_generation: 2, provider: :claude_cli} = inv, actor) do
    if actor.role != :reviewer and
         match?(%ModelResultRelease{disposition: :released}, inv.result_release),
       do: :ok,
       else: {:error, :withheld}
  end

  defp model_visible(%ModelInvocation{}, _), do: :ok

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, {0, _, _, _}), do: query

  defp after_cursor(query, {1, instant, producer, id}) do
    time = DateTime.from_unix!(instant, :microsecond)
    equal_producer = producer == "outreach_drafts"
    later_producer = "outreach_drafts" > producer

    Ash.Query.filter(
      query,
      inserted_at > ^time or
        (inserted_at == ^time and (^later_producer or (^equal_producer and id > ^id)))
    )
  end

  defp window(%{
         week_start_utc: %DateTime{time_zone: "Etc/UTC"} = first,
         next_week_start_utc: %DateTime{time_zone: "Etc/UTC"} = last
       }) do
    seconds = DateTime.diff(last, first, :second)
    if seconds in (167 * 3_600)..(169 * 3_600), do: :ok, else: {:error, :invalid_input}
  end

  defp window(_), do: {:error, :invalid_input}
end
