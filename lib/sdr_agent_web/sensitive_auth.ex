defmodule SdrAgentWeb.SensitiveAuth do
  @moduledoc """
  Tags credential-bearing processes `sdr_sensitive_input` before they hold a
  credential (hosted auth hardening plan r1, S1; ported from the
  deploy-hosted lineage, magic links removed), so
  `SdrAgent.Logger.ExceptionFilter` replaces their crash, termination and
  error-or-higher reports, message and metadata alike, with a fixed
  diagnostic (the AdminLive mechanism, ADR-0005 R0-05 amendment).

  **HTTP and the LiveView socket (`SdrAgentWeb.Endpoint.call/2`, before
  Phoenix's socket dispatch and every plug).** Phoenix dispatches socket
  transports (`/live/websocket`) ahead of every declared endpoint plug, so
  the classification runs in the endpoint's own `call/2`, before them all.
  A request is credential-bearing (`sensitive?/1`) when:

    * its URI-decoded first path segment (`sensitive_path?/1`) is a
      credential-bearing route family. `Phoenix.Router` decodes every
      segment before matching, so every spelling the router routes there
      is caught (`%61uth` is `auth`); the classification is also
      case-insensitive and treats an encoded `/` as a separator, so it is
      never narrower than routing. The families are `auth` (passwords and
      emails in bodies and queries), `sign-in`, `sign-out` and
      `hosted-enrollment` (the enrollment token in the body). An
      undecodable segment counts as credential-bearing (fail closed);
    * its first segment is `live`, the LiveView socket: its handshake
      carries the session cookie and CSRF token, and after the upgrade the
      same connection process is the WebSocket transport, receiving every
      frame (typed input included) and holding the decoded session; it
      stays tagged for its lifetime;
    * it carries a `cookie`, `authorization` or `proxy-authorization`
      header, on any path: a signed-in browser's session cookie holds the
      bearer token, and a failure before the session is decoded would
      otherwise report the raw header.

  So every signed-in request's error report is withheld whole; the
  diagnostics lost are the price of never reporting a credential.
  `SdrAgent.Logger.CredentialRedaction` additionally redacts every event's
  terms for processes that are not tagged.

  **Lifetime on a reused process.** The tag is not cleared when the
  response is sent: Phoenix renders and sends an error response first,
  then re-raises, and Bandit writes its report (with the request's conn
  and crash reason in metadata) after that. The tag therefore holds until
  the start of the next request on the same connection process that is
  not credential-bearing, which clears it, or until the process ends. A
  plain request never clears a tag this plug did not set. The cost is
  that a connection's later, protocol-level error reports may also be
  withheld; withholding errs that way on purpose.

  The router's `:auth_edge` pipeline also plugs it with `:always`, so any
  route added there is tagged whatever its path.

  **LiveView.** As the first `on_mount` hook of the sign-in LiveView
  (`on_mount_prepend`), each connected channel is tagged for its lifetime,
  before the view receives typed input. A disconnected render is the
  tagged HTTP request itself.

  Parameters and sessions in ordinary `:info` and `:debug` lines are
  filtered (`config :phoenix, :filter_parameters`). OpenTelemetry spans may
  record exception data: hosted and prod export none
  (`traces_exporter: :none`), and redaction is a prerequisite before any
  exporter is enabled there.
  """
  @behaviour Plug

  @tag :sdr_sensitive_input
  @owned {__MODULE__, :http_tag}
  @families ["auth", "sign-in", "sign-out", "hosted-enrollment"]
  @socket "live"
  @credential_headers ["cookie", "authorization", "proxy-authorization"]
  @undecodable "auth"

  @impl Plug
  def init(:always), do: :always
  def init(_opts), do: :classify

  @impl Plug
  def call(conn, :always) do
    tag_http()
    conn
  end

  def call(conn, :classify) do
    if sensitive?(conn), do: tag_http(), else: release_http()
    conn
  end

  @doc """
  Whether `conn` is credential-bearing: a credential-bearing route family
  (`sensitive_path?/1`), the LiveView socket (`/live`), or any request
  carrying a `cookie`, `authorization` or `proxy-authorization` header,
  whatever its path.
  """
  @spec sensitive?(Plug.Conn.t()) :: boolean()
  def sensitive?(conn),
    do: sensitive_path?(conn) or family(conn) == @socket or credential_header?(conn)

  @doc "Whether `conn`'s path is in a credential-bearing route family (see the moduledoc)."
  @spec sensitive_path?(Plug.Conn.t()) :: boolean()
  def sensitive_path?(conn), do: family(conn) in @families

  @doc "LiveView hook: tags a connected channel; a disconnected render is the tagged request."
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: tag()
    {:cont, socket}
  end

  # The URI-decoded, downcased first segment (an encoded "/" splits it).
  # An undecodable segment (a malformed escape, or bytes that are not
  # UTF-8 once decoded) counts as a credential-bearing family.
  defp family(%Plug.Conn{path_info: [first | _]}) do
    decoded = URI.decode(first)

    if Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, first) or not String.valid?(decoded) do
      @undecodable
    else
      decoded |> String.downcase() |> String.split("/", trim: true) |> List.first()
    end
  rescue
    ArgumentError -> @undecodable
  end

  defp family(_conn), do: nil

  defp credential_header?(%Plug.Conn{req_headers: headers}),
    do: Enum.any?(headers, fn {name, _value} -> String.downcase(name) in @credential_headers end)

  defp tag_http do
    Process.put(@owned, true)
    tag()
  end

  defp release_http do
    if Process.delete(@owned), do: Logger.metadata([{@tag, nil}])
  end

  defp tag, do: :logger.update_process_metadata(%{@tag => true})
end
