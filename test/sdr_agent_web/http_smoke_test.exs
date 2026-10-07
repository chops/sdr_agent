defmodule SdrAgentWeb.HttpSmokeTest do
  @moduledoc """
  S13 smoke over real HTTP (the CI-able part of the browser smoke; the
  in-browser walk-through is recorded in `notes/features/s13-acceptance.org`).
  The endpoint is served by a real Bandit listener on an ephemeral loopback
  port and driven with Req, cookies and CSRF tokens as a browser would: the
  sign-in page, a password sign-in through the real form route, the
  console's pages for the signed-in operator, the LiveView socket route,
  and a sign-in refused for a wrong password. Connected LiveView behaviour
  (assign, approve, capture, live refresh) is covered by LiveViewTest
  (`golden_path_test.exs`, `live_refresh_test.exs`).
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Demo.Fixtures

  setup do
    server =
      start_supervised!(
        {Bandit, plug: SdrAgentWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{base: "http://127.0.0.1:#{port}"}
  end

  defp get!(base, path, cookie),
    do: Req.get!(base <> path, headers: cookie_header(cookie), redirect: false, retry: false)

  defp cookie_header(nil), do: []
  defp cookie_header(cookie), do: [{"cookie", cookie}]

  defp session_cookie(response, previous) do
    case Req.Response.get_header(response, "set-cookie") do
      [] -> previous
      cookies -> Enum.map_join(cookies, "; ", &(&1 |> String.split(";") |> hd()))
    end
  end

  defp csrf!(html) do
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html)
    token
  end

  defp sign_in!(base, password) do
    page = get!(base, "/sign-in", nil)
    assert page.status == 200
    cookie = session_cookie(page, nil)
    reviewer = Enum.find(Fixtures.users(), &(&1.role == :reviewer))

    response =
      Req.post!(base <> "/auth/user/password/sign_in",
        form: %{
          "_csrf_token" => csrf!(page.body),
          "user[email]" => reviewer.email,
          "user[password]" => password.(reviewer)
        },
        headers: cookie_header(cookie),
        redirect: false,
        retry: false
      )

    {response, session_cookie(response, cookie)}
  end

  test "sign in over HTTP, then the console's pages render for the operator", %{base: base} do
    {response, cookie} = sign_in!(base, & &1.password)
    assert response.status in [302, 303]
    assert [location] = Req.Response.get_header(response, "location")
    assert location in ["/", base <> "/"]

    for path <- ["/", "/leads", "/review", "/operations"] do
      page = get!(base, path, cookie)
      assert page.status == 200, "#{path} returned #{page.status}"
      assert page.body =~ "data-phx-main", "#{path} is not a LiveView page"
      assert page.body =~ ~s(id="current-role")
    end

    # The LiveView socket route exists (a plain GET is not an upgrade).
    assert get!(base, "/live/websocket", cookie).status in [400, 403, 426]
  end

  test "a wrong password is refused and the console stays closed", %{base: base} do
    {response, cookie} = sign_in!(base, fn _ -> "wrong-password-0" end)

    refute response.status in [302, 303] and
             Req.Response.get_header(response, "location") in [["/"]]

    page = get!(base, "/", cookie)
    assert page.status == 302
    assert Req.Response.get_header(page, "location") |> hd() =~ "/sign-in"
  end
end
