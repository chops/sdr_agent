defmodule SdrAgentWeb.AuditLive do
  @moduledoc """
  Audit timeline (S10b; ADM, AUR): the tenant's AuditEvents, newest first,
  filterable by lead, agent run or draft through the URL (`?lead=`, `?run=`,
  `?draft=`), each with its actor, subject (linked to its console page),
  payload and Tempo trace link; the chain head; and chain verification
  (`Audit.verify_chain/1`, recorded by the kernel as a `chain_verify`
  access).

  Every timeline view — for any role — first records a `timeline_view`
  AuditAccess naming the filter (`Audit.record_access/5`); if that fails
  nothing is served (fail closed).

  Filters: *lead* — events whose subject is the lead, its runs, research
  artifacts, claims, qualifications, enrollments, drafts, revisions,
  approvals, deliveries or receipts, or that belong to one of its runs;
  *run* — events of the run or about it; *draft* — events about the draft,
  its revisions, approvals, deliveries and receipts.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Outreach
  alias SdrAgent.Research
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData

  on_mount {SdrAgentWeb.LiveUserAuth, {:roles, [:admin, :auditor]}}

  @limit 300

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Audit timeline",
       loaded?: false,
       withheld: nil,
       filter: nil,
       chain_result: nil
     )
     |> stream(:events, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter =
      cond do
        uuid?(params["lead"]) -> {:lead, params["lead"]}
        uuid?(params["run"]) -> {:run, params["run"]}
        uuid?(params["draft"]) -> {:draft, params["draft"]}
        true -> nil
      end

    socket = assign(socket, filter: filter)
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  # A 36-character UUID string only (Ecto.UUID.cast/1 also accepts 16 raw bytes).
  defp uuid?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp load(socket) do
    scope = socket.assigns.current_scope
    opts = [actor: scope.user]
    filter = socket.assigns.filter

    with {:ok, matcher} <- matcher(filter, opts),
         {:ok, events} <- Audit.list_events(opts),
         {:ok, head} <- Audit.get_chain_head(opts),
         {:ok, users} <- Accounts.list_users(opts),
         {:ok, options} <- filter_options(scope),
         {:ok, _access} <-
           Audit.record_access(
             :timeline_view,
             "SdrAgent.Audit.AuditEvent",
             filter_ref(filter),
             "audit timeline",
             opts
           ) do
      shown =
        events
        |> Enum.filter(matcher)
        |> Enum.sort_by(& &1.sequence, :desc)
        |> Enum.take(@limit)

      socket
      |> assign(
        loaded?: true,
        withheld: nil,
        head: head,
        users: Map.new(users, &{&1.id, &1}),
        options: options,
        shown: length(shown),
        total: length(events),
        filter_form: filter_form(filter)
      )
      |> stream(:events, shown, reset: true)
    else
      {:error, reason} ->
        assign(socket, loaded?: false, withheld: AuditedView.error_message(reason))
    end
  end

  defp filter_ref(nil), do: "latest #{@limit}"
  defp filter_ref({kind, id}), do: "#{kind}:#{id}"

  defp filter_form(nil), do: to_form(%{"lead" => "", "run" => "", "draft" => ""}, as: :filter)

  defp filter_form({kind, id}),
    do:
      to_form(Map.put(%{"lead" => "", "run" => "", "draft" => ""}, to_string(kind), id),
        as: :filter
      )

  # Event predicates for a filter.
  defp matcher(nil, _opts), do: {:ok, fn _event -> true end}

  defp matcher({:run, id}, _opts),
    do: {:ok, fn event -> event.agent_run_id == id or event.subject_id == id end}

  defp matcher({:draft, id}, opts) do
    with {:ok, ids} <- draft_ids([id], opts) do
      set = MapSet.new(ids)
      {:ok, fn event -> MapSet.member?(set, event.subject_id) end}
    end
  end

  defp matcher({:lead, id}, opts) do
    with {:ok, runs} <- Agents.list_runs(Keyword.put(opts, :lead_id, id)),
         {:ok, drafts} <-
           Outreach.list_records(Outreach.Draft, Keyword.put(opts, :filter, lead_id: id)),
         {:ok, draft_related} <- draft_ids(Enum.map(drafts, & &1.id), opts),
         {:ok, research} <- lead_research_ids(id, opts),
         {:ok, enrollments} <-
           Sales.list_records(Sales.CampaignEnrollment, Keyword.put(opts, :filter, lead_id: id)) do
      run_ids = MapSet.new(runs, & &1.id)

      subjects =
        MapSet.new(
          [id] ++
            Enum.map(runs, & &1.id) ++
            draft_related ++ research ++ Enum.map(enrollments, & &1.id)
        )

      {:ok,
       fn event ->
         MapSet.member?(subjects, event.subject_id) or MapSet.member?(run_ids, event.agent_run_id)
       end}
    end
  end

  defp lead_research_ids(lead_id, opts) do
    filtered = Keyword.put(opts, :filter, lead_id: lead_id)

    with {:ok, artifacts} <- Research.list_records(Research.ResearchArtifact, filtered),
         {:ok, claims} <- Research.list_records(Research.EvidenceClaim, filtered),
         {:ok, qualifications} <- Research.list_records(Research.Qualification, filtered) do
      {:ok, Enum.map(artifacts ++ claims ++ qualifications, & &1.id)}
    end
  end

  defp draft_ids([], _opts), do: {:ok, []}

  defp draft_ids(draft_ids, opts) do
    Enum.reduce_while(draft_ids, {:ok, draft_ids}, fn draft_id, {:ok, acc} ->
      case related_to_draft(draft_id, opts) do
        {:ok, ids} -> {:cont, {:ok, acc ++ ids}}
        error -> {:halt, error}
      end
    end)
  end

  defp related_to_draft(draft_id, opts) do
    by_draft = Keyword.put(opts, :filter, draft_id: draft_id)

    with {:ok, revisions} <- Outreach.list_records(Outreach.DraftRevision, by_draft),
         {:ok, approvals} <- Outreach.list_records(Outreach.Approval, by_draft),
         {:ok, deliveries} <- Outreach.list_records(Outreach.DeliveryOperation, by_draft),
         {:ok, receipts} <- receipts(deliveries, opts) do
      {:ok, Enum.map(revisions ++ approvals ++ deliveries ++ receipts, & &1.id)}
    end
  end

  defp receipts(deliveries, opts) do
    Enum.reduce_while(deliveries, {:ok, []}, fn delivery, {:ok, acc} ->
      case Outreach.list_records(
             Outreach.DeliveryReceipt,
             Keyword.put(opts, :filter, delivery_operation_id: delivery.id)
           ) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        error -> {:halt, error}
      end
    end)
  end

  defp filter_options(scope) do
    with {:ok, leads} <- ConsoleData.index(scope, Sales.Lead),
         {:ok, contacts} <- ConsoleData.index(scope, Sales.Contact),
         {:ok, runs} <- Agents.list_runs(actor: scope.user),
         {:ok, drafts} <- Outreach.list_records(Outreach.Draft, actor: scope.user) do
      name = fn lead_id ->
        lead = leads[lead_id]
        ConsoleData.contact_name(lead && contacts[lead.contact_id])
      end

      {:ok,
       %{
         leads: leads |> Map.values() |> Enum.map(&{name.(&1.id), &1.id}) |> Enum.sort(),
         runs:
           Enum.map(runs, fn run ->
             {"#{name.(run.lead_id)} · #{run.status} · #{String.slice(run.id, 0, 8)}", run.id}
           end),
         drafts:
           Enum.map(drafts, fn draft ->
             {"#{name.(draft.lead_id)} · #{draft.status} · #{String.slice(draft.id, 0, 8)}",
              draft.id}
           end)
       }}
    end
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    query =
      params
      |> Map.take(["lead", "run", "draft"])
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.take(1)

    {:noreply, push_patch(socket, to: ~p"/audit?#{query}")}
  end

  def handle_event("verify_chain", _params, socket) do
    case Audit.verify_chain(actor: socket.assigns.current_scope.user) do
      {:ok, result} ->
        head =
          case Audit.get_chain_head(actor: socket.assigns.current_scope.user) do
            {:ok, head} -> head
            _ -> socket.assigns[:head]
          end

        {:noreply, assign(socket, chain_result: result, head: head)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AuditedView.error_message(reason))}
    end
  end

  defp actor_label(event, users) do
    case {event.actor_type, users[event.actor_id]} do
      {:user, %{display_name: name}} -> name
      {type, _} -> humanize(type)
    end
  end

  defp subject_path(%{subject_resource: "SdrAgent.Sales.Lead", subject_id: id}),
    do: "/leads/#{id}"

  defp subject_path(%{subject_resource: "SdrAgent.Outreach.Draft", subject_id: id}),
    do: "/drafts/#{id}"

  defp subject_path(%{subject_resource: "SdrAgent.Agents.AgentRun", subject_id: id}),
    do: "/runs/#{id}"

  defp subject_path(_event), do: nil

  defp short_resource(nil), do: "—"
  defp short_resource(resource), do: resource |> String.split(".") |> List.last()

  defp payload_json(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload, pretty: true, limit: 200)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:audit}>
      <.page_header eyebrow="System of record">
        Audit timeline
        <:subtitle>
          The hash-chained ledger in Postgres. Opening this view is itself recorded.
        </:subtitle>
        <:actions>
          <.ui_button navigate={~p"/audit/exports"} size="sm">
            <.icon name="hero-archive-box-arrow-down" class="size-4" /> Exports
          </.ui_button>
          <.ui_button
            id="verify-chain"
            size="sm"
            variant="primary"
            phx-click="verify_chain"
            phx-disable-with="Verifying…"
          >
            <.icon name="hero-shield-check" class="size-4" /> Verify chain
          </.ui_button>
        </:actions>
      </.page_header>

      <.empty
        :if={@withheld}
        id="withheld"
        icon="hero-lock-closed"
        title="This view could not be served"
      >
        {@withheld}
      </.empty>
      <.loading :if={!@loaded? and is_nil(@withheld)} />

      <div :if={@loaded?} class="space-y-6">
        <div
          :if={@chain_result}
          id="chain-result"
          data-valid={to_string(@chain_result.valid?)}
          role="status"
          class={[
            "flex items-start gap-3 rounded-xl border px-4 py-3 text-sm",
            if(@chain_result.valid?,
              do: "border-emerald-200 bg-emerald-50 text-emerald-900",
              else: "border-rose-200 bg-rose-50 text-rose-900"
            )
          ]}
        >
          <.icon
            name={if(@chain_result.valid?, do: "hero-shield-check", else: "hero-shield-exclamation")}
            class="mt-0.5 size-5 shrink-0"
          />
          <div>
            <p class="font-semibold">
              {if(@chain_result.valid?, do: "Chain verified", else: "Chain verification failed")}
            </p>
            <p>
              <span data-events-checked={@chain_result.events_checked}>{@chain_result.events_checked}</span>
              events checked through sequence {@chain_result.last_sequence}.
            </p>
            <ul :if={@chain_result.issues != []} class="mt-1 list-disc pl-5 font-mono text-xs">
              <li :for={issue <- Enum.take(@chain_result.issues, 20)}>{inspect(issue)}</li>
            </ul>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-3">
          <.card title="Filter" class="lg:col-span-2">
            <.form
              for={@filter_form}
              id="timeline-filter"
              phx-change="filter"
              class="grid gap-3 sm:grid-cols-3"
            >
              <.input
                field={@filter_form[:lead]}
                type="select"
                label="Lead"
                prompt="Any lead"
                options={@options.leads}
                class="w-full rounded-lg border border-zinc-300 bg-white px-2.5 py-1.5 text-sm"
              />
              <.input
                field={@filter_form[:run]}
                type="select"
                label="Agent run"
                prompt="Any run"
                options={@options.runs}
                class="w-full rounded-lg border border-zinc-300 bg-white px-2.5 py-1.5 text-sm"
              />
              <.input
                field={@filter_form[:draft]}
                type="select"
                label="Draft"
                prompt="Any draft"
                options={@options.drafts}
                class="w-full rounded-lg border border-zinc-300 bg-white px-2.5 py-1.5 text-sm"
              />
            </.form>
            <p class="mt-2 text-xs text-zinc-500">
              Showing {@shown} of {@total} events{if @filter,
                do: " for the selected #{elem(@filter, 0)}",
                else: " (newest #{@shown})"}.
              <.link
                :if={@filter}
                patch={~p"/audit"}
                class="ml-1 font-medium text-teal-700 hover:underline"
              >
                Clear filter
              </.link>
            </p>
          </.card>

          <.card title="Chain head">
            <dl :if={@head} class="divide-y divide-zinc-100">
              <.field label="Last sequence">
                <span class="tabular-nums">{@head.last_sequence}</span>
              </.field>
              <.field label="Last hash"><.hash value={@head.last_event_hash} /></.field>
            </dl>
          </.card>
        </div>

        <div class="overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm">
          <ol id="events" phx-update="stream" class="divide-y divide-zinc-100">
            <li
              id="events-empty"
              class="hidden px-5 py-10 text-center text-sm text-zinc-500 only:block"
            >
              No events match this filter.
            </li>
            <li :for={{dom_id, event} <- @streams.events} id={dom_id} class="px-5 py-3">
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <span class="w-14 font-mono text-xs text-zinc-400">#{event.sequence}</span>
                <span class="font-mono text-xs font-medium text-zinc-900">{event.event_type}</span>
                <.badge status={event.category} attr="category" />
                <span class="text-xs text-zinc-600">
                  by {actor_label(event, @users)}
                  <span :if={event.actor_role} class="text-zinc-400">({event.actor_role})</span>
                </span>
                <span class="ml-auto flex items-center gap-2 text-xs text-zinc-500">
                  <.trace_link trace_id={event.trace_id} />
                  <.timestamp at={event.occurred_at} />
                </span>
              </div>
              <div class="mt-1 flex flex-wrap items-center gap-2 pl-[4.25rem] text-xs text-zinc-500">
                <span>{short_resource(event.subject_resource)}</span>
                <.link
                  :if={subject_path(event)}
                  navigate={subject_path(event)}
                  class="font-mono text-teal-700 hover:underline"
                >
                  {event.subject_id && String.slice(event.subject_id, 0, 8)}
                </.link>
                <span :if={is_nil(subject_path(event)) and event.subject_id} class="font-mono">
                  {String.slice(event.subject_id, 0, 12)}
                </span>
                <.hash value={event.event_hash} />
                <details :if={event.payload != %{}} class="w-full">
                  <summary class="cursor-pointer select-none text-zinc-600 hover:text-zinc-900">
                    event payload
                  </summary>
                  <pre class="mt-1 max-h-64 overflow-auto rounded-lg bg-zinc-950 p-3 font-mono text-[0.7rem] leading-relaxed text-zinc-300">{payload_json(event.payload)}</pre>
                </details>
              </div>
            </li>
          </ol>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
