defmodule SdrAgentWeb.AdminLive do
  @moduledoc """
  Admin / provider status (S10b; ADM only): the runtime-selected model
  provider (`SdrAgent.AI.ModelProvider.Runtime.status/0`, Q0.1: configured
  and effective provider — none, with the refusal, while calls are refused —
  model alias and resolved id, reviewed CLI version, the app's pinned CLI
  path (R0-02; shown, never run), whether its supervised server runs and the
  last init attestation; the card only reflects the attestation, the
  per-call attestation is what refuses a drifted CLI) and integration
  adapters (module names only — never credentials), the daily model-call
  budget (`Agents.daily_model_calls/1` against
  `Agents.daily_model_call_limit/0`) and per-run limits, delivery (local
  capture only) with today's send quota (`SendQuotaDay`) and the compliance
  defaults, and the operators (`Accounts.list_users/1`; display name, email,
  role and status — password hashes are never read by operators).

  The model card, the switch request and the resolver (R0-05,
  `docs/product/r0/r0-05-interface.md`; `SdrAgentWeb.AdminLive.ModelComponents`):

    * **The card** shows one C2-02c sample (desired, running and accepting
      profile, hold and stage, the open switch, the publication time; an
      unknown field is "unknown", never the default) and the newest stored
      switch (`Agents.list_profile_switches/1`, as the admin). It is re-read
      whenever an audit event commits (`SdrAgentWeb.LiveRefresh`) and by
      "Refresh status"; there is no timer, so it can lag the coordinator.
    * **A switch** is staged in the page: opening it reads the setting
      (`Agents.get_profile_setting/1`; its from and revision, or the
      registry default at revision 1 when absent; a failed read opens
      nothing), a target is chosen from `ModelProfiles.real_ids/0` and
      reviewed, and only the confirmation calls
      `Coordinator.request_switch/2` with the stored review.
    * **A blocked switch** is resolved through a socket-local review
      (`SdrAgentWeb.AdminLive.Resolution`): the facts
      (`Agents.blocked_switch_facts/2`), b2β's statement and the typed
      `STOPPED <switch id>`; the attempt (`Agents.resolve_blocked_switch/3`)
      runs off the view process (`start_async/3`), dispatched once from the
      stored review and matched to it on completion. `:submitting` and
      `:uncertain` are frozen; "Check again" resends exactly the same
      identity; a task exit or an unknown result is an unknown outcome,
      never a rollback.

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

  import SdrAgentWeb.AdminLive.ModelComponents, only: [model_card: 1, short: 1]

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.Integrations
  alias SdrAgent.Outreach
  alias SdrAgent.Outreach.Compliance
  alias SdrAgent.Outreach.Delivery
  alias SdrAgentWeb.AdminLive.ModelComponents
  alias SdrAgentWeb.AdminLive.Resolution
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
       confirm: nil,
       switch: nil,
       switch_notice: nil,
       resolution: nil,
       stored: :unknown
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
        now: SdrAgent.Clock.utc_now(),
        stored: stored_switch(opts)
      )
      |> recheck_facts()
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

  def handle_event("edit_grant", %{"id" => id}, socket) when is_binary(id) do
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
    do: update_budget(socket, &%{&1 | params: GrantForm.normalize(params)})

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
    do: update_budget(socket, &review(&1, GrantForm.normalize(params)))

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

  ## The model card, the switch request and the resolver (R0-05)

  def handle_event("refresh_status", _params, socket), do: {:noreply, load(socket)}

  def handle_event("open_switch", _params, socket) do
    if ModelComponents.switch_allowed?(socket.assigns[:provider] || %{}),
      do: {:noreply, open_switch(socket)},
      else: {:noreply, socket}
  end

  def handle_event("reload_switch", _params, %{assigns: %{switch: %{}}} = socket),
    do: {:noreply, open_switch(socket)}

  def handle_event("cancel_switch", _params, socket),
    do: {:noreply, assign(socket, switch: nil, switch_notice: nil)}

  def handle_event("review_switch", params, %{assigns: %{switch: %{step: :choose}}} = socket),
    do: {:noreply, assign(socket, switch: choose(socket.assigns.switch, target_param(params)))}

  # Sends only the review the socket holds: browser params are never read.
  def handle_event("confirm_switch", _params, %{assigns: %{switch: %{step: :review}}} = socket),
    do: {:noreply, request_switch(socket, socket.assigns.switch)}

  def handle_event("open_resolution", _params, socket) do
    review = socket.assigns.resolution
    blocked = ModelComponents.blocked_switch(socket.assigns[:provider] || %{})

    if blocked && (is_nil(review) or review.state in [:facts, :terminal]) do
      read = Agents.blocked_switch_facts(blocked.id, actor: actor(socket))

      {:noreply,
       assign(socket, resolution: Resolution.open(blocked.id, read, requester(socket, read)))}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "change_resolution",
        %{"resolution_confirmation" => text},
        %{assigns: %{resolution: %{state: :editing} = review}} = socket
      )
      when is_binary(text),
      do: {:noreply, assign(socket, resolution: Resolution.typed(review, text))}

  # Acts only on the :editing review the socket holds; the attempt carries
  # the operator's own text and the frozen facts and id.
  def handle_event(
        "confirm_resolution",
        params,
        %{assigns: %{resolution: %{state: :editing} = review}} = socket
      ) do
    text =
      case params do
        %{"resolution_confirmation" => text} when is_binary(text) -> text
        _no_text -> ""
      end

    {:noreply, dispatch(socket, Resolution.attest(review, text))}
  end

  # Resends exactly the frozen identity; only from :uncertain.
  def handle_event(
        "check_again",
        _params,
        %{assigns: %{resolution: %{state: :uncertain}}} = socket
      ),
      do: {:noreply, dispatch(socket, socket.assigns.resolution)}

  def handle_event(_ignored_event, _params, socket), do: {:noreply, socket}

  # The attempt's completion, matched to the active review's dispatch; a
  # result for any other review or state is ignored.
  @impl true
  def handle_async(
        {:resolution, ref},
        result,
        %{assigns: %{resolution: %{state: :submitting, dispatch: ref} = review}} = socket
      ) do
    {review, reread?} = Resolution.settle(review, result)
    socket = assign(socket, resolution: review)
    {:noreply, if(reread?, do: load(socket), else: socket)}
  end

  def handle_async(
        {:facts_check, id},
        {:ok, read},
        %{assigns: %{resolution: %{state: :editing, attestation_id: id} = review}} = socket
      ) do
    if Resolution.changed?(review, read),
      do:
        {:noreply,
         assign(socket,
           resolution: Resolution.facts_changed(review, read, requester(socket, read))
         )},
      else: {:noreply, socket}
  end

  def handle_async(_stale, _result, socket), do: {:noreply, socket}

  defp actor(socket), do: socket.assigns.current_scope.user

  ## The switch request (R0-05 section 2)

  # The review's from and revision come from the setting itself; a failed
  # read is never treated as absent.
  defp open_switch(socket) do
    case Agents.get_profile_setting(actor: actor(socket)) do
      {:ok, nil} ->
        assign(socket, switch: switch_panel(ModelProfiles.default_real(), 1), switch_notice: nil)

      {:ok, %{desired_profile_id: from, revision: revision}} ->
        assign(socket, switch: switch_panel(from, revision), switch_notice: nil)

      {:error, %Ash.Error.Forbidden{} = error} ->
        assign(socket,
          switch: nil,
          switch_notice: notice(:error, AuditedView.error_message(error))
        )

      {:error, _unreadable} ->
        assign(socket,
          switch: nil,
          switch_notice: notice(:error, "Not opened: the setting can't be read; try again.")
        )
    end
  end

  defp switch_panel(from, revision) do
    %{
      step: :choose,
      from: from,
      revision: revision,
      choices: ModelProfiles.real_ids() -- [from],
      choice_error: nil,
      review: nil,
      stale: nil
    }
  end

  defp target_param(%{"switch" => %{"to_profile_id" => to}}) when is_binary(to), do: to
  defp target_param(_params), do: nil

  defp choose(panel, target) do
    case Enum.find(panel.choices, &(to_string(&1) == target)) do
      nil ->
        %{panel | choice_error: "Choose one of the listed profiles."}

      to ->
        %{
          panel
          | step: :review,
            choice_error: nil,
            review: %{from: panel.from, to_profile_id: to, expected_revision: panel.revision}
        }
    end
  end

  defp request_switch(socket, %{review: review} = panel) do
    attrs = %{to_profile_id: review.to_profile_id, expected_revision: review.expected_revision}

    case Coordinator.request_switch(attrs, actor: actor(socket)) do
      {:ok, _switch} ->
        socket
        |> assign(
          switch: nil,
          switch_notice:
            notice(
              :ok,
              "Switch requested: #{review.from} → #{review.to_profile_id}. The card follows " <>
                "the switch as the status is refreshed."
            )
        )
        |> load()

      {:error, :switch_open} ->
        socket
        |> assign(
          switch: nil,
          switch_notice:
            notice(:error, "Another switch is open. The status was read again; see the card.")
        )
        |> load()

      {:error, :coordinator_not_ready} ->
        assign(socket,
          switch_notice:
            notice(:error, "The model server isn't ready to switch; try again shortly.")
        )

      {:error, error} ->
        if stale?(error) do
          stale =
            "The model profile setting changed since you opened this review (you reviewed " <>
              "revision #{review.expected_revision}). Nothing was requested; reload to review " <>
              "the current setting."

          assign(socket, switch: %{panel | stale: stale}, switch_notice: nil)
        else
          assign(socket, switch_notice: notice(:error, AuditedView.error_message(error)))
        end
    end
  end

  defp notice(kind, text), do: %{kind: kind, text: text}

  ## The resolver (R0-05 section 3)

  # Who requested the switch, by name, from the operators this page lists.
  defp requester(socket, {:ok, %{switch: %{requested_by_id: id}}}) do
    case Enum.find(socket.assigns[:users] || [], &(&1.id == id)) do
      %{display_name: name} -> name
      nil -> "an operator not listed here"
    end
  end

  defp requester(_socket, _read), do: nil

  # One attempt from the review the socket holds, off the view process; the
  # review is :submitting (frozen) until its own completion arrives.
  defp dispatch(socket, review) do
    ref = make_ref()
    actor = actor(socket)
    switch_id = review.switch_id
    attestation = review.attestation

    socket
    |> assign(resolution: Resolution.submitting(review, ref))
    |> start_async({:resolution, ref}, fn ->
      Agents.resolve_blocked_switch(switch_id, attestation, actor: actor)
    end)
  end

  # While :editing, a refresh re-reads the facts (off the view process) so
  # a change asks for a new review; the status card itself is never
  # replaced by it.
  defp recheck_facts(%{assigns: %{resolution: %{state: :editing} = review}} = socket) do
    actor = actor(socket)
    switch_id = review.switch_id

    start_async(socket, {:facts_check, review.attestation_id}, fn ->
      Agents.blocked_switch_facts(switch_id, actor: actor)
    end)
  end

  defp recheck_facts(socket), do: socket

  # The tenant's newest stored switch, read as the actor (unknown on a
  # failed read, never inferred).
  defp stored_switch(opts) do
    case Agents.list_profile_switches(opts) do
      {:ok, [latest | _older]} -> {:ok, latest}
      {:ok, []} -> {:ok, nil}
      {:error, _unreadable} -> :unknown
    end
  end

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

    with {:ok, terms} <- GrantForm.parse(params, originals(budget)),
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

  # An edit keeps the stored instant of every time field the admin did not touch.
  defp originals(%{mode: :edit, grant: grant}), do: GrantForm.originals(grant)
  defp originals(_budget), do: %{}

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
        <.model_card
          provider={@provider}
          switch={@switch}
          switch_notice={@switch_notice}
          resolution={@resolution}
          stored={@stored}
        />

        <div class="grid gap-6 lg:grid-cols-2">
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
