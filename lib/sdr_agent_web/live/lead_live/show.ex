defmodule SdrAgentWeb.LeadLive.Show do
  @moduledoc """
  Lead detail (S10a): the contact and account, the current qualification
  (criteria verdicts, score, confidence, reason and the evidence claims it
  cites), the research evidence drill-down — each ResearchArtifact with its
  EvidenceClaims; selecting a claim (`?claim=`) shows its quote and source,
  and the full source content is fetched only through the audited payload
  read (`SdrAgent.Audit.read_content/2`) with the quoted span highlighted —
  and the lead's drafts. When a draft is `pending_review` (the newest, if
  several), a call to action under the header links to it (Q0.3): "Open
  draft" for ADM and REV, "View draft" for an auditor. It is only a link;
  approval stays on the draft page and its revision binding.

  ADM and REV may assign a new lead to the agent (`SdrAgent.SDR.assign_lead/2`
  with the active campaign); any refusal (e.g. an auditor's forged event) is
  the domain's, audited by `SdrAgent.Audit.Guard`, and shown as an error.
  An auditor's view is recorded with the lead id before it is served. The
  agent's progress (runs, evidence, qualification, drafts) appears live
  (`SdrAgentWeb.LiveRefresh`).
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Outreach
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData
  alias SdrAgentWeb.LiveRefresh
  alias SdrAgentWeb.Scope

  @criteria [:company_size, :industry, :geography, :persona, :trigger]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Lead",
       loaded?: false,
       withheld: nil,
       not_found?: false,
       lead_id: nil,
       claim_id: nil,
       source: nil,
       criteria: @criteria
     )
     |> LiveRefresh.attach(&refresh/1)}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    socket = assign(socket, claim_id: params["claim"])

    cond do
      not connected?(socket) -> {:noreply, socket}
      socket.assigns.loaded? and socket.assigns.lead_id == id -> {:noreply, select_claim(socket)}
      true -> {:noreply, socket |> assign(lead_id: id, source: nil) |> load(id) |> select_claim()}
    end
  end

  defp refresh(%{assigns: %{lead_id: nil}} = socket), do: socket
  defp refresh(socket), do: socket |> load(socket.assigns.lead_id) |> select_claim()

  defp load(socket, id) do
    scope = socket.assigns.current_scope
    opts = [actor: scope.user]

    with {:ok, lead} <- fetch_lead(id, opts),
         {:ok, contact} <- Sales.fetch(Sales.Contact, lead.contact_id, opts),
         {:ok, account} <- Sales.fetch(Sales.Account, lead.account_id, opts),
         {:ok, qualification} <- Research.current_qualification(lead.id, opts),
         {:ok, cited} <- cited_claim_ids(qualification, opts),
         {:ok, artifacts} <-
           Research.list_records(
             Research.ResearchArtifact,
             Keyword.merge(opts, filter: [lead_id: lead.id], sort: [retrieved_at: :asc, id: :asc])
           ),
         {:ok, claims} <-
           Research.list_records(
             Research.EvidenceClaim,
             Keyword.put(opts, :filter, lead_id: lead.id)
           ),
         {:ok, drafts} <-
           Outreach.list_records(
             Outreach.Draft,
             Keyword.merge(opts, filter: [lead_id: lead.id], sort: [inserted_at: :desc, id: :asc])
           ),
         {:ok, revisions} <- ConsoleData.current_revisions(scope, drafts),
         {:ok, runs} <- SdrAgent.Agents.list_runs(Keyword.put(opts, :lead_id, id)),
         :ok <-
           AuditedView.record(scope, "SdrAgent.Sales.Lead", lead.id, "lead detail and evidence") do
      assign(socket,
        loaded?: true,
        withheld: nil,
        not_found?: false,
        page_title: ConsoleData.contact_name(contact),
        lead: lead,
        contact: contact,
        account: account,
        qualification: qualification,
        cited: cited,
        artifacts: artifacts,
        claims_by_artifact: Enum.group_by(claims, & &1.research_artifact_id),
        claims: Map.new(claims, &{&1.id, &1}),
        drafts: drafts,
        pending_draft: Enum.find(drafts, &(&1.status == :pending_review)),
        revisions: revisions,
        runs: runs
      )
    else
      {:error, :not_found} ->
        socket |> withhold(:not_found) |> assign(not_found?: true)

      {:error, reason} ->
        withhold(socket, reason)
    end
  end

  defp fetch_lead(id, opts) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         {:ok, lead} <- Sales.fetch(Sales.Lead, id, opts) do
      {:ok, lead}
    else
      :error -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      other -> other
    end
  end

  defp cited_claim_ids(nil, _opts), do: {:ok, []}

  defp cited_claim_ids(qualification, opts) do
    with {:ok, links} <-
           Research.list_records(
             Research.QualificationEvidence,
             Keyword.put(opts, :filter, qualification_id: qualification.id)
           ) do
      {:ok, Enum.map(links, & &1.evidence_claim_id)}
    end
  end

  defp select_claim(%{assigns: %{loaded?: true}} = socket) do
    claim = socket.assigns.claim_id && socket.assigns.claims[socket.assigns.claim_id]

    artifact =
      claim && Enum.find(socket.assigns.artifacts, &(&1.id == claim.research_artifact_id))

    source =
      if claim && socket.assigns.source && socket.assigns.source.claim_id == claim.id,
        do: socket.assigns.source

    assign(socket, selected: claim, selected_artifact: artifact, source: source)
  end

  defp select_claim(socket), do: assign(socket, selected: nil, selected_artifact: nil)

  @impl true
  def handle_event("show_source", _params, %{assigns: %{selected: claim}} = socket)
      when not is_nil(claim) do
    artifact = socket.assigns.selected_artifact

    case AuditedView.read_content(
           socket.assigns.current_scope,
           artifact.content_sha256,
           "evidence drill-down for claim #{claim.id}"
         ) do
      {:ok, content} ->
        {:noreply, assign(socket, source: highlight(content, claim))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AuditedView.error_message(reason))}
    end
  end

  def handle_event("assign", _params, socket) do
    scope = socket.assigns.current_scope
    lead = socket.assigns.lead

    with {:ok, campaign} <- active_campaign(scope),
         {:ok, _assignment} <-
           SdrAgent.SDR.assign_lead(lead, actor: scope.user, campaign_id: campaign.id) do
      {:noreply,
       socket
       |> put_flash(:info, "Lead assigned — the agent run is queued.")
       |> assign(loaded?: false)
       |> load(lead.id)
       |> select_claim()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, AuditedView.error_message(reason))}
    end
  end

  defp active_campaign(scope) do
    case Sales.list_records(Sales.Campaign, filter: [status: :active], actor: scope.user) do
      {:ok, [campaign | _]} -> {:ok, campaign}
      {:ok, []} -> {:error, :no_active_campaign}
      error -> error
    end
  end

  defp highlight(content, claim) do
    %{char_start: from, char_end: to} = claim.source_location
    codepoints = String.codepoints(content)

    %{
      claim_id: claim.id,
      before: codepoints |> Enum.take(from) |> Enum.join(),
      quote: codepoints |> Enum.slice(from, to - from) |> Enum.join(),
      after: codepoints |> Enum.drop(to) |> Enum.join()
    }
  end

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
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:leads}>
      <.link
        navigate={~p"/leads"}
        class="mb-4 inline-flex items-center gap-1 text-xs font-medium text-zinc-500 hover:text-zinc-900"
      >
        <.icon name="hero-arrow-left" class="size-3.5" /> All leads
      </.link>

      <.empty :if={@not_found?} id="not-found" icon="hero-magnifying-glass" title="Lead not found">
        It does not exist in your tenant.
      </.empty>
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
        <.page_header id="lead-header" eyebrow={@account.name}>
          {ConsoleData.contact_name(@contact)}
          <.badge status={@lead.status} class="ml-2 align-middle" />
          <:subtitle>
            {@contact.title} · <span class="font-mono text-xs">{to_string(@contact.email)}</span>
            <span :if={@lead.status_reason} class="block text-xs text-zinc-500">
              {@lead.status_reason}
            </span>
          </:subtitle>
          <:actions>
            <.ui_button
              :if={Scope.reviewer?(@current_scope) and @lead.status == :new}
              id="assign-lead"
              variant="primary"
              phx-click="assign"
              phx-disable-with="Assigning…"
            >
              <.icon name="hero-sparkles" class="size-4" /> Assign to agent
            </.ui_button>
          </:actions>
        </.page_header>

        <div
          :if={@pending_draft}
          id="draft-awaiting-review"
          class="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 shadow-sm"
        >
          <div class="flex min-w-0 items-center gap-3">
            <span class="flex size-9 shrink-0 items-center justify-center rounded-full bg-amber-100 text-amber-700">
              <.icon name="hero-envelope-open" class="size-5" />
            </span>
            <div class="min-w-0">
              <p class="text-sm font-semibold text-amber-900">Draft awaiting review</p>
              <p class="truncate text-xs text-amber-800">
                {(@revisions[@pending_draft.current_revision_id] &&
                    @revisions[@pending_draft.current_revision_id].subject) ||
                  "The agent handed off a draft for human review."}
              </p>
            </div>
          </div>
          <.link
            id="open-pending-draft"
            navigate={~p"/drafts/#{@pending_draft.id}"}
            class="inline-flex items-center gap-1.5 rounded-lg bg-amber-600 px-3 py-1.5 text-sm font-semibold text-white shadow-sm transition hover:bg-amber-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-amber-600"
          >
            {if Scope.reviewer?(@current_scope), do: "Open draft", else: "View draft"}
            <.icon name="hero-arrow-right" class="size-4" />
          </.link>
        </div>

        <div class="grid gap-6 lg:grid-cols-3">
          <div class="space-y-6 lg:col-span-2">
            <.card id="qualification" title="Qualification">
              <:subtitle :if={@qualification}>
                {humanize(@qualification.source)} · <.timestamp at={@qualification.inserted_at} />
              </:subtitle>
              <.empty :if={is_nil(@qualification)} icon="hero-scale" title="Not qualified yet">
                The agent records a qualification once research completes.
              </.empty>
              <div :if={@qualification} class="space-y-4">
                <div class="flex flex-wrap items-center gap-4">
                  <span
                    data-qualified={to_string(@qualification.qualified)}
                    class={[
                      "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-semibold",
                      if(@qualification.qualified,
                        do: "bg-emerald-50 text-emerald-800",
                        else: "bg-rose-50 text-rose-800"
                      )
                    ]}
                  >
                    <.icon
                      name={
                        if(@qualification.qualified, do: "hero-check-badge", else: "hero-x-circle")
                      }
                      class="size-5"
                    />
                    {if(@qualification.qualified, do: "Qualified", else: "Disqualified")}
                  </span>
                  <div class="text-sm">
                    <span class="text-zinc-500">Score</span>
                    <span id="qualification-score" class="ml-1 text-lg font-semibold tabular-nums">
                      {@qualification.score}
                    </span>
                    <span class="text-zinc-400">/100</span>
                  </div>
                  <div :if={@qualification.confidence} class="text-sm text-zinc-500">
                    confidence {Float.round(@qualification.confidence * 100, 0) |> trunc()}%
                  </div>
                </div>
                <p class="text-sm leading-relaxed text-zinc-700">{@qualification.reason}</p>
                <div class="grid grid-cols-2 gap-2 sm:grid-cols-5">
                  <div
                    :for={criterion <- @criteria}
                    class="rounded-lg border border-zinc-100 bg-zinc-50/60 px-3 py-2"
                  >
                    <p class="text-[0.68rem] uppercase tracking-wider text-zinc-500">
                      {humanize(criterion)}
                    </p>
                    <.badge
                      status={Map.get(@qualification.criteria, criterion)}
                      attr="verdict"
                      class="mt-1"
                    />
                  </div>
                </div>
                <div id="qualification-evidence">
                  <p class="mb-2 text-xs font-medium uppercase tracking-wider text-zinc-500">
                    Cited evidence
                  </p>
                  <ul class="space-y-1.5">
                    <li :for={claim_id <- @cited}>
                      <.link
                        patch={~p"/leads/#{@lead.id}?claim=#{claim_id}"}
                        class="group flex items-start gap-2 text-sm text-zinc-700 hover:text-teal-800"
                      >
                        <.icon name="hero-link" class="mt-0.5 size-4 shrink-0 text-teal-600" />
                        <span class="group-hover:underline">
                          {(@claims[claim_id] && @claims[claim_id].claim) || claim_id}
                        </span>
                      </.link>
                    </li>
                  </ul>
                </div>
              </div>
            </.card>

            <.card id="research" title="Research evidence">
              <:subtitle>Sources the agent retrieved and the claims grounded in them.</:subtitle>
              <.empty
                :if={@artifacts == []}
                icon="hero-document-magnifying-glass"
                title="No research yet"
              />
              <ol class="space-y-4">
                <li
                  :for={artifact <- @artifacts}
                  id={"artifact-#{artifact.id}"}
                  class="rounded-lg border border-zinc-100 p-4"
                >
                  <div class="flex flex-wrap items-start justify-between gap-2">
                    <div class="min-w-0">
                      <p class="font-medium text-zinc-900">{artifact.title || artifact.source_url}</p>
                      <p class="truncate font-mono text-xs text-zinc-500">{artifact.source_url}</p>
                    </div>
                    <div class="flex flex-wrap gap-1.5">
                      <.badge status={artifact.source_type} attr="source-type" />
                      <.badge status={artifact.trust_level} attr="trust" />
                      <.badge status={artifact.freshness} attr="freshness" />
                    </div>
                  </div>
                  <p :if={artifact.excerpt} class="mt-2 line-clamp-3 text-sm text-zinc-600">
                    {artifact.excerpt}
                  </p>
                  <ul class="mt-3 space-y-1.5">
                    <li
                      :for={claim <- Map.get(@claims_by_artifact, artifact.id, [])}
                      id={"claim-#{claim.id}"}
                    >
                      <.link
                        patch={~p"/leads/#{@lead.id}?claim=#{claim.id}"}
                        class={[
                          "flex items-start gap-2 rounded-md px-2 py-1.5 text-sm transition",
                          if(@selected && @selected.id == claim.id,
                            do: "bg-teal-50 text-teal-900 ring-1 ring-teal-600/30",
                            else: "text-zinc-700 hover:bg-zinc-50"
                          )
                        ]}
                      >
                        <.icon
                          name="hero-chat-bubble-bottom-center-text"
                          class="mt-0.5 size-4 shrink-0 text-zinc-400"
                        />
                        <span class="flex-1">{claim.claim}</span>
                        <.badge status={claim.quality} attr="quality" />
                      </.link>
                    </li>
                  </ul>
                </li>
              </ol>
            </.card>
          </div>

          <div class="space-y-6">
            <.card id="evidence-panel" title="Evidence" class="lg:sticky lg:top-6">
              <.empty :if={is_nil(@selected)} icon="hero-cursor-arrow-rays" title="Select a claim">
                Choose a claim or a cited qualification link to see its source.
              </.empty>
              <div :if={@selected} data-claim-id={@selected.id} class="space-y-3">
                <p class="text-sm font-medium text-zinc-900">{@selected.claim}</p>
                <blockquote class="border-l-2 border-teal-500 bg-teal-50/50 py-2 pl-3 pr-2 text-sm italic text-zinc-700">
                  {@selected.quote}
                </blockquote>
                <dl class="divide-y divide-zinc-100">
                  <.field label="Confidence">
                    {if @selected.confidence, do: "#{round(@selected.confidence * 100)}%", else: "—"}
                  </.field>
                  <.field label="Source">
                    <a
                      href={@selected_artifact.source_url}
                      class="break-all font-mono text-xs text-teal-700 hover:underline"
                      rel="noopener noreferrer"
                    >
                      {@selected_artifact.source_url}
                    </a>
                  </.field>
                  <.field label="Provider">{humanize(@selected_artifact.provider)}</.field>
                  <.field label="Retrieved">
                    <.timestamp at={@selected_artifact.retrieved_at} />
                  </.field>
                  <.field label="Offsets">
                    <span class="font-mono text-xs">
                      {@selected.source_location.char_start}–{@selected.source_location.char_end}
                    </span>
                  </.field>
                  <.field label="Content hash">
                    <.hash value={@selected_artifact.content_sha256} />
                  </.field>
                </dl>
                <.ui_button
                  :if={is_nil(@source)}
                  id="show-source"
                  size="sm"
                  phx-click="show_source"
                  class="w-full"
                >
                  <.icon name="hero-document-text" class="size-4" /> Show full source (recorded)
                </.ui_button>
                <pre
                  :if={@source}
                  id="source-content"
                  class="max-h-80 overflow-auto whitespace-pre-wrap rounded-lg bg-zinc-950 p-3 font-mono text-[0.72rem] leading-relaxed text-zinc-300"
                >{@source.before}<mark class="rounded bg-amber-300 px-0.5 text-zinc-950">{@source.quote}</mark>{@source.after}</pre>
              </div>
            </.card>

            <.card id="lead-runs" title="Agent runs">
              <:actions :if={@current_scope.role in [:admin, :auditor]}>
                <.link
                  id="lead-audit-link"
                  navigate={~p"/audit?lead=#{@lead.id}"}
                  class="text-xs font-medium text-teal-700 hover:underline"
                >
                  Audit trail →
                </.link>
              </:actions>
              <.empty :if={@runs == []} icon="hero-cpu-chip" title="Not assigned to the agent yet" />
              <ul class="-my-1 divide-y divide-zinc-100">
                <li :for={run <- @runs} class="flex items-center justify-between gap-2 py-2">
                  <.link
                    navigate={~p"/runs/#{run.id}"}
                    class="group min-w-0 text-sm text-zinc-800 hover:text-teal-800"
                  >
                    <span class="block truncate">{run.trigger_signal_type}</span>
                    <span class="block text-xs text-zinc-500"><.timestamp at={run.inserted_at} /></span>
                  </.link>
                  <span class="flex shrink-0 items-center gap-2">
                    <.trace_link trace_id={run.trace_id} />
                    <.badge status={run.status} />
                  </span>
                </li>
              </ul>
            </.card>

            <.card id="lead-drafts" title="Drafts">
              <.empty :if={@drafts == []} icon="hero-envelope" title="No drafts yet" />
              <ul class="-my-1 divide-y divide-zinc-100">
                <li :for={draft <- @drafts} class="py-2">
                  <.link
                    navigate={~p"/drafts/#{draft.id}"}
                    class="group flex items-center justify-between gap-2"
                  >
                    <span class="min-w-0 truncate text-sm text-zinc-800 group-hover:text-teal-800">
                      {@revisions[draft.current_revision_id] &&
                        @revisions[draft.current_revision_id].subject}
                    </span>
                    <.badge status={draft.status} />
                  </.link>
                </li>
              </ul>
            </.card>

            <.card title="Account">
              <dl class="divide-y divide-zinc-100">
                <.field label="Domain">
                  <span class="font-mono text-xs">{to_string(@account.domain)}</span>
                </.field>
                <.field label="Industry">{@account.industry || "—"}</.field>
                <.field label="Employees">{@account.employee_count || "—"}</.field>
                <.field label="Geography">{@account.geography || "—"}</.field>
                <.field label="Contact time zone">{@contact.timezone || "—"}</.field>
              </dl>
            </.card>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
