defmodule SdrAgentWeb.PayloadLive do
  @moduledoc """
  Payload viewer (S10b): one content-addressed Payload by its sha256 hex
  (model requests/responses, tool inputs/outputs, research sources,
  captured messages). Content is read only through
  `SdrAgent.Audit.read_content/2` (ADM, REV, AUR), which records a
  `payload_view` AuditAccess first and fails closed: if the access cannot
  be recorded, or the payload does not exist, nothing is shown. The content
  is checked against the requested hash before it is displayed; JSON is
  pretty-printed.
  """
  use SdrAgentWeb, :live_view

  alias SdrAgentWeb.AuditedView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Payload", loaded?: false, withheld: nil, sha256: nil)}
  end

  @impl true
  def handle_params(%{"sha256" => sha256}, _uri, socket) do
    # Every hash starts from nothing: no content of a previous hash survives.
    socket =
      assign(socket,
        sha256: String.downcase(sha256),
        loaded?: false,
        withheld: nil,
        content: nil,
        bytes: nil
      )

    {:noreply, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp load(socket) do
    sha = socket.assigns.sha256

    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) || {:error, :invalid_sha256},
         {:ok, content} <-
           AuditedView.read_content(socket.assigns.current_scope, sha, "payload viewer"),
         true <-
           Base.encode16(:crypto.hash(:sha256, content), case: :lower) == sha ||
             {:error, :content_hash_mismatch} do
      assign(socket,
        loaded?: true,
        withheld: nil,
        content: display(content),
        bytes: byte_size(content)
      )
    else
      {:error, reason} ->
        assign(socket,
          loaded?: false,
          content: nil,
          bytes: nil,
          withheld: AuditedView.error_message(reason)
        )
    end
  end

  defp display(content) do
    with true <- String.valid?(content),
         {:ok, decoded} <- Jason.decode(content),
         {:ok, pretty} <- Jason.encode(decoded, pretty: true) do
      pretty
    else
      _ ->
        if String.valid?(content),
          do: content,
          else: "binary content (#{byte_size(content)} bytes)"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:audit}>
      <.page_header eyebrow="Payload store">
        Payload
        <:subtitle>
          <span id="payload-sha" class="break-all font-mono text-xs">{@sha256}</span>
        </:subtitle>
      </.page_header>

      <.empty :if={@withheld} id="withheld" icon="hero-lock-closed" title="Content not served">
        {@withheld}
      </.empty>
      <.loading :if={!@loaded? and is_nil(@withheld)} />

      <.card :if={@loaded?} title="Content">
        <:subtitle>
          {@bytes} bytes · hash verified · this view was recorded as a payload_view access
        </:subtitle>
        <pre
          id="payload-content"
          class="max-h-[70vh] overflow-auto whitespace-pre-wrap break-words rounded-lg bg-zinc-950 p-4 font-mono text-[0.72rem] leading-relaxed text-zinc-200"
        >{@content}</pre>
      </.card>
    </Layouts.app>
    """
  end
end
