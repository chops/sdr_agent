defmodule SdrAgentWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SdrAgentWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The operator console shell (S10): a sidebar (a top bar on small screens)
  with the views the signed-in role may use, the operator's name and role,
  sign-out, and — for the auditor — a read-only notice. The role only shapes
  navigation; every action is authorized by the domain.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} active={:leads}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom, default: nil, doc: "the navigation item of the current view"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav, nav_items(assigns.current_scope))

    ~H"""
    <div class="min-h-dvh bg-zinc-50 text-zinc-900 antialiased lg:flex">
      <aside class="border-b border-zinc-200 bg-white lg:sticky lg:top-0 lg:flex lg:h-dvh lg:w-64 lg:shrink-0 lg:flex-col lg:border-b-0 lg:border-r">
        <div class="flex items-center justify-between gap-3 px-4 py-3 lg:px-5 lg:py-5">
          <.link
            navigate={~p"/"}
            class="flex items-center gap-2.5 rounded-md focus-visible:outline-2 focus-visible:outline-teal-600"
          >
            <span class="grid size-8 place-items-center rounded-lg bg-zinc-900 text-white shadow-sm">
              <.icon name="hero-paper-airplane" class="size-4 -rotate-12" />
            </span>
            <span class="leading-tight">
              <span class="block text-sm font-semibold tracking-tight">SDR Console</span>
              <span class="block text-[0.68rem] uppercase tracking-[0.14em] text-zinc-500">
                audit-first
              </span>
            </span>
          </.link>
          <.link
            :if={@current_scope}
            id="sign-out-link-compact"
            href={~p"/sign-out"}
            method="delete"
            class="rounded-md p-1.5 text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 lg:hidden"
            aria-label="Sign out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
          </.link>
        </div>

        <nav
          :if={@current_scope}
          aria-label="Console"
          class="flex gap-1 overflow-x-auto px-3 pb-2 lg:flex-1 lg:flex-col lg:overflow-visible lg:px-3 lg:pb-0"
        >
          <.link
            :for={item <- @nav}
            id={"nav-#{item.key}"}
            navigate={item.path}
            aria-current={if(item.key == @active, do: "page")}
            class={[
              "group flex shrink-0 items-center gap-2.5 rounded-lg px-3 py-2 text-sm font-medium transition",
              "focus-visible:outline-2 focus-visible:outline-teal-600",
              if(item.key == @active,
                do: "bg-zinc-900 text-white shadow-sm",
                else: "text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900"
              )
            ]}
          >
            <.icon
              name={item.icon}
              class={[
                "size-4.5",
                if(item.key == @active,
                  do: "text-teal-300",
                  else: "text-zinc-400 group-hover:text-zinc-600"
                )
              ]}
            />
            {item.label}
          </.link>
        </nav>

        <div :if={@current_scope} class="hidden border-t border-zinc-100 p-4 lg:block">
          <div class="flex items-center gap-3">
            <span class="grid size-9 place-items-center rounded-full bg-teal-50 text-sm font-semibold text-teal-800 ring-1 ring-teal-600/20">
              {initials(@current_scope.user.display_name)}
            </span>
            <div class="min-w-0 flex-1">
              <p id="current-operator" class="truncate text-sm font-medium">
                {@current_scope.user.display_name}
              </p>
              <p id="current-role" class="text-xs capitalize text-zinc-500">
                {@current_scope.role}
              </p>
            </div>
            <.link
              id="sign-out-link"
              href={~p"/sign-out"}
              method="delete"
              class="rounded-md p-1.5 text-zinc-500 transition hover:bg-zinc-100 hover:text-zinc-900 focus-visible:outline-2 focus-visible:outline-teal-600"
              aria-label="Sign out"
              title="Sign out"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
            </.link>
          </div>
        </div>
      </aside>

      <main class="min-w-0 flex-1">
        <div
          :if={@current_scope && @current_scope.role == :auditor}
          id="read-only-banner"
          class="flex items-center gap-2 border-b border-amber-200 bg-amber-50 px-4 py-2 text-xs text-amber-900 sm:px-8"
          role="note"
        >
          <.icon name="hero-eye" class="size-4" />
          <span>
            Auditor view — read-only. Every page and payload you open is recorded in the audit ledger.
          </span>
        </div>
        <div class="mx-auto max-w-6xl px-4 py-8 sm:px-8 lg:py-10">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc "The navigation items `scope` may use, in menu order."
  def nav_items(nil), do: []

  def nav_items(%{role: role}) do
    [
      %{key: :dashboard, label: "Dashboard", path: "/", icon: "hero-squares-2x2", roles: :all},
      %{key: :leads, label: "Leads", path: "/leads", icon: "hero-user-group", roles: :all},
      %{
        key: :review,
        label: "Review queue",
        path: "/review",
        icon: "hero-inbox-stack",
        roles: :all
      }
    ]
    |> Enum.filter(&(&1.roles == :all or role in &1.roles))
  end

  defp initials(name) do
    name
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
