defmodule SdrAgentWeb.SensitiveAuth do
  @moduledoc """
  Tags auth processes `sdr_sensitive_input` before they hold a credential
  (Codex M2/L1, P2, I1), so `SdrAgent.Logger.ExceptionFilter` replaces
  their crash, termination and error-or-higher reports, message and
  metadata alike, with a fixed diagnostic (the AdminLive mechanism,
  ADR-0005 R0-05 amendment).

  **HTTP (the endpoint's first plug, before the body parsers and the
  browser pipeline).** Each request is classified by `sensitive_path?/1`
  on its URI-decoded first path segment — `Phoenix.Router` decodes every
  segment before matching, so every spelling the router routes to a
  credential-bearing family is caught (`%6dagic_link` is `magic_link`);
  the classification is also case-insensitive and treats an encoded `/` as
  a separator, so it is never narrower than routing. The families are
  `auth` (passwords, link tokens, emails in bodies and queries),
  `magic_link` (the link token in the path), `sign-in` and `sign-out`.

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
  route added to the auth scope is tagged whatever its path.

  **LiveView.** As the first `on_mount` hook of the sign-in and magic-link
  LiveViews (`on_mount_prepend`), each connected channel is tagged for its
  lifetime, before the view assigns the token or receives typed input.

  Ordinary `:info` and `:debug` lines are not withheld: the endpoint skips
  the request line of `token_path?/1` requests (`SdrAgentWeb.Endpoint`),
  and parameters and sessions are filtered (`config :phoenix,
  :filter_parameters`, `SdrAgentWeb.LiveViewMountLog`). OpenTelemetry spans
  still record `url.path` (the link token) and exception data: prod
  exports none (`traces_exporter: :none`), and URL/path and exception
  redaction is a prerequisite before any exporter is enabled there.
  """
  @behaviour Plug

  @tag :sdr_sensitive_input
  @owned {__MODULE__, :http_tag}
  @families ["auth", "magic_link", "sign-in", "sign-out"]

  @impl Plug
  def init(:always), do: :always
  def init(_opts), do: :classify

  @impl Plug
  def call(conn, :always) do
    tag_http()
    conn
  end

  def call(conn, :classify) do
    if sensitive_path?(conn), do: tag_http(), else: release_http()
    conn
  end

  @doc "Whether `conn`'s path is in a credential-bearing route family (see the moduledoc)."
  @spec sensitive_path?(Plug.Conn.t()) :: boolean()
  def sensitive_path?(conn), do: family(conn) in @families

  @doc "Whether `conn`'s path is a magic-link confirmation path, whose last segment is a token."
  @spec token_path?(Plug.Conn.t()) :: boolean()
  def token_path?(conn), do: family(conn) == "magic_link"

  @doc "LiveView hook: tags a connected channel; a disconnected render is the tagged request."
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: tag()
    {:cont, socket}
  end

  # The URI-decoded, downcased first segment (an encoded "/" splits it);
  # an undecodable segment counts as the token family (fail closed).
  defp family(%Plug.Conn{path_info: [first | _]}) do
    first
    |> URI.decode()
    |> String.downcase()
    |> String.split("/", trim: true)
    |> List.first()
  rescue
    ArgumentError -> "magic_link"
  end

  defp family(_conn), do: nil

  defp tag_http do
    Process.put(@owned, true)
    tag()
  end

  defp release_http do
    if Process.delete(@owned), do: Logger.metadata([{@tag, nil}])
  end

  defp tag, do: :logger.update_process_metadata(%{@tag => true})
end
