defmodule SdrAgentWeb.AuthControllerTest do
  @moduledoc """
  Password sign-in and sign-out through the browser auth routes: each
  outcome is recorded in the audit chain, and self-service routes
  (registration, reset, confirmation, magic link) do not exist.
  """
  use SdrAgentWeb.ConnCase, async: false

  import SdrAgent.AuditCase,
    only: [bootstrap!: 0, human: 2, events_of_type: 2, test_password: 0]

  setup do
    tenant = bootstrap!()
    %{tenant: tenant, reviewer: human(:reviewer, tenant)}
  end

  defp sign_in(conn, email, password) do
    post(conn, "/auth/user/password/sign_in", %{
      "user" => %{"email" => email, "password" => password}
    })
  end

  test "a correct password signs in and is recorded", %{conn: conn} = ctx do
    conn = sign_in(conn, to_string(ctx.reviewer.email), test_password())

    assert redirected_to(conn) == "/"
    assert [event] = events_of_type(ctx.tenant, "auth.sign_in.succeeded")
    assert event.actor_id == ctx.reviewer.id
  end

  test "a wrong password is refused and recorded anonymously", %{conn: conn} = ctx do
    conn = sign_in(conn, to_string(ctx.reviewer.email), "wrong-password-0")

    assert redirected_to(conn) == "/sign-in"
    assert [event] = events_of_type(ctx.tenant, "auth.sign_in.failed")
    assert event.actor_type == :anonymous
  end

  test "signing out is recorded for the signed-in user", %{conn: conn} = ctx do
    conn = sign_in(conn, to_string(ctx.reviewer.email), test_password())
    conn = conn |> recycle() |> delete("/sign-out")

    assert redirected_to(conn) == "/"
    assert [event] = events_of_type(ctx.tenant, "auth.signed_out")
    assert event.actor_id == ctx.reviewer.id
  end

  test "self-service account routes are not served" do
    paths = Enum.map(Phoenix.Router.routes(SdrAgentWeb.Router), & &1.path)

    for path <- paths do
      refute path =~ ~r/register|reset|confirm|magic/, "unexpected route #{path}"
    end
  end
end
