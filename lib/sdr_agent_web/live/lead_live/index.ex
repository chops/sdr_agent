defmodule SdrAgentWeb.LeadLive.Index do
  @moduledoc """
  Leads list (S10a): every lead of the tenant with its company, contact and
  lifecycle status, filterable by status through the URL (`?status=`).
  Read-only; an auditor's view is recorded with the ids of the leads shown.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData

  @filters ~w(new assigned researching qualifying qualified disqualified in_outreach replied stopped blocked)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Leads", loaded?: false, withheld: nil, status: nil, filters: @filters)
     |> stream(:leads, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @filters, do: params["status"]
    socket = assign(socket, :status, status)
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    filter = if s = socket.assigns.status, do: [status: String.to_existing_atom(s)], else: []

    with {:ok, leads} <-
           Sales.list_records(Sales.Lead,
             filter: filter,
             sort: [updated_at: :desc, id: :asc],
             actor: scope.user
           ),
         {:ok, contacts} <- ConsoleData.index(scope, Sales.Contact),
         {:ok, accounts} <- ConsoleData.index(scope, Sales.Account),
         :ok <-
           AuditedView.record(
             scope,
             "SdrAgent.Sales.Lead",
             Enum.map(leads, & &1.id),
             "leads list"
           ) do
      rows =
        Enum.map(leads, fn lead ->
          %{
            id: lead.id,
            lead: lead,
            contact: contacts[lead.contact_id],
            account: accounts[lead.account_id]
          }
        end)

      socket
      |> assign(loaded?: true, count: length(rows))
      |> stream(:leads, rows, reset: true)
    else
      {:error, reason} -> assign(socket, withheld: AuditedView.error_message(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:leads}>
      <.page_header eyebrow="Pipeline">
        Leads
        <:subtitle>
          Fictional accounts and contacts (synthetic <code class="font-mono text-xs">.test</code>
          domains). Open a lead to see the research evidence behind its qualification.
        </:subtitle>
      </.page_header>

      <nav aria-label="Filter by status" class="mb-4 flex flex-wrap gap-1.5">
        <.link
          id="status-filter-all"
          patch={~p"/leads"}
          class={filter_class(is_nil(@status))}
          aria-current={if(is_nil(@status), do: "true")}
        >
          All
        </.link>
        <.link
          :for={f <- @filters}
          id={"status-filter-#{f}"}
          patch={~p"/leads?status=#{f}"}
          class={filter_class(@status == f)}
          aria-current={if(@status == f, do: "true")}
        >
          {humanize(f)}
        </.link>
      </nav>

      <.empty
        :if={@withheld}
        id="withheld"
        icon="hero-lock-closed"
        title="This view could not be served"
      >
        {@withheld}
      </.empty>
      <.loading :if={!@loaded? and is_nil(@withheld)} />

      <div :if={@loaded?} class="overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm">
        <div class="overflow-x-auto">
          <table class="w-full min-w-[40rem] text-left text-sm">
            <thead class="border-b border-zinc-200 bg-zinc-50/80 text-xs uppercase tracking-wider text-zinc-500">
              <tr>
                <th scope="col" class="px-5 py-3 font-medium">Company</th>
                <th scope="col" class="px-5 py-3 font-medium">Contact</th>
                <th scope="col" class="px-5 py-3 font-medium">Status</th>
                <th scope="col" class="px-5 py-3 font-medium">Updated</th>
                <th scope="col" class="px-5 py-3"><span class="sr-only">Open</span></th>
              </tr>
            </thead>
            <tbody id="leads" phx-update="stream" class="divide-y divide-zinc-100">
              <tr id="leads-empty" class="hidden only:table-row">
                <td colspan="5" class="px-5 py-10 text-center text-sm text-zinc-500">
                  No leads in this status.
                </td>
              </tr>
              <tr
                :for={{dom_id, row} <- @streams.leads}
                id={dom_id}
                class="group transition hover:bg-zinc-50"
              >
                <td class="px-5 py-3.5">
                  <p class="font-medium text-zinc-900">{row.account && row.account.name}</p>
                  <p class="font-mono text-xs text-zinc-500">
                    {row.account && to_string(row.account.domain)}
                  </p>
                </td>
                <td class="px-5 py-3.5">
                  <p class="text-zinc-900">{ConsoleData.contact_name(row.contact)}</p>
                  <p class="text-xs text-zinc-500">{row.contact && row.contact.title}</p>
                </td>
                <td class="px-5 py-3.5"><.badge status={row.lead.status} /></td>
                <td class="px-5 py-3.5 text-xs text-zinc-500">
                  <.timestamp at={row.lead.updated_at} />
                </td>
                <td class="px-5 py-3.5 text-right">
                  <.link
                    navigate={~p"/leads/#{row.id}"}
                    class="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs font-medium text-teal-700 hover:bg-teal-50 focus-visible:outline-2 focus-visible:outline-teal-600"
                  >
                    Open <.icon name="hero-arrow-right" class="size-3.5" />
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp filter_class(active?) do
    [
      "rounded-full px-3 py-1 text-xs font-medium capitalize transition focus-visible:outline-2 focus-visible:outline-teal-600",
      if(active?,
        do: "bg-zinc-900 text-white",
        else: "bg-white text-zinc-600 ring-1 ring-inset ring-zinc-200 hover:bg-zinc-50"
      )
    ]
  end
end
