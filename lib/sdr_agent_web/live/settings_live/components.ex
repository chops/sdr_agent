defmodule SdrAgentWeb.SettingsLive.Components do
  @moduledoc """
  Function components of the run settings page (C4-01b,
  `SdrAgentWeb.SettingsLive`): one card per setting with its source and
  value, the operational limits table (value, built-in default, validation
  range, enforcement), the staged editor (form, review with the per-field
  raise confirmation, stale prompt), and the read-only tenant-day limits,
  source quotas, grants and safeguards. Rendering only: every event is
  handled by `SdrAgentWeb.SettingsLive`, which holds the state shown here.
  """
  use SdrAgentWeb, :html

  import SdrAgentWeb.AdminLive.BudgetComponents, only: [allocation_label: 1]

  alias SdrAgent.Agents.RunSettings.Safeguards
  alias SdrAgentWeb.GrantForm
  alias SdrAgentWeb.SettingsLive.Form

  @input "w-full rounded-lg border bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm placeholder:text-zinc-400 focus:outline-none focus:ring-2 transition"
  @ok "border-zinc-300 focus:border-teal-600 focus:ring-teal-600/20"
  @bad "border-rose-400 focus:border-rose-500 focus:ring-rose-500/20"
  @check "size-4 rounded border-zinc-300 text-teal-700 focus:ring-teal-600/30"

  @titles %{
    offering_profile: "offering profile",
    booking_link: "booking link",
    writing_guide: "writing guide",
    research_brief: "research brief",
    operational_limits: "operational limits"
  }

  @blurbs %{
    offering_profile: "What we sell, as items research and drafts cite.",
    booking_link:
      "The scheduling page used in asks; withheld at use if its host fails the guard.",
    writing_guide: "Tone and shape of drafts.",
    research_brief: "Editable research guidance; the fixed research rules stay in code.",
    operational_limits:
      "Per-run ceilings an admin raises or lowers. Raising one grants no spend: grants, the tenant-day limit and provider quotas still bound every run."
  }

  @doc "The setting's name in words (`:writing_guide` → \"writing guide\")."
  @spec title(atom()) :: String.t()
  def title(kind), do: Map.fetch!(@titles, kind)

  @doc "An integer with thousands separators (2147483647 → \"2,147,483,647\")."
  @spec delimit(integer()) :: String.t()
  def delimit(n) when is_integer(n) and n < 0, do: "-" <> delimit(-n)

  def delimit(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def delimit(other), do: to_string(other)

  defp label(field), do: field |> to_string() |> String.replace("_", " ") |> String.capitalize()

  ## One setting

  attr :kind, :atom, required: true
  attr :slot, :map, required: true
  attr :admin?, :boolean, required: true
  attr :edit, :map, default: nil
  attr :daily_limit, :integer, required: true
  attr :limit_defaults, :map, required: true

  @doc "The card of one setting: source, value (or the editor while it is edited)."
  def setting(assigns) do
    assigns =
      assign(assigns, editing?: is_map(assigns.edit) and assigns.edit.kind == assigns.kind)

    ~H"""
    <.card id={"settings-#{@kind}"} title={String.capitalize(title(@kind))}>
      <:subtitle>{Map.fetch!(blurbs(), @kind)}</:subtitle>
      <:actions>
        <.ui_button
          :if={@admin? and not @editing?}
          id={"edit-#{@kind}"}
          size="sm"
          phx-click="edit_settings"
          phx-value-kind={@kind}
        >
          <.icon name="hero-pencil-square" class="size-4" /> Edit
        </.ui_button>
      </:actions>

      <.source kind={@kind} slot={@slot} />

      <.editor
        :if={@editing?}
        edit={@edit}
        daily_limit={@daily_limit}
        limit_defaults={@limit_defaults}
      />

      <div :if={not @editing?} class="mt-3">
        <.content_view
          :if={@slot.content}
          id={"settings-#{@kind}-value"}
          kind={@kind}
          content={@slot.content}
          limit_defaults={@limit_defaults}
        />
        <p :if={is_nil(@slot.content)} id={"settings-#{@kind}-empty"} class="text-sm text-zinc-500">
          {empty_text(@kind)}
        </p>
      </div>
    </.card>
    """
  end

  defp blurbs, do: @blurbs

  defp empty_text(:offering_profile),
    do: "No offering profile saved yet. Runs that need business content are refused until one is."

  defp empty_text(:booking_link),
    do: "No booking link saved. Drafts ask a question first and never propose meeting times."

  defp empty_text(_kind), do: "Not set."

  attr :kind, :atom, required: true
  attr :slot, :map, required: true

  defp source(assigns) do
    ~H"""
    <p
      id={"settings-#{@kind}-source"}
      data-source={@slot.source}
      class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs"
    >
      <span :if={@slot.source == :revision} class={pill("bg-teal-50 text-teal-800 ring-teal-600/20")}>
        <.icon name="hero-check-badge" class="size-3.5" /> revision {@slot.revision.number}
      </span>
      <span :if={@slot.source == :revision} class="text-zinc-500">
        saved <.timestamp at={@slot.revision.inserted_at} />
      </span>
      <span
        :if={@slot.source == :code_default}
        class={pill("bg-amber-50 text-amber-800 ring-amber-600/20")}
      >
        <.icon name="hero-cube" class="size-3.5" /> built-in default version {@slot.version}
      </span>
      <span :if={@slot.source == :code_default} class="text-amber-800">not yet reviewed by you</span>
      <span :if={@slot.source == :absent} class={pill("bg-zinc-100 text-zinc-700 ring-zinc-500/20")}>
        <.icon name="hero-minus-circle" class="size-3.5" /> not set
      </span>
    </p>
    """
  end

  defp pill(tone),
    do: [
      "inline-flex items-center gap-1 rounded-full px-2 py-0.5 font-medium ring-1 ring-inset",
      tone
    ]

  ## Values (current or staged)

  attr :id, :string, default: nil
  attr :kind, :atom, required: true
  attr :content, :map, required: true
  attr :limit_defaults, :map, required: true

  defp content_view(%{kind: :offering_profile} = assigns) do
    ~H"""
    <div id={@id} class="space-y-3 text-sm">
      <div>
        <p class="font-semibold text-zinc-900">{@content.name}</p>
        <p class="mt-1 whitespace-pre-line text-zinc-700">{@content.summary}</p>
        <p :if={present?(@content.audience)} class="mt-1 text-xs text-zinc-500">
          Audience: <span class="whitespace-pre-line">{@content.audience}</span>
        </p>
      </div>
      <ul class="divide-y divide-zinc-100 rounded-lg border border-zinc-200">
        <li :for={item <- @content.items} class="flex gap-3 px-3 py-2">
          <span class="shrink-0 font-mono text-xs text-zinc-500">{item.id}</span>
          <span class="shrink-0 rounded bg-zinc-100 px-1.5 py-0.5 text-xs text-zinc-700">
            {humanize(item.kind)}
          </span>
          <span class="min-w-0 whitespace-pre-line text-zinc-800">{item.text}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp content_view(%{kind: :booking_link} = assigns) do
    ~H"""
    <p id={@id} class="break-all font-mono text-sm text-zinc-800">{@content.url}</p>
    """
  end

  defp content_view(%{kind: :writing_guide} = assigns) do
    ~H"""
    <div
      id={@id}
      class="max-h-72 overflow-y-auto whitespace-pre-line rounded-lg bg-zinc-50 p-3 text-sm leading-relaxed text-zinc-800"
    >
      {@content.text}
    </div>
    """
  end

  defp content_view(%{kind: :research_brief} = assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <div class="max-h-72 overflow-y-auto whitespace-pre-line rounded-lg bg-zinc-50 p-3 text-sm leading-relaxed text-zinc-800">
        {@content.guidance}
      </div>
      <p class="text-xs text-zinc-500">Depth: {humanize(@content.depth)} (one depth in the MVP)</p>
    </div>
    """
  end

  defp content_view(%{kind: :operational_limits} = assigns) do
    assigns = assign(assigns, rules: Safeguards.limit_rules())

    ~H"""
    <div id={@id} class="overflow-x-auto">
      <table class="w-full min-w-[44rem] text-left text-sm">
        <thead class="text-xs uppercase tracking-wider text-zinc-500">
          <tr>
            <th scope="col" class="py-2 pr-4 font-medium">Limit</th>
            <th scope="col" class="py-2 pr-4 text-right font-medium">Value</th>
            <th scope="col" class="py-2 pr-4 text-right font-medium">Built-in default</th>
            <th scope="col" class="py-2 pr-4 font-medium">Valid range</th>
            <th scope="col" class="py-2 font-medium">Enforced</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100">
          <tr
            :for={{field, rule} <- @rules}
            id={"limit-#{field}"}
            data-value={Map.fetch!(@content, field)}
            data-default={Map.fetch!(@limit_defaults, field)}
            data-min={rule.min}
            data-max={rule.max}
            class="transition hover:bg-zinc-50/70"
          >
            <th scope="row" class="py-2 pr-4 font-medium text-zinc-900">{label(field)}</th>
            <td class={[
              "py-2 pr-4 text-right tabular-nums",
              Map.fetch!(@content, field) != Map.fetch!(@limit_defaults, field) &&
                "font-semibold text-teal-800"
            ]}>
              {delimit(Map.fetch!(@content, field))}
            </td>
            <td class="py-2 pr-4 text-right tabular-nums text-zinc-500">
              {delimit(Map.fetch!(@limit_defaults, field))}
            </td>
            <td id={"limit-#{field}-range"} class="py-2 pr-4 text-xs tabular-nums text-zinc-600">
              {delimit(rule.min)} to {delimit(rule.max)}{cross_field(field)}
            </td>
            <td class="py-2 text-xs">
              <span :if={rule.enforced_by} class="text-emerald-700">
                <.icon name="hero-shield-check" class="size-3.5" /> {rule.enforced_by}
              </span>
              <span :if={is_nil(rule.enforced_by)} class="text-amber-700">
                not yet enforced (its consumer is not built)
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp cross_field(:research_max_total_source_chars), do: ", at least the per-source characters"
  defp cross_field(:research_max_model_calls), do: ", at most the run's model calls"
  defp cross_field(:research_target_seconds), do: ", at most the job limit (a warning)"
  defp cross_field(_field), do: ""

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  ## The staged editor

  attr :edit, :map, required: true
  attr :daily_limit, :integer, required: true
  attr :limit_defaults, :map, required: true

  defp editor(assigns) do
    ~H"""
    <section
      id="settings-editor"
      class="mt-4 rounded-xl border border-zinc-200 bg-zinc-50/60 p-4 sm:p-5"
      aria-label={"Edit the #{title(@edit.kind)}"}
    >
      <h3 class="text-sm font-semibold text-zinc-900">
        Edit the {title(@edit.kind)}
        <span class="font-normal text-zinc-500">
          {if @edit.expected_number == 0,
            do: "(no revision saved yet)",
            else: "(from revision #{@edit.expected_number})"}
        </span>
      </h3>

      <div
        :if={@edit.step == :stale}
        id="settings-stale"
        role="alert"
        class="mt-3 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-rose-200 bg-rose-50 p-3"
      >
        <p class="text-sm text-rose-800">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          Someone saved revision {@edit.stale} of the {title(@edit.kind)} after you opened this
          form. Nothing was saved; reload to edit from revision {@edit.stale}.
        </p>
        <div class="flex gap-2">
          <.ui_button id="reload-settings" size="sm" phx-click="reload_settings">
            <.icon name="hero-arrow-path" class="size-4" /> Reload revision {@edit.stale}
          </.ui_button>
          <.ui_button size="sm" variant="ghost" phx-click="cancel_settings">Cancel</.ui_button>
        </div>
      </div>

      <.review
        :if={@edit.step == :review}
        edit={@edit}
        daily_limit={@daily_limit}
        limit_defaults={@limit_defaults}
      />

      <.form
        :if={@edit.step == :edit}
        for={%{}}
        id="settings-form"
        data-kind={@edit.kind}
        phx-change="change_settings"
        phx-submit="review_settings"
        class="mt-4 space-y-4"
      >
        <.field_error id="settings-error-base" errors={@edit.errors["base"]} boxed />
        <.field_error
          id="settings-error-confirm_raised"
          errors={@edit.errors["confirm_raised"]}
          boxed
        />

        <.fields
          kind={@edit.kind}
          params={@edit.params}
          errors={@edit.errors}
          limit_defaults={@limit_defaults}
        />

        <.text_input
          field="note"
          label="Revision note (optional, at most 200 characters)"
          params={@edit.params}
          errors={@edit.errors}
          placeholder="Why this change"
        />

        <div class="flex flex-wrap gap-2 border-t border-zinc-200 pt-4">
          <.ui_button id="review-settings" type="submit" variant="primary">
            Review…
          </.ui_button>
          <.ui_button id="cancel-settings" type="button" variant="ghost" phx-click="cancel_settings">
            Cancel
          </.ui_button>
        </div>
      </.form>
    </section>
    """
  end

  attr :kind, :atom, required: true
  attr :params, :map, required: true
  attr :errors, :map, required: true
  attr :limit_defaults, :map, required: true

  defp fields(%{kind: :offering_profile} = assigns) do
    assigns = assign(assigns, rows: Form.item_rows(assigns.params), check: @check)

    ~H"""
    <.text_input field="name" label="Name" params={@params} errors={@errors} />
    <.text_input
      field="summary"
      label="Summary"
      type="textarea"
      rows="3"
      params={@params}
      errors={@errors}
    />
    <.text_input
      field="audience"
      label="Audience (optional)"
      type="textarea"
      rows="2"
      params={@params}
      errors={@errors}
    />
    <fieldset>
      <div class="flex items-center justify-between gap-3">
        <legend class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
          Items (1 to 30)
        </legend>
        <.ui_button id="add-item" type="button" size="sm" phx-click="add_item">
          <.icon name="hero-plus" class="size-4" /> Add item
        </.ui_button>
      </div>
      <.field_error id="settings-error-items" errors={@errors["items"]} />
      <div class="mt-2 space-y-3">
        <div
          :for={{index, row} <- @rows}
          id={"settings-item-#{index}"}
          class="grid gap-3 rounded-lg border border-zinc-200 bg-white p-3 shadow-[0_1px_2px_rgba(24,24,27,0.04)] sm:grid-cols-[10rem_9rem_1fr_auto]"
        >
          <.input
            id={"settings-input-items-#{index}-id"}
            name={"settings_content[items][#{index}][id]"}
            value={row["id"]}
            label="Id"
            placeholder="calendar_sync"
            class={[input_class(), "font-mono"]}
          />
          <.input
            id={"settings-input-items-#{index}-kind"}
            name={"settings_content[items][#{index}][kind]"}
            type="select"
            value={row["kind"]}
            label="Kind"
            options={Enum.map(Form.item_kinds(), &{humanize(&1), &1})}
            class={input_class()}
          />
          <.input
            id={"settings-input-items-#{index}-text"}
            name={"settings_content[items][#{index}][text]"}
            value={row["text"]}
            label="Text"
            class={input_class()}
          />
          <div class="flex items-end pb-2">
            <.ui_button
              type="button"
              size="sm"
              variant="ghost"
              phx-click="remove_item"
              phx-value-index={index}
              aria-label={"Remove item #{index}"}
            >
              <.icon name="hero-trash" class="size-4" />
            </.ui_button>
          </div>
        </div>
      </div>
    </fieldset>
    """
  end

  defp fields(%{kind: :booking_link} = assigns) do
    ~H"""
    <.text_input
      field="url"
      label="Booking link (https, at most 2,048 bytes)"
      type="url"
      params={@params}
      errors={@errors}
      placeholder="https://book.example.test/demo/intro"
    />
    """
  end

  defp fields(%{kind: :writing_guide} = assigns) do
    ~H"""
    <.text_input
      field="text"
      label="Writing guide (at most 6,000 characters)"
      type="textarea"
      rows="10"
      params={@params}
      errors={@errors}
    />
    """
  end

  defp fields(%{kind: :research_brief} = assigns) do
    ~H"""
    <.text_input
      field="guidance"
      label="Research guidance (at most 12,000 characters)"
      type="textarea"
      rows="10"
      params={@params}
      errors={@errors}
    />
    <.text_input
      field="depth"
      label="Depth"
      type="select"
      options={Enum.map(Form.depths(), &{humanize(&1), &1})}
      params={@params}
      errors={@errors}
    />
    """
  end

  defp fields(%{kind: :operational_limits} = assigns) do
    assigns = assign(assigns, rules: Safeguards.limit_rules())

    ~H"""
    <div class="grid gap-x-4 gap-y-1 sm:grid-cols-2 lg:grid-cols-3">
      <div :for={{field, rule} <- @rules}>
        <.text_input
          field={Atom.to_string(field)}
          label={label(field)}
          type="number"
          min={rule.min}
          max={rule.max}
          step="1"
          params={@params}
          errors={@errors}
        />
        <p class="-mt-1 mb-2 text-xs text-zinc-500">
          default {delimit(Map.fetch!(@limit_defaults, field))} · {delimit(rule.min)} to {delimit(
            rule.max
          )}
          <span :if={is_nil(rule.enforced_by)} class="text-amber-700">· not yet enforced</span>
        </p>
      </div>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :params, :map, required: true
  attr :errors, :map, required: true
  attr :options, :list, default: []
  attr :rest, :global, include: ~w(rows min max step placeholder)

  defp text_input(assigns) do
    assigns =
      assign(assigns,
        id: "settings-input-#{assigns.field}",
        error_id: "settings-error-#{assigns.field}",
        field_errors: assigns.errors[assigns.field]
      )

    ~H"""
    <div>
      <.input
        id={@id}
        name={"settings_content[#{@field}]"}
        type={@type}
        value={@params[@field]}
        label={@label}
        options={@options}
        class={input_class(@field_errors)}
        aria-invalid={if @field_errors, do: "true"}
        aria-describedby={if @field_errors, do: @error_id}
        {@rest}
      />
      <.field_error id={@error_id} errors={@field_errors} />
    </div>
    """
  end

  defp input_class(errors \\ nil), do: [@input, if(errors, do: @bad, else: @ok)]

  attr :id, :string, required: true
  attr :errors, :list, default: nil
  attr :boxed, :boolean, default: false

  defp field_error(assigns) do
    ~H"""
    <div
      :if={@errors}
      id={@id}
      role="alert"
      class={[
        "mt-1 space-y-1 text-sm text-rose-700",
        @boxed && "rounded-lg border border-rose-200 bg-rose-50 p-3"
      ]}
    >
      <p :for={message <- @errors} class="flex items-start gap-1.5">
        <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" /> {message}
      </p>
    </div>
    """
  end

  ## The review step

  attr :edit, :map, required: true
  attr :daily_limit, :integer, required: true
  attr :limit_defaults, :map, required: true

  defp review(assigns) do
    assigns = assign(assigns, review: assigns.edit.review, check: @check)

    ~H"""
    <div id="settings-review" class="mt-4 space-y-4">
      <div class="rounded-lg border border-teal-200 bg-teal-50/70 p-3 text-sm text-teal-900">
        <p class="font-semibold">
          Review: this will be saved as revision {@edit.expected_number + 1} of the {title(@edit.kind)}.
        </p>
        <p class="mt-0.5 text-teal-900/80">
          Nothing is saved until you confirm. Runs already created keep their snapshot; new
          runs use this revision.
        </p>
      </div>

      <.staged_limits
        :if={@edit.kind == :operational_limits}
        content={@review.content}
        in_effect={@review.in_effect}
      />
      <.content_view
        :if={@edit.kind != :operational_limits}
        kind={@edit.kind}
        content={staged(@edit.kind, @review.content)}
        limit_defaults={@limit_defaults}
      />
      <p :if={@review.note} class="text-xs text-zinc-600">
        Note: <span class="whitespace-pre-line">{@review.note}</span>
      </p>

      <.form for={%{}} id="settings-confirm" phx-submit="confirm_settings" class="space-y-3">
        <fieldset :if={@review.raised != []} class="space-y-2">
          <legend class="text-sm font-semibold text-amber-900">
            Confirm each raised limit
          </legend>
          <div
            :for={field <- @review.raised}
            id={"raise-#{field}"}
            data-from={Map.fetch!(@review.in_effect, field)}
            data-to={Map.fetch!(@review.content, field)}
            data-default={Map.fetch!(@limit_defaults, field)}
            class="rounded-lg border border-amber-200 bg-amber-50/70 p-3"
          >
            <label class="flex items-start gap-2 text-sm text-amber-900">
              <input
                type="checkbox"
                id={"confirm-raise-#{field}"}
                name="confirm_raised[]"
                value={field}
                class={[@check, "mt-0.5"]}
              />
              <span>
                Raise <span class="font-medium">{label(field)}</span>
                from {delimit(Map.fetch!(@review.in_effect, field))} to
                <span class="font-semibold">{delimit(Map.fetch!(@review.content, field))}</span>
                (built-in default {delimit(Map.fetch!(@limit_defaults, field))}).
              </span>
            </label>
            <p class="mt-1 pl-6 text-xs text-amber-900/80">
              {raise_bounds(field, @daily_limit)}
            </p>
          </div>
        </fieldset>

        <div class="flex flex-wrap gap-2 border-t border-zinc-200 pt-4">
          <.ui_button id="confirm-settings" type="submit" variant="primary">
            <.icon name="hero-check" class="size-4" /> Confirm and save
          </.ui_button>
          <.ui_button id="back-to-edit" type="button" phx-click="back_to_edit">
            Back to edit
          </.ui_button>
          <.ui_button type="button" variant="ghost" phx-click="cancel_settings">Cancel</.ui_button>
        </div>
      </.form>
    </div>
    """
  end

  defp raise_bounds(field, daily_limit) when field in [:run_max_model_calls, :run_max_tokens],
    do:
      "Raising it grants no spend: model calls stay bounded by the real-model grant " <>
        "allocations, the tenant-day limit of #{delimit(daily_limit)} model calls per UTC day " <>
        "and provider quotas, each checked at use."

  defp raise_bounds(field, _daily_limit) when field in [:research_max_search_requests],
    do:
      "Raising it grants no spend: searches stay bounded by the provider source quotas " <>
        "(1,000 Brave requests and $5 of Exa per month) and every model call by its grant."

  defp raise_bounds(_field, daily_limit),
    do:
      "Raising it grants no spend: every model call in a run stays bounded by its grant, " <>
        "the tenant-day limit of #{delimit(daily_limit)} model calls per UTC day and provider quotas."

  # The staged content in the shape the value view reads (atom keys, items as maps).
  defp staged(:offering_profile, content) do
    %{
      name: content.name,
      summary: content.summary,
      audience: content.audience,
      items: Enum.map(content.items, &%{id: &1.id, kind: &1.kind, text: &1.text})
    }
  end

  defp staged(_kind, content), do: content

  attr :content, :map, required: true
  attr :in_effect, :map, required: true

  defp staged_limits(assigns) do
    assigns =
      assign(assigns,
        changed:
          for(
            field <- Safeguards.limit_fields(),
            Map.fetch!(assigns.content, field) != Map.fetch!(assigns.in_effect, field),
            do: field
          )
      )

    ~H"""
    <div id="settings-review-limits" class="text-sm">
      <p :if={@changed == []} class="text-zinc-600">
        No limit changes: the values in effect are saved again as a new revision.
      </p>
      <ul :if={@changed != []} class="divide-y divide-zinc-100 rounded-lg border border-zinc-200">
        <li :for={field <- @changed} class="flex items-center justify-between gap-3 px-3 py-2">
          <span class="text-zinc-800">{label(field)}</span>
          <span class="tabular-nums">
            <span class="text-zinc-500">{delimit(Map.fetch!(@in_effect, field))}</span>
            <.icon name="hero-arrow-right" class="size-3.5 text-zinc-400" />
            <span class="font-semibold text-zinc-900">{delimit(Map.fetch!(@content, field))}</span>
          </span>
        </li>
      </ul>
    </div>
    """
  end

  ## Read-only budgets and safeguards

  attr :daily_limit, :integer, required: true
  attr :send_cap, :integer, required: true
  attr :timezone, :string, required: true

  @doc "The tenant-day limits and provider source quotas, read-only with their source."
  def tenant_limits(assigns) do
    ~H"""
    <.card id="tenant-limits" title="Tenant-day limits and quotas">
      <:subtitle>Shared by every run; read-only here. No run setting raises them.</:subtitle>
      <ul class="divide-y divide-zinc-100">
        <li
          id="tenant-limit-daily_model_calls"
          data-cap={@daily_limit}
          class="py-3 first:pt-0"
        >
          <p class="flex items-baseline justify-between gap-3">
            <span class="text-sm font-medium text-zinc-900">Model calls</span>
            <span class="text-sm tabular-nums text-zinc-900">
              {delimit(@daily_limit)} per UTC day
            </span>
          </p>
          <p class="mt-0.5 text-xs text-zinc-500">
            Source: the built-in limit of 200 (ADR-0004); config may only lower it. Checked
            at each model call reservation.
          </p>
        </li>
        <li id="tenant-limit-daily_sends" data-cap={@send_cap} class="py-3">
          <p class="flex items-baseline justify-between gap-3">
            <span class="text-sm font-medium text-zinc-900">Sends</span>
            <span class="text-sm tabular-nums text-zinc-900">
              {@send_cap} per local day ({@timezone})
            </span>
          </p>
          <p class="mt-0.5 text-xs text-zinc-500">
            Source: the built-in limit of 25 (compliance defaults); config may only lower it.
            Checked at each send.
          </p>
        </li>
        <li id="tenant-limit-source_quotas" data-status="not_built" class="py-3 last:pb-0">
          <p class="flex items-baseline justify-between gap-3">
            <span class="text-sm font-medium text-zinc-900">Provider source quotas</span>
            <span class={pill("bg-zinc-100 text-zinc-700 ring-zinc-500/20") ++ ["text-xs"]}>
              not yet built
            </span>
          </p>
          <p class="mt-0.5 text-xs text-zinc-500">
            1,000 Brave search requests and $5 of Exa per month (D-102). Their counter is
            the C5-02 source adapter, not yet built: no usage is counted or shown until then.
          </p>
        </li>
      </ul>
    </.card>
    """
  end

  attr :grants, :any, required: true
  attr :admin?, :boolean, required: true

  @doc "The current real-model grants and allocations, read-only, or why they are not shown."
  def grants(assigns) do
    ~H"""
    <.card id="settings-grants" title="Real-model grants and allocations">
      <:subtitle>
        Every real model call spends an owner-granted attempt; grant admission checks it at use.
      </:subtitle>
      <p id="settings-grants-source" class="mb-3 text-xs text-zinc-500">
        Source: the owner's grants (C9), created and edited on the
        <.link
          :if={@admin?}
          navigate={~p"/admin"}
          class="font-medium text-teal-700 hover:underline"
        >
          Admin page
        </.link>
        <span :if={!@admin?}>Admin page</span>.
      </p>

      <p
        :if={@grants == :hidden}
        id="settings-grants-hidden"
        class="flex items-center gap-2 text-sm text-zinc-600"
      >
        <.icon name="hero-eye-slash" class="size-4" /> Grants are not visible to your role.
      </p>

      <div
        :if={match?({:withheld, _}, @grants)}
        id="settings-grants-withheld"
        class="flex items-start gap-2 rounded-lg border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800"
      >
        <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0" />
        <span>The grants could not be shown: {elem(@grants, 1)}</span>
      </div>

      <p :if={@grants == {:ok, []}} id="settings-grants-none" class="text-sm text-zinc-600">
        No model-call grant: no real model call can be admitted until the owner creates one.
        The deterministic fake needs none.
      </p>

      <ul :if={match?({:ok, [_ | _]}, @grants)} class="divide-y divide-zinc-100">
        <li
          :for={grant <- elem(@grants, 1)}
          id={"settings-grant-#{grant.id}"}
          data-status={grant.status}
          data-total-attempts={grant.total_attempts}
          class="py-3 first:pt-0 last:pb-0"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="text-sm font-semibold text-zinc-900">{grant.name}</span>
            <.badge status={grant.status} />
            <span class="text-xs text-zinc-500">revision {grant.revision}</span>
          </div>
          <p class="mt-0.5 text-xs text-zinc-600">
            {delimit(grant.total_attempts)} attempts in total<span :if={grant.per_utc_day_attempts}>,
            at most {delimit(grant.per_utc_day_attempts)} per UTC day</span>
            · {GrantForm.utc(grant.starts_at)} to {GrantForm.utc(grant.expires_at)}
          </p>
          <ul class="mt-2 space-y-1">
            <li
              :for={allocation <- grant.allocations}
              id={"settings-allocation-#{allocation.id}"}
              data-attempts={allocation.attempts}
              class="flex items-center justify-between gap-3 rounded-md bg-zinc-50 px-2.5 py-1.5 text-xs"
            >
              <span class="text-zinc-800">{allocation_label(allocation)}</span>
              <span class="tabular-nums text-zinc-600">{delimit(allocation.attempts)} attempts</span>
            </li>
          </ul>
        </li>
      </ul>
    </.card>
    """
  end

  @doc "The fixed safeguards no setting touches, with their reasons (D-062)."
  def safeguards(assigns) do
    assigns = assign(assigns, entries: Safeguards.entries(), version: Safeguards.version())

    ~H"""
    <.card id="safeguards-card" title="Fixed safeguards">
      <:subtitle>
        Never editable here; changed only through reviewed code (registry version {@version}).
      </:subtitle>
      <ul id="safeguards" class="grid gap-3 sm:grid-cols-2">
        <li
          :for={entry <- @entries}
          class="rounded-lg border border-zinc-200 p-3 transition hover:border-zinc-300"
        >
          <p class="flex items-start gap-2 text-sm font-medium text-zinc-900">
            <.icon name="hero-lock-closed" class="mt-0.5 size-4 shrink-0 text-zinc-400" />
            {entry.name}
          </p>
          <p class="mt-1 pl-6 text-xs text-zinc-600">{entry.reason}</p>
          <p class="mt-1 pl-6 font-mono text-[0.7rem] text-zinc-400">{entry.enforced_by}</p>
        </li>
      </ul>
    </.card>
    """
  end
end
