defmodule SdrAgentWeb.ReviewLive do
  @moduledoc """
  Review queue (S10a): drafts awaiting a human verdict
  (`SdrAgent.Outreach.list_review_queue/1`, oldest first) with recipient,
  company, the current revision's subject and author, plus the most recent
  decided drafts. Read-only; opening a draft leads to `SdrAgentWeb.DraftLive`.
  An auditor's view is recorded with the ids of the drafts shown.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData

  @recent 10

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Review queue", loaded?: false, withheld: nil, count: 0)
     |> stream_configure(:review_queue, dom_id: &"review-queue-#{&1.id}")
     |> stream_configure(:recent_drafts, dom_id: &"recent-drafts-#{&1.id}")
     |> stream(:review_queue, [])
     |> stream(:recent_drafts, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    with {:ok, queue} <- Outreach.list_review_queue(actor: scope.user),
         {:ok, all} <-
           Outreach.list_records(Outreach.Draft,
             sort: [updated_at: :desc, id: :asc],
             actor: scope.user
           ),
         recent = all |> Enum.reject(&(&1.status == :pending_review)) |> Enum.take(@recent),
         {:ok, revisions} <- ConsoleData.current_revisions(scope, queue ++ recent),
         {:ok, contacts} <- ConsoleData.index(scope, Sales.Contact),
         {:ok, accounts} <- ConsoleData.index(scope, Sales.Account),
         :ok <-
           AuditedView.record(
             scope,
             "SdrAgent.Outreach.Draft",
             Enum.map(queue ++ recent, & &1.id),
             "review queue"
           ) do
      row = fn draft ->
        contact = contacts[draft.recipient_contact_id]

        %{
          id: draft.id,
          draft: draft,
          revision: revisions[draft.current_revision_id],
          contact: contact,
          account: contact && accounts[contact.account_id]
        }
      end

      socket
      |> assign(loaded?: true, count: length(queue))
      |> stream(:review_queue, Enum.map(queue, row), reset: true)
      |> stream(:recent_drafts, Enum.map(recent, row), reset: true)
    else
      {:error, reason} -> assign(socket, withheld: AuditedView.error_message(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:review}>
      <.page_header eyebrow="Human approval">
        Review queue
        <span
          id="review-count"
          class="ml-2 inline-grid min-w-7 place-items-center rounded-full bg-teal-700 px-2 py-0.5 align-middle text-sm font-semibold text-white"
        >
          {@count}
        </span>
        <:subtitle>
          Every outbound message needs an approval bound to its exact revision and recipient (tier 0).
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
        <ul id="review-queue" phx-update="stream" class="space-y-3">
          <li id="review-queue-empty" class="hidden only:block">
            <.card>
              <.empty icon="hero-check-circle" title="The queue is empty">
                Assign a lead to the agent; its proposed draft lands here.
              </.empty>
            </.card>
          </li>
          <li :for={{dom_id, row} <- @streams.review_queue} id={dom_id}>
            <.link
              navigate={~p"/drafts/#{row.id}"}
              class="group flex flex-col gap-3 rounded-xl border border-zinc-200 bg-white p-4 shadow-sm transition hover:-translate-y-0.5 hover:border-teal-600/40 hover:shadow-md focus-visible:outline-2 focus-visible:outline-teal-600 sm:flex-row sm:items-center"
            >
              <span class="grid size-10 shrink-0 place-items-center rounded-lg bg-teal-50 text-teal-700">
                <.icon name="hero-envelope" class="size-5" />
              </span>
              <div class="min-w-0 flex-1">
                <p class="truncate font-medium text-zinc-900 group-hover:text-teal-800">
                  {row.revision && row.revision.subject}
                </p>
                <p class="mt-0.5 truncate text-xs text-zinc-500">
                  to {ConsoleData.contact_name(row.contact)}
                  <span class="font-mono">&lt;{row.contact && to_string(row.contact.email)}&gt;</span>
                  · {row.account && row.account.name}
                </p>
              </div>
              <div class="flex shrink-0 items-center gap-3 text-xs text-zinc-500">
                <span>
                  rev #{row.revision && row.revision.revision_number} by {row.revision &&
                    humanize(row.revision.author_type)}
                </span>
                <.timestamp at={row.draft.inserted_at} />
                <.icon
                  name="hero-chevron-right"
                  class="size-4 text-zinc-400 group-hover:text-teal-700"
                />
              </div>
            </.link>
          </li>
        </ul>

        <.card title="Recent decisions">
          <:subtitle>The latest drafts that left the queue.</:subtitle>
          <ul id="recent-drafts" phx-update="stream" class="-my-2 divide-y divide-zinc-100">
            <li
              id="recent-drafts-empty"
              class="hidden py-4 text-center text-sm text-zinc-500 only:block"
            >
              No decisions yet.
            </li>
            <li :for={{dom_id, row} <- @streams.recent_drafts} id={dom_id} class="py-2.5">
              <.link
                navigate={~p"/drafts/#{row.id}"}
                class="group flex items-center justify-between gap-3"
              >
                <span class="min-w-0">
                  <span class="block truncate text-sm text-zinc-800 group-hover:text-teal-800">
                    {row.revision && row.revision.subject}
                  </span>
                  <span class="block truncate text-xs text-zinc-500">
                    {ConsoleData.contact_name(row.contact)} · {row.account && row.account.name}
                  </span>
                </span>
                <.badge status={row.draft.status} />
              </.link>
            </li>
          </ul>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
