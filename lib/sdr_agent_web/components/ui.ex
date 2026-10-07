defmodule SdrAgentWeb.UI do
  @moduledoc """
  Hand-written Tailwind components of the operator console (S10): cards,
  page headers, status badges, stat tiles, hashes, timestamps, buttons and
  empty states. Plain Tailwind utility classes only (no daisyUI), with
  visible focus rings and colour never the only carrier of meaning (every
  badge also carries its text and a `data-*` value for tests).
  """
  use Phoenix.Component

  import SdrAgentWeb.CoreComponents, only: [icon: 1]

  @doc "A page title with an optional eyebrow, subtitle and actions."
  attr :id, :string, default: nil
  attr :eyebrow, :string, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header id={@id} class="mb-8 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div class="min-w-0">
        <p
          :if={@eyebrow}
          class="mb-1 text-xs font-semibold uppercase tracking-[0.14em] text-teal-700"
        >
          {@eyebrow}
        </p>
        <h1 class="text-2xl font-semibold tracking-tight text-zinc-900 sm:text-[1.7rem]">
          {render_slot(@inner_block)}
        </h1>
        <div :if={@subtitle != []} class="mt-1.5 text-sm text-zinc-600">
          {render_slot(@subtitle)}
        </div>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc "A bordered surface with an optional titled header."
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions
  slot :subtitle

  def card(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "rounded-xl border border-zinc-200 bg-white shadow-[0_1px_2px_rgba(24,24,27,0.04)]",
        @class
      ]}
      {@rest}
    >
      <div
        :if={@title || @actions != []}
        class="flex items-start justify-between gap-3 border-b border-zinc-100 px-5 py-3.5"
      >
        <div class="min-w-0">
          <h2 :if={@title} class="text-sm font-semibold text-zinc-900">{@title}</h2>
          <p :if={@subtitle != []} class="mt-0.5 text-xs text-zinc-500">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      <div class="px-5 py-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  A status badge. `status` is rendered as text (underscores → spaces) and as
  `data-status`; `attr` renames the data attribute (e.g. `"state"`).
  """
  attr :status, :any, required: true
  attr :attr, :string, default: "status"
  attr :class, :any, default: nil

  def badge(assigns) do
    assigns =
      assign(assigns,
        data: %{"data-#{assigns.attr}" => to_string(assigns.status)},
        tone: tone(assigns.status)
      )

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset",
        @tone,
        @class
      ]}
      {@data}
    >
      <span class="size-1.5 rounded-full bg-current opacity-70" aria-hidden="true"></span>
      {humanize(@status)}
    </span>
    """
  end

  @doc "A metric tile; the value carries `data-value` for tests."
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :hint, :string, default: nil
  attr :navigate, :string, default: nil
  attr :tone, :string, default: "zinc", values: ~w(zinc teal amber rose sky)

  def stat(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="group relative block overflow-hidden rounded-xl border border-zinc-200 bg-white p-4 shadow-[0_1px_2px_rgba(24,24,27,0.04)] transition hover:-translate-y-0.5 hover:border-zinc-300 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-600"
    >
      <div class="flex items-center justify-between">
        <span class="text-xs font-medium uppercase tracking-wider text-zinc-500">{@label}</span>
        <span class={["rounded-lg p-1.5", stat_tone(@tone)]}>
          <.icon name={@icon} class="size-4" />
        </span>
      </div>
      <p class="mt-3 text-3xl font-semibold tabular-nums tracking-tight text-zinc-900" data-value>
        {@value}
      </p>
      <p :if={@hint} class="mt-1 text-xs text-zinc-500">{@hint}</p>
    </.link>
    """
  end

  @doc "A sha256 (binary or hex) in monospace: abbreviated, full value in the title, or `full`."
  attr :value, :any, required: true
  attr :id, :string, default: nil
  attr :full, :boolean, default: false

  def hash(assigns) do
    assigns = assign(assigns, :hex, hex(assigns.value))

    ~H"""
    <code
      id={@id}
      title={@hex}
      class={[
        "rounded bg-zinc-100 px-1.5 py-0.5 font-mono text-[0.72rem] text-zinc-700",
        @full && "break-all"
      ]}
    >{if @full, do: @hex, else: abbreviate(@hex)}</code>
    """
  end

  @doc "A UTC timestamp, rendered in a `<time>` element (UTC, minute precision)."
  attr :at, :any, required: true
  attr :class, :any, default: nil

  def timestamp(assigns) do
    ~H"""
    <time
      :if={@at}
      datetime={DateTime.to_iso8601(@at)}
      class={["whitespace-nowrap tabular-nums", @class]}
    >
      {Calendar.strftime(@at, "%b %-d, %H:%M UTC")}
    </time>
    <span :if={is_nil(@at)} class="text-zinc-400">—</span>
    """
  end

  @doc "A button or link styled for the console."
  attr :variant, :string, default: "secondary", values: ~w(primary secondary danger ghost)
  attr :size, :string, default: "md", values: ~w(sm md)
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch method type disabled form name value)
  slot :inner_block, required: true

  def ui_button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        "inline-flex items-center justify-center gap-1.5 rounded-lg font-medium transition active:translate-y-px",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-teal-600",
        "disabled:cursor-not-allowed disabled:opacity-50 phx-submit-loading:opacity-60 phx-click-loading:opacity-60",
        size(assigns.size),
        variant(assigns.variant),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc "An empty or withheld state."
  attr :id, :string, default: nil
  attr :icon, :string, default: "hero-inbox"
  attr :title, :string, required: true
  slot :inner_block

  def empty(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center px-6 py-10 text-center">
      <span class="mb-3 rounded-full bg-zinc-100 p-3 text-zinc-500">
        <.icon name={@icon} class="size-6" />
      </span>
      <p class="text-sm font-medium text-zinc-800">{@title}</p>
      <div :if={@inner_block != []} class="mt-1 max-w-sm text-sm text-zinc-500">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "A loading skeleton shown on the first (disconnected) render, before any data is read."
  attr :id, :string, default: "loading"

  def loading(assigns) do
    ~H"""
    <div id={@id} class="animate-pulse space-y-3" aria-busy="true" aria-label="Loading">
      <div class="h-8 w-1/3 rounded-lg bg-zinc-200/70"></div>
      <div class="h-24 rounded-xl bg-zinc-200/50"></div>
      <div class="h-24 rounded-xl bg-zinc-200/40"></div>
    </div>
    """
  end

  @doc "A definition-list row (label → value)."
  attr :label, :string, required: true
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-4 py-1.5 text-sm">
      <dt class="shrink-0 text-zinc-500">{@label}</dt>
      <dd class="min-w-0 text-right text-zinc-900">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  @doc "Underscored atoms as words (`:pending_review` → \"pending review\")."
  def humanize(nil), do: "—"
  def humanize(value), do: value |> to_string() |> String.replace("_", " ")

  @doc "Lower-case hex of a binary digest (hex input is returned as is)."
  def hex(nil), do: nil

  def hex(value) when is_binary(value) do
    if String.printable?(value) and String.match?(value, ~r/\A[0-9a-f]+\z/),
      do: value,
      else: Base.encode16(value, case: :lower)
  end

  defp abbreviate(nil), do: "—"
  defp abbreviate(hex) when byte_size(hex) > 16, do: binary_part(hex, 0, 12) <> "…"
  defp abbreviate(hex), do: hex

  @good ~w(qualified accepted delivered sent granted consumed approved succeeded resolved converted pass active)a
  @busy ~w(assigned researching qualifying queued pending attempting running enqueued in_outreach acknowledged)a
  @warn ~w(pending_review unknown failed_retryable replied warning blocked budget_exhausted nurture open)a
  @bad ~w(disqualified failed failed_permanent bounced rejected revoked invalidated cancelled stopped critical discarded fail)a

  defp tone(status) when is_binary(status) do
    tone(String.to_existing_atom(status))
  rescue
    ArgumentError -> tone(:other)
  end

  defp tone(status) when status in @good, do: "bg-emerald-50 text-emerald-800 ring-emerald-600/20"
  defp tone(status) when status in @busy, do: "bg-sky-50 text-sky-800 ring-sky-600/20"
  defp tone(status) when status in @warn, do: "bg-amber-50 text-amber-800 ring-amber-600/25"
  defp tone(status) when status in @bad, do: "bg-rose-50 text-rose-800 ring-rose-600/20"
  defp tone(_status), do: "bg-zinc-100 text-zinc-700 ring-zinc-500/20"

  defp stat_tone("teal"), do: "bg-teal-50 text-teal-700"
  defp stat_tone("amber"), do: "bg-amber-50 text-amber-700"
  defp stat_tone("rose"), do: "bg-rose-50 text-rose-700"
  defp stat_tone("sky"), do: "bg-sky-50 text-sky-700"
  defp stat_tone(_), do: "bg-zinc-100 text-zinc-600"

  defp size("sm"), do: "px-2.5 py-1.5 text-xs"
  defp size(_), do: "px-3.5 py-2 text-sm"

  defp variant("primary"),
    do: "bg-teal-700 text-white shadow-sm hover:bg-teal-800"

  defp variant("danger"),
    do: "bg-white text-rose-700 ring-1 ring-inset ring-rose-200 hover:bg-rose-50"

  defp variant("ghost"), do: "text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900"

  defp variant(_),
    do: "bg-white text-zinc-800 ring-1 ring-inset ring-zinc-200 shadow-sm hover:bg-zinc-50"
end
