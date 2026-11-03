defmodule SdrAgentWeb.LeadLive.ProspectSearchPanel do
  @moduledoc """
  The owner-only, company-first "Find prospects" panel on the leads page
  (ADR-0027). It renders server-held search state from
  `SdrAgentWeb.LeadLive.Index`: the company search, company cards, the
  company confirmation form, the confirmed company with its people search
  and company page, and person cards.

  Card fields that come from the provider's structured data are marked
  `data-provider-data` and labelled unverified, apart from the literal
  excerpt (`data-excerpt`). Unknown fields say so. Provider text is only
  ever rendered as escaped text, and no third-party image is loaded.
  Refusals are closed codes shown as fixed messages that never repeat a
  query or a result.
  """
  use Phoenix.Component

  import SdrAgentWeb.CoreComponents, only: [icon: 1, input: 1]

  @messages %{
    forbidden: "Only the current owner can search.",
    unavailable: "Search is not available right now.",
    invalid_input: "That search or company detail was not accepted. Check it and try again.",
    busy: "Another search is still running. Wait for it or cancel it.",
    cooldown: "Wait a few seconds before the next search.",
    timeout: "The search took too long and was stopped.",
    cancelled: "The search was cancelled.",
    rate_limited: "The search service is limiting requests. Try again shortly.",
    quota_exceeded: "The search service credit is used up.",
    provider_auth: "The search service did not accept the configured key.",
    provider_unavailable: "The search service is unavailable.",
    invalid_response: "The search service sent an unusable answer.",
    too_large: "The search service answer was too large.",
    unsafe_url: "The company website address was not accepted.",
    source_mismatch: "The company page came back from a different website, so it was not used.",
    source_missing: "Get the company page first. It is the required company website source.",
    employer_unconfirmed:
      "This person's current employer is not confirmed, so it cannot be used.",
    internal: "The search could not be completed."
  }

  @doc "The fixed message for a refusal code; never a submitted or returned value."
  @spec message(term()) :: String.t()
  def message(code), do: Map.get(@messages, code, "The search could not be completed.")

  attr :search, :any, default: nil
  attr :error, :any, default: nil
  attr :companies, :list, default: []
  attr :selected, :any, default: nil
  attr :context, :any, default: nil
  attr :people, :list, default: []
  attr :source, :any, default: nil

  @doc "The panel."
  def panel(assigns) do
    ~H"""
    <section
      id="prospect-search"
      class="mb-6 overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm"
    >
      <header class="flex items-start justify-between gap-3 border-b border-zinc-100 px-5 py-4">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-zinc-900">Find prospects</h2>
          <p id="search-disclosure" class="mt-1 text-xs text-zinc-500">
            Your search text is sent to Exa, a paid search service; each search uses credit.
            Results are Exa data and are not verified. Nothing is saved until you save a prospect.
          </p>
        </div>
        <button
          type="button"
          phx-click="search_close"
          class="rounded-md p-1 text-zinc-400 transition hover:bg-zinc-100 hover:text-zinc-700"
          aria-label="Close search"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </header>

      <div class="space-y-6 px-5 py-5">
        <.form
          for={%{}}
          as={:search}
          id="company-search-form"
          phx-submit="search_companies"
          class="flex flex-col gap-3 sm:flex-row sm:items-end"
        >
          <div class="min-w-0 flex-1">
            <.input
              name="search[query]"
              value=""
              label="Companies to find"
              placeholder="e.g. seed-stage developer tools companies in Canada"
              required
            />
          </div>
          <button
            type="submit"
            class="rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-zinc-700 focus-visible:outline-2 focus-visible:outline-teal-600"
          >
            Search companies
          </button>
        </.form>

        <div
          :if={@search}
          id="search-running"
          role="status"
          class="flex items-center justify-between gap-3 rounded-lg bg-zinc-50 px-4 py-3 text-sm text-zinc-700"
        >
          <span class="inline-flex items-center gap-2">
            <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" /> Searching…
          </span>
          <button
            id="search-cancel"
            type="button"
            phx-click="search_cancel"
            class="text-xs font-medium text-rose-700 hover:underline"
          >
            Cancel
          </button>
        </div>

        <p
          :if={@error}
          id="search-error"
          role="alert"
          class="rounded-lg border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-800"
        >
          {message(@error)}
        </p>

        <div :if={@companies != [] and is_nil(@context)} id="company-results" class="grid gap-3">
          <.card :for={c <- @companies} candidate={c}>
            <:action>
              <button
                id={"select-company-#{c.id}"}
                type="button"
                phx-click="select_company"
                phx-value-id={c.id}
                class="rounded-md px-2 py-1 text-xs font-medium text-teal-700 ring-1 ring-inset ring-teal-200 transition hover:bg-teal-50"
              >
                Use this company
              </button>
            </:action>
          </.card>
        </div>

        <.form
          :if={@selected && is_nil(@context)}
          for={%{}}
          as={:company}
          id="company-confirm-form"
          phx-submit="confirm_company"
          class="space-y-3 rounded-lg border border-teal-100 bg-teal-50/40 p-4"
        >
          <p class="text-xs text-zinc-600">
            Confirm the company's own website and domain. A directory or profile page is not a
            company website.
          </p>
          <div class="grid gap-3 sm:grid-cols-2">
            <.input
              name="company[website_url]"
              value={@selected.website_url || ""}
              type="url"
              label="Company website"
              placeholder="https://example.com/"
              required
            />
            <.input
              name="company[domain]"
              value={@selected.domain || ""}
              label="Domain"
              placeholder="example.com"
              required
            />
          </div>
          <div class="flex justify-end">
            <button
              type="submit"
              class="rounded-lg bg-teal-700 px-4 py-2 text-sm font-medium text-white transition hover:bg-teal-800"
            >
              Confirm company
            </button>
          </div>
        </.form>

        <div
          :if={@context}
          id="company-context"
          class="space-y-4 rounded-lg border border-zinc-200 p-4"
        >
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <div class="min-w-0">
              <p class="text-sm font-semibold text-zinc-900">{@context.name}</p>
              <p class="break-all font-mono text-xs text-zinc-500">
                {@context.domain} · {@context.website_url}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <button
                id="change-company"
                type="button"
                phx-click="change_company"
                class="rounded-md px-2 py-1 text-xs font-medium text-zinc-600 transition hover:bg-zinc-100"
              >
                Change company
              </button>
              <button
                id="get-company-page"
                type="button"
                phx-click="get_company_page"
                class="rounded-md px-2 py-1 text-xs font-medium text-teal-700 ring-1 ring-inset ring-teal-200 transition hover:bg-teal-50"
              >
                Get company page
              </button>
            </div>
          </div>

          <div :if={@source} id="company-source" class="rounded-lg bg-zinc-50 p-3 text-sm">
            <p class="break-all font-mono text-xs text-teal-800">{@source.url}</p>
            <p data-excerpt class="mt-1 whitespace-pre-wrap text-zinc-700">{@source.excerpt}</p>
          </div>

          <.form
            for={%{}}
            as={:people}
            id="people-search-form"
            phx-submit="search_people"
            class="flex flex-col gap-3 sm:flex-row sm:items-end"
          >
            <div class="min-w-0 flex-1">
              <.input
                name="people[query]"
                value=""
                label={"People at #{@context.name}"}
                placeholder="e.g. founder or CEO"
                required
              />
            </div>
            <button
              type="submit"
              class="rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-zinc-700"
            >
              Search people
            </button>
          </.form>

          <div :if={@people != []} id="people-results" class="grid gap-3">
            <.card :for={p <- @people} candidate={p}>
              <:action>
                <button
                  :if={p.employer_match?}
                  id={"prefill-#{p.id}"}
                  type="button"
                  phx-click="prefill"
                  phx-value-id={p.id}
                  class="rounded-md bg-teal-700 px-2 py-1 text-xs font-medium text-white transition hover:bg-teal-800"
                >
                  Add as prospect
                </button>
              </:action>
            </.card>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :candidate, :map, required: true
  slot :action

  defp card(assigns) do
    ~H"""
    <article
      id={"candidate-#{@candidate.id}"}
      class="rounded-lg border border-zinc-200 p-4 transition hover:border-zinc-300"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <p class="font-medium text-zinc-900">{heading(@candidate)}</p>
          <a
            href={@candidate.url}
            target="_blank"
            rel="noopener noreferrer nofollow"
            class="break-all font-mono text-xs text-teal-700 hover:underline"
          >
            {@candidate.url}
          </a>
        </div>
        {render_slot(@action)}
      </div>

      <dl class="mt-3 grid gap-x-6 gap-y-1 text-xs sm:grid-cols-3">
        <%= for {label, key, value} <- facts(@candidate) do %>
          <div>
            <dt class="text-zinc-500">{label}</dt>
            <dd :if={is_nil(value)} data-unknown={key} class="text-zinc-400">Unknown</dd>
            <dd :if={not is_nil(value)} data-provider-data class="text-zinc-900">{value}</dd>
          </div>
        <% end %>
      </dl>
      <p
        :if={@candidate.kind == :person and not @candidate.employer_match?}
        data-employer-unconfirmed
        class="mt-2 inline-block rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-inset ring-amber-200"
      >
        Employer unconfirmed
      </p>
      <p class="mt-2 text-[11px] uppercase tracking-wide text-zinc-400">
        Exa data, unverified · read {Date.to_iso8601(@candidate.retrieved_on)}
      </p>
      <blockquote
        :if={@candidate.excerpt}
        data-excerpt
        class="mt-2 whitespace-pre-wrap border-l-2 border-zinc-200 pl-3 text-sm text-zinc-700"
      >
        {@candidate.excerpt}
      </blockquote>
    </article>
    """
  end

  defp heading(%{kind: :person} = c) do
    case Enum.reject([c.first_name, c.last_name], &is_nil/1) do
      [] -> c.title
      names -> Enum.join(names, " ")
    end
  end

  defp heading(c), do: c.name || c.title

  defp facts(%{kind: :company} = c) do
    [
      {"People", "employee_count", c.employee_count},
      {"Location", "location", c.location},
      {"Website", "website_url", c.website_url}
    ]
  end

  defp facts(c) do
    [
      {"Role", "role", c.role},
      {"Company", "company_name", c.company_name},
      {"Location", "location", c.location}
    ]
  end
end
