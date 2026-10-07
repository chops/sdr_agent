defmodule SdrAgentWeb.RunLive do
  @moduledoc """
  One agent run, reconstructed from Postgres alone (S10b; spec §12, S7 "what
  S10 must know"): the AgentRun (status, phase, budget, trace), its
  Decisions, ModelInvocations and ToolInvocations in order, and the signal
  AuditEvents of the run. Request/response/input/output bodies link to the
  payload viewer (audited `read_content`); trace ids link to Grafana Tempo.
  Read-only; an auditor's view is recorded with the run id first.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.Sales
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData
  alias SdrAgentWeb.LiveRefresh

  @budget [
    {"Model calls", :model_calls_used, :max_model_calls},
    {"Tool calls", :tool_calls_used, :max_tool_calls},
    {"Tokens", :tokens_used, :max_tokens}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Agent run",
       loaded?: false,
       withheld: nil,
       not_found?: false,
       run_id: nil
     )
     |> LiveRefresh.attach(&refresh/1)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, if(connected?(socket), do: socket |> assign(run_id: id) |> load(id), else: socket)}
  end

  defp refresh(%{assigns: %{run_id: nil}} = socket), do: socket
  defp refresh(socket), do: load(socket, socket.assigns.run_id)

  defp load(socket, id) do
    scope = socket.assigns.current_scope
    opts = [actor: scope.user]

    with {:ok, run} <- fetch_run(id, opts),
         {:ok, decisions} <- Agents.list_decisions(run.id, opts),
         {:ok, invocations} <- Agents.list_model_invocations(run.id, opts),
         {:ok, tools} <- Agents.list_tool_invocations(run.id, opts),
         {:ok, events} <- Audit.list_events(opts),
         {:ok, contact} <- run_contact(run, opts),
         :ok <- AuditedView.record(scope, "SdrAgent.Agents.AgentRun", run.id, "agent run view") do
      assign(socket,
        loaded?: true,
        withheld: nil,
        not_found?: false,
        page_title: "Run · #{ConsoleData.contact_name(contact)}",
        run: run,
        contact: contact,
        decisions: decisions,
        invocations: invocations,
        tools: tools,
        signals: Enum.filter(events, &(&1.agent_run_id == run.id and &1.category == :signal)),
        budget: budget(run.budget)
      )
    else
      {:error, :not_found} ->
        assign(socket, loaded?: false, withheld: nil, not_found?: true)

      {:error, reason} ->
        assign(socket, loaded?: false, withheld: AuditedView.error_message(reason))
    end
  end

  defp fetch_run(id, opts) do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         {:ok, run} <- Agents.get_run(id, opts) do
      {:ok, run}
    else
      :error -> {:error, :not_found}
      {:error, %Ash.Error.Invalid{}} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      other -> other
    end
  end

  defp run_contact(%{lead_id: nil}, _opts), do: {:ok, nil}

  defp run_contact(%{lead_id: lead_id}, opts) do
    with {:ok, lead} <- Sales.fetch(Sales.Lead, lead_id, opts) do
      Sales.fetch(Sales.Contact, lead.contact_id, opts)
    end
  end

  defp budget(budget) do
    for {label, used, max} <- @budget do
      used = Map.get(budget, used) || 0
      max = Map.get(budget, max)

      %{
        label: label,
        used: used,
        max: max,
        pct: if(max && max > 0, do: min(100, round(used * 100 / max)), else: 0)
      }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:operations}>
      <.link
        navigate={~p"/operations"}
        class="mb-4 inline-flex items-center gap-1 text-xs font-medium text-zinc-500 hover:text-zinc-900"
      >
        <.icon name="hero-arrow-left" class="size-3.5" /> Runs & operations
      </.link>

      <.empty :if={@not_found?} id="not-found" icon="hero-magnifying-glass" title="Run not found" />
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
        <.page_header id="run-header" eyebrow={"Agent run · #{@run.trigger_signal_type}"}>
          {ConsoleData.contact_name(@contact)}
          <.badge status={@run.status} class="ml-2 align-middle" />
          <:subtitle>
            <span class="flex flex-wrap items-center gap-2">
              phase {humanize(@run.phase)} · started <.timestamp at={@run.started_at} /> · finished
              <.timestamp at={@run.finished_at} />
              <.trace_link trace_id={@run.trace_id} label="Trace in Tempo" />
              <.link
                :if={@run.lead_id}
                navigate={~p"/leads/#{@run.lead_id}"}
                class="text-teal-700 hover:underline"
              >
                Lead →
              </.link>
            </span>
            <span :if={@run.failure_reason} class="mt-1 block text-rose-700">{@run.failure_reason}</span>
          </:subtitle>
        </.page_header>

        <div class="grid gap-3 sm:grid-cols-3">
          <div :for={b <- @budget} class="rounded-xl border border-zinc-200 bg-white p-4 shadow-sm">
            <p class="text-xs uppercase tracking-wider text-zinc-500">{b.label}</p>
            <p class="mt-1 text-xl font-semibold tabular-nums">
              {b.used}<span class="text-sm font-normal text-zinc-400"> / {b.max || "∞"}</span>
            </p>
            <div class="mt-2 h-1.5 overflow-hidden rounded-full bg-zinc-100">
              <div class="h-full rounded-full bg-teal-600" style={"width: #{b.pct}%"}></div>
            </div>
          </div>
        </div>

        <.card id="decisions" title="Decisions">
          <:subtitle>
            What the agent decided and why, in order (deterministic rules and LLM judgements).
          </:subtitle>
          <ol class="-my-2 divide-y divide-zinc-100">
            <li :for={decision <- @decisions} id={"decision-#{decision.id}"} class="py-2.5">
              <div class="flex flex-wrap items-center gap-2">
                <span class="text-sm font-medium text-zinc-900">{humanize(decision.kind)}</span>
                <.badge status={decision.mode} attr="mode" />
                <span class="rounded bg-zinc-100 px-1.5 py-0.5 font-mono text-xs text-zinc-700">
                  {decision.outcome}
                </span>
                <span :if={decision.confidence} class="text-xs text-zinc-500">
                  {round(decision.confidence * 100)}%
                </span>
                <span class="ml-auto text-xs text-zinc-500"><.timestamp at={decision.decided_at} /></span>
              </div>
              <p :if={decision.rationale} class="mt-1 text-sm text-zinc-600">{decision.rationale}</p>
              <p :if={decision.rule_id} class="mt-0.5 font-mono text-xs text-zinc-500">
                rule {decision.rule_id}@{decision.rule_version}
              </p>
            </li>
          </ol>
          <.empty :if={@decisions == []} icon="hero-scale" title="No decisions recorded" />
        </.card>

        <div class="grid gap-6 xl:grid-cols-2">
          <.card id="model-invocations" title="Model invocations">
            <ol class="-my-2 divide-y divide-zinc-100">
              <li
                :for={inv <- @invocations}
                id={"model-invocation-#{inv.id}"}
                class="space-y-1 py-2.5"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-sm font-medium">#{inv.sequence_in_run} {humanize(inv.purpose)}</span>
                  <.badge status={inv.status} />
                  <.badge
                    :if={inv.validation_status}
                    status={inv.validation_status}
                    attr="validation"
                  />
                </div>
                <p class="text-xs text-zinc-500">
                  {humanize(inv.provider)} · <span class="font-mono">{inv.model_id}</span>
                  <span :if={inv.latency_ms}>· {inv.latency_ms} ms</span>
                  <span :if={inv.usage}>
                    · {inv.usage.input_tokens} in / {inv.usage.output_tokens} out tokens
                  </span>
                </p>
                <p class="flex flex-wrap gap-2 text-xs">
                  <.link
                    navigate={~p"/audit/payloads/#{hex(inv.request_sha256)}"}
                    class="text-teal-700 hover:underline"
                  >
                    request
                  </.link>
                  <.link
                    :if={inv.response_sha256}
                    navigate={~p"/audit/payloads/#{hex(inv.response_sha256)}"}
                    class="text-teal-700 hover:underline"
                  >
                    response
                  </.link>
                  <.trace_link trace_id={inv.trace_id} />
                </p>
              </li>
            </ol>
            <.empty :if={@invocations == []} icon="hero-cpu-chip" title="No model calls" />
          </.card>

          <.card id="tool-invocations" title="Tool invocations">
            <ol class="-my-2 divide-y divide-zinc-100">
              <li :for={tool <- @tools} id={"tool-invocation-#{tool.id}"} class="space-y-1 py-2.5">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-sm font-medium">
                    #{tool.sequence_in_run} {tool.action_module |> String.split(".") |> List.last()}
                  </span>
                  <.badge status={tool.status} />
                  <span :if={tool.duration_ms} class="text-xs text-zinc-500">{tool.duration_ms} ms</span>
                </div>
                <p class="flex flex-wrap gap-2 text-xs">
                  <.link
                    navigate={~p"/audit/payloads/#{hex(tool.input_sha256)}"}
                    class="text-teal-700 hover:underline"
                  >
                    input
                  </.link>
                  <.link
                    :if={tool.output_sha256}
                    navigate={~p"/audit/payloads/#{hex(tool.output_sha256)}"}
                    class="text-teal-700 hover:underline"
                  >
                    output
                  </.link>
                </p>
              </li>
            </ol>
            <.empty :if={@tools == []} icon="hero-wrench" title="No tool calls" />
          </.card>
        </div>

        <.card id="signals" title="Signals">
          <:subtitle>The run's signal events from the audit ledger.</:subtitle>
          <ol class="-my-1 divide-y divide-zinc-100">
            <li
              :for={event <- @signals}
              id={"signal-#{event.id}"}
              class="flex items-center gap-3 py-2 text-sm"
            >
              <span class="w-14 font-mono text-xs text-zinc-400">#{event.sequence}</span>
              <span class="font-mono text-xs text-zinc-800">{event.event_type}</span>
              <span class="ml-auto text-xs text-zinc-500"><.timestamp at={event.occurred_at} /></span>
            </li>
          </ol>
          <.empty :if={@signals == []} icon="hero-bolt" title="No signals recorded" />
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
