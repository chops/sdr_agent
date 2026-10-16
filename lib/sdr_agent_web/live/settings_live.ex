defmodule SdrAgentWeb.SettingsLive do
  @moduledoc """
  The run settings page (C4-01b, `docs/product/c4/readiness.md` sections
  3.3-3.6 and 6; C4-R1, C4-R2, C4-R3, C4-R10, C4-R11, C4-R12; OQ-6), in the
  operator console's live session. Every operator reads it; only an admin
  edits.

    * **The five settings** (`SdrAgent.Agents.current_settings/1`, the one
      caller of that read): per kind its value and its source — the saved
      revision number, the built-in default version ("not yet reviewed by
      you") or "not set". Every operational limit shows its value, built-in
      default, validation range and whether code enforces it yet, read from
      `SdrAgent.Agents.RunSettings.Safeguards` and `CodeDefaults`.
    * **The staged editor** (the C9-05 grant editor pattern,
      `SdrAgentWeb.SettingsLive.Form`): an edit form, an in-page review of
      exactly what will be saved, and a confirmation. Only the confirmation
      calls `SdrAgent.Agents.create_settings_revision/2`, as the signed-in
      user, with the kind, content and `expected_number` held by the socket's
      review (the number of the revision shown when the form was opened);
      the event params contribute only the ticked raise confirmations,
      matched against the held raised fields. A stale save shows a reload
      prompt; refusals are shown next to their fields, the input kept. A
      forged event without a held review does nothing.
    * **Read-only budgets:** the tenant-day limits with their source, the
      provider source quotas as not yet built (no counter is invented), the
      current grants and allocations (`Agents.list_grants/1`; admin and
      auditor reads only — a reviewer is told they are not visible to the
      role, never shown an empty state), and the fixed safeguards with their
      reasons. Whether a call is allowed now is decided only at use.

  Roles and revalidation: the role shapes the UI only; the domain decides.
  Every event is re-validated by `SdrAgentWeb.LiveUserAuth` first (a
  disabled or revoked operator is signed out before anything runs); when the
  re-read role differs from the role the page was loaded for, any staged
  edit is discarded and the page is reloaded for the new role, without
  acting on the event. An auditor's view records, before anything is shown,
  one AuditAccess naming the revisions shown and one naming the grants shown
  (`SdrAgentWeb.AuditedView`); when the first cannot be recorded nothing is
  served, when the second cannot the grants are withheld.

  Privacy (section 3.6): settings text is business content shown only on
  this authorized seam. Form params live under `settings_content` (filtered
  by `config :phoenix, :filter_parameters`), the LiveView lifecycle is not
  logged (`log: false`), and no message, flash or log line carries a value.
  """
  use SdrAgentWeb, {:live_view, log: false}

  import SdrAgentWeb.SettingsLive.Components

  alias SdrAgent.Agents
  alias SdrAgent.Agents.RunSettings.CodeDefaults
  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgent.Outreach.Compliance
  alias SdrAgentWeb.AuditedView
  alias SdrAgentWeb.LiveRefresh
  alias SdrAgentWeb.Scope
  alias SdrAgentWeb.SettingsLive.Form

  @revisions "SdrAgent.Agents.SettingsRevision"
  @grants "SdrAgent.Agents.ModelCallGrant"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Run settings",
       loaded?: false,
       withheld: nil,
       loaded_role: nil,
       settings: nil,
       grants: nil,
       edit: nil
     )
     |> LiveRefresh.attach(&load/1)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  # Reads everything as the signed-in operator. A staged edit survives a
  # reload only while the operator is still the admin it was staged by.
  defp load(socket) do
    scope = socket.assigns.current_scope
    edit = if keep_edit?(socket), do: socket.assigns.edit, else: nil

    with {:ok, settings} <- Agents.current_settings(actor: scope.user),
         :ok <- AuditedView.record(scope, @revisions, revision_ids(settings), "settings view") do
      assign(socket,
        loaded?: true,
        withheld: nil,
        loaded_role: scope.role,
        settings: settings,
        grants: load_grants(scope),
        edit: edit,
        daily_limit: Agents.daily_model_call_limit(),
        send_cap: Compliance.daily_send_cap(),
        timezone: Compliance.timezone()
      )
    else
      {:error, reason} ->
        assign(socket,
          loaded?: false,
          withheld: AuditedView.error_message(reason),
          loaded_role: scope.role,
          settings: nil,
          grants: nil,
          edit: nil
        )
    end
  end

  defp keep_edit?(socket) do
    Scope.admin?(socket.assigns.current_scope) and socket.assigns.loaded_role in [nil, :admin]
  end

  defp revision_ids(settings) do
    for kind <- Form.kinds(),
        %{source: :revision, revision: revision} <- [settings[kind]],
        do: revision.id
  end

  # Grants are read only by the roles their policy admits (admin, auditor);
  # an auditor's view is recorded first. A failed read or record withholds
  # them; it never becomes "no grant".
  defp load_grants(%Scope{role: role} = scope) when role in [:admin, :auditor] do
    with {:ok, grants} <- Agents.list_grants(actor: scope.user),
         :ok <-
           AuditedView.record(scope, @grants, Enum.map(grants, & &1.id), "settings grants view") do
      {:ok, Enum.reverse(grants)}
    else
      {:error, reason} -> {:withheld, AuditedView.error_message(reason)}
    end
  end

  defp load_grants(_scope), do: :hidden

  ## Events

  @impl true
  def handle_event(event, params, socket) do
    if socket.assigns.loaded_role != socket.assigns.current_scope.role do
      # The operator's role changed while connected (re-read by the
      # LiveUserAuth hook): drop any staged edit and serve the new role's
      # view; the event itself is not acted on.
      {:noreply, socket |> assign(edit: nil) |> load()}
    else
      {:noreply, event(event, params, socket)}
    end
  end

  defp event("edit_settings", %{"kind" => name}, socket) do
    case Form.kind(name) do
      nil -> socket
      kind -> if editable?(socket), do: assign(socket, edit: new_edit(socket, kind)), else: socket
    end
  end

  defp event("change_settings", %{"settings_content" => raw}, socket) do
    update_edit(socket, :edit, fn edit ->
      case Form.normalize(edit.kind, raw) do
        nil -> edit
        params -> %{edit | params: params}
      end
    end)
  end

  defp event("add_item", _params, socket),
    do: update_edit(socket, :edit, &%{&1 | params: Form.add_item(&1.params)})

  defp event("remove_item", %{"index" => index}, socket),
    do: update_edit(socket, :edit, &%{&1 | params: Form.remove_item(&1.params, index)})

  defp event("review_settings", %{"settings_content" => raw}, socket) do
    update_edit(socket, :edit, fn edit ->
      case Form.normalize(edit.kind, raw) do
        nil -> edit
        params -> review(edit, params, in_effect(socket, edit.kind))
      end
    end)
  end

  defp event("back_to_edit", _params, socket),
    do: update_edit(socket, :review, &%{&1 | step: :edit, review: nil})

  defp event("cancel_settings", _params, socket), do: assign(socket, edit: nil)

  # Acts only on the review the socket holds; the params add nothing but the
  # ticked raise confirmations, matched against the held raised fields.
  defp event("confirm_settings", params, %{assigns: %{edit: %{step: :review} = edit}} = socket) do
    if editable?(socket),
      do: confirm(socket, edit, Form.confirmed(params["confirm_raised"], edit.review.raised)),
      else: socket
  end

  defp event("reload_settings", _params, %{assigns: %{edit: %{step: :stale} = edit}} = socket) do
    socket = load(socket)

    if socket.assigns.loaded? and editable?(socket),
      do: assign(socket, edit: new_edit(socket, edit.kind)),
      else: assign(socket, edit: nil)
  end

  defp event(_event, _params, socket), do: socket

  defp editable?(socket),
    do: socket.assigns.loaded? and Scope.admin?(socket.assigns.current_scope)

  defp update_edit(%{assigns: %{edit: %{step: step} = edit}} = socket, step, fun) do
    if editable?(socket), do: assign(socket, edit: fun.(edit)), else: socket
  end

  defp update_edit(socket, _step, _fun), do: socket

  # The form opens on the setting in effect; `expected_number` is the number
  # of the revision shown (0 when none is saved).
  defp new_edit(socket, kind) do
    slot = socket.assigns.settings[kind]

    %{
      kind: kind,
      step: :edit,
      expected_number: if(slot.revision, do: slot.revision.number, else: 0),
      params: Form.params_for(kind, slot.content),
      errors: %{},
      review: nil,
      stale: nil
    }
  end

  defp in_effect(socket, :operational_limits) do
    content = socket.assigns.settings.operational_limits.content
    Map.new(Safeguards.limit_fields(), &{&1, Map.fetch!(content, &1)})
  end

  defp in_effect(_socket, _kind), do: nil

  defp review(edit, params, in_effect) do
    content = Form.content(edit.kind, params)
    note = Form.note(params)

    case Form.check(edit.kind, content, note, edit.expected_number) do
      :ok ->
        raised = if in_effect, do: Form.raised(content, in_effect), else: []

        %{
          edit
          | params: params,
            step: :review,
            errors: %{},
            review: %{content: content, note: note, raised: raised, in_effect: in_effect}
        }

      {:error, errors} ->
        %{edit | params: params, step: :edit, errors: Form.errors_by_field(edit.kind, errors)}
    end
  end

  defp confirm(socket, edit, confirmed) do
    if Enum.sort(confirmed) != Enum.sort(edit.review.raised) do
      refused(socket, edit, {:invalid, [confirm_raised: :mismatch]})
    else
      attrs = %{
        kind: edit.kind,
        content: edit.review.content,
        expected_number: edit.expected_number,
        note: edit.review.note,
        confirm_raised: confirmed
      }

      case Agents.create_settings_revision(attrs, actor: socket.assigns.current_scope.user) do
        {:ok, revision} ->
          socket
          |> assign(edit: nil)
          |> put_flash(:info, "Saved the #{title(edit.kind)} as revision #{revision.number}.")
          |> load()

        {:error, reason} ->
          refused(socket, edit, reason)
      end
    end
  end

  defp refused(socket, edit, {:stale_revision, latest}),
    do: assign(socket, edit: %{edit | step: :stale, stale: latest, review: nil})

  defp refused(socket, edit, {:invalid, errors}) do
    assign(socket,
      edit: %{edit | step: :edit, review: nil, errors: Form.errors_by_field(edit.kind, errors)}
    )
  end

  defp refused(socket, edit, reason) do
    assign(socket,
      edit: %{edit | step: :edit, review: nil, errors: %{"base" => [refusal(reason)]}}
    )
  end

  defp refusal(:forbidden), do: AuditedView.error_message(%Ash.Error.Forbidden{})
  defp refusal(reason), do: AuditedView.error_message(reason)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        admin?: Scope.admin?(assigns.current_scope),
        limit_defaults: CodeDefaults.current(:operational_limits).content
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <.page_header id="settings-header" eyebrow="Run settings">
        Settings every new run is created with
        <:subtitle>
          Each agent run binds a snapshot of these settings when it is created; a later save
          never changes an existing run. Saves are numbered revisions, never edits in place.
          <span :if={!@admin?} id="settings-read-only" class="font-medium text-zinc-800">
            Read-only for your role.
          </span>
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
        <div class="grid gap-6 lg:grid-cols-2">
          <.setting
            :for={kind <- [:offering_profile, :booking_link, :writing_guide, :research_brief]}
            kind={kind}
            slot={@settings[kind]}
            admin?={@admin?}
            edit={@edit}
            daily_limit={@daily_limit}
            limit_defaults={@limit_defaults}
          />
        </div>

        <.setting
          kind={:operational_limits}
          slot={@settings.operational_limits}
          admin?={@admin?}
          edit={@edit}
          daily_limit={@daily_limit}
          limit_defaults={@limit_defaults}
        />

        <div class="grid gap-6 lg:grid-cols-2">
          <.tenant_limits daily_limit={@daily_limit} send_cap={@send_cap} timezone={@timezone} />
          <.grants grants={@grants} admin?={@admin?} />
        </div>

        <.safeguards />
      </div>
    </Layouts.app>
    """
  end
end
