defmodule SdrAgentWeb.AuthRequestLimit do
  @moduledoc """
  Bounds unauthenticated credential attempts before the action runs (hosted
  auth hardening plan r1, S3; entity delta r1 RateLimitBucket), counted in
  `SdrAgent.RateLimiter`. No key is a client address (behind Caddy every
  peer is the loopback), an email in clear or a token.

    * **Password sign-in** (`POST /auth/user/password/sign_in`): one global
      bucket of 30 per minute, checked first, then 5 per 15 minutes
      per sha256 of the trimmed, downcased email. A missing, malformed or
      nested email counts against the global bucket only, so a refused
      global attempt charges no email bucket. Over a bound the answer is
      the wrong-credential answer (`SdrAgentWeb.AuthController.failure/3`),
      and the sign-in action never runs: no audit event, no session.
    * **Hosted enrollment** (`POST /hosted-enrollment`): one global bucket
      of 10 per 15 minutes; over it the answer is the closed rejection
      (`SdrAgentWeb.HostedEnrollmentController.refused/1`) and no link is
      read or consumed.

  Requests are matched on their URI-decoded, downcased path, never
  narrower than routing. Every other request passes untouched. The limiter
  fails closed: an unavailable limiter refuses every counted attempt.
  """
  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  alias SdrAgent.RateLimiter

  @minute :timer.minutes(1)
  @quarter_hour :timer.minutes(15)
  @sign_in_global {30, @minute}
  @sign_in_email {5, @quarter_hour}
  @enrollment_global {10, @quarter_hour}
  @email ~r/\A[^\s@]+@[^\s@]+\z/u

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case decoded_path(conn) do
      ["auth", "user", "password", "sign_in"] -> sign_in(conn)
      ["hosted-enrollment"] -> enrollment(conn)
      _other -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp sign_in(conn) do
    with :ok <- hit({:sign_in, :global}, @sign_in_global),
         :ok <- email_hit(conn.params) do
      conn
    else
      :limited ->
        conn
        |> SdrAgentWeb.AuthController.failure({:password, :sign_in}, :rate_limited)
        |> halt()
    end
  end

  defp enrollment(conn) do
    case hit({:hosted_enrollment, :global}, @enrollment_global) do
      :ok -> conn
      :limited -> conn |> SdrAgentWeb.HostedEnrollmentController.refused() |> halt()
    end
  end

  defp email_hit(%{"user" => %{"email" => email}}) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if Regex.match?(@email, normalized),
      do: hit({:sign_in_email, :crypto.hash(:sha256, normalized)}, @sign_in_email),
      else: :ok
  end

  defp email_hit(_params), do: :ok

  defp hit(key, {limit, window_ms}), do: RateLimiter.hit(key, limit, window_ms)

  # As the router decodes segments before matching; an undecodable path
  # is not one of these routes (the router cannot match it either).
  defp decoded_path(%Plug.Conn{path_info: segments}) do
    Enum.map(segments, &(&1 |> URI.decode() |> String.downcase()))
  rescue
    ArgumentError -> []
  end
end
