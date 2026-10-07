defmodule SdrAgentWeb.DashboardLive do
  @moduledoc """
  Dashboard (S10a): pipeline counts (leads, drafts awaiting review,
  deliveries accepted, open attention), the oldest drafts awaiting review,
  and the operator-attention queue (`SdrAgent.Operations.list_attention/1`:
  open and acknowledged Failures, newest first). Read-only for every role;
  an auditor's view is recorded first (`SdrAgentWeb.AuditedView`).
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Operations
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Dashboard", loaded?: false, withheld: nil)
     |> stream(:attention, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    opts = [actor: scope.user]

    with {:ok, leads} <- Sales.list_records(Sales.Lead, opts),
         {:ok, queue} <- Outreach.list_review_queue(opts),
         {:ok, deliveries} <- Outreach.list_records(Outreach.DeliveryOperation, opts),
         {:ok, attention} <- Operations.list_attention(opts),
         {:ok, contacts} <- ConsoleData.index(scope, Sales.Contact),
         {:ok, revisions} <- ConsoleData.current_revisions(scope, Enum.take(queue, 5)),
         :ok <-
           AuditedView.record(
             scope,
             "Dashboard",
             Enum.map(attention, & &1.id) ++ Enum.map(queue, & &1.id),
             "dashboard: attention failures and review queue"
           ) do
      attention = Enum.map(attention, &Map.put(&1, :path, ConsoleData.subject_path(scope, &1)))

      socket
      |> assign(
        loaded?: true,
        lead_count: length(leads),
        lead_stages: stages(leads),
        pending_count: length(queue),
        queue: Enum.take(queue, 5),
        contacts: contacts,
        revisions: revisions,
        accepted_count: Enum.count(deliveries, &(&1.state in [:accepted, :delivered])),
        in_flight_count:
          Enum.count(
            deliveries,
            &(&1.state in [:pending, :attempting, :failed_retryable, :unknown])
          ),
        attention_count: length(attention)
      )
      |> stream(:attention, attention, reset: true)
    else
      {:error, reason} -> assign(socket, withheld: AuditedView.error_message(reason))
    end
  end

  defp stages(leads) do
    groups = [
      {"New", [:new]},
      {"Researching", [:assigned, :researching, :qualifying]},
      {"Qualified", [:qualified]},
      {"In outreach", [:in_outreach]},
      {"Replied", [:replied]},
      {"Closed", [:disqualified, :converted, :nurture, :stopped]},
      {"Blocked", [:blocked]}
    ]

    total = max(length(leads), 1)

    for {label, statuses} <- groups do
      count = Enum.count(leads, &(&1.status in statuses))
      %{label: label, count: count, pct: round(count * 100 / total)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:dashboard}>
      <.page_header eyebrow="Operator console">
        Good to see you, {@current_scope.user.display_name}
        <:subtitle>
          What the agent is doing, what waits for a human, and what needs attention.
        </:subtitle>
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

      <div :if={@loaded?} class="space-y-8">
        <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <.stat
            id="stat-leads"
            label="Leads"
            value={@lead_count}
            icon="hero-user-group"
            hint="fictional demo accounts"
            navigate={~p"/leads"}
          />
          <.stat
            id="stat-pending-review"
            label="Awaiting review"
            value={@pending_count}
            icon="hero-inbox-stack"
            tone="teal"
            hint="drafts needing a human"
            navigate={~p"/review"}
          />
          <.stat
            id="stat-delivered"
            label="Accepted sends"
            value={@accepted_count}
            icon="hero-paper-airplane"
            tone="sky"
            hint={"#{@in_flight_count} in flight · local capture only"}
            navigate={~p"/review"}
          />
          <.stat
            id="stat-attention"
            label="Attention"
            value={@attention_count}
            icon="hero-exclamation-triangle"
            tone={if(@attention_count > 0, do: "amber", else: "zinc")}
            hint="open failures"
            navigate={~p"/"}
          />
        </div>

        <.card id="pipeline" title="Lead pipeline">
          <div class="flex h-2.5 overflow-hidden rounded-full bg-zinc-100" aria-hidden="true">
            <div
              :for={{stage, i} <- Enum.with_index(@lead_stages)}
              :if={stage.count > 0}
              class={["h-full", pipeline_color(i)]}
              style={"width: #{stage.pct}%"}
            >
            </div>
          </div>
          <dl class="mt-4 grid grid-cols-2 gap-x-6 gap-y-2 sm:grid-cols-4 lg:grid-cols-7">
            <div :for={{stage, i} <- Enum.with_index(@lead_stages)} class="flex items-center gap-2">
              <span class={["size-2 rounded-full", pipeline_color(i)]} aria-hidden="true"></span>
              <dt class="text-xs text-zinc-500">{stage.label}</dt>
              <dd class="ml-auto text-sm font-semibold tabular-nums">{stage.count}</dd>
            </div>
          </dl>
        </.card>

        <div class="grid gap-6 lg:grid-cols-5">
          <.card id="dashboard-review-queue" title="Awaiting review" class="lg:col-span-2">
            <:actions>
              <.link navigate={~p"/review"} class="text-xs font-medium text-teal-700 hover:underline">
                Open queue →
              </.link>
            </:actions>
            <ul :if={@queue != []} class="-my-2 divide-y divide-zinc-100">
              <li :for={draft <- @queue} class="py-2.5">
                <.link
                  navigate={~p"/drafts/#{draft.id}"}
                  class="group block rounded-md focus-visible:outline-2 focus-visible:outline-teal-600"
                >
                  <p class="truncate text-sm font-medium text-zinc-900 group-hover:text-teal-800">
                    {@revisions[draft.current_revision_id] &&
                      @revisions[draft.current_revision_id].subject}
                  </p>
                  <p class="mt-0.5 truncate text-xs text-zinc-500">
                    to {ConsoleData.contact_name(@contacts[draft.recipient_contact_id])} ·
                    <.timestamp at={draft.inserted_at} />
                  </p>
                </.link>
              </li>
            </ul>
            <.empty :if={@queue == []} icon="hero-check-circle" title="Nothing waiting">
              Every proposed draft has a verdict.
            </.empty>
          </.card>

          <.card id="attention" title="Needs attention" class="lg:col-span-3">
            <:subtitle>Open and acknowledged failures, newest first.</:subtitle>
            <ul id="attention-list" phx-update="stream" class="-my-2 divide-y divide-zinc-100">
              <li
                id="attention-empty"
                class="hidden py-6 text-center text-sm text-zinc-500 only:block"
              >
                <.icon name="hero-shield-check" class="mb-1 size-6 text-emerald-600" /><br />
                No open failures — nothing needs a human right now.
              </li>
              <li :for={{dom_id, failure} <- @streams.attention} id={dom_id} class="flex gap-3 py-3">
                <span class={[
                  "mt-1 size-2 shrink-0 rounded-full",
                  if(failure.severity == :critical, do: "bg-rose-500", else: "bg-amber-500")
                ]}></span>
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <.badge status={failure.severity} attr="severity" />
                    <span class="text-xs font-medium text-zinc-700">{humanize(failure.class)}</span>
                    <.badge :if={failure.status == :acknowledged} status={failure.status} />
                  </div>
                  <p class="mt-1 text-sm text-zinc-900">{failure.message}</p>
                  <p class="mt-0.5 text-xs text-zinc-500">
                    {failure.subject_resource |> String.split(".") |> List.last()} ·
                    <.timestamp at={failure.occurred_at} />
                    <.link
                      :if={failure.path}
                      navigate={failure.path}
                      class="ml-1 font-medium text-teal-700 hover:underline"
                    >
                      Open subject →
                    </.link>
                  </p>
                </div>
              </li>
            </ul>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp pipeline_color(i),
    do:
      Enum.at(
        ~w(bg-zinc-300 bg-sky-400 bg-teal-500 bg-emerald-500 bg-amber-400 bg-zinc-500 bg-rose-500),
        i
      )
end
