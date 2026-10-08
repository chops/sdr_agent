defmodule SdrAgentWeb.AdminLive do
  @moduledoc """
  Admin / provider status (S10b; ADM only): the runtime-selected model
  provider (`SdrAgent.AI.ModelProvider.Runtime.status/0`, Q0.1: model alias
  and resolved id, reviewed CLI version, whether its supervised server runs
  and the last init attestation) and integration adapters (module names
  only — never credentials), the
  daily model-call budget (`Agents.daily_model_calls/1` against
  `Agents.daily_model_call_limit/0`) and per-run limits, delivery (local
  capture only) with today's send quota (`SendQuotaDay`) and the compliance
  defaults, and the operators (`Accounts.list_users/1`; display name, email,
  role and status — password hashes are never read by operators).

  No `IntegrationCredential` resource exists yet (S2 assigns it to S6; it
  was not built), so credential status is not shown; adding it is an
  entity-model change outside S10. Read-only: user management stays with
  the `Accounts` API and `mix sdr.bootstrap_admin`.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Integrations
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Compliance
  alias SdrAgent.Outreach.Delivery
  alias SdrAgentWeb.AuditedView

  on_mount {SdrAgentWeb.LiveUserAuth, {:roles, [:admin]}}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Admin", loaded?: false, withheld: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user
    opts = [actor: user]

    with {:ok, users} <- Accounts.list_users(Keyword.put(opts, :sort, display_name: :asc)),
         {:ok, quotas} <-
           Outreach.list_records(
             Outreach.SendQuotaDay,
             Keyword.put(opts, :sort, local_date: :desc)
           ) do
      assign(socket,
        loaded?: true,
        withheld: nil,
        provider: Runtime.status(),
        integrations: [
          {"CRM", Integrations.crm()},
          {"Search", Integrations.search()},
          {"Web fetch", Integrations.web()}
        ],
        delivery_adapter: Delivery.adapter(),
        daily_used: Agents.daily_model_calls(user.tenant_id),
        daily_limit: Agents.daily_model_call_limit(),
        quota: List.first(quotas),
        send_cap: Compliance.daily_send_cap(),
        timezone: Compliance.timezone(),
        users: users
      )
    else
      {:error, reason} ->
        assign(socket, loaded?: false, withheld: AuditedView.error_message(reason))
    end
  end

  defp server_label(:running), do: "running"
  defp server_label(:not_running), do: "not running"
  defp server_label(:not_applicable), do: "in-process (no server)"

  defp attestation_label(%{status: :not_applicable}), do: "not applicable (deterministic)"
  defp attestation_label(%{status: :not_running}), do: "none (server not running)"

  defp attestation_label(%{status: :pending} = attestation),
    do: "pending: checked at the first call" <> launcher_note(attestation)

  defp attestation_label(%{status: :attested} = attestation),
    do: "attested #{attestation.model} on Claude Code #{attestation.version}"

  defp attestation_label(%{status: :drift} = attestation),
    do:
      "drift: #{attestation.reason}; calls are refused until the reviewed configuration is restored"

  defp launcher_note(%{command?: false}), do: " (llm-proxy-shim not found)"
  defp launcher_note(_attestation), do: ""

  defp short(nil), do: "not configured"
  defp short(module) when is_atom(module), do: module |> Module.split() |> List.last()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:admin}>
      <.page_header eyebrow="Administration">
        Providers, budgets & operators
        <:subtitle>
          Configuration as the running node sees it. Credentials are never displayed.
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
        <div class="grid gap-6 lg:grid-cols-3">
          <.card title="Model provider">
            <dl class="divide-y divide-zinc-100">
              <.field label="Provider">
                <span id="model-provider" class="font-medium">{short(@provider.provider)}</span>
              </.field>
              <.field label="Module">
                <span class="break-all font-mono text-xs">{inspect(@provider.provider)}</span>
              </.field>
              <.field label="Model">
                <span class="font-mono text-xs">
                  <span :if={@provider.model_alias} id="model-alias">{@provider.model_alias}</span>
                  <span :if={@provider.model_alias} class="text-zinc-400">→</span>
                  <span id="model-id">{@provider.model_id || "—"}</span>
                </span>
              </.field>
              <.field :if={@provider.reviewed_version} label="Reviewed CLI">
                <span id="reviewed-cli-version" class="font-mono text-xs">
                  Claude Code {@provider.reviewed_version}
                </span>
              </.field>
              <.field label="Server">
                <span
                  id="provider-server"
                  data-status={@provider.server}
                  class={[
                    "text-xs font-medium",
                    if(@provider.server == :not_running, do: "text-rose-700", else: "text-zinc-700")
                  ]}
                >
                  {server_label(@provider.server)}
                </span>
              </.field>
              <.field label="Last attestation">
                <span
                  id="model-attestation"
                  data-status={@provider.attestation.status}
                  class={[
                    "text-xs",
                    if(@provider.attestation.status == :drift,
                      do: "font-medium text-rose-700",
                      else: "text-zinc-700"
                    )
                  ]}
                >
                  {attestation_label(@provider.attestation)}
                  <span :if={@provider.attestation[:at]} class="block text-zinc-400">
                    <.timestamp at={@provider.attestation.at} />
                  </span>
                </span>
              </.field>
            </dl>
            <p class="mt-3 text-xs text-zinc-500">
              The deterministic fake is the default; <code>SDR_MODEL_PROVIDER=claude_cli</code>
              selects ClaudeCLI in development only (ADR-0004). Attestation drift on a real
              provider opens a critical attention failure.
            </p>
          </.card>

          <.card id="daily-budget" title="Model budget">
            <p class="text-3xl font-semibold tabular-nums" data-used={@daily_used}>
              {@daily_used}<span class="text-base font-normal text-zinc-400"> / {@daily_limit}</span>
            </p>
            <p class="text-xs text-zinc-500">model calls reserved today (UTC)</p>
            <div class="mt-3 h-2 overflow-hidden rounded-full bg-zinc-100">
              <div
                class="h-full rounded-full bg-teal-600"
                style={"width: #{if @daily_limit > 0, do: min(100, round(@daily_used * 100 / @daily_limit)), else: 100}%"}
              >
              </div>
            </div>
            <p class="mt-3 text-xs text-zinc-500">
              Per run: ≤ 20 model calls, ≤ 100k tokens; exhaustion stops the run with a recorded reason.
            </p>
          </.card>

          <.card title="Delivery">
            <dl class="divide-y divide-zinc-100">
              <.field label="Adapter">
                <span id="delivery-adapter" class="font-mono text-xs">{short(@delivery_adapter)}</span>
              </.field>
              <.field label="External delivery">
                <span class="text-emerald-700">none (local capture)</span>
              </.field>
              <.field label="Send cap">{@send_cap} / day ({@timezone})</.field>
              <.field label="Today">
                <span :if={@quota}>{@quota.consumed} / {@quota.cap} on {@quota.local_date}</span>
                <span :if={is_nil(@quota)} class="text-zinc-400">no sends yet</span>
              </.field>
            </dl>
          </.card>
        </div>

        <.card title="Integrations">
          <:subtitle>Fixture-backed adapters (no network in the MVP).</:subtitle>
          <dl class="grid gap-x-8 sm:grid-cols-3">
            <.field :for={{label, module} <- @integrations} label={label}>
              <span class="font-mono text-xs">{short(module)}</span>
            </.field>
          </dl>
        </.card>

        <.card id="operators" title="Operators">
          <div class="overflow-x-auto">
            <table class="w-full min-w-[32rem] text-left text-sm">
              <thead class="text-xs uppercase tracking-wider text-zinc-500">
                <tr>
                  <th scope="col" class="py-2 pr-4 font-medium">Name</th>
                  <th scope="col" class="py-2 pr-4 font-medium">Email</th>
                  <th scope="col" class="py-2 pr-4 font-medium">Role</th>
                  <th scope="col" class="py-2 font-medium">Status</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-100">
                <tr :for={user <- @users} id={"users-#{user.id}"}>
                  <td class="py-2.5 pr-4 font-medium text-zinc-900">{user.display_name}</td>
                  <td class="py-2.5 pr-4 font-mono text-xs text-zinc-600">{to_string(user.email)}</td>
                  <td class="py-2.5 pr-4"><.badge status={user.role} attr="role" /></td>
                  <td class="py-2.5"><.badge status={user.status} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
