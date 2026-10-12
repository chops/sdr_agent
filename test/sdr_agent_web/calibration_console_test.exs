defmodule SdrAgentWeb.CalibrationConsoleTest do
  @moduledoc """
  R0-07 §3: the calibration console offers only the admin sign-in and the
  admin (budget) page. `SdrAgentWeb.CalibrationConsole` is inert unless
  `mix sdr.calibration.console serve` activated it; active, every other
  HTTP path is 404, `/` goes to `/admin`, and a live navigation from
  `/admin` to any other console view is sent back to `/admin`.
  """
  use SdrAgentWeb.OperatorCase, async: false

  alias SdrAgentWeb.CalibrationConsole

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

    test "a live navigation from /admin to another view is sent back", %{conn: conn} do
      admin = sign_in(conn, :admin)

      for path <- [~p"/", ~p"/leads", ~p"/operations", ~p"/audit"] do
        {:ok, view, _html} = live(admin, ~p"/admin")
        assert {:error, {:redirect, %{to: "/admin"}}} = live_redirect(view, to: path)
      end
    end
  end
end
