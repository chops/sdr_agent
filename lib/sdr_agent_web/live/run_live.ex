defmodule SdrAgentWeb.RunLive do
  @moduledoc """
  One agent run, reconstructed from Postgres alone (S10b; spec §12, S7 "what
  S10 must know"): the AgentRun (status, phase, budget, trace), its
  Decisions, ModelInvocations and ToolInvocations in order, and the signal
  AuditEvents of the run. Request/response/input/output bodies link to the
  payload viewer (audited `read_content`); trace ids link to Grafana Tempo.
  An admin may retry a stopped run that has no retry yet (`SDR.retry_run/2`,
  S13b; the new run opens); everything else is read-only. An auditor's view
  is recorded with the run id first.

  The run's settings snapshot (C4-R4, C4-R11, C4-R14;
  `SdrAgent.Agents.run_settings_summary/2`, metadata only): per setting the
  revision number, the built-in default version or "not set", and each limit
  as the "limit at snapshot" and the "run ceiling" (the run's frozen
  allowance before independent budgets), apart from "allowed now", which is
  not determined here: grants, the tenant-day limit and provider quotas are
  checked at use. A later save never changes what is shown. A run created
  before C4 has no snapshot and says so. An auditor's view of the snapshot
  is recorded first; without that record the snapshot is withheld, never
  shown as missing.

  The three B1-04 source caps say "checked at use" only for a run whose
  pinned AgentDefinition declares the enforcing `BuildEvidenceBundle`
  version; an older run is labelled "not enforced for this run", so the
  registry never implies retroactive enforcement. The run's
  `research_caps` Decision (in the Decisions list) is what was applied.
  """
  use SdrAgentWeb, :live_view

  import SdrAgentWeb.SettingsLive.Components, only: [delimit: 1]

  alias SdrAgent.Agents
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Audit
  alias SdrAgent.Sales
  alias SdrAgent.SDR
  alias SdrAgent.SDR.Actions.BuildEvidenceBundle
  alias SdrAgent.SDR.SDRAgent
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.ConsoleData
  alias SdrAgentWeb.LiveRefresh
  alias SdrAgentWeb.Scope

  @settings_kinds [
    :offering_profile,
    :booking_link,
    :writing_guide,
    :research_brief,
    :operational_limits
  ]

  # Enforced by BuildEvidenceBundle (B1-04) only for runs whose definition declares it.
  @b1_caps [:research_max_sources, :research_max_source_chars, :research_max_total_source_chars]

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
         {:ok, runs} <- Agents.list_runs(opts),
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
        budget: budget(run.budget),
        settings: settings_summary(run, scope),
        caps_declared: caps_declared?(run, opts),
        retryable?:
          run.status in [:failed, :budget_exhausted, :cancelled] and
            not Enum.any?(runs, &(&1.retry_of_id == run.id))
      )
    else
      {:error, :not_found} ->
        assign(socket, loaded?: false, withheld: nil, not_found?: true)

      {:error, reason} ->
        assign(socket, loaded?: false, withheld: AuditedView.error_message(reason))
    end
  end

  @impl true
  def handle_event("retry_run", _params, socket) do
    case SDR.retry_run(socket.assigns.run.id, actor: socket.assigns.current_scope.user) do
      {:ok, %{run: run}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Retry queued: this is the new run.")
         |> push_navigate(to: ~p"/runs/#{run.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AuditedView.error_message(reason))}
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

  # Whether the run's pinned definition declares the B1-04 caps' enforcer.
  defp caps_declared?(run, opts) do
    case Agents.get_definition(run.agent_definition_id, opts) do
      {:ok, definition} -> SDRAgent.declares?(definition.definition, BuildEvidenceBundle)
      _other -> false
    end
  end

  # The snapshot shown, recorded first for an auditor. A failed read or
  # record withholds it; only a run without a snapshot is `:none`.
  defp settings_summary(%{settings_snapshot_id: nil}, _scope), do: :none

  defp settings_summary(run, scope) do
    with {:ok, summary} <- Agents.run_settings_summary(run, actor: scope.user),
         :ok <-
           AuditedView.record(
             scope,
             "SdrAgent.Agents.RunSettingsSnapshot",
             summary.id,
             "run settings view"
           ) do
      {:ok, summary}
    else
      {:error, :no_settings_snapshot} -> :none
      {:error, reason} -> {:withheld, AuditedView.error_message(reason)}
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

  attr :settings, :any, required: true
  attr :kinds, :list, required: true
  attr :caps_declared, :boolean, required: true

  defp run_settings(assigns) do
    assigns =
      assign(assigns,
        rules:
          for {field, rule} <- Safeguards.limit_rules() do
            {field, Map.put(rule, :label, enforcement(field, rule, assigns.caps_declared))}
          end
      )

    ~H"""
    <.card id="run-settings" title="Settings snapshot">
      <:subtitle>
        The settings this run uses, bound when it was created; a later save never changes them.
      </:subtitle>
      <:actions>
        <.link navigate={~p"/settings"} class="text-xs font-medium text-teal-700 hover:underline">
          Current settings →
        </.link>
      </:actions>

      <p :if={@settings == :none} id="run-settings-none" class="text-sm text-zinc-600">
        <.icon name="hero-clock" class="size-4 text-zinc-400" />
        This run was created before run settings existed: it has no settings snapshot, and
        its settings-dependent steps fail closed. Nothing current is shown in its place.
      </p>

      <div
        :if={match?({:withheld, _}, @settings)}
        id="run-settings-withheld"
        class="flex items-start gap-2 rounded-lg border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800"
      >
        <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
        <span>The settings snapshot could not be shown: {elem(@settings, 1)}</span>
      </div>

      <div :if={match?({:ok, _}, @settings)} class="space-y-5">
        <ul class="grid gap-2 sm:grid-cols-2 lg:grid-cols-5">
          <li
            :for={kind <- @kinds}
            id={"run-setting-#{kind}"}
            data-source={elem(@settings, 1).slots[kind].source}
            class="rounded-lg border border-zinc-200 px-3 py-2"
          >
            <p class="text-xs uppercase tracking-wider text-zinc-500">{humanize(kind)}</p>
            <p class="mt-0.5 text-sm font-medium text-zinc-900">
              {slot_label(elem(@settings, 1).slots[kind])}
            </p>
          </li>
        </ul>

        <div class="overflow-x-auto">
          <table class="w-full min-w-[40rem] text-left text-sm">
            <thead class="text-xs uppercase tracking-wider text-zinc-500">
              <tr>
                <th scope="col" class="py-2 pr-4 font-medium">Limit</th>
                <th scope="col" class="py-2 pr-4 text-right font-medium">limit at snapshot</th>
                <th scope="col" class="py-2 pr-4 text-right font-medium">run ceiling</th>
                <th scope="col" class="py-2 font-medium">allowed now</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100">
              <tr
                :for={{field, rule} <- @rules}
                id={"run-limit-#{field}"}
                data-at-snapshot={elem(@settings, 1).limits[field]}
                data-run-ceiling={elem(@settings, 1).run_ceilings[field]}
              >
                <th scope="row" class="py-2 pr-4 font-medium text-zinc-900">{humanize(field)}</th>
                <td class="py-2 pr-4 text-right tabular-nums">
                  {delimit(elem(@settings, 1).limits[field])}
                </td>
                <td class="py-2 pr-4 text-right tabular-nums">
                  {delimit(elem(@settings, 1).run_ceilings[field])}
                </td>
                <td class="py-2 text-xs">
                  <span :if={rule.label == :checked} class="text-zinc-700">checked at use</span>
                  <span :if={rule.label == :not_for_run} class="text-amber-700">
                    not enforced for this run
                  </span>
                  <span :if={rule.label == :not_yet} class="text-amber-700">
                    not yet enforced
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-xs text-zinc-500">
          The run ceiling is the run's frozen allowance: the snapshot value, lowered for the
          run_* fields by its assignment. Whether another call is allowed now is not
          determined here: at each use the guarded step also applies the real-model grant
          allocation, the tenant-day model-call limit and provider quotas.
        </p>
      </div>
    </.card>
    """
  end

  defp enforcement(_field, %{enforced_by: nil}, _declared?), do: :not_yet
  defp enforcement(field, _rule, false) when field in @b1_caps, do: :not_for_run
  defp enforcement(_field, _rule, _declared?), do: :checked

  defp slot_label(%{source: :revision, number: number}), do: "revision #{number}"

  defp slot_label(%{source: :code_default, version: version}),
    do: "built-in default version #{version}"

  defp slot_label(%{source: :absent}), do: "not set"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, settings_kinds: @settings_kinds)

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
          <:actions>
            <.ui_button
              :if={Scope.admin?(@current_scope) and @retryable?}
              id="retry-run"
              phx-click="retry_run"
              data-confirm="Start a new run for this lead from the same trigger?"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Retry run
            </.ui_button>
          </:actions>
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

        <.run_settings
          settings={@settings}
          kinds={@settings_kinds}
          caps_declared={@caps_declared}
        />

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
