defmodule SdrAgentWeb.OperationsLive do
  @moduledoc """
  Runs & operations (S10b): the operator-attention queue
  (`Operations.list_attention/1`) with acknowledge and resolve-with-note
  (`acknowledge_failure/2`, `resolve_failure/3`; ADM, REV), the durable
  operations (`Operations.list_operations/1`) with cancel for enqueued or
  failed ones (`cancel_operation/2`; ADM), and the agent runs
  (`Agents.list_runs/1`) linking to `SdrAgentWeb.RunLive`, with a retry for
  stopped runs (`SDR.retry_run/2`), and the failed webhook events
  (`Operations.list_failed_webhooks/1`) with a retry
  (`Outreach.retry_webhook/2`) — both ADM only (S13b).

  Operation *retry* is not offered: `retry_operation/2` is an internal
  execution primitive of the kind actor (S13b). Operator retries are the
  failed-run retry (`SDR.retry_run/2`) and the failed-webhook retry
  (`Outreach.retry_webhook/2`), admin only. Every action goes to the domain with the
  scope's user; an auditor's forged event is refused and audited, a
  reviewer's cancel is refused by the Operation policy. An auditor's view is
  recorded before it is served. Updates live (`SdrAgentWeb.LiveRefresh`).

  A current hosted owner sees permitted run metadata and the explicit
  Operations worker facade controls. Ungranted Failure/Operation/Webhook
  panels say unavailable, not empty. The one-time enrollment token is
  displayed as base64url text until dismissed. Successful authorized reloads
  preserve it; refusal, failed reload or a new mount clears it.
  No control launches a model call or grants ordinary admin/reviewer powers.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Agents
  alias SdrAgent.Operations
  alias SdrAgent.Outreach
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData
  alias SdrAgentWeb.LiveRefresh
  alias SdrAgentWeb.Scope

  @run_limit 50
  @operation_limit 50
  @worker_pin_keys ~w(profile_id model_id cli_version executable_sha256)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Runs & operations",
       loaded?: false,
       withheld: nil,
       workers: [],
       worker_token: nil,
       owner_controls?: false,
       panels_unavailable?: false,
       worker_form: to_form(Map.new(@worker_pin_keys, &{&1, ""}), as: :worker),
       resolve_form: to_form(%{"resolution_note" => ""}, as: :resolve)
     )
     |> stream(:failures, [])
     |> stream(:operations, [])
     |> stream(:runs, [])
     |> stream_configure(:webhooks, dom_id: &"failed-webhooks-#{&1.id}")
     |> stream(:webhooks, [])
     |> LiveRefresh.attach(&load/1)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    socket = assign(socket, workers: [])
    scope = socket.assigns.current_scope
    opts = [actor: scope.user]
    owner? = Scope.hosted_owner?(scope)

    with {:ok, panels} <- operation_panels(owner?, opts),
         {:ok, workers} <- workers(owner?, opts),
         {:ok, runs} <- Agents.list_runs(opts),
         {:ok, leads} <- ConsoleData.index(scope, Sales.Lead),
         {:ok, contacts} <- ConsoleData.index(scope, Sales.Contact),
         operations = Enum.take(panels.operations, @operation_limit),
         runs = Enum.take(runs, @run_limit),
         :ok <-
           AuditedView.record(
             scope,
             "Operations",
             Enum.map(panels.failures ++ operations ++ runs ++ panels.webhooks, & &1.id),
             "runs and operations view"
           ) do
      failures =
        Enum.map(panels.failures, &Map.put(&1, :path, ConsoleData.subject_path(scope, &1)))

      runs =
        Enum.map(runs, fn run ->
          lead = run.lead_id && leads[run.lead_id]

          run
          |> Map.put(:contact, lead && contacts[lead.contact_id])
          |> Map.put(:retried?, Enum.any?(runs, &(&1.retry_of_id == run.id)))
        end)

      socket
      |> assign(
        loaded?: true,
        withheld: nil,
        workers: workers,
        worker_token: if(owner?, do: socket.assigns.worker_token),
        owner_controls?: owner?,
        panels_unavailable?: owner?,
        counts: %{failures: length(failures), runs: length(runs)}
      )
      |> stream(:failures, failures, reset: true)
      |> stream(:operations, operations, reset: true)
      |> stream(:runs, runs, reset: true)
      |> stream(:webhooks, panels.webhooks, reset: true)
    else
      {:error, reason} ->
        assign(socket,
          loaded?: false,
          worker_token: nil,
          owner_controls?: false,
          withheld: AuditedView.error_message(reason)
        )
    end
  end

  defp operation_panels(true, _opts),
    do: {:ok, %{failures: [], operations: [], webhooks: []}}

  defp operation_panels(false, opts) do
    with {:ok, failures} <- Operations.list_attention(opts),
         {:ok, operations} <- Operations.list_operations(opts),
         {:ok, webhooks} <- Operations.list_failed_webhooks(opts) do
      {:ok, %{failures: failures, operations: operations, webhooks: webhooks}}
    end
  end

  defp workers(true, opts), do: Operations.list_mac_workers(opts)
  defp workers(false, _opts), do: {:ok, []}

  @impl true
  if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
    def handle_event("enrol_worker", %{"worker" => pins}, socket) when is_map(pins) do
      actor = socket.assigns.current_scope.user
      attrs = %{profile_pins: Map.take(pins, @worker_pin_keys)}

      case Operations.enrol_mac_worker(attrs, actor: actor) do
        {:ok, worker} ->
          socket = load(socket)

          token =
            if socket.assigns.loaded? and socket.assigns.owner_controls? do
              Base.url_encode64(Ash.Resource.get_metadata(worker, :token), padding: false)
            end

          {:noreply, assign(socket, worker_token: token)}

        {:error, reason} ->
          reply({:error, reason}, socket, nil)
      end
    end
  else
    # The domain is a constant refusal without prototype authority. Keep
    # the forged-event path through it without an unreachable success arm.
    def handle_event("enrol_worker", %{"worker" => pins}, socket) when is_map(pins) do
      attrs = %{profile_pins: Map.take(pins, @worker_pin_keys)}

      reply(
        Operations.enrol_mac_worker(attrs, actor: socket.assigns.current_scope.user),
        socket,
        nil
      )
    end
  end

  def handle_event("dismiss_worker_token", _params, socket),
    do: {:noreply, assign(socket, worker_token: nil)}

  def handle_event("pause_worker", %{"id" => id}, socket),
    do: update_worker(socket, id, &Operations.set_mac_worker_intake(&1, :paused, &2))

  def handle_event("resume_worker", %{"id" => id}, socket),
    do: update_worker(socket, id, &Operations.set_mac_worker_intake(&1, :open, &2))

  def handle_event("disable_worker", %{"id" => id}, socket),
    do: update_worker(socket, id, &Operations.disable_mac_worker/2)

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

  def handle_event("retry_run", %{"id" => id}, socket) do
    SDR.retry_run(id, actor: socket.assigns.current_scope.user)
    |> reply(socket, "Retry queued: a new run will start shortly.")
  end

  def handle_event("retry_webhook", %{"id" => id}, socket) do
    case Outreach.retry_webhook(id, actor: socket.assigns.current_scope.user) do
      {:ok, %{ordinal: ordinal}} = ok ->
        reply(ok, socket, "Webhook retry #{ordinal} of 3 queued.")

      error ->
        reply(error, socket, nil)
    end
  end

  defp update_worker(socket, id, fun) do
    opts = [actor: socket.assigns.current_scope.user]

    result =
      with {:ok, workers} <- Operations.list_mac_workers(opts),
           %{} = worker <- Enum.find(workers, &(&1.id == id)) do
        fun.(worker, opts)
      else
        nil -> {:error, :not_found}
        error -> error
      end

    reply(result, socket, "Worker updated.")
  end

  defp with_record(_socket, {:ok, record}, fun), do: fun.(record)
  defp with_record(_socket, error, _fun), do: error

  defp reply({:ok, _}, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> load()}

  defp reply({:error, reason}, socket, _message),
    do:
      {:noreply,
       socket
       |> assign(worker_token: nil, workers: [])
       |> put_flash(:error, AuditedView.error_message(reason))}

  @impl true
  def render(assigns) do
    # Presentation is fresh for this render (including a refused event),
    # but authority queries must never run once per streamed row.
    assigns =
      assign(assigns,
        worker_pin_keys: @worker_pin_keys,
        can_review?: Scope.reviewer?(assigns.current_scope),
        can_admin?: Scope.admin?(assigns.current_scope)
      )

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
        <.card :if={@owner_controls?} id="mac-worker-controls" title="Mac worker">
          <:subtitle>
            Enrollment and intake controls only. These actions do not start a model call.
          </:subtitle>
          <.form for={@worker_form} id="worker-enrol" phx-submit="enrol_worker" class="space-y-3">
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                :for={key <- @worker_pin_keys}
                field={@worker_form[key]}
                label={humanize(key)}
                type="text"
                required
                autocomplete="off"
              />
            </div>
            <.ui_button type="submit" variant="primary">Enroll worker</.ui_button>
          </.form>
          <div :if={@worker_token} class="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-4">
            <p class="text-sm text-amber-900">Copy this token now. It is displayed only once.</p>
            <code id="worker-token" class="mt-2 block break-all text-sm">{@worker_token}</code>
            <.ui_button id="dismiss-worker-token" phx-click="dismiss_worker_token" size="sm">
              Dismiss token
            </.ui_button>
          </div>
          <ul class="mt-4 divide-y divide-zinc-100">
            <li :for={worker <- @workers} id={"worker-#{worker.id}"} class="space-y-2 py-3">
              <div class="flex flex-wrap items-center gap-2 text-sm">
                <span class="font-mono">{worker.id}</span>
                <.badge status={worker.status} />
                <span>Intake: {worker.intake}</span>
              </div>
              <div :if={worker.status == :active} class="flex gap-2">
                <.ui_button
                  :if={worker.intake == :open}
                  id={"worker-pause-#{worker.id}"}
                  phx-click="pause_worker"
                  phx-value-id={worker.id}
                  size="sm"
                >Pause intake</.ui_button>
                <.ui_button
                  :if={worker.intake == :paused}
                  id={"worker-resume-#{worker.id}"}
                  phx-click="resume_worker"
                  phx-value-id={worker.id}
                  size="sm"
                >Resume intake</.ui_button>
                <.ui_button
                  id={"worker-disable-#{worker.id}"}
                  phx-click="disable_worker"
                  phx-value-id={worker.id}
                  size="sm"
                  variant="danger"
                >Disable worker</.ui_button>
              </div>
            </li>
          </ul>
        </.card>
        <.empty
          :if={@panels_unavailable?}
          id="attention-unavailable"
          icon="hero-lock-closed"
          title="Unavailable"
        >
          Failure records are not granted to this hosted owner.
        </.empty>
        <.card :if={!@panels_unavailable?} id="attention" title="Needs attention">
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
                  :if={@can_review?}
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
              <li
                :for={{dom_id, run} <- @streams.runs}
                id={dom_id}
                class="flex items-center gap-2 py-2.5"
              >
                <.link
                  navigate={~p"/runs/#{run.id}"}
                  class="group flex min-w-0 flex-1 items-center justify-between gap-3"
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
                <.ui_button
                  :if={@can_admin? and retryable?(run)}
                  id={"retry-run-#{run.id}"}
                  size="sm"
                  phx-click="retry_run"
                  phx-value-id={run.id}
                  data-confirm="Start a new run for this lead from the same trigger?"
                >
                  <.icon name="hero-arrow-path" class="size-4" /> Retry
                </.ui_button>
              </li>
            </ul>
          </.card>

          <.empty
            :if={@panels_unavailable?}
            id="webhooks-unavailable"
            icon="hero-lock-closed"
            title="Unavailable"
          >
            Failed webhook records are not granted to this hosted owner.
          </.empty>
          <.card :if={!@panels_unavailable?} id="failed-webhooks-card" title="Failed webhooks">
            <:subtitle>
              Provider events that could not be applied. A retry re-runs the original job (at most 3).
            </:subtitle>
            <ul id="failed-webhooks" phx-update="stream" class="-my-2 divide-y divide-zinc-100">
              <li
                id="failed-webhooks-empty"
                class="hidden py-6 text-center text-sm text-zinc-500 only:block"
              >
                No failed webhook events.
              </li>
              <li :for={{dom_id, event} <- @streams.webhooks} id={dom_id} class="py-2.5">
                <div class="flex items-center justify-between gap-3">
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium text-zinc-900">
                      {humanize(event.event_type)}
                      <span class="font-normal text-zinc-500">· {event.external_event_id}</span>
                    </p>
                    <p class="truncate text-xs text-zinc-500">
                      received <.timestamp at={event.received_at} />
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-2">
                    <.badge status={event.processing_status} />
                    <.ui_button
                      :if={@can_admin?}
                      id={"retry-webhook-#{event.id}"}
                      size="sm"
                      phx-click="retry_webhook"
                      phx-value-id={event.id}
                      data-confirm="Re-run this webhook event's original job?"
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> Retry
                    </.ui_button>
                  </div>
                </div>
              </li>
            </ul>
          </.card>

          <.empty
            :if={@panels_unavailable?}
            id="operations-unavailable"
            icon="hero-lock-closed"
            title="Unavailable"
          >
            Operation records are not granted to this hosted owner.
          </.empty>
          <.card :if={!@panels_unavailable?} id="operations-card" title="Operations">
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
                      :if={@can_admin? and operation.status in [:enqueued, :failed]}
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

  defp retryable?(run),
    do: run.status in [:failed, :budget_exhausted, :cancelled] and not run.retried?
end
