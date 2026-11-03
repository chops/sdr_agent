defmodule SdrAgentWeb.LeadLive.OwnerIntakePanel do
  @moduledoc """
  The owner-only "Add prospect" panel on the leads page (ADR-0026).

  The form is turned into the string-key params of
  `SdrAgent.Prototype.OwnerIntake.preview/2`. Only the known fields are
  kept, and sources are taken in index order. The page keeps the preview
  the domain returns in server assigns; the client never supplies one.
  Refusals are closed codes shown as fixed messages that never repeat a
  submitted value.
  """
  use Phoenix.Component

  import SdrAgentWeb.CoreComponents, only: [icon: 1, input: 1]

  @fields ~w(company_name domain website_url first_name last_name title email)
  @source_fields ~w(url source_type retrieved_on excerpt)
  @max_sources 3
  @source_types [
    {"Company website", "company_site"},
    {"Written by the person", "person_authored"},
    {"Attributed third party", "attributed_third_party"},
    {"Directory", "directory"},
    {"Other third party", "third_party"}
  ]

  @messages %{
    forbidden: "Only the current owner can add prospects.",
    invalid_input:
      "Some fields are missing or not accepted. Check the company domain (plain ASCII), the " <>
        "work email at that domain (no role mailbox), and each source: an HTTPS link, a date " <>
        "that is not in the future, and an excerpt of at most 2,000 bytes.",
    intake_conflict: "This contact is already saved with different details.",
    preview_stale: "Something changed since the preview. Preview the prospect again.",
    account_inactive: "That company is archived and cannot take new prospects.",
    suppressed: "That company or address is on the suppression list.",
    website_source_missing:
      "Add exactly one company website source whose link is the company website address.",
    website_source_ambiguous: "Only one source may be the company website page.",
    no_preview: "Preview the prospect before saving it."
  }

  @doc "The most sources one request may carry."
  def max_sources, do: @max_sources

  @doc "The domain params for the submitted form map, keeping only known fields."
  @spec params(map()) :: map()
  def params(form) when is_map(form) do
    sources =
      form
      |> Map.get("sources", %{})
      |> source_list()
      |> Enum.map(&Map.take(&1, @source_fields))

    form |> Map.take(@fields) |> Map.put("sources", sources)
  end

  def params(_form), do: %{"sources" => []}

  defp source_list(sources) when is_map(sources) do
    sources
    |> Enum.flat_map(fn {key, value} ->
      case Integer.parse(to_string(key)) do
        {index, ""} when is_map(value) -> [{index, value}]
        _other -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp source_list(_sources), do: []

  @doc "The fixed message for a refusal code; never a submitted value."
  @spec message(term()) :: String.t()
  def message(code), do: Map.get(@messages, code, "The prospect could not be saved.")

  @doc "The preview mode label."
  def mode_label(:create), do: "New company"
  def mode_label(:reuse), do: "Existing company"
  def mode_label(:replay), do: "Already added"
  def mode_label(_mode), do: "Unknown"

  attr :form, :any, required: true
  attr :source_rows, :list, required: true
  attr :preview, :any, default: nil
  attr :error, :any, default: nil

  @doc "The panel: disclosures, the form, any refusal and the preview."
  def panel(assigns) do
    assigns = assign(assigns, source_types: @source_types, max_sources: @max_sources)

    ~H"""
    <section
      id="owner-intake"
      class="mb-6 overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm"
    >
      <header class="flex items-start justify-between gap-3 border-b border-zinc-100 px-5 py-4">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold text-zinc-900">Add a prospect</h2>
          <p
            id={if(is_nil(@preview), do: "intake-unverified", else: "intake-unverified-header")}
            class="mt-1 text-xs text-amber-800"
          >
            What you enter is saved as owner-supplied and not independently verified. The agent
            treats it as unverified evidence.
          </p>
          <p id="intake-correction-unsupported" class="mt-1 text-xs text-zinc-500">
            Saved prospects cannot be edited or withdrawn in this version. Check the preview
            before saving.
          </p>
        </div>
        <button
          type="button"
          phx-click="intake_close"
          class="rounded-md p-1 text-zinc-400 transition hover:bg-zinc-100 hover:text-zinc-700"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </header>

      <.form
        for={@form}
        id="owner-intake-form"
        phx-change="intake_change"
        phx-submit="intake_preview"
        class="space-y-6 px-5 py-5"
      >
        <fieldset class="grid gap-4 sm:grid-cols-3">
          <legend class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">
            Company
          </legend>
          <.input field={@form[:company_name]} label="Company name" required />
          <.input field={@form[:domain]} label="Domain" placeholder="example.com" required />
          <.input
            field={@form[:website_url]}
            type="url"
            label="Website"
            placeholder="https://example.com/"
            required
          />
        </fieldset>

        <fieldset class="grid gap-4 sm:grid-cols-2">
          <legend class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">
            Contact
          </legend>
          <.input field={@form[:first_name]} label="First name" required />
          <.input field={@form[:last_name]} label="Last name" required />
          <.input field={@form[:title]} label="Title" required />
          <.input field={@form[:email]} type="email" label="Work email" required />
        </fieldset>

        <fieldset class="space-y-4">
          <legend class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">
            Sources (one must be the company website page)
          </legend>
          <div
            :for={index <- @source_rows}
            id={"intake-source-#{index}"}
            class="grid gap-4 rounded-lg border border-zinc-100 bg-zinc-50/60 p-4 sm:grid-cols-3"
          >
            <.input
              name={"intake[sources][#{index}][url]"}
              value={source_value(@form, index, "url")}
              type="url"
              label="Link"
              required
            />
            <.input
              name={"intake[sources][#{index}][source_type]"}
              value={source_value(@form, index, "source_type") || "company_site"}
              type="select"
              options={@source_types}
              label="Kind"
            />
            <.input
              name={"intake[sources][#{index}][retrieved_on]"}
              value={source_value(@form, index, "retrieved_on")}
              type="date"
              label="Read on"
              required
            />
            <div class="sm:col-span-3">
              <.input
                name={"intake[sources][#{index}][excerpt]"}
                value={source_value(@form, index, "excerpt")}
                type="textarea"
                label="Exact excerpt (kept byte for byte)"
                rows="3"
                required
              />
            </div>
          </div>
          <button
            :if={length(@source_rows) < @max_sources}
            id="intake-add-source"
            type="button"
            phx-click="intake_add_source"
            class="inline-flex items-center gap-1 text-xs font-medium text-teal-700 hover:underline"
          >
            <.icon name="hero-plus" class="size-3.5" /> Add another source
          </button>
        </fieldset>

        <p
          :if={@error}
          id="intake-error"
          role="alert"
          class="rounded-lg border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-800"
        >
          {message(@error)}
        </p>

        <div class="flex justify-end">
          <button
            type="submit"
            class="rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-zinc-700 focus-visible:outline-2 focus-visible:outline-teal-600"
          >
            Preview
          </button>
        </div>
      </.form>

      <div :if={@preview} id="intake-preview" class="border-t border-zinc-100 bg-teal-50/40 px-5 py-5">
        <div class="flex flex-wrap items-center gap-2">
          <h3 class="text-sm font-semibold text-zinc-900">Preview</h3>
          <span
            id="intake-preview-mode"
            class="rounded-full bg-white px-2 py-0.5 text-xs font-medium text-teal-800 ring-1 ring-inset ring-teal-200"
          >
            {mode_label(@preview.mode)}
          </span>
          <span
            id="intake-unverified"
            class="rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-inset ring-amber-200"
          >
            Owner-supplied, not independently verified
          </span>
        </div>
        <dl class="mt-4 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
          <div>
            <dt class="text-xs text-zinc-500">Company</dt>
            <dd id="intake-preview-company" class="text-zinc-900">{company_name(@preview)}</dd>
          </div>
          <div>
            <dt class="text-xs text-zinc-500">Domain</dt>
            <dd id="intake-preview-domain" class="font-mono text-zinc-900">
              {@preview.input["domain"]}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-zinc-500">Website</dt>
            <dd id="intake-preview-website" class="break-all font-mono text-zinc-900">
              {website_url(@preview)}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-zinc-500">Contact</dt>
            <dd class="text-zinc-900">
              {@preview.input["first_name"]} {@preview.input["last_name"]} · {@preview.input[
                "title"
              ]}
            </dd>
          </div>
          <div>
            <dt class="text-xs text-zinc-500">Work email</dt>
            <dd id="intake-preview-email" class="font-mono text-zinc-900">
              {@preview.input["email"]}
            </dd>
          </div>
        </dl>
        <ol class="mt-4 space-y-2">
          <li
            :for={{source, index} <- Enum.with_index(@preview.input["sources"] || [])}
            data-source-key={"s#{index + 1}"}
            class="rounded-lg border border-zinc-200 bg-white p-3 text-sm"
          >
            <p class="break-all font-mono text-xs text-teal-800">{source["url"]}</p>
            <p class="mt-1 whitespace-pre-wrap text-zinc-700">{source["excerpt"]}</p>
          </li>
        </ol>
        <div class="mt-5 flex justify-end">
          <button
            id="intake-commit"
            type="button"
            phx-click="intake_commit"
            phx-disable-with="Saving…"
            class="rounded-lg bg-teal-700 px-4 py-2 text-sm font-medium text-white transition hover:bg-teal-800 focus-visible:outline-2 focus-visible:outline-teal-600"
          >
            {if @preview.mode == :replay, do: "Open the saved lead", else: "Save prospect"}
          </button>
        </div>
      </div>
    </section>
    """
  end

  # Reuse never changes the existing Account. Show its server-read values,
  # not ignored replacements typed into the form. Create uses normalized input.
  defp company_name(%{mode: :reuse, account: %{name: name}}), do: name
  defp company_name(%{input: input}), do: input["company_name"]

  defp website_url(%{mode: :reuse, account: %{website_url: url}}), do: to_string(url)
  defp website_url(%{input: input}), do: input["website_url"]

  defp source_value(form, index, key) do
    case form.params do
      %{"sources" => %{} = sources} -> get_in(sources, [to_string(index), key])
      _other -> nil
    end
  end
end
