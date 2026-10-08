defmodule SdrAgentWeb.DraftLive do
  @moduledoc """
  Draft review (S10a; spec §15 "human approval = capability boundary").

  Shows the draft's current immutable revision with its cited sentences
  ("click a sentence → see evidence": RevisionCitation → EvidenceClaim →
  ResearchArtifact), the revision history, the AI-vs-human diff
  (`diff_from_ai_baseline`), the approvals, and each delivery with its
  receipts and — through the audited payload read — the exact captured
  message.

  ADM and REV act through the Outreach domain with `actor: scope.user`:

    * edit → `Outreach.edit_draft/3` (a new human revision);
    * approve / reject → `Outreach.approve/3` / `Outreach.reject/3` with the
      revision id and hex content hash **rendered in the form**; if the draft
      changed after it was shown, the domain refuses the stale verdict and
      the error is displayed with the now-current revision;
    * revoke → `Outreach.revoke/2`; cancel a retry → `Outreach.cancel_retry/2`.

  The displayed revision's `risk_flags` — what the model asked a reviewer to
  check — are shown, escaped, as "Reviewer notes from the AI" (Q0.2,
  display only; approval does not depend on them).

  The UI hides these controls from the auditor, but authorization is the
  domain's: a forged event from an auditor is refused (and audited) by
  `SdrAgent.Audit.Guard` and shown as an error. An auditor's view is
  recorded with the draft id before it is served.

  Live refresh (`SdrAgentWeb.LiveRefresh`) updates approvals, deliveries,
  receipts, status and history as they commit, but never swaps the revision
  or the recipient under the reviewer: when another revision has become
  current or the recipient's email changed, the displayed revision and
  recipient — and the approve/reject binding to them — stay frozen while
  lifecycle data keeps refreshing, and a notice offers to show the latest. A
  verdict on what is displayed is then refused as stale by the domain,
  exactly as before live refresh.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Outreach
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData
  alias SdrAgentWeb.LiveRefresh
  alias SdrAgentWeb.Scope

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Draft review",
       loaded?: false,
       withheld: nil,
       not_found?: false,
       draft_id: nil,
       citation: nil,
       cited_claim: nil,
       cited_artifact: nil,
       editing?: false,
       review_error: nil,
       newer_revision?: false,
       messages: %{}
     )
     |> LiveRefresh.attach(&refresh/1)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if connected?(socket),
      do: {:noreply, socket |> assign(draft_id: id) |> load()},
      else: {:noreply, socket}
  end

  ## Loading

  # What the reviewer is reading and binding a verdict to: the revision, its
  # rendering, the recipient shown, and the forms carrying that binding.
  @frozen [
    :current,
    :segments,
    :citations,
    :diff,
    :contact,
    :approve_form,
    :reject_form,
    :edit_form,
    :page_title
  ]

  # Re-read everything (audited for an auditor). If the revision or the
  # recipient email changed, put the reviewed snapshot back: lifecycle data
  # (status, approvals, deliveries, history) stays live, the content and the
  # recipient under review do not, and the domain refuses a verdict on them
  # as stale.
  defp refresh(%{assigns: %{loaded?: true} = shown} = socket) do
    fresh = load(socket)

    if fresh.assigns.loaded? and binding_changed?(shown, fresh.assigns) do
      fresh |> assign(Map.take(shown, @frozen)) |> assign(newer_revision?: true)
    else
      fresh
    end
  end

  defp refresh(%{assigns: %{draft_id: nil}} = socket), do: socket
  defp refresh(socket), do: load(socket)

  defp binding_changed?(shown, fresh) do
    shown.current.id != fresh.current.id or
      to_string(shown.contact.email) != to_string(fresh.contact.email)
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    opts = [actor: scope.user]

    with {:ok, draft} <- fetch_draft(socket.assigns.draft_id, opts),
         {:ok, revisions} <-
           Outreach.list_records(
             Outreach.DraftRevision,
             Keyword.merge(opts, filter: [draft_id: draft.id], sort: [revision_number: :asc])
           ),
         current = Enum.find(revisions, &(&1.id == draft.current_revision_id)),
         {:ok, citations} <-
           Outreach.list_records(
             Outreach.RevisionCitation,
             Keyword.put(opts, :filter, draft_revision_id: current.id)
           ),
         {:ok, claims} <-
           Research.list_records(
             Research.EvidenceClaim,
             Keyword.put(opts, :filter, lead_id: draft.lead_id)
           ),
         {:ok, artifacts} <-
           Research.list_records(
             Research.ResearchArtifact,
             Keyword.put(opts, :filter, lead_id: draft.lead_id)
           ),
         {:ok, contact} <- Sales.fetch(Sales.Contact, draft.recipient_contact_id, opts),
         {:ok, account} <- Sales.fetch(Sales.Account, contact.account_id, opts),
         {:ok, campaign} <- Sales.fetch(Sales.Campaign, draft.campaign_id, opts),
         {:ok, step} <- Sales.fetch(Sales.SequenceStep, draft.sequence_step_id, opts),
         {:ok, approvals} <-
           Outreach.list_records(
             Outreach.Approval,
             Keyword.merge(opts,
               filter: [draft_id: draft.id],
               sort: [inserted_at: :desc, id: :asc]
             )
           ),
         {:ok, deliveries} <- deliveries(draft, opts),
         :ok <- AuditedView.record(scope, "SdrAgent.Outreach.Draft", draft.id, "draft review") do
      assign(socket,
        loaded?: true,
        withheld: nil,
        not_found?: false,
        newer_revision?: false,
        page_title: "Review · #{current.subject}",
        draft: draft,
        revisions: revisions,
        current: current,
        segments: segments(current.body_text, citations),
        citations: Map.new(citations, &{&1.id, &1}),
        claims: Map.new(claims, &{&1.id, &1}),
        artifacts: Map.new(artifacts, &{&1.id, &1}),
        diff: diff_lines(current.diff_from_ai_baseline),
        contact: contact,
        account: account,
        campaign: campaign,
        step: step,
        approvals: approvals,
        deliveries: deliveries,
        approve_form: binding_form(current, contact, :approve),
        reject_form: binding_form(current, contact, :reject),
        edit_form:
          to_form(%{"subject" => current.subject, "body_text" => current.body_text},
            as: :revision
          )
      )
    else
      {:error, :not_found} -> socket |> withhold(:not_found) |> assign(not_found?: true)
      {:error, reason} -> withhold(socket, reason)
    end
  end

  defp fetch_draft(id, opts) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         {:ok, draft} <- Outreach.fetch(Outreach.Draft, id, opts) do
      {:ok, draft}
    else
      :error -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      other -> other
    end
  end

  defp deliveries(draft, opts) do
    with {:ok, deliveries} <-
           Outreach.list_records(
             Outreach.DeliveryOperation,
             Keyword.merge(opts,
               filter: [draft_id: draft.id],
               sort: [inserted_at: :desc, id: :asc]
             )
           ) do
      Enum.reduce_while(deliveries, {:ok, []}, &with_receipts(&1, &2, opts))
    end
  end

  defp with_receipts(delivery, {:ok, acc}, opts) do
    case Outreach.list_records(
           Outreach.DeliveryReceipt,
           Keyword.put(opts, :filter, delivery_operation_id: delivery.id)
         ) do
      {:ok, receipts} -> {:cont, {:ok, acc ++ [Map.put(delivery, :receipts, receipts)]}}
      error -> {:halt, error}
    end
  end

  defp binding_form(revision, contact, name) do
    to_form(
      %{
        "draft_revision_id" => revision.id,
        "recipient_email" => to_string(contact.email),
        "content_sha256" => Base.encode16(revision.content_sha256, case: :lower),
        "reason" => ""
      },
      as: name
    )
  end

  # The body as text and cited spans (first occurrence of each citation's
  # verbatim text; overlapping citations keep the earliest).
  defp segments(body, citations) do
    spans =
      citations
      |> Enum.flat_map(fn citation ->
        case :binary.match(body, citation.text) do
          {start, len} -> [{start, len, citation}]
          :nomatch -> []
        end
      end)
      |> Enum.sort_by(fn {start, len, _} -> {start, -len} end)

    {parts, pos} =
      Enum.reduce(spans, {[], 0}, fn {start, len, citation}, {parts, pos} ->
        if start < pos do
          {parts, pos}
        else
          parts = [
            {:cite, citation, binary_part(body, start, len)},
            {:text, binary_part(body, pos, start - pos)} | parts
          ]

          {parts, start + len}
        end
      end)

    Enum.reverse([{:text, binary_part(body, pos, byte_size(body) - pos)} | parts])
  end

  defp diff_lines(nil), do: []

  defp diff_lines(diff) do
    diff
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn
      {"+" <> line, i} -> %{i: i, op: "ins", text: line}
      {"-" <> line, i} -> %{i: i, op: "del", text: line}
      {"#" <> _ = line, i} -> %{i: i, op: "note", text: line}
      {" " <> line, i} -> %{i: i, op: "eq", text: line}
      {line, i} -> %{i: i, op: "eq", text: line}
    end)
  end

  ## Events

  @impl true
  def handle_event("cite", %{"id" => id}, socket) do
    {:noreply, cite(socket, socket.assigns.citations[id])}
  end

  def handle_event("show_latest", _params, socket) do
    {:noreply, socket |> assign(editing?: false) |> cite(nil) |> load()}
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, editing?: !socket.assigns.editing?)}
  end

  def handle_event("save_edit", %{"revision" => params}, socket) do
    attrs = %{subject: params["subject"], body_text: params["body_text"]}

    socket
    |> act(fn draft, actor -> Outreach.edit_draft(draft, attrs, actor: actor) end)
    |> reply("Saved as a new revision.", editing?: false)
  end

  # The approve form carries the recipient email the page displayed; the
  # domain compares it to the locked contact (stale → refused, page reloads
  # with the current recipient). Always called, so every refusal — including
  # an auditor's forged event — is the domain's and is audited.
  def handle_event("approve", %{"approve" => params}, socket) do
    binding = %{
      draft_revision_id: params["draft_revision_id"],
      content_sha256: params["content_sha256"],
      recipient_email: params["recipient_email"]
    }

    socket
    |> act(fn draft, actor -> Outreach.approve(draft, binding, actor: actor) end)
    |> reply(
      "Approved for #{params["recipient_email"]}. The delivery is queued for local capture."
    )
  end

  def handle_event("reject", %{"reject" => params}, socket) do
    binding = %{
      draft_revision_id: params["draft_revision_id"],
      content_sha256: params["content_sha256"],
      reason: params["reason"]
    }

    socket
    |> act(fn draft, actor -> Outreach.reject(draft, binding, actor: actor) end)
    |> reply("Rejected with your reason.")
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    socket
    |> act_on(Outreach.Approval, id, &Outreach.revoke(&1, actor: &2))
    |> reply("Approval revoked; the draft is back in review.")
  end

  def handle_event("cancel_retry", %{"id" => id}, socket) do
    socket
    |> act_on(Outreach.DeliveryOperation, id, &Outreach.cancel_retry(&1, actor: &2))
    |> reply("Retry cancelled; the draft is cancelled.")
  end

  def handle_event("show_message", %{"id" => id}, socket) do
    delivery = Enum.find(socket.assigns.deliveries, &(&1.id == id))

    with %{rendered_sha256: sha} when is_binary(sha) <- delivery,
         {:ok, content} <-
           AuditedView.read_content(
             socket.assigns.current_scope,
             sha,
             "captured message of delivery #{id}"
           ) do
      {:noreply, assign(socket, messages: Map.put(socket.assigns.messages, id, content))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, AuditedView.error_message(reason))}
      _ -> {:noreply, put_flash(socket, :error, "This delivery has no captured message yet.")}
    end
  end

  defp cite(socket, nil), do: assign(socket, citation: nil, cited_claim: nil, cited_artifact: nil)

  defp cite(socket, citation) do
    claim = socket.assigns.claims[citation.evidence_claim_id]
    artifact = claim && socket.assigns.artifacts[claim.research_artifact_id]
    assign(socket, citation: citation, cited_claim: claim, cited_artifact: artifact)
  end

  defp act(socket, fun),
    do: {socket, fun.(socket.assigns.draft, socket.assigns.current_scope.user)}

  defp act_on(socket, resource, id, fun) do
    actor = socket.assigns.current_scope.user

    case Outreach.fetch(resource, id, actor: actor) do
      {:ok, record} -> {socket, fun.(record, actor)}
      error -> {socket, error}
    end
  end

  defp reply({socket, result}, message, extra \\ []) do
    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(Keyword.merge([review_error: nil], extra))
         |> cite(nil)
         |> put_flash(:info, message)
         |> load()}

      {:error, reason} ->
        error = AuditedView.error_message(reason)

        {:noreply,
         socket
         |> load()
         |> assign(review_error: error)
         |> put_flash(:error, error)}
    end
  end

  ## Rendering

  # Fail closed on every (re)load: nothing previously shown stays on screen.
  defp withhold(socket, :not_found), do: assign(socket, loaded?: false, withheld: nil)

  defp withhold(socket, reason),
    do:
      assign(socket,
        loaded?: false,
        not_found?: false,
        withheld: AuditedView.error_message(reason)
      )

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:review}>
      <.link
        navigate={~p"/review"}
        class="mb-4 inline-flex items-center gap-1 text-xs font-medium text-zinc-500 hover:text-zinc-900"
      >
        <.icon name="hero-arrow-left" class="size-3.5" /> Review queue
      </.link>

      <.empty :if={@not_found?} id="not-found" icon="hero-magnifying-glass" title="Draft not found" />
      <.empty
        :if={@withheld}
        id="withheld"
        icon="hero-lock-closed"
        title="This view could not be served"
      >
        {@withheld}
      </.empty>
      <.loading :if={!@loaded? and !@not_found? and is_nil(@withheld)} />

      <div :if={@loaded?} class="space-y-6">
        <.page_header id="draft-header" eyebrow={"#{@account.name} · #{@campaign.name}"}>
          {ConsoleData.contact_name(@contact)}
          <.badge status={@draft.status} class="ml-2 align-middle" />
          <:subtitle>
            <span class="font-mono text-xs">{to_string(@contact.email)}</span>
            · {@contact.title} · step {@step.position + 1} ({humanize(@step.channel)})
            <.link navigate={~p"/leads/#{@draft.lead_id}"} class="ml-1 text-teal-700 hover:underline">
              Lead & evidence →
            </.link>
            <.link
              :if={@current_scope.role in [:admin, :auditor]}
              id="draft-audit-link"
              navigate={~p"/audit?draft=#{@draft.id}"}
              class="ml-2 text-teal-700 hover:underline"
            >
              Audit trail →
            </.link>
          </:subtitle>
        </.page_header>

        <div
          :if={@newer_revision?}
          id="newer-revision"
          role="status"
          class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900"
        >
          <p class="flex items-start gap-2">
            <.icon name="hero-arrow-path" class="mt-0.5 size-5 shrink-0" />
            <span>
              This draft's revision or recipient changed after it was shown. A
              verdict on what you are reading will be refused as stale.
            </span>
          </p>
          <.ui_button id="show-latest-revision" size="sm" phx-click="show_latest">
            Show the latest
          </.ui_button>
        </div>

        <div
          :if={@review_error}
          id="review-error"
          role="alert"
          class="flex items-start gap-3 rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-900"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0" />
          <div>
            <p class="font-semibold">The action was refused</p>
            <p>{@review_error}</p>
            <p class="mt-1 text-xs text-rose-800/80">
              The page now shows the current revision — review it before deciding.
            </p>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-3">
          <div class="space-y-6 lg:col-span-2">
            <.card id="revision">
              <div class="mb-4 flex flex-wrap items-center justify-between gap-2">
                <p class="text-xs text-zinc-500">
                  Revision
                  <span class="font-semibold text-zinc-800">#{@current.revision_number}</span>
                  by {humanize(@current.author_type)} · <.timestamp at={@current.inserted_at} />
                </p>
                <.ui_button
                  :if={Scope.reviewer?(@current_scope) and @draft.status == :pending_review}
                  id="edit-toggle"
                  size="sm"
                  variant="ghost"
                  phx-click="toggle_edit"
                >
                  <.icon
                    name={if(@editing?, do: "hero-x-mark", else: "hero-pencil-square")}
                    class="size-4"
                  />
                  {if(@editing?, do: "Cancel edit", else: "Edit")}
                </.ui_button>
              </div>

              <div :if={!@editing?}>
                <p class="text-xs font-medium uppercase tracking-wider text-zinc-500">Subject</p>
                <h2 id="revision-subject" class="mt-1 text-lg font-semibold text-zinc-900">
                  {@current.subject}
                </h2>
                <div
                  id="revision-body"
                  class="mt-4 whitespace-pre-wrap rounded-lg border border-zinc-100 bg-zinc-50/60 p-4 text-[0.94rem] leading-7 text-zinc-800"
                  phx-no-format
                ><%= for segment <- @segments do %><%= case segment do %><% {:text, text} -> %>{text}<% {:cite, citation, text} -> %><button type="button" data-citation-id={citation.id} phx-click="cite" phx-value-id={citation.id} title="Show the evidence for this sentence" class={cite_class(citation, @citation)}>{text}</button><% end %><% end %></div>
                <p class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-500">
                  <span><span class="mr-1 inline-block h-0.5 w-4 bg-teal-500 align-middle"></span>claim — click for evidence</span>
                  <span><span class="mr-1 inline-block h-0.5 w-4 bg-sky-400 align-middle"></span>personalization</span>
                </p>
              </div>

              <section
                :if={(@current.risk_flags || []) != []}
                id="risk-flags"
                aria-labelledby="risk-flags-title"
                class="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-4"
              >
                <h3
                  id="risk-flags-title"
                  class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-amber-800"
                >
                  <.icon name="hero-flag" class="size-4" /> Reviewer notes from the AI
                </h3>
                <p class="mt-1 text-xs text-amber-700">
                  What the agent flagged for a human to check in revision #{@current.revision_number}.
                  Advisory only: it does not change what approval binds to.
                </p>
                <ul class="mt-2 list-disc space-y-1 pl-5 text-sm text-amber-900">
                  <li :for={flag <- @current.risk_flags}>{flag}</li>
                </ul>
              </section>

              <.form
                :if={@editing?}
                for={@edit_form}
                id="edit-form"
                phx-submit="save_edit"
                class="space-y-3"
              >
                <.input
                  field={@edit_form[:subject]}
                  type="text"
                  label="Subject"
                  class={input_class()}
                />
                <.input
                  field={@edit_form[:body_text]}
                  type="textarea"
                  label="Body"
                  rows="12"
                  class={[input_class(), "font-sans leading-6"]}
                />
                <p class="text-xs text-zinc-500">
                  Saving creates an immutable human revision; citations whose sentence you keep verbatim carry over.
                </p>
                <.ui_button type="submit" variant="primary" phx-disable-with="Saving…">
                  Save revision
                </.ui_button>
              </.form>
            </.card>

            <.card id="ai-diff" title="AI vs human">
              <:subtitle>Changes from the agent's proposal to this revision.</:subtitle>
              <.empty :if={@diff == []} icon="hero-cpu-chip" title="Unedited agent proposal">
                No human edits yet: this is what the agent drafted.
              </.empty>
              <pre
                :if={@diff != []}
                class="rounded-lg bg-zinc-950 py-2 font-mono text-[0.75rem] leading-6"
              ><div :for={line <- @diff} data-op={line.op} class={["whitespace-pre-wrap break-words px-3", diff_class(line.op)]}><span class="mr-2 select-none opacity-60">{diff_sign(line.op)}</span>{line.text}</div></pre>
            </.card>

            <.card id="deliveries" title="Delivery">
              <:subtitle>Local capture only — nothing leaves this machine.</:subtitle>
              <.empty :if={@deliveries == []} icon="hero-paper-airplane" title="Not approved yet">
                An approval queues exactly one delivery of the approved revision.
              </.empty>
              <div :for={delivery <- @deliveries} id={"delivery-#{delivery.id}"} class="space-y-3">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <div class="flex items-center gap-2">
                    <.badge status={delivery.state} attr="state" />
                    <span class="text-xs text-zinc-500">
                      attempt {delivery.attempt_count}/{delivery.max_attempts} · {humanize(
                        delivery.provider
                      )}
                    </span>
                  </div>
                  <div class="flex gap-2">
                    <.ui_button
                      :if={Scope.reviewer?(@current_scope) and delivery.state == :failed_retryable}
                      id={"cancel-retry-#{delivery.id}"}
                      size="sm"
                      variant="danger"
                      phx-click="cancel_retry"
                      phx-value-id={delivery.id}
                      data-confirm="Stop this delivery? The draft will be cancelled."
                    >
                      Cancel retry
                    </.ui_button>
                    <.ui_button
                      :if={delivery.rendered_sha256 && !Map.has_key?(@messages, delivery.id)}
                      id={"show-message-#{delivery.id}"}
                      size="sm"
                      phx-click="show_message"
                      phx-value-id={delivery.id}
                    >
                      <.icon name="hero-envelope-open" class="size-4" /> Captured message (recorded)
                    </.ui_button>
                  </div>
                </div>
                <dl class="grid gap-x-6 sm:grid-cols-2">
                  <.field label="Recipient">
                    <span class="font-mono text-xs">{to_string(delivery.recipient_email)}</span>
                  </.field>
                  <.field label="Requested"><.timestamp at={delivery.requested_at} /></.field>
                  <.field label="Accepted"><.timestamp at={delivery.accepted_at} /></.field>
                  <.field label="Provider message">
                    <span class="break-all font-mono text-xs">{delivery.provider_message_id || "—"}</span>
                  </.field>
                  <.field label="Revision hash">
                    <.hash value={delivery.revision_content_sha256} />
                  </.field>
                  <.field label="Rendered hash"><.hash value={delivery.rendered_sha256} /></.field>
                </dl>
                <p
                  :if={delivery.last_error}
                  class="rounded-lg bg-rose-50 px-3 py-2 font-mono text-xs text-rose-900"
                >
                  {inspect(delivery.last_error)}
                </p>
                <ul :if={delivery.receipts != []} class="space-y-1">
                  <li
                    :for={receipt <- delivery.receipts}
                    id={"receipt-#{receipt.id}"}
                    class="flex flex-wrap items-center gap-2 text-xs text-zinc-600"
                  >
                    <.badge status={receipt.kind} attr="kind" />
                    <span>{humanize(receipt.provider)}</span>
                    <.timestamp at={receipt.received_at} />
                    <.hash value={receipt.rendered_sha256} />
                  </li>
                </ul>
                <pre
                  :if={Map.has_key?(@messages, delivery.id)}
                  id={"captured-message-#{delivery.id}"}
                  class="max-h-96 overflow-auto whitespace-pre-wrap rounded-lg bg-zinc-950 p-4 font-mono text-[0.72rem] leading-relaxed text-zinc-200"
                >{@messages[delivery.id]}</pre>
              </div>
            </.card>
          </div>

          <div class="space-y-6">
            <.card id="decision" title="Decision">
              <div class="rounded-lg border border-dashed border-zinc-300 bg-zinc-50 p-3 text-xs">
                <p class="font-medium text-zinc-700">Your verdict binds exactly:</p>
                <p class="mt-1 text-zinc-600">
                  revision
                  <span id="binding-revision" class="font-semibold text-zinc-900">#{@current.revision_number}</span>
                  to
                  <span id="binding-recipient" class="font-mono font-semibold text-zinc-900">
                    {to_string(@contact.email)}
                  </span>
                </p>
                <p class="mt-1.5 text-zinc-500">content sha256</p>
                <.hash id="binding-hash" value={@current.content_sha256} full />
              </div>

              <div
                :if={Scope.reviewer?(@current_scope) and @draft.status == :pending_review}
                class="mt-4 space-y-4"
              >
                <.form for={@approve_form} id="approve-form" phx-submit="approve">
                  <.input type="hidden" field={@approve_form[:draft_revision_id]} />
                  <.input type="hidden" field={@approve_form[:content_sha256]} />
                  <.input type="hidden" field={@approve_form[:recipient_email]} />
                  <.ui_button
                    type="submit"
                    variant="primary"
                    class="w-full"
                    phx-disable-with="Approving…"
                  >
                    <.icon name="hero-check" class="size-4" />
                    Approve revision #{@current.revision_number}
                  </.ui_button>
                </.form>

                <.form for={@reject_form} id="reject-form" phx-submit="reject" class="space-y-2">
                  <.input type="hidden" field={@reject_form[:draft_revision_id]} />
                  <.input type="hidden" field={@reject_form[:content_sha256]} />
                  <.input
                    field={@reject_form[:reason]}
                    type="textarea"
                    label="Reason for rejecting"
                    rows="2"
                    required
                    class={input_class()}
                  />
                  <.ui_button
                    type="submit"
                    variant="danger"
                    class="w-full"
                    phx-disable-with="Rejecting…"
                  >
                    Reject
                  </.ui_button>
                </.form>
              </div>
              <p :if={@draft.status != :pending_review} class="mt-3 text-xs text-zinc-500">
                This draft is {humanize(@draft.status)}; no verdict is pending.
              </p>
            </.card>

            <.card id="citation-panel" title="Evidence" class="lg:sticky lg:top-6">
              <.empty
                :if={is_nil(@citation)}
                icon="hero-cursor-arrow-rays"
                title="Click an underlined sentence"
              >
                Each cited sentence is backed by an accepted evidence claim.
              </.empty>
              <div
                :if={@citation}
                data-claim-id={@citation.evidence_claim_id}
                class="space-y-3"
              >
                <div class="flex items-center gap-2">
                  <.badge status={@citation.kind} attr="kind" />
                  <span :if={@citation.confidence} class="text-xs text-zinc-500">
                    confidence {round(@citation.confidence * 100)}%
                  </span>
                </div>
                <p :if={@cited_claim} class="text-sm font-medium text-zinc-900">
                  {@cited_claim.claim}
                </p>
                <blockquote
                  :if={@cited_claim}
                  class="border-l-2 border-teal-500 bg-teal-50/50 py-2 pl-3 pr-2 text-sm italic text-zinc-700"
                >
                  {@cited_claim.quote}
                </blockquote>
                <dl :if={@cited_artifact} class="divide-y divide-zinc-100">
                  <.field label="Source">
                    <a
                      href={@cited_artifact.source_url}
                      rel="noopener noreferrer"
                      class="break-all font-mono text-xs text-teal-700 hover:underline"
                    >
                      {@cited_artifact.source_url}
                    </a>
                  </.field>
                  <.field label="Trust">{humanize(@cited_artifact.trust_level)}</.field>
                  <.field label="Freshness">{humanize(@cited_artifact.freshness)}</.field>
                </dl>
                <.link
                  :if={@cited_claim}
                  navigate={~p"/leads/#{@draft.lead_id}?claim=#{@cited_claim.id}"}
                  class="inline-flex items-center gap-1 text-xs font-medium text-teal-700 hover:underline"
                >
                  Open in the evidence drill-down →
                </.link>
              </div>
            </.card>

            <.card id="approvals" title="Approvals">
              <.empty :if={@approvals == []} icon="hero-shield-check" title="No verdicts yet" />
              <ul class="-my-1 divide-y divide-zinc-100">
                <li
                  :for={approval <- @approvals}
                  id={"approval-#{approval.id}"}
                  class="space-y-1 py-2.5"
                >
                  <div class="flex items-center justify-between gap-2">
                    <div class="flex items-center gap-2">
                      <.badge status={approval.verdict} attr="verdict" />
                      <.badge status={approval.status} />
                    </div>
                    <.ui_button
                      :if={Scope.reviewer?(@current_scope) and approval.status == :granted}
                      id={"revoke-#{approval.id}"}
                      size="sm"
                      variant="danger"
                      phx-click="revoke"
                      phx-value-id={approval.id}
                      data-confirm="Revoke this approval? Its pending delivery is cancelled."
                    >
                      Revoke
                    </.ui_button>
                  </div>
                  <p class="text-xs text-zinc-500">
                    to
                    <span
                      class="font-mono"
                      data-recipient={to_string(approval.recipient_email)}
                    >
                      {to_string(approval.recipient_email)}
                    </span>
                    · {approver_label(approval, @current_scope)} ·
                    <.timestamp at={approval.decided_at} />
                  </p>
                  <p :if={approval.reason} class="text-xs text-zinc-700">“{approval.reason}”</p>
                  <p class="text-xs text-zinc-500">
                    binds rev {revision_number(@revisions, approval.draft_revision_id)} ·
                    <.hash value={approval.revision_content_sha256} />
                  </p>
                </li>
              </ul>
            </.card>

            <.card id="revisions" title="Revisions">
              <ol class="-my-1 divide-y divide-zinc-100">
                <li
                  :for={revision <- Enum.reverse(@revisions)}
                  id={"revision-#{revision.id}"}
                  class="py-2"
                >
                  <div class="flex items-center justify-between gap-2 text-xs">
                    <span class="font-medium text-zinc-800">
                      #{revision.revision_number} · {humanize(revision.author_type)}
                      <span :if={revision.id == @current.id} class="ml-1 text-teal-700">current</span>
                    </span>
                    <.timestamp at={revision.inserted_at} class="text-zinc-500" />
                  </div>
                  <p class="mt-0.5 truncate text-xs text-zinc-500">{revision.subject}</p>
                  <.hash value={revision.content_sha256} />
                </li>
              </ol>
            </.card>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp approver_label(approval, scope) do
    if approval.approver_id == scope.user.id, do: "by you", else: "by another operator"
  end

  defp revision_number(revisions, id) do
    case Enum.find(revisions, &(&1.id == id)) do
      nil -> "?"
      revision -> "##{revision.revision_number}"
    end
  end

  defp cite_class(citation, selected) do
    [
      "rounded-sm text-left underline decoration-2 underline-offset-4 transition focus-visible:outline-2 focus-visible:outline-teal-600",
      if(citation.kind == :personalization,
        do: "decoration-sky-400 hover:bg-sky-50",
        else: "decoration-teal-500 hover:bg-teal-50"
      ),
      selected && selected.id == citation.id && "bg-teal-100"
    ]
  end

  defp input_class,
    do:
      "w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm placeholder:text-zinc-400 focus:border-teal-600 focus:outline-none focus:ring-2 focus:ring-teal-600/20"

  defp diff_class("ins"), do: "bg-emerald-950/70 text-emerald-200"
  defp diff_class("del"), do: "bg-rose-950/70 text-rose-200"
  defp diff_class("note"), do: "text-amber-300/80"
  defp diff_class(_), do: "text-zinc-400"

  defp diff_sign("ins"), do: "+"
  defp diff_sign("del"), do: "−"
  defp diff_sign(_), do: " "
end
