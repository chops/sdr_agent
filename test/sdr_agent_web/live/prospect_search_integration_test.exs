defmodule SdrAgentWeb.ProspectSearchIntegrationTest do
  @moduledoc "Synthetic HTTP-only seam: real authenticated LiveView, facade, limiter, client and prefill."
  use SdrAgentWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SdrAgent.Discovery.ExaTransport
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Repo

  setup do
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    signed = H.consume!(enrolled.enrollment_token)
    H.enter!(ctx)

    env = [
      prospect_search_enabled: true,
      prospect_search_test_key: "synthetic-key",
      prospect_search_cooldown_ms: 0,
      prospect_search_req_options: [plug: {Req.Test, ExaTransport}]
    ]

    previous = for {key, _} <- env, do: {key, Application.fetch_env(:sdr_agent, key)}
    for {key, value} <- env, do: Application.put_env(:sdr_agent, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:sdr_agent, key, old)
          :error -> Application.delete_env(:sdr_agent, key)
        end
      end
    end)

    Req.Test.set_req_test_to_shared()
    start_supervised!(SdrAgent.Discovery.Supervisor)
    %{token: signed.__metadata__.token}
  end

  defp counts do
    for table <- ~w(accounts contacts leads owner_prospect_intakes agent_runs remote_model_calls) do
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM " <> table)
      {table, count}
    end
  end

  defp await_element(view, selector, remaining \\ 100)
  defp await_element(view, selector, 0), do: assert(has_element?(view, selector))

  defp await_element(view, selector, remaining) do
    if has_element?(view, selector) do
      :ok
    else
      Process.sleep(10)
      await_element(view, selector, remaining - 1)
    end
  end

  test "real search pipeline produces cited prefill without any persistence or model call", ctx do
    parent = self()

    Req.Test.stub(ExaTransport, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      send(parent, {:provider, conn.request_path, payload})

      result =
        case {conn.request_path, payload["category"]} do
          {"/search", "company"} ->
            %{
              "results" => [
                %{
                  "url" => "https://cedar-integration.test/",
                  "title" => "Cedar Tools",
                  "entities" => [
                    %{"type" => "company", "properties" => %{"name" => "Cedar Tools"}}
                  ]
                }
              ]
            }

          {"/search", "people"} ->
            %{
              "results" => [
                %{
                  "url" => "https://www.linkedin.com/in/jordan-synthetic",
                  "title" => "Jordan Synthetic",
                  "text" => "Jordan leads Cedar Tools.",
                  "entities" => [
                    %{
                      "type" => "person",
                      "properties" => %{
                        "firstName" => "Jordan",
                        "lastName" => "Synthetic",
                        "workHistory" => [
                          %{
                            "dates" => %{"to" => nil},
                            "title" => "Founder",
                            "company" => %{"name" => "Cedar Tools"}
                          }
                        ]
                      }
                    }
                  ]
                }
              ]
            }

          {"/contents", nil} ->
            %{
              "results" => [
                %{
                  "url" => "https://cedar-integration.test/",
                  "text" => "Cedar Tools builds developer tools."
                }
              ]
            }
        end

      Req.Test.json(conn, result)
    end)

    before = counts()
    {:ok, view, _} = ctx.conn |> init_test_session(%{"user_token" => ctx.token}) |> live("/leads")
    view |> element("#find-prospects") |> render_click()
    view |> form("#company-search-form", search: %{query: "developer tools"}) |> render_submit()
    assert_receive {:provider, "/search", %{"category" => "company"}}, 1000
    await_element(view, "#company-results button")
    view |> element("#company-results button") |> render_click()

    view
    |> form("#company-confirm-form",
      company: %{
        website_url: "https://cedar-integration.test/",
        domain: "cedar-integration.test"
      }
    )
    |> render_submit()

    view |> form("#people-search-form", people: %{query: "Founder"}) |> render_submit()
    assert_receive {:provider, "/search", %{"category" => "people"}}, 1000
    await_element(view, "#people-results button")
    view |> element("#get-company-page") |> render_click()

    assert_receive {:provider, "/contents", %{"urls" => ["https://cedar-integration.test/"]}},
                   1000

    await_element(view, "#company-source")
    view |> element("#people-results button") |> render_click()

    assert has_element?(
             view,
             "#owner-intake-form input[name='intake[first_name]'][value='Jordan']"
           )

    assert has_element?(view, "#owner-intake-form input[name='intake[email]'][value='']")

    assert has_element?(
             view,
             "#owner-intake-form textarea",
             "Cedar Tools builds developer tools."
           )

    refute has_element?(view, "#intake-preview")
    assert counts() == before
    refute_receive {:provider, _, _}, 30
  end
end
