defmodule SdrAgentWeb.OperationsLive do
  @moduledoc """
  Runs & operations (S10b): the operator-attention queue
  (`Operations.list_attention/1`) with acknowledge and resolve-with-note
  (`acknowledge_failure/2`, `resolve_failure/3`; ADM, REV), the durable
  operations (`Operations.list_operations/1`) with cancel for enqueued or
  failed ones (`cancel_operation/2`; ADM), and the agent runs
  (`Agents.list_runs/1`) linking to `SdrAgentWeb.RunLive`.

  Operation *retry* is deliberately not offered: `retry_operation/2` only
  moves the row to `running` and no path re-enqueues its job yet (S7/S8
  notes: resume-after-failure is S13), so a button would leave a running
  operation with nothing running. Every action goes to the domain with the
  scope's user; an auditor's forged event is refused and audited, a
  reviewer's cancel is refused by the Operation policy. An auditor's view is
  recorded before it is served.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Agents
  alias SdrAgent.Operations
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData
  alias SdrAgentWeb.Scope

  @run_limit 50
  @operation_limit 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Runs & operations",
       loaded?: false,
       withheld: nil,
       resolve_form: to_form(%{"resolution_note" => ""}, as: :resolve)
     )
     |> stream(:failures, [])
     |> stream(:operations, [])
     |> stream(:runs, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    opts = [actor: scope.user]

    with {:ok, failures} <- Operations.list_attention(opts),
         {:ok, operations} <- Operations.list_operations(opts),
         {:ok, runs} <- Agents.list_runs(opts),
         {:ok, leads} <- ConsoleData.index(scope, Sales.Lead),
         {:ok, contacts} <- ConsoleData.index(scope, Sales.Contact),
         operations = Enum.take(operations, @operation_limit),
         runs = Enum.take(runs, @run_limit),
         :ok <-
           AuditedView.record(
             scope,
             "Operations",
             Enum.map(failures ++ operations ++ runs, & &1.id),
             "runs and operations view"
           ) do
      failures = Enum.map(failures, &Map.put(&1, :path, ConsoleData.subject_path(scope, &1)))

      runs =
        Enum.map(runs, fn run ->
          lead = run.lead_id && leads[run.lead_id]
          Map.put(run, :contact, lead && contacts[lead.contact_id])
        end)

      socket
      |> assign(
        loaded?: true,
        withheld: nil,
        counts: %{failures: length(failures), runs: length(runs)}
      )
      |> stream(:failures, failures, reset: true)
      |> stream(:operations, operations, reset: true)
      |> stream(:runs, runs, reset: true)
    else
      {:error, reason} ->
        assign(socket, loaded?: false, withheld: AuditedView.error_message(reason))
    end
  end

  @impl true
  def handle_event("acknowledge", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with_record(socket, Operations.get_failure(id, actor: actor), fn failure ->
      Operations.acknowledge_failure(failure, actor: actor)
    end)
    |> reply(socket, "Acknowledged.")
  end

  def handle_event("resolve", %{"id" => id} = params, socket) do
    actor = socket.assigns.current_scope.user
    note = get_in(params, ["resolve", "resolution_note"])

    with_record(socket, Operations.get_failure(id, actor: actor), fn failure ->
      Operations.resolve_failure(failure, %{resolution_note: note}, actor: actor)
    end)
    |> reply(socket, "Resolved with your note.")
  end

  def handle_event("cancel_operation", %{"id" => id}, socket) do
    actor = socket.assigns.current_scope.user

    with_record(socket, Operations.get_operation(id, actor: actor), fn operation ->
      Operations.cancel_operation(operation, actor: actor)
    end)
    |> reply(socket, "Operation cancelled.")
  end

  defp with_record(_socket, {:ok, record}, fun), do: fun.(record)
  defp with_record(_socket, error, _fun), do: error

  defp reply({:ok, _}, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> load()}

  defp reply({:error, reason}, socket, _message),
    do: {:noreply, put_flash(socket, :error, AuditedView.error_message(reason))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:operations}>
      <.page_header eyebrow="Durable work">
        Runs & operations
        <:subtitle>
          Failures that need a human, the background work behind them, and every agent run.
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

      <div :if={@loaded?} class="space-y-6">
        <.card id="attention" title="Needs attention">
          <:subtitle>
            Open and acknowledged failures, newest first. Resolving requires a note.
          </:subtitle>
          <ul id="failures" phx-update="stream" class="-my-2 divide-y divide-zinc-100">
            <li id="failures-empty" class="hidden py-6 text-center text-sm text-zinc-500 only:block">
              No open failures.
            </li>
            <li :for={{dom_id, failure} <- @streams.failures} id={dom_id} class="py-3">
              <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <.badge status={failure.severity} attr="severity" />
                    <.badge status={failure.status} />
                    <span class="text-xs font-medium text-zinc-700">{humanize(failure.class)}</span>
                    <span :if={failure.retryable} class="text-xs text-zinc-500">retryable</span>
                  </div>
                  <p class="mt-1 text-sm text-zinc-900">{failure.message}</p>
                  <p class="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-zinc-500">
                    {failure.subject_resource |> String.split(".") |> List.last()} ·
                    <.timestamp at={failure.occurred_at} />
                    <.link
                      :if={failure.path}
                      navigate={failure.path}
                      class="font-medium text-teal-700 hover:underline"
                    >
                      Open subject →
                    </.link>
                    <.trace_link trace_id={failure.trace_id} />
                  </p>
                </div>
                <div
                  :if={Scope.reviewer?(@current_scope)}
                  class="flex shrink-0 flex-wrap items-start gap-2"
                >
                  <.ui_button
                    :if={failure.status == :open}
                    id={"acknowledge-#{failure.id}"}
                    size="sm"
                    phx-click="acknowledge"
                    phx-value-id={failure.id}
                  >
                    Acknowledge
                  </.ui_button>
                  <.form
                    for={@resolve_form}
                    id={"resolve-#{failure.id}"}
                    phx-submit="resolve"
                    class="flex items-start gap-2"
                  >
                    <.input
                      type="hidden"
                      name="id"
                      id={"resolve-id-#{failure.id}"}
                      value={failure.id}
                    />
                    <.input
                      field={@resolve_form[:resolution_note]}
                      id={"resolve-note-#{failure.id}"}
                      type="text"
                      placeholder="Resolution note"
                      aria-label="Resolution note"
                      class="w-56 rounded-lg border border-zinc-300 bg-white px-2.5 py-1.5 text-xs shadow-sm focus:border-teal-600 focus:outline-none focus:ring-2 focus:ring-teal-600/20"
                    />
                    <.ui_button type="submit" size="sm" variant="primary">Resolve</.ui_button>
                  </.form>
                </div>
              </div>
            </li>
          </ul>
        </.card>

        <div class="grid gap-6 xl:grid-cols-2">
          <.card id="agent-runs" title="Agent runs">
            <:subtitle>Newest first. Open a run to reconstruct it from Postgres.</:subtitle>
            <ul id="runs" phx-update="stream" class="-my-2 divide-y divide-zinc-100">
              <li id="runs-empty" class="hidden py-6 text-center text-sm text-zinc-500 only:block">
                No agent runs yet — assign a lead.
              </li>
              <li :for={{dom_id, run} <- @streams.runs} id={dom_id} class="py-2.5">
                <.link
                  navigate={~p"/runs/#{run.id}"}
                  class="group flex items-center justify-between gap-3"
                >
                  <span class="min-w-0">
                    <span class="block truncate text-sm font-medium text-zinc-900 group-hover:text-teal-800">
                      {ConsoleData.contact_name(run.contact)}
                    </span>
                    <span class="block truncate text-xs text-zinc-500">
                      {run.trigger_signal_type} · phase {humanize(run.phase)} ·
                      <.timestamp at={run.inserted_at} />
                    </span>
                  </span>
                  <.badge status={run.status} />
                </.link>
              </li>
            </ul>
          </.card>

          <.card id="operations-card" title="Operations">
            <:subtitle>The domain view of each Oban job.</:subtitle>
            <ul id="operations" phx-update="stream" class="-my-2 divide-y divide-zinc-100">
              <li
                id="operations-empty"
                class="hidden py-6 text-center text-sm text-zinc-500 only:block"
              >
                No operations yet.
              </li>
              <li :for={{dom_id, operation} <- @streams.operations} id={dom_id} class="py-2.5">
                <div class="flex items-center justify-between gap-3">
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium text-zinc-900">
                      {humanize(operation.kind)}
                      <span class="font-normal text-zinc-500">on {humanize(operation.queue)}</span>
                    </p>
                    <p class="truncate text-xs text-zinc-500">
                      attempt {operation.attempts}/{operation.max_attempts} ·
                      <.timestamp at={operation.inserted_at} />
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-2">
                    <.badge status={operation.status} />
                    <.ui_button
                      :if={Scope.admin?(@current_scope) and operation.status in [:enqueued, :failed]}
                      id={"cancel-operation-#{operation.id}"}
                      size="sm"
                      variant="danger"
                      phx-click="cancel_operation"
                      phx-value-id={operation.id}
                      data-confirm="Cancel this operation?"
                    >
                      Cancel
                    </.ui_button>
                  </div>
                </div>
              </li>
            </ul>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
