defmodule SdrAgentWeb.LeadLive.Index do
  @moduledoc """
  Leads list (S10a): every lead of the tenant with its company, contact and
  lifecycle status, filterable by status through the URL (`?status=`).
  An auditor's view is recorded with the ids of the leads shown. The current
  hosted owner also gets the "Add prospect" panel
  (`SdrAgentWeb.LeadLive.OwnerIntakePanel`, ADR-0026), which previews and
  saves through `SdrAgent.Prototype.OwnerIntake`. Every event rechecks the
  owner, and the preview stays in server assigns.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Prototype.OwnerIntake
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData
  alias SdrAgentWeb.LeadLive.OwnerIntakePanel
  alias SdrAgentWeb.Scope

  @filters ~w(new assigned researching qualifying qualified disqualified in_outreach replied stopped blocked)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Leads", loaded?: false, withheld: nil, status: nil, filters: @filters)
     |> assign(owner?: false)
     |> reset_intake(false)
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
      |> assign(owner?: Scope.hosted_owner?(scope))
      |> assign(loaded?: true, withheld: nil, count: length(rows))
      |> stream(:leads, rows, reset: true)
    else
      {:error, reason} -> withhold(socket, reason)
    end
  end

  # Fail closed on every (re)load: nothing previously shown stays on screen.
  defp withhold(socket, reason),
    do: assign(socket, loaded?: false, withheld: AuditedView.error_message(reason))

  ## Owner intake (ADR-0026)

  @impl true
  def handle_event("intake_open", _params, socket),
    do: {:noreply, if(owner_now?(socket), do: reset_intake(socket, true), else: socket)}

  def handle_event("intake_close", _params, socket), do: {:noreply, reset_intake(socket, false)}

  def handle_event("intake_change", %{"intake" => form}, socket) when is_map(form),
    do: {:noreply, assign(socket, intake_form: to_form(form, as: :intake))}

  def handle_event("intake_change", _params, socket), do: {:noreply, socket}

  def handle_event("intake_add_source", _params, socket) do
    rows = socket.assigns.source_rows

    rows =
      if length(rows) < OwnerIntakePanel.max_sources(), do: rows ++ [length(rows)], else: rows

    {:noreply, assign(socket, source_rows: rows)}
  end

  def handle_event("intake_preview", %{"intake" => form}, socket) when is_map(form) do
    socket = assign(socket, intake_form: to_form(form, as: :intake), preview: nil, intake_params: nil)

    if owner_now?(socket) do
      params = OwnerIntakePanel.params(form)

      case OwnerIntake.preview(params, socket.assigns.current_scope.user) do
        {:ok, preview} ->
          {:noreply, assign(socket, preview: preview, intake_params: params, intake_error: nil)}

        {:error, code} ->
          {:noreply, assign(socket, intake_error: code)}
      end
    else
      {:noreply, refuse_intake(socket)}
    end
  end

  def handle_event("intake_preview", _params, socket), do: {:noreply, refuse_intake(socket)}

  # Any client "preview" is ignored: only the server-held preview counts.
  def handle_event("intake_commit", _params, socket) do
    %{preview: preview, intake_params: params} = socket.assigns

    cond do
      not owner_now?(socket) ->
        {:noreply, refuse_intake(socket)}

      is_nil(preview) or is_nil(params) ->
        {:noreply, assign(socket, intake_error: :no_preview)}

      true ->
        commit(socket, params, preview)
    end
  end

  defp commit(socket, params, preview) do
    case OwnerIntake.commit(params, preview, socket.assigns.current_scope.user) do
      {:ok, mode, %{lead_id: lead_id}} when mode in [:created, :replay] ->
        flash = if mode == :created, do: "Prospect saved.", else: "This prospect was already saved."
        {:noreply, socket |> put_flash(:info, flash) |> push_navigate(to: ~p"/leads/#{lead_id}")}

      {:error, code} ->
        {:noreply, assign(socket, intake_error: code, preview: nil, intake_params: nil)}
    end
  end

  # The owner check is re-run on every event; socket assigns may be stale.
  defp owner_now?(socket), do: Scope.hosted_owner?(socket.assigns.current_scope)

  defp refuse_intake(socket),
    do: socket |> reset_intake(false) |> assign(owner?: false, intake_error: nil)

  defp reset_intake(socket, open?) do
    assign(socket,
      intake_open?: open?,
      intake_form: to_form(%{}, as: :intake),
      source_rows: [0],
      preview: nil,
      intake_params: nil,
      intake_error: nil
    )
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
        <:actions :if={@owner? and not @intake_open?}>
          <button
            id="add-prospect"
            type="button"
            phx-click="intake_open"
            class="inline-flex items-center gap-1.5 rounded-lg bg-teal-700 px-3 py-2 text-sm font-medium text-white shadow-sm transition hover:-translate-y-px hover:bg-teal-800 focus-visible:outline-2 focus-visible:outline-teal-600"
          >
            <.icon name="hero-plus" class="size-4" /> Add prospect
          </button>
        </:actions>
      </.page_header>

      <OwnerIntakePanel.panel
        :if={@owner? and @intake_open?}
        form={@intake_form}
        source_rows={@source_rows}
        preview={@preview}
        error={@intake_error}
      />

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
