defmodule SdrAgentWeb.CalibrationConsoleTest do
  @moduledoc """
  R0-07 §3: the calibration console offers only the admin sign-in and the
  admin (budget) page. `SdrAgentWeb.CalibrationConsole` is inert unless
  `mix sdr.calibration.console serve` activated it; active, every other
  HTTP path is 404, `/` goes to `/admin`, and a live navigation from
  `/admin` to any other console view is sent back to `/admin`.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgent.Agents
  alias SdrAgentWeb.CalibrationConsole

  @g_r0 %{
    "name" => "G-R0",
    "purpose" => "Calibration of the two R0 profiles",
    "profile_ids" => ["claude_cli_opus", "claude_cli_sonnet"],
    "total_attempts" => "4",
    "per_utc_day_attempts" => "2",
    "starts_at" => "2026-10-12T00:00",
    "expires_at" => "2026-10-18T23:59",
    "allocations" => %{
      "0" => %{
        "key" => "proof",
        "profile_id" => "claude_cli_opus",
        "applies_to" => ["proof"],
        "attempts" => "2",
        "available_from" => "",
        "available_until" => ""
      },
      "1" => %{
        "key" => "proof",
        "profile_id" => "claude_cli_sonnet",
        "applies_to" => ["proof"],
        "attempts" => "2",
        "available_from" => "",
        "available_until" => ""
      }
    }
  }

  defp activate! do
    Application.put_env(:sdr_agent, CalibrationConsole, active: true)
    on_exit(fn -> Application.delete_env(:sdr_agent, CalibrationConsole) end)
  end

  describe "inactive (every ordinary server and test)" do
    test "changes nothing", %{conn: conn} do
      refute CalibrationConsole.active?()
      assert conn |> sign_in(:admin) |> get(~p"/leads") |> html_response(200)
      assert {:ok, _view, _html} = conn |> sign_in(:admin) |> live(~p"/operations")
    end
  end

  describe "the session cookie" do
    test "is the app's own when inactive and the console's own when active", %{conn: conn} do
      assert SdrAgentWeb.Endpoint.session_options()[:key] == "_sdr_agent_key"
      inactive = get(conn, ~p"/sign-in")
      assert Map.has_key?(inactive.resp_cookies, "_sdr_agent_key")

      activate!()
      key = SdrAgentWeb.Endpoint.session_options()[:key]
      assert key == "_sdr_agent_calibration_key"

      active = get(build_conn(), ~p"/sign-in")
      assert Map.has_key?(active.resp_cookies, key)
      refute Map.has_key?(active.resp_cookies, "_sdr_agent_key")

      # The next request reads the console's cookie and never writes the app's.
      again = active |> recycle() |> get(~p"/sign-in")
      assert again.req_cookies[key] == active.resp_cookies[key].value
      refute Map.has_key?(again.resp_cookies, "_sdr_agent_key")
    end

    test "the LiveView socket reads the same, runtime, session options" do
      [{"/live", Phoenix.LiveView.Socket, config}] =
        Enum.filter(SdrAgentWeb.Endpoint.__sockets__(), &(elem(&1, 0) == "/live"))

      for transport <- [:websocket, :longpoll] do
        assert {:session, {SdrAgentWeb.Endpoint, :session_options, []}} in config[transport][
                 :connect_info
               ]
      end
    end
  end

  describe "active" do
    setup do
      activate!()
      :ok
    end

    test "/ goes to /admin", %{conn: conn} do
      assert conn |> sign_in(:admin) |> get(~p"/") |> redirected_to() == ~p"/admin"
    end

    test "the sign-in page and the admin page are served", %{conn: conn} do
      assert get(conn, ~p"/sign-in") |> html_response(200)
      assert {:ok, _view, html} = conn |> sign_in(:admin) |> live(~p"/admin")
      assert html =~ "model-provider"
    end

    test "every other path is not found", %{conn: conn} do
      admin = sign_in(conn, :admin)

      for path <- [
            "/leads",
            "/review",
            "/operations",
            "/audit",
            "/audit/exports",
            "/runs/#{Ecto.UUID.generate()}",
            "/dev/dashboard",
            "/nowhere"
          ] do
        assert admin |> get(path) |> response(404), path
      end

      assert conn |> post("/webhooks/capture_sim/delivered", %{}) |> response(404)
    end

    test "the admin creates G-R0 on /admin through review and confirmation, audited",
         %{conn: conn} = ctx do
      {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
      view |> element("#new-grant") |> render_click()
      for _ <- 1..2, do: view |> element("#add-allocation") |> render_click()
      view |> form("#grant-form", grant: @g_r0) |> render_submit()

      assert has_element?(view, "#grant-review", "G-R0")
      assert {:ok, []} = Agents.list_grants(actor: ctx.admin)

      view |> element("#confirm-grant") |> render_click()

      assert {:ok, [grant]} = Agents.list_grants(actor: ctx.admin)
      assert grant.name == "G-R0"
      assert grant.total_attempts == 4
      assert grant.created_by_id == ctx.admin.id
      assert grant.expires_at == ~U[2026-10-19 05:59:00.000000Z]

      assert grant.allocations |> Enum.map(&{&1.key, &1.profile_id, &1.attempts}) |> Enum.sort() ==
               [{:proof, :claude_cli_opus, 2}, {:proof, :claude_cli_sonnet, 2}]

      assert [event] = events_of_type(ctx.tenant, "model.grant.created")
      assert event.actor_id == ctx.admin.id
      assert has_element?(view, "#grants-#{grant.id} [data-status='active']")
    end

    for role <- [:reviewer, :auditor] do
      test "a #{role} cannot reach the budget editor and is not bounced in a loop",
           %{conn: conn} = ctx do
        signed_in = sign_in(conn, unquote(role))

        # Sent to the sign-out page: not "/", which this console sends back to /admin.
        assert {:error, {:redirect, %{to: "/sign-out"}}} = live(signed_in, ~p"/admin")
        assert signed_in |> get(~p"/admin") |> redirected_to() == "/sign-out"
        assert signed_in |> get(~p"/sign-out") |> html_response(200)
        assert {:ok, []} = Agents.list_grants(actor: ctx.admin)
      end
    end

    test "a live navigation from /admin to another view is sent back", %{conn: conn} do
      admin = sign_in(conn, :admin)

      for path <- [~p"/", ~p"/leads", ~p"/operations", ~p"/audit"] do
        {:ok, view, _html} = live(admin, ~p"/admin")
        assert {:error, {:redirect, %{to: "/admin"}}} = live_redirect(view, to: path)
      end
    end
  end
end
