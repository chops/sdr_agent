defmodule SdrAgentWeb.AdminLive.BudgetComponents do
  @moduledoc """
  Function components of the admin page's model call budgets (C9-05):
  the grant list with allocations, availability and consumption, the
  create/edit form with its allocation rows and review step
  (`SdrAgentWeb.GrantForm`), and the inline revoke/release confirmation.
  Rendering only: every event is handled by `SdrAgentWeb.AdminLive`, which
  holds the budget and confirmation state these components show.
  """
  use SdrAgentWeb, :html

  alias SdrAgentWeb.GrantForm

  @input "w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm placeholder:text-zinc-400 focus:border-teal-600 focus:outline-none focus:ring-2 focus:ring-teal-600/20"
  @check "size-4 rounded border-zinc-300 text-teal-700 focus:ring-teal-600/30"

  @doc """
  The \"Model call budgets\" card: the grants with their allocations and
  consumption, the editor while a budget is being created or edited, and the
  inline confirmation of a pending revoke or release.
  """
  attr :grants, :list, required: true
  attr :usage, :map, required: true
  attr :budget, :map, default: nil
  attr :confirm, :map, default: nil
  attr :now, :any, required: true

  def budgets(assigns) do
    ~H"""
    <.card id="model-call-budgets" title="Model call budgets">
      <:subtitle>
        Owner grants of real-model attempts. Every real call is charged to one allocation;
        attempts are never refunded. Times are America/Denver, with UTC alongside.
      </:subtitle>
      <:actions>
        <.ui_button
          :if={is_nil(@budget)}
          id="new-grant"
          size="sm"
          variant="primary"
          phx-click="new_grant"
        >
          <.icon name="hero-plus" class="size-4" /> New budget
        </.ui_button>
      </:actions>

      <.grant_editor :if={@budget} budget={@budget} />

      <.empty
        :if={@grants == [] and is_nil(@budget)}
        id="grants-empty"
        icon="hero-banknotes"
        title="No budgets yet"
      >
        Without a budget no real model call is made; the Fake needs none.
      </.empty>

      <ul id="grants" class="divide-y divide-zinc-100">
        <li :for={grant <- @grants} id={"grants-#{grant.id}"} class="py-4 first:pt-0 last:pb-0">
          <.grant_row
            grant={grant}
            usage={@usage[grant.id] || %{consumed: 0, today: 0, allocations: %{}}}
            confirm={@confirm}
            now={@now}
            editing?={not is_nil(@budget)}
          />
        </li>
      </ul>
    </.card>
    """
  end

  attr :grant, :map, required: true
  attr :usage, :map, required: true
  attr :confirm, :map, default: nil
  attr :now, :any, required: true
  attr :editing?, :boolean, default: false

  defp grant_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <h3 class="text-sm font-semibold text-zinc-900">{@grant.name}</h3>
          <.badge status={@grant.status} />
          <span class="text-xs text-zinc-500">
            revision
            <span id={"grant-revision-#{@grant.id}"} class="tabular-nums">{@grant.revision}</span>
          </span>
        </div>
        <p class="mt-0.5 text-sm text-zinc-600">{@grant.purpose}</p>
      </div>
      <div
        :if={@grant.status == :active and not @editing?}
        class="flex shrink-0 flex-wrap items-center gap-2"
      >
        <.ui_button
          id={"edit-grant-#{@grant.id}"}
          size="sm"
          phx-click="edit_grant"
          phx-value-id={@grant.id}
        >
          <.icon name="hero-pencil-square" class="size-4" /> Edit terms
        </.ui_button>
        <.ui_button
          id={"revoke-grant-#{@grant.id}"}
          size="sm"
          variant="danger"
          phx-click="revoke_grant"
          phx-value-id={@grant.id}
        >
          Revoke…
        </.ui_button>
      </div>
    </div>

    <.confirm_panel :if={@confirm && @confirm.grant_id == @grant.id} confirm={@confirm} />

    <dl class="mt-3 grid gap-x-8 sm:grid-cols-2 xl:grid-cols-3">
      <.field label="Profiles">{profiles_label(@grant.profile_ids)}</.field>
      <.field label="Consumed">
        <span id={"grant-consumed-#{@grant.id}"} data-consumed={@usage.consumed} class="tabular-nums">
          {@usage.consumed} / {@grant.total_attempts}
        </span>
      </.field>
      <.field label="Today (UTC)">
        <span id={"grant-today-#{@grant.id}"} class="tabular-nums">
          <span :if={@grant.per_utc_day_attempts}>
            {@usage.today} / {@grant.per_utc_day_attempts}
          </span>
          <span :if={is_nil(@grant.per_utc_day_attempts)}>{@usage.today} (no day limit)</span>
        </span>
      </.field>
      <.field label="Starts">
        <span class="text-xs">
          {GrantForm.denver(@grant.starts_at)}
          <span class="block text-zinc-400">{GrantForm.utc(@grant.starts_at)}</span>
        </span>
      </.field>
      <.field label="Expires">
        <span class="text-xs">
          {GrantForm.denver(@grant.expires_at)}
          <span class="block text-zinc-400">{GrantForm.utc(@grant.expires_at)}</span>
        </span>
      </.field>
      <.field :if={@grant.revoked_at} label="Revoked">
        <span class="text-xs">{GrantForm.denver(@grant.revoked_at)}</span>
      </.field>
    </dl>

    <div class="mt-3 overflow-x-auto">
      <table class="w-full min-w-[40rem] text-left text-sm">
        <thead class="text-xs uppercase tracking-wider text-zinc-500">
          <tr>
            <th scope="col" class="py-2 pr-4 font-medium">Allocation</th>
            <th scope="col" class="py-2 pr-4 font-medium">Funds</th>
            <th scope="col" class="py-2 pr-4 font-medium">Consumed</th>
            <th scope="col" class="py-2 pr-4 font-medium">Availability</th>
            <th scope="col" class="py-2 font-medium"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100">
          <tr
            :for={allocation <- GrantForm.sort_allocations(@grant.allocations)}
            id={"allocation-#{allocation.id}"}
          >
            <td class="py-2.5 pr-4 font-medium text-zinc-900">{allocation_label(allocation)}</td>
            <td class="py-2.5 pr-4 text-xs text-zinc-600">{profiles_label(allocation.applies_to)}</td>
            <td class="py-2.5 pr-4 tabular-nums">
              <span
                data-consumed={@usage.allocations[allocation.id] || 0}
                data-attempts={allocation.attempts}
              >
                {@usage.allocations[allocation.id] || 0} / {allocation.attempts}
              </span>
            </td>
            <td class="py-2.5 pr-4 text-xs">
              <.availability_state allocation={allocation} now={@now} />
            </td>
            <td class="py-2.5 text-right">
              <.ui_button
                :if={
                  @grant.status == :active and not @editing? and
                    availability(allocation, @now) == :held
                }
                id={"release-#{allocation.id}"}
                size="sm"
                phx-click="release_allocation"
                phx-value-id={allocation.id}
              >
                Release early…
              </.ui_button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :allocation, :map, required: true
  attr :now, :any, required: true

  defp availability_state(assigns) do
    assigns = assign(assigns, :state, availability(assigns.allocation, assigns.now))

    ~H"""
    <span data-availability={@state} class={availability_tone(@state)}>
      <span :if={@state == :available}>available</span>
      <span :if={@state == :released}>
        released early {GrantForm.denver(@allocation.released_at)}
      </span>
      <span :if={@state == :held}>
        held until {GrantForm.denver(@allocation.available_from)}
        <span class="block text-zinc-400">{GrantForm.utc(@allocation.available_from)}</span>
      </span>
      <span :if={@state == :closed}>closed {GrantForm.denver(@allocation.available_until)}</span>
      <span
        :if={@allocation.available_until && @state in [:available, :released]}
        class="block text-zinc-400"
      >
        until {GrantForm.denver(@allocation.available_until)}
      </span>
    </span>
    """
  end

  defp availability_tone(:available), do: "text-emerald-700"
  defp availability_tone(:released), do: "text-teal-700"
  defp availability_tone(:held), do: "text-amber-700"
  defp availability_tone(:closed), do: "text-zinc-500"

  attr :confirm, :map, required: true

  defp confirm_panel(assigns) do
    ~H"""
    <div
      id="confirm-action"
      role="alertdialog"
      aria-labelledby="confirm-action-title"
      class="mt-3 rounded-lg border border-amber-200 bg-amber-50/70 p-4"
    >
      <p id="confirm-action-title" class="text-sm font-semibold text-amber-900">
        <span :if={@confirm.action == :revoke}>Revoke {@confirm.name}?</span>
        <span :if={@confirm.action == :release}>
          Release {allocation_label(@confirm)} of {@confirm.name} early?
        </span>
      </p>
      <p class="mt-1 text-sm text-amber-900/80">
        <span :if={@confirm.action == :revoke}>
          Revocation is terminal: no new reservation can use this budget, and it cannot be edited again.
          Attempts already consumed stay charged.
        </span>
        <span :if={@confirm.action == :release}>
          The allocation becomes spendable now instead of at its available-from time. Its attempts do not change.
        </span>
        Applies to revision {@confirm.revision}.
      </p>
      <p :if={@confirm.error} id="confirm-action-error" class="mt-2 text-sm font-medium text-rose-700">
        {@confirm.error}
      </p>
      <div class="mt-3 flex flex-wrap gap-2">
        <.ui_button
          id="confirm-action-button"
          size="sm"
          variant={if @confirm.action == :revoke, do: "danger", else: "primary"}
          phx-click="confirm_action"
          phx-disable-with="Saving…"
        >
          <span :if={@confirm.action == :revoke}>Revoke budget</span>
          <span :if={@confirm.action == :release}>Release allocation</span>
        </.ui_button>
        <.ui_button id="cancel-action" size="sm" variant="ghost" phx-click="cancel_action">
          Cancel
        </.ui_button>
      </div>
    </div>
    """
  end

  attr :budget, :map, required: true

  defp grant_editor(assigns) do
    assigns =
      assign(assigns,
        params: assigns.budget.params,
        rows: GrantForm.allocation_rows(assigns.budget.params),
        originals:
          if(assigns.budget.grant, do: GrantForm.originals(assigns.budget.grant), else: %{}),
        input: @input,
        check: @check
      )

    ~H"""
    <section
      id="grant-editor"
      class="mb-5 rounded-xl border border-zinc-200 bg-zinc-50/60 p-4 sm:p-5"
    >
      <h3 class="text-sm font-semibold text-zinc-900">
        <span :if={@budget.mode == :create}>New budget</span>
        <span :if={@budget.mode == :edit}>
          Edit {@budget.grant.name} (revision {@budget.grant.revision})
        </span>
      </h3>

      <div
        :if={@budget.stale}
        id="grant-stale"
        class="mt-3 flex flex-wrap items-center justify-between gap-3 rounded-lg border border-rose-200 bg-rose-50 p-3"
      >
        <p class="text-sm text-rose-800">
          <.icon name="hero-exclamation-triangle" class="size-4" /> {@budget.stale}
        </p>
        <.ui_button id="reload-grant" size="sm" phx-click="reload_grant">
          <.icon name="hero-arrow-path" class="size-4" /> Reload
        </.ui_button>
      </div>

      <.grant_review :if={@budget.step == :review} budget={@budget} />

      <.form
        :if={@budget.step == :edit}
        for={%{}}
        as={:grant}
        id="grant-form"
        phx-change="change_grant"
        phx-submit="review_grant"
        class="mt-4 space-y-5"
      >
        <p
          :if={@budget.error}
          id="grant-errors"
          class="rounded-lg border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800"
        >
          {@budget.error}
        </p>
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            id="grant-name"
            name="grant[name]"
            value={@params["name"]}
            label="Name"
            placeholder="G-R0"
            errors={errors_for(@budget, :name)}
            class={@input}
          />
          <fieldset>
            <legend class="mb-1 text-sm text-zinc-700">Profiles</legend>
            <input type="hidden" name="grant[profile_ids][]" value="" />
            <div class="flex flex-wrap gap-4 py-2">
              <label
                :for={profile <- GrantForm.profiles()}
                class="inline-flex items-center gap-2 text-sm text-zinc-800"
              >
                <input
                  type="checkbox"
                  id={"grant-profile-#{profile}"}
                  name="grant[profile_ids][]"
                  value={profile}
                  checked={checked?(@params, "profile_ids", to_string(profile))}
                  class={@check}
                />
                {humanize(profile)}
              </label>
            </div>
            <.field_errors errors={errors_for(@budget, :profile_ids)} />
          </fieldset>
          <div class="sm:col-span-2">
            <.input
              id="grant-purpose"
              name="grant[purpose]"
              type="textarea"
              rows="2"
              value={@params["purpose"]}
              label="Purpose"
              errors={errors_for(@budget, :purpose)}
              class={@input}
            />
          </div>
          <.input
            id="grant-total-attempts"
            name="grant[total_attempts]"
            type="number"
            min="1"
            value={@params["total_attempts"]}
            label="Total attempts"
            errors={errors_for(@budget, :total_attempts)}
            class={@input}
          />
          <.input
            id="grant-per-day"
            name="grant[per_utc_day_attempts]"
            type="number"
            min="1"
            value={@params["per_utc_day_attempts"]}
            label="Per UTC day (optional)"
            errors={errors_for(@budget, :per_utc_day_attempts)}
            class={@input}
          />
          <.wall_time
            id="grant-starts-at"
            name="grant[starts_at]"
            label="Starts (America/Denver)"
            value={@params["starts_at"]}
            original={@originals[{:grant, :starts_at}]}
            errors={errors_for(@budget, :starts_at)}
            class={@input}
          />
          <.wall_time
            id="grant-expires-at"
            name="grant[expires_at]"
            label="Expires (America/Denver)"
            value={@params["expires_at"]}
            original={@originals[{:grant, :expires_at}]}
            errors={errors_for(@budget, :expires_at)}
            class={@input}
          />
        </div>

        <div>
          <div class="flex items-center justify-between gap-3">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Allocations</h4>
            <.ui_button id="add-allocation" type="button" size="sm" phx-click="add_allocation">
              <.icon name="hero-plus" class="size-4" /> Add allocation
            </.ui_button>
          </div>
          <p :if={@budget.mode == :edit} class="mt-1 text-xs text-zinc-500">
            Existing allocations keep their key and profile and are never deleted; move attempts by lowering one and raising another.
          </p>
          <.field_errors errors={errors_for(@budget, :allocations)} />
          <p :if={@rows == []} class="mt-2 text-sm text-zinc-500">
            No allocations: nothing in this budget can be spent until one is added.
          </p>
          <div class="mt-2 space-y-3">
            <.allocation_row
              :for={{index, row} <- @rows}
              index={index}
              row={row}
              locked?={MapSet.member?(@budget.locked, index)}
              errors={errors_for(@budget, {:allocation, index})}
              originals={@originals}
              input={@input}
              check={@check}
            />
          </div>
        </div>

        <div class="flex flex-wrap gap-2 border-t border-zinc-200 pt-4">
          <.ui_button id="review-grant" type="submit" variant="primary">
            Review…
          </.ui_button>
          <.ui_button id="cancel-grant" type="button" variant="ghost" phx-click="cancel_grant">
            Cancel
          </.ui_button>
        </div>
      </.form>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: ""
  attr :original, :any, default: nil, doc: "the stored instant on an edit (kept while untouched)"
  attr :errors, :list, default: []
  attr :class, :string, required: true

  defp wall_time(assigns) do
    assigns = assign(assigns, :preview, GrantForm.preview(assigns.value, assigns.original))

    ~H"""
    <div>
      <.input
        id={@id}
        name={@name}
        type="datetime-local"
        value={@value}
        label={@label}
        errors={@errors}
        class={@class}
      />
      <p id={"#{@id}-utc"} class="-mt-1 text-xs text-zinc-500">
        {if @preview, do: "= #{@preview}", else: "Enter a Denver wall time; UTC is shown here."}
      </p>
    </div>
    """
  end

  attr :errors, :list, required: true

  defp field_errors(assigns) do
    ~H"""
    <p :for={message <- @errors} class="mt-1.5 flex items-center gap-2 text-sm text-rose-700">
      <.icon name="hero-exclamation-circle" class="size-4" /> {message}
    </p>
    """
  end

  attr :index, :string, required: true
  attr :row, :map, required: true
  attr :locked?, :boolean, default: false
  attr :errors, :list, default: []
  attr :originals, :map, default: %{}
  attr :input, :string, required: true
  attr :check, :string, required: true

  defp allocation_row(assigns) do
    assigns = assign(assigns, :prefix, "grant[allocations][#{assigns.index}]")

    ~H"""
    <div
      id={"allocation-row-#{@index}"}
      class="rounded-lg border border-zinc-200 bg-white p-3 shadow-[0_1px_2px_rgba(24,24,27,0.04)]"
    >
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div :if={@locked?}>
          <input type="hidden" name={"#{@prefix}[key]"} value={@row["key"]} />
          <input type="hidden" name={"#{@prefix}[profile_id]"} value={@row["profile_id"]} />
          <p class="text-xs text-zinc-500">Allocation</p>
          <p class="py-2 text-sm font-medium text-zinc-900">
            {humanize(@row["key"])} · {if @row["profile_id"] in [nil, ""],
              do: "any profile",
              else: humanize(@row["profile_id"])}
          </p>
        </div>
        <.input
          :if={not @locked?}
          id={"allocation-#{@index}-key"}
          name={"#{@prefix}[key]"}
          type="select"
          label="Key"
          prompt="Choose…"
          options={Enum.map(GrantForm.keys(), &{humanize(&1), &1})}
          value={@row["key"]}
          class={@input}
        />
        <.input
          :if={not @locked?}
          id={"allocation-#{@index}-profile"}
          name={"#{@prefix}[profile_id]"}
          type="select"
          label="Profile"
          options={[
            {"Any of the budget's profiles", ""} | Enum.map(GrantForm.profiles(), &{humanize(&1), &1})
          ]}
          value={@row["profile_id"]}
          class={@input}
        />
        <.input
          id={"allocation-#{@index}-attempts"}
          name={"#{@prefix}[attempts]"}
          type="number"
          min="1"
          label="Attempts"
          value={@row["attempts"]}
          class={@input}
        />
        <fieldset class={if @locked?, do: "lg:col-span-2", else: ""}>
          <legend class="mb-1 text-sm text-zinc-700">Funds buckets</legend>
          <input type="hidden" name={"#{@prefix}[applies_to][]"} value="" />
          <div class="flex flex-wrap gap-x-3 gap-y-1 py-2">
            <label
              :for={bucket <- GrantForm.buckets()}
              class="inline-flex items-center gap-1.5 text-sm text-zinc-800"
            >
              <input
                type="checkbox"
                id={"allocation-#{@index}-applies-#{bucket}"}
                name={"#{@prefix}[applies_to][]"}
                value={bucket}
                checked={checked?(@row, "applies_to", to_string(bucket))}
                class={@check}
              />
              {humanize(bucket)}
            </label>
          </div>
        </fieldset>
        <.wall_time
          id={"allocation-#{@index}-available-from"}
          name={"#{@prefix}[available_from]"}
          label="Available from (optional)"
          value={@row["available_from"]}
          original={GrantForm.row_original(@originals, @row, :available_from)}
          class={@input}
        />
        <.wall_time
          id={"allocation-#{@index}-available-until"}
          name={"#{@prefix}[available_until]"}
          label="Available until (optional)"
          value={@row["available_until"]}
          original={GrantForm.row_original(@originals, @row, :available_until)}
          class={@input}
        />
      </div>
      <div class="mt-2 flex items-start justify-between gap-3">
        <.field_errors errors={@errors} />
        <.ui_button
          :if={not @locked?}
          id={"remove-allocation-#{@index}"}
          type="button"
          size="sm"
          variant="ghost"
          phx-click="remove_allocation"
          phx-value-index={@index}
          class="ml-auto"
        >
          <.icon name="hero-trash" class="size-4" /> Remove
        </.ui_button>
      </div>
    </div>
    """
  end

  attr :budget, :map, required: true

  defp grant_review(assigns) do
    ~H"""
    <div id="grant-review" class="mt-4 space-y-4">
      <p class="text-sm text-zinc-600">
        <span :if={@budget.mode == :create}>
          Review the new budget <span class="font-medium text-zinc-900">{@budget.terms.name}</span>.
          Nothing is saved until you create it.
        </span>
        <span :if={@budget.mode == :edit}>
          Review the changes to <span class="font-medium text-zinc-900">{@budget.grant.name}</span>,
          saving as revision {@budget.grant.revision + 1} (only if it is still at revision {@budget.grant.revision}).
        </span>
      </p>

      <dl
        :if={@budget.mode == :create}
        class="grid gap-x-8 rounded-lg border border-zinc-200 bg-white px-4 py-2 sm:grid-cols-2"
      >
        <.field label="Name">{@budget.terms.name}</.field>
        <.field label="Profiles">{profiles_label(@budget.terms.profile_ids)}</.field>
        <.field label="Total attempts">{@budget.terms.total_attempts}</.field>
        <.field label="Per UTC day">{@budget.terms.per_utc_day_attempts || "no day limit"}</.field>
        <.field label="Starts">
          <span id="review-starts-at" class="text-xs">
            {GrantForm.denver(@budget.terms.starts_at)}
            <span class="block text-zinc-500">{GrantForm.utc(@budget.terms.starts_at)}</span>
          </span>
        </.field>
        <.field label="Expires">
          <span id="review-expires-at" class="text-xs">
            {GrantForm.denver(@budget.terms.expires_at)}
            <span class="block text-zinc-500">{GrantForm.utc(@budget.terms.expires_at)}</span>
          </span>
        </.field>
        <div class="py-1.5 text-sm sm:col-span-2">
          <dt class="text-zinc-500">Purpose</dt>
          <dd class="mt-0.5 text-zinc-900">{@budget.terms.purpose}</dd>
        </div>
      </dl>

      <ul
        :if={@budget.mode == :edit}
        id="review-changes"
        class="divide-y divide-zinc-100 rounded-lg border border-zinc-200 bg-white px-4"
      >
        <li :if={@budget.changes.terms == []} class="py-2 text-sm text-zinc-500">
          No change to the budget terms.
        </li>
        <li :for={{field, old, new} <- @budget.changes.terms} class="py-2 text-sm">
          <span class="text-zinc-500">{humanize(field)}:</span>
          <span class="text-zinc-700">{value_label(old)}</span>
          → <span class="font-medium text-zinc-900">{value_label(new)}</span>
        </li>
      </ul>

      <div>
        <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Allocations</h4>
        <ul
          id="review-allocations"
          class="mt-2 divide-y divide-zinc-100 rounded-lg border border-zinc-200 bg-white px-4"
        >
          <li
            :if={@budget.mode == :create and @budget.terms.allocations == []}
            class="py-2 text-sm text-zinc-500"
          >
            None: nothing in this budget can be spent until one is added.
          </li>
          <li
            :for={allocation <- if(@budget.mode == :create, do: @budget.terms.allocations, else: [])}
            class="py-2 text-sm"
          >
            <.review_allocation allocation={allocation} />
          </li>
          <li
            :if={@budget.mode == :edit and @budget.changes.allocations == []}
            class="py-2 text-sm text-zinc-500"
          >
            No change to the allocations.
          </li>
          <li
            :for={change <- if(@budget.mode == :edit, do: @budget.changes.allocations, else: [])}
            class="py-2 text-sm"
          >
            <.review_change change={change} />
          </li>
        </ul>
      </div>

      <ul :if={@budget.terms.notes != []} id="review-notes" class="space-y-1 text-xs text-amber-800">
        <li :for={note <- @budget.terms.notes} class="flex gap-1.5">
          <.icon name="hero-clock" class="size-4 shrink-0" /> {note}
        </li>
      </ul>

      <div class="flex flex-wrap gap-2 border-t border-zinc-200 pt-4">
        <.ui_button
          id="confirm-grant"
          variant="primary"
          phx-click="confirm_grant"
          phx-disable-with="Saving…"
        >
          <.icon name="hero-check" class="size-4" />
          {if @budget.mode == :create, do: "Create budget", else: "Save changes"}
        </.ui_button>
        <.ui_button id="back-to-edit" variant="ghost" phx-click="back_to_edit">
          Back to edit
        </.ui_button>
      </div>
    </div>
    """
  end

  attr :allocation, :map, required: true

  defp review_allocation(assigns) do
    ~H"""
    <span class="font-medium text-zinc-900">{allocation_label(@allocation)}</span>
    <span class="text-zinc-600">
      · {@allocation.attempts} attempts · funds {profiles_label(@allocation.applies_to)}
    </span>
    <span :if={@allocation.available_from} class="block text-xs text-zinc-500">
      from {value_label(@allocation.available_from)}
    </span>
    <span :if={@allocation.available_until} class="block text-xs text-zinc-500">
      until {value_label(@allocation.available_until)}
    </span>
    """
  end

  attr :change, :any, required: true

  defp review_change(%{change: {:create, allocation}} = assigns) do
    assigns = assign(assigns, :allocation, allocation)

    ~H"""
    <span class="mr-1 rounded bg-teal-50 px-1.5 py-0.5 text-xs font-medium text-teal-800">new</span>
    <.review_allocation allocation={@allocation} />
    """
  end

  defp review_change(%{change: {:update, pair, diffs}} = assigns) do
    assigns = assign(assigns, pair: pair, diffs: diffs)

    ~H"""
    <span class="font-medium text-zinc-900">{allocation_label(@pair)}:</span>
    <span :for={{field, old, new} <- @diffs} class="block text-zinc-700">
      {humanize(field)} {value_label(old)} → {value_label(new)}
    </span>
    """
  end

  @doc """
  An allocation's availability at `now`: `:closed` (at or past
  `available_until`), `:released` (released early), `:held` (before
  `available_from`) or `:available`, as `SdrAgent.Agents.Admission.available?/2`
  decides it: spendable when released or past `available_from`, and before
  `available_until`.
  """
  def availability(allocation, now) do
    cond do
      allocation.available_until && DateTime.compare(now, allocation.available_until) != :lt ->
        :closed

      allocation.released_at ->
        :released

      allocation.available_from && DateTime.compare(allocation.available_from, now) == :gt ->
        :held

      true ->
        :available
    end
  end

  @doc "An allocation (or anything with `key` and `profile_id`) as \"proof · claude cli opus\"."
  def allocation_label(allocation) do
    profile = if allocation.profile_id, do: humanize(allocation.profile_id), else: "any profile"
    "#{humanize(allocation.key)} · #{profile}"
  end

  defp profiles_label([]), do: "none"
  defp profiles_label(profiles), do: Enum.map_join(profiles, ", ", &humanize/1)

  defp value_label(%DateTime{} = at), do: "#{GrantForm.denver(at)} · #{GrantForm.utc(at)}"
  defp value_label(nil), do: "none"
  defp value_label(list) when is_list(list), do: profiles_label(list)
  defp value_label(value) when is_atom(value), do: humanize(value)
  defp value_label(value), do: to_string(value)

  defp errors_for(budget, field), do: Map.get(budget.errors, field, [])

  defp checked?(params, field, value), do: value in List.wrap(params[field])
end
