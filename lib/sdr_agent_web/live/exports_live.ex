defmodule SdrAgentWeb.ExportsLive do
  @moduledoc """
  Audit exports (S10b; ADM, AUR): the S11 AuditExport rows
  (`Audit.list_exports/1`) with scope, status, sequence range, bundle hash,
  signing key id and assurance level.

  Creating an export needs the Ed25519 anchor-signing private key, which
  exists only in the environment of `bin/with-secrets` (ADR-0005); the web
  node never holds it. The view therefore shows the exact CLI command for a
  lead, run or draft instead of triggering a build. An auditor's view is
  recorded with the export ids shown.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgent.Audit
  alias SdrAgentWeb.AuditedView

  on_mount {SdrAgentWeb.LiveUserAuth, {:roles, [:admin, :auditor]}}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Audit exports", loaded?: false, withheld: nil)
     |> stream(:exports, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope_arg =
      cond do
        is_binary(params["lead"]) -> "--lead #{params["lead"]}"
        is_binary(params["run"]) -> "--run #{params["run"]}"
        is_binary(params["draft"]) -> "--draft #{params["draft"]}"
        true -> "--lead LEAD_ID"
      end

    socket = assign(socket, scope_arg: sanitize(scope_arg))
    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp sanitize(arg), do: String.replace(arg, ~r/[^A-Za-z0-9_\- ]/, "")

  defp load(socket) do
    scope = socket.assigns.current_scope

    with {:ok, exports} <- Audit.list_exports(actor: scope.user),
         :ok <-
           AuditedView.record(
             scope,
             "SdrAgent.Audit.AuditExport",
             Enum.map(exports, & &1.id),
             "audit exports list"
           ) do
      socket
      |> assign(loaded?: true)
      |> stream(:exports, exports, reset: true)
    else
      {:error, reason} -> assign(socket, withheld: AuditedView.error_message(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:audit}>
      <.link
        navigate={~p"/audit"}
        class="mb-4 inline-flex items-center gap-1 text-xs font-medium text-zinc-500 hover:text-zinc-900"
      >
        <.icon name="hero-arrow-left" class="size-3.5" /> Audit timeline
      </.link>
      <.page_header eyebrow="Independent verification">
        Audit exports
        <:subtitle>Signed, anchored bundles that verify without this application.</:subtitle>
      </.page_header>

      <.card title="Create an export" class="mb-6">
        <p class="text-sm text-zinc-600">
          Exports are signed with the anchor key, which only the CLI receives through <code class="font-mono text-xs">bin/with-secrets</code>. Run from the project root:
        </p>
        <pre
          id="export-command"
          class="mt-3 overflow-x-auto rounded-lg bg-zinc-950 p-3 font-mono text-xs text-zinc-200"
        >bin/with-secrets SDR_AUDIT_ANCHOR_PRIVATE_KEY -- mix sdr.audit.export {@scope_arg}</pre>
        <p class="mt-2 text-xs text-zinc-500">
          Verify a bundle with <code class="font-mono">mix sdr.audit.verify --key-set docs/audit/trusted-keys.json BUNDLE</code>.
        </p>
      </.card>

      <.empty
        :if={@withheld}
        id="withheld"
        icon="hero-lock-closed"
        title="This view could not be served"
      >
        {@withheld}
      </.empty>
      <.loading :if={!@loaded? and is_nil(@withheld)} />

      <div :if={@loaded?} class="overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-sm">
        <ul id="exports" phx-update="stream" class="divide-y divide-zinc-100">
          <li
            id="exports-empty"
            class="hidden px-5 py-10 text-center text-sm text-zinc-500 only:block"
          >
            No exports yet.
          </li>
          <li :for={{dom_id, export} <- @streams.exports} id={dom_id} class="px-5 py-3.5">
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-sm font-medium text-zinc-900">{export.scope}</span>
              <span class="font-mono text-xs text-zinc-500">{export.scope_ref}</span>
              <.badge status={export.status} />
              <.badge :if={export.assurance_level} status={export.assurance_level} attr="assurance" />
              <span class="ml-auto text-xs text-zinc-500"><.timestamp at={export.inserted_at} /></span>
            </div>
            <p class="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-zinc-500">
              <span :if={export.from_sequence}>events #{export.from_sequence}–#{export.to_sequence}</span>
              <span :if={export.bundle_sha256}>bundle <.hash value={export.bundle_sha256} /></span>
              <span :if={export.key_id}>key <span class="font-mono">{export.key_id}</span></span>
              <span :if={export.failure_reason} class="text-rose-700">{export.failure_reason}</span>
            </p>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
