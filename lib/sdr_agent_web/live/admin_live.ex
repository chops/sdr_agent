defmodule SdrAgentWeb.AdminLive do
  @moduledoc """
  Admin / provider status (S10b; ADM only): the runtime-selected model
  provider (`SdrAgent.AI.ModelProvider.Runtime.status/0`, Q0.1: configured
  and effective provider — none, with the refusal, while calls are refused —
  the configured and effective model profile and the refusal's reason in
  words (R0-05; read-only, no model call, no switch: that is C2), model alias
  and resolved id, reviewed CLI version, the app's pinned CLI path (R0-02;
  shown, never run), whether its supervised server runs
  and the last init attestation — refreshed live, like the other console
  views (`SdrAgentWeb.LiveRefresh`), whenever an audit event commits, so a
  first call's attestation or drift shows without a revisit; the card only
  reflects it, the per-call attestation is what refuses a drifted CLI) and
  integration adapters (module names
  only — never credentials), the
  daily model-call budget (`Agents.daily_model_calls/1` against
  `Agents.daily_model_call_limit/0`) and per-run limits, delivery (local
  capture only) with today's send quota (`SendQuotaDay`) and the compliance
  defaults, and the operators (`Accounts.list_users/1`; display name, email,
  role and status — password hashes are never read by operators).

  Model call budgets (C9-05, REQ-R0-9): the tenant's real-model call grants
  (`Agents.list_grants/1`) with their allocations, availability and the
  attempts consumed (`Agents.grant_usage/2`), and the owner's editor:
  create, edit terms, revoke, release a held allocation early. Each change
  is staged in the page first — a review step showing exactly what will be
  saved (times entered as America/Denver wall times, shown in Denver and
  UTC; `SdrAgentWeb.GrantForm`) or an inline confirmation for revoke and
  release, never a browser dialog — and only the confirmation calls the
  domain, as the signed-in user, with the revision the admin saw
  (`expected_revision`); a stale one shows a reload prompt. Domain
  refusals are shown next to the inputs. The confirmation acts only on
  state held by the socket, so a forged event without a review step or a
  pending confirmation does nothing; a demoted or signed-out operator is
  redirected before any event reaches the domain (`SdrAgentWeb.LiveUserAuth`).

  No `IntegrationCredential` resource exists yet (S2 assigns it to S6; it
  was not built), so credential status is not shown; adding it is an
  entity-model change outside S10. Read-only: user management stays with
  the `Accounts` API and `mix sdr.bootstrap_admin`.
  """
  use SdrAgentWeb, :live_view

  import SdrAgentWeb.AdminLive.BudgetComponents,
    only: [budgets: 1, availability: 2, allocation_label: 1]

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Integrations
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Compliance
  alias SdrAgent.Outreach.Delivery
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.GrantForm
  alias SdrAgentWeb.LiveRefresh

  on_mount {SdrAgentWeb.LiveUserAuth, {:roles, [:admin]}}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Admin",
       loaded?: false,
       withheld: nil,
       grants: [],
       usage: %{},
       budget: nil,
       confirm: nil
     )
     |> LiveRefresh.attach(&load/1)}
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
           ),
         {:ok, grants} <- Agents.list_grants(opts),
         {:ok, usage} <- Agents.grant_usage(Enum.map(grants, & &1.id), opts) do
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
        users: users,
        grants: Enum.reverse(grants),
        usage: usage,
        now: SdrAgent.Clock.utc_now()
      )
    else
      {:error, reason} ->
        assign(socket, loaded?: false, withheld: AuditedView.error_message(reason))
    end
  end

  ## Model call budgets (C9-05)

  @impl true
  def handle_event("new_grant", _params, socket) do
    {:noreply, assign(socket, budget: new_budget(:create, nil), confirm: nil)}
  end

  def handle_event("edit_grant", %{"id" => id}, socket) do
    case Agents.get_grant(id, actor: actor(socket)) do
      {:ok, %{status: :active} = grant} ->
        {:noreply, assign(socket, budget: new_budget(:edit, grant), confirm: nil)}

      {:ok, _revoked} ->
        {:noreply,
         socket |> assign(budget: nil) |> put_flash(:error, "A revoked budget cannot be edited.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AuditedView.error_message(reason))}
    end
  end

  def handle_event("reload_grant", _params, %{assigns: %{budget: %{mode: :edit}}} = socket),
    do: handle_event("edit_grant", %{"id" => socket.assigns.budget.grant.id}, socket)

  def handle_event("cancel_grant", _params, socket), do: {:noreply, assign(socket, budget: nil)}

  def handle_event("change_grant", %{"grant" => params}, socket),
    do: update_budget(socket, &%{&1 | params: params})

  def handle_event("add_allocation", _params, socket),
    do: update_budget(socket, &%{&1 | params: GrantForm.add_allocation(&1.params)})

  def handle_event("remove_allocation", %{"index" => index}, socket) do
    update_budget(socket, fn budget ->
      if MapSet.member?(budget.locked, index),
        do: budget,
        else: %{budget | params: GrantForm.remove_allocation(budget.params, index)}
    end)
  end

  def handle_event("review_grant", %{"grant" => params}, socket),
    do: update_budget(socket, &review(&1, params))

  def handle_event("back_to_edit", _params, socket),
    do: update_budget(socket, &%{&1 | step: :edit})

  # Acts only on a review the socket holds: a forged event saves nothing.
  def handle_event("confirm_grant", _params, %{assigns: %{budget: %{step: :review}}} = socket),
    do: save(socket, socket.assigns.budget)

  def handle_event("revoke_grant", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.grants, &(&1.id == id and &1.status == :active)) do
      nil ->
        {:noreply, socket}

      grant ->
        confirm = %{
          action: :revoke,
          grant_id: grant.id,
          revision: grant.revision,
          name: grant.name,
          error: nil
        }

        {:noreply, assign(socket, confirm: confirm, budget: nil)}
    end
  end

  def handle_event("release_allocation", %{"id" => id}, socket) do
    case held_allocation(socket.assigns, id) do
      nil ->
        {:noreply, socket}

      {grant, allocation} ->
        confirm = %{
          action: :release,
          grant_id: grant.id,
          revision: grant.revision,
          name: grant.name,
          allocation_id: allocation.id,
          key: allocation.key,
          profile_id: allocation.profile_id,
          error: nil
        }

        {:noreply, assign(socket, confirm: confirm, budget: nil)}
    end
  end

  def handle_event("cancel_action", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  # Acts only on the confirmation the socket holds, never on event params.
  def handle_event("confirm_action", _params, %{assigns: %{confirm: %{} = confirm}} = socket) do
    actor = actor(socket)

    with {:ok, grant} <- Agents.get_grant(confirm.grant_id, actor: actor),
         {:ok, _grant} <- perform(confirm, grant, actor) do
      {:noreply,
       socket
       |> assign(confirm: nil)
       |> put_flash(:info, performed(confirm))
       |> load()}
    else
      {:error, error} ->
        {:noreply, assign(socket, confirm: %{confirm | error: refusal_message(error)})}
    end
  end

  def handle_event(_budget_event, _params, socket), do: {:noreply, socket}

  defp actor(socket), do: socket.assigns.current_scope.user

  defp new_budget(mode, grant) do
    params = if grant, do: GrantForm.params_for(grant), else: GrantForm.new_params()

    %{
      mode: mode,
      grant: grant,
      step: :edit,
      params: params,
      locked: if(grant, do: MapSet.new(Map.keys(params["allocations"])), else: MapSet.new()),
      terms: nil,
      changes: nil,
      errors: %{},
      error: nil,
      stale: nil
    }
  end

  defp update_budget(%{assigns: %{budget: nil}} = socket, _fun), do: {:noreply, socket}

  defp update_budget(socket, fun),
    do: {:noreply, assign(socket, budget: fun.(socket.assigns.budget))}

  defp review(budget, params) do
    budget = %{budget | params: params, error: nil, stale: nil}

    with {:ok, terms} <- GrantForm.parse(params),
         {:ok, changes} <- changes_for(budget, terms) do
      %{budget | step: :review, terms: terms, changes: changes, errors: %{}}
    else
      {:error, errors} ->
        %{budget | step: :edit, errors: errors}

      :unchanged ->
        %{
          budget
          | step: :edit,
            errors: %{},
            error: "Nothing to change: the form matches revision #{budget.grant.revision}."
        }
    end
  end

  defp changes_for(%{mode: :create}, _terms), do: {:ok, nil}

  defp changes_for(%{mode: :edit, grant: grant}, terms) do
    case GrantForm.changes(grant, terms) do
      %{terms: [], allocations: []} -> :unchanged
      changes -> {:ok, changes}
    end
  end

  defp save(socket, budget) do
    case write(budget, actor(socket)) do
      {:ok, grant} ->
        verb =
          if budget.mode == :create, do: "created", else: "saved as revision #{grant.revision}"

        {:noreply,
         socket
         |> assign(budget: nil)
         |> put_flash(:info, "Budget #{grant.name} #{verb}.")
         |> load()}

      {:error, error} ->
        {:noreply, assign(socket, budget: refused(budget, error))}
    end
  end

  defp write(%{mode: :create, terms: terms}, actor),
    do: Agents.create_grant(GrantForm.create_attrs(terms), actor: actor)

  defp write(%{mode: :edit, grant: grant, changes: changes}, actor),
    do: Agents.update_grant_terms(grant, GrantForm.update_attrs(grant, changes), actor: actor)

  defp refused(budget, error) do
    budget = %{budget | step: :edit}

    if stale?(error) do
      %{budget | stale: stale_message(error)}
    else
      errors =
        error
        |> AuditedView.field_errors()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      %{budget | errors: errors, error: AuditedView.error_message(error)}
    end
  end

  defp stale?(error),
    do: error |> AuditedView.field_errors() |> Enum.any?(&(elem(&1, 0) == :expected_revision))

  defp stale_message(error) do
    {_field, detail} =
      error |> AuditedView.field_errors() |> Enum.find(&(elem(&1, 0) == :expected_revision))

    "Someone changed this budget since you opened it (your revision #{detail}). " <>
      "Nothing was saved; reload to see the current terms."
  end

  defp refusal_message(error) do
    if stale?(error), do: stale_message(error), else: AuditedView.error_message(error)
  end

  defp perform(%{action: :revoke} = confirm, grant, actor),
    do: Agents.revoke_grant(grant, %{expected_revision: confirm.revision}, actor: actor)

  defp perform(%{action: :release} = confirm, grant, actor) do
    Agents.release_allocation(
      grant,
      %{expected_revision: confirm.revision, key: confirm.key, profile_id: confirm.profile_id},
      actor: actor
    )
  end

  defp performed(%{action: :revoke, name: name}), do: "Budget #{name} revoked."

  defp performed(%{action: :release} = confirm),
    do: "Allocation #{allocation_label(confirm)} of #{confirm.name} released early."

  defp held_allocation(assigns, allocation_id) do
    Enum.find_value(assigns.grants, fn grant ->
      allocation = Enum.find(grant.allocations, &(&1.id == allocation_id))

      if (grant.status == :active and allocation) &&
           availability(allocation, assigns.now) == :held,
         do: {grant, allocation}
    end)
  end

  defp server_label(:running), do: "running"
  defp server_label(:not_running), do: "not running"

  defp server_label(:blocked),
    do: "blocked: earlier CLI work is not confirmed stopped; calls are refused"

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

  # One server serves the configured provider, so the effective profile is
  # the configured one while calls are admitted, and none while refused.
  defp effective_profile(%{effective: nil}), do: "none"
  defp effective_profile(provider), do: provider.profile_id || "none"

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
              <.field label="Configured">
                <span id="model-provider" class="font-medium">{short(@provider.configured)}</span>
              </.field>
              <.field label="Effective">
                <span
                  id="effective-provider"
                  data-effective={
                    if @provider.effective, do: short(@provider.effective), else: "none"
                  }
                  class={[
                    "text-xs font-medium",
                    if(@provider.effective, do: "text-emerald-700", else: "text-rose-700")
                  ]}
                >
                  <span :if={@provider.effective}>{short(@provider.effective)}</span>
                  <span :if={is_nil(@provider.effective)}>
                    none: calls refused ({@provider.refusal})
                  </span>
                </span>
              </.field>
              <.field :if={@provider.refusal} label="Refused because">
                <span
                  id="provider-refusal"
                  data-refusal={@provider.refusal}
                  class="block max-w-xs text-xs text-rose-700"
                >
                  {Runtime.refusal_message(@provider.refusal)}
                </span>
              </.field>
              <.field label="Configured profile">
                <span
                  id="configured-profile"
                  data-profile={@provider.profile_id || "none"}
                  class="font-mono text-xs"
                >
                  {@provider.profile_id || "none"}
                </span>
              </.field>
              <.field label="Effective profile">
                <span
                  id="effective-profile"
                  data-profile={effective_profile(@provider)}
                  class={[
                    "font-mono text-xs",
                    if(@provider.effective, do: "text-emerald-700", else: "text-rose-700")
                  ]}
                >
                  {effective_profile(@provider)}
                </span>
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
              <.field :if={@provider.cli_executable} label="Pinned CLI">
                <span id="pinned-cli-path" class="break-all font-mono text-xs">
                  {@provider.cli_executable}
                </span>
                <span
                  :if={@provider.reviewed_version}
                  id="pinned-cli-version"
                  class="block text-xs text-zinc-500"
                >
                  Claude Code {@provider.reviewed_version} (the reviewed build)
                </span>
              </.field>
              <.field label="Server">
                <span
                  id="provider-server"
                  data-status={@provider.server}
                  class={[
                    "text-xs font-medium",
                    if(@provider.server in [:not_running, :blocked],
                      do: "text-rose-700",
                      else: "text-zinc-700"
                    )
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

        <.budgets
          grants={@grants}
          usage={@usage}
          budget={@budget}
          confirm={@confirm}
          now={@now}
        />

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
