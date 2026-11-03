defmodule SdrAgentWeb.ProspectSearchLiveTest do
  @moduledoc """
  RED (ADR-0027; notes/features/website-prospect-search.org; shared contract
  e3f72d8c): the owner-only, company-first "Find prospects" search on /leads.

  The owner searches companies, confirms one company's website and domain,
  searches people at it, gets the company page through the provider, and
  pre-fills the existing Add prospect form from one employer-matched person.
  Results are ephemeral server assigns. Only the active request's result is
  used, and only after a fresh owner check. Cards keep provider data
  (unverified suggestions) apart from the literal excerpt. Nothing is saved
  until the owner previews and saves through the unchanged OwnerIntake.

  The search backend is `SdrAgentWeb.ProspectSearchFake` (test seam); no
  network, model or paid call.
  """
  use SdrAgentWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Repo
  alias SdrAgentWeb.ProspectSearchFake, as: Fake

  setup do
    ctx = H.activated!()
    enrolled = H.enrol!(ctx)
    signed = H.consume!(enrolled.enrollment_token)
    assert {:ok, auditor_token, _} = AshAuthentication.Jwt.token_for_user(ctx.fx.auditor)
    H.enter!(ctx)

    start_supervised!({Fake, self()})
    previous = Application.fetch_env(:sdr_agent, :prospect_search_ui_adapter)
    Application.put_env(:sdr_agent, :prospect_search_ui_adapter, Fake)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdr_agent, :prospect_search_ui_adapter, value)
        :error -> Application.delete_env(:sdr_agent, :prospect_search_ui_adapter)
      end
    end)

    Map.merge(ctx, %{
      enrolled: enrolled,
      user: signed,
      token: signed.__metadata__.token,
      auditor_token: auditor_token
    })
  end

  defp today, do: DateTime.utc_now() |> DateTime.to_date()

  defp open(ctx, token \\ nil) do
    {:ok, view, _html} =
      ctx.conn |> init_test_session(%{"user_token" => token || ctx.token}) |> live("/leads")

    view
  end

  defp open_search(view) do
    assert has_element?(view, "#find-prospects"), "no Find prospects control on /leads"
    view |> element("#find-prospects") |> render_click()
    view
  end

  defp company_candidate(overrides \\ %{}) do
    Map.merge(
      %{
        id: "c1",
        kind: :company,
        provider_id: "exa-company-1",
        url: "https://cedar-search.test/",
        title: "Cedar Tools homepage",
        name: "Cedar Tools",
        first_name: nil,
        last_name: nil,
        role: nil,
        company_name: nil,
        website_url: "https://cedar-search.test/",
        domain: "cedar-search.test",
        employee_count: 12,
        location: "Denver, US",
        employer_match?: false,
        excerpt: "Cedar makes developer tools.",
        retrieved_on: today(),
        provider_date: "2020-01-01"
      },
      overrides
    )
  end

  defp person_candidate(overrides \\ %{}) do
    Map.merge(
      %{
        id: "p1",
        kind: :person,
        provider_id: "exa-person-1",
        url: "https://www.linkedin.com/in/jordan-testperson",
        title: "Jordan Testperson - profile",
        name: nil,
        first_name: "Jordan",
        last_name: "Testperson",
        role: "Founder",
        company_name: "Cedar Tools",
        website_url: nil,
        domain: nil,
        employee_count: nil,
        location: nil,
        employer_match?: true,
        excerpt: "Jordan leads Cedar.",
        retrieved_on: today(),
        provider_date: nil
      },
      overrides
    )
  end

  defp source do
    %{
      url: "https://cedar-search.test/",
      source_type: :company_site,
      retrieved_on: today(),
      excerpt: "Cedar Tools builds developer tools for small teams."
    }
  end

  defp search_companies(view, query \\ "developer tools startups") do
    view |> form("#company-search-form", search: %{query: query}) |> render_submit()
    assert_receive {:fake_search_started, id, request, caller}
    assert caller == view.pid, "the search was not started by the LiveView process"
    {id, request}
  end

  defp deliver(view, id, outcome) do
    send(view.pid, {:prospect_search_result, id, outcome})
    render(view)
  end

  defp result(kind, candidates),
    do: {:ok, %{kind: kind, candidates: candidates, cost_dollars: nil}}

  defp companies_shown(view, candidates \\ [company_candidate()]) do
    {id, _} = search_companies(view)
    deliver(view, id, result(:company, candidates))
    view
  end

  defp confirm_company(view) do
    view |> element("#select-company-c1") |> render_click()

    view
    |> form("#company-confirm-form",
      company: %{website_url: "https://cedar-search.test/", domain: "cedar-search.test"}
    )
    |> render_submit()

    assert has_element?(view, "#company-context", "Cedar Tools")
    view
  end

  defp people_shown(view, candidates \\ [person_candidate()]) do
    view |> form("#people-search-form", people: %{query: "founder"}) |> render_submit()
    assert_receive {:fake_search_started, id, request, _caller}
    assert %{kind: :people, query: "founder", company: %{name: "Cedar Tools"}} = request
    deliver(view, id, result(:people, candidates))
    view
  end

  defp company_page(view) do
    view |> element("#get-company-page") |> render_click()
    assert_receive {:fake_search_started, id, request, _caller}

    assert %{kind: :contents, company: %{website_url: "https://cedar-search.test/"}} =
             request

    deliver(view, id, {:ok, %{kind: :contents, source: source(), cost_dollars: nil}})
    view
  end

  defp count(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}", [])
    n
  end

  defp counts,
    do:
      Enum.map(
        ~w(leads contacts accounts owner_prospect_intakes operations model_invocations),
        &count/1
      )

  describe "visibility" do
    test "the owner opens the company search, which says the query is sent to Exa", ctx do
      view = ctx |> open() |> open_search()
      assert has_element?(view, "#prospect-search")
      assert has_element?(view, "#company-search-form")
      assert has_element?(view, "#search-disclosure", "Exa")
    end

    test "search is hidden when the backend is unavailable", ctx do
      Fake.put(:available?, false)
      view = open(ctx)
      refute has_element?(view, "#find-prospects")
      refute has_element?(view, "#prospect-search")
    end

    test "a non-owner sees no search, and forged events start nothing", ctx do
      view = open(ctx, ctx.auditor_token)
      refute has_element?(view, "#find-prospects")

      for {event, params} <- [
            {"search_open", %{}},
            {"search_companies", %{"search" => %{"query" => "x"}}},
            {"select_company", %{"id" => "c1"}},
            {"confirm_company", %{"company" => %{"website_url" => "https://a.test/"}}},
            {"search_people", %{"people" => %{"query" => "founder"}}},
            {"get_company_page", %{}},
            {"prefill", %{"id" => "p1"}}
          ] do
        render_hook(view, event, params)
      end

      refute_received {:fake_search_started, _, _, _}
      refute has_element?(view, "#prospect-search")
      refute has_element?(view, "#owner-intake-form")
    end
  end

  describe "company results" do
    test "a company search sends only the typed query and shows a cancellable running state",
         ctx do
      view = ctx |> open() |> open_search()
      {_id, request} = search_companies(view, "developer tools startups")
      assert request == %{kind: :company, query: "developer tools startups"}
      assert has_element?(view, "#search-running")
      assert has_element?(view, "#search-cancel")
    end

    test "cards label provider data apart from the literal excerpt, and unknowns stay unknown",
         ctx do
      view = ctx |> open() |> open_search()

      second =
        company_candidate(%{id: "c2", name: "Birch Labs", employee_count: nil, location: nil})

      html = view |> companies_shown([company_candidate(), second]) |> render()

      assert has_element?(view, "#candidate-c1", "Cedar Tools")
      assert has_element?(view, "#candidate-c1 [data-provider-data]", "12")
      assert has_element?(view, "#candidate-c1 [data-provider-data]", "Denver, US")
      assert has_element?(view, "#candidate-c1 [data-excerpt]", "Cedar makes developer tools.")
      assert has_element?(view, "#candidate-c1 a[href='https://cedar-search.test/']")
      assert has_element?(view, "#candidate-c2 [data-unknown='employee_count']")
      assert has_element?(view, "#candidate-c2 [data-unknown='location']")
      refute has_element?(view, "#search-running")
      refute html =~ "<img"
    end

    test "provider text is escaped, never rendered as markup", ctx do
      view = ctx |> open() |> open_search()

      html =
        view
        |> companies_shown([
          company_candidate(%{name: "<script>alert(1)</script>", excerpt: "<b>bold</b>"})
        ])
        |> render()

      refute html =~ "<script>alert(1)</script>"
      refute html =~ "<b>bold</b>"
      assert html =~ "&lt;script&gt;"
    end

    test "a result for an older request is ignored", ctx do
      view = ctx |> open() |> open_search()
      {old, _} = search_companies(view, "first query")
      {new, _} = search_companies(view, "second query")
      assert old != new

      deliver(view, old, result(:company, [company_candidate(%{id: "old1", name: "Old Co"})]))
      refute has_element?(view, "#candidate-old1")
      assert has_element?(view, "#search-running")

      deliver(view, new, result(:company, [company_candidate()]))
      assert has_element?(view, "#candidate-c1")
    end

    test "cancel calls the backend, and the cancelled request's late result is ignored", ctx do
      view = ctx |> open() |> open_search()
      {id, _} = search_companies(view)
      view |> element("#search-cancel") |> render_click()
      assert_receive {:fake_search_cancelled, ^id, caller}
      assert caller == view.pid
      refute has_element?(view, "#search-running")

      deliver(view, id, result(:company, [company_candidate()]))
      refute has_element?(view, "#candidate-c1")
    end

    test "a provider error shows a fixed message without the query", ctx do
      view = ctx |> open() |> open_search()
      {id, _} = search_companies(view, "SENTINEL-QUERY-91b2")
      html = deliver(view, id, {:error, :rate_limited})
      assert has_element?(view, "#search-error")
      refute html =~ "SENTINEL-QUERY-91b2"
      refute has_element?(view, "#search-running")
    end

    test "a refused start (busy) shows a fixed message and no running state", ctx do
      Fake.put(:start, {:error, :busy})
      view = ctx |> open() |> open_search()
      view |> form("#company-search-form", search: %{query: "x"}) |> render_submit()
      assert has_element?(view, "#search-error")
      refute has_element?(view, "#search-running")
    end

    test "a revoked owner's pending result is withheld and the search closes", ctx do
      view = ctx |> open() |> open_search()
      {id, _} = search_companies(view)
      assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.user)
      html = deliver(view, id, result(:company, [company_candidate()]))
      refute has_element?(view, "#candidate-c1")
      refute has_element?(view, "#prospect-search")
      refute html =~ "Cedar makes developer tools."
    end
  end

  describe "company-first people search" do
    test "people search needs a confirmed company and is scoped to it", ctx do
      view = ctx |> open() |> open_search() |> companies_shown()
      refute has_element?(view, "#people-search-form")
      view = confirm_company(view)
      assert has_element?(view, "#company-context", "cedar-search.test")
      view |> people_shown()
      assert has_element?(view, "#candidate-p1", "Jordan")
    end

    test "a directory card without a website gets no suggestion, and the owner must type one",
         ctx do
      view =
        ctx
        |> open()
        |> open_search()
        |> companies_shown([company_candidate(%{website_url: nil, domain: nil})])

      view |> element("#select-company-c1") |> render_click()
      assert has_element?(view, "#company-confirm-form")
      refute has_element?(view, "#company-confirm-form input[value='https://cedar-search.test/']")
    end

    test "an invalid company confirmation is refused and gives no people search", ctx do
      view = ctx |> open() |> open_search() |> companies_shown()
      view |> element("#select-company-c1") |> render_click()

      view
      |> form("#company-confirm-form",
        company: %{website_url: "http://cedar-search.test/", domain: "cedar-search.test"}
      )
      |> render_submit()

      assert has_element?(view, "#search-error")
      refute has_element?(view, "#company-context")
      refute has_element?(view, "#people-search-form")
    end

    test "an employer-unconfirmed person is labelled and cannot pre-fill", ctx do
      view = ctx |> open() |> open_search() |> companies_shown() |> confirm_company()

      people_shown(view, [
        person_candidate(),
        person_candidate(%{id: "p2", first_name: "Riley", employer_match?: false, role: nil})
      ])

      assert has_element?(view, "#prefill-p1")
      assert has_element?(view, "#candidate-p2 [data-employer-unconfirmed]")
      refute has_element?(view, "#prefill-p2")
    end

    test "a new company search clears the confirmed company, people and page", ctx do
      view =
        ctx |> open() |> open_search() |> companies_shown() |> confirm_company() |> people_shown()

      company_page(view)
      {_id, _} = search_companies(view, "another query")
      refute has_element?(view, "#company-context")
      refute has_element?(view, "#candidate-p1")
      refute has_element?(view, "#company-source")
    end

    test "changing company cancels pending people work, and its late result is not attached",
         ctx do
      birch =
        company_candidate(%{
          id: "c2",
          name: "Birch Labs",
          url: "https://birch-search.test/",
          website_url: "https://birch-search.test/",
          domain: "birch-search.test"
        })

      view =
        ctx |> open() |> open_search() |> companies_shown([company_candidate(), birch])

      view = confirm_company(view)
      view |> form("#people-search-form", people: %{query: "founder"}) |> render_submit()
      assert_receive {:fake_search_started, pending, %{kind: :people}, _caller}

      view |> element("#change-company") |> render_click()
      assert_receive {:fake_search_cancelled, ^pending, _caller}
      view |> element("#select-company-c2") |> render_click()

      view
      |> form("#company-confirm-form",
        company: %{website_url: "https://birch-search.test/", domain: "birch-search.test"}
      )
      |> render_submit()

      assert has_element?(view, "#company-context", "Birch Labs")
      deliver(view, pending, result(:people, [person_candidate()]))
      refute has_element?(view, "#candidate-p1")
    end
  end

  describe "pre-fill into Add prospect" do
    test "pre-fill clears an earlier valid preview, so a stale commit saves nothing", ctx do
      view = open(ctx)
      view |> element("#add-prospect") |> render_click()

      earlier = %{
        "company_name" => "Acme Intake",
        "domain" => "acme-intake.test",
        "website_url" => "https://www.acme-intake.test/",
        "first_name" => "Avery",
        "last_name" => "Intake",
        "title" => "VP Operations",
        "email" => "avery@acme-intake.test",
        "sources" => %{
          "0" => %{
            "url" => "https://www.acme-intake.test/",
            "source_type" => "company_site",
            "retrieved_on" => Date.to_iso8601(today()),
            "excerpt" => "Acme Intake builds warehouse robots."
          }
        }
      }

      view |> form("#owner-intake-form", intake: earlier) |> render_submit()
      assert has_element?(view, "#intake-preview")

      view = view |> open_search() |> companies_shown() |> confirm_company() |> people_shown()
      company_page(view)
      view |> element("#prefill-p1") |> render_click()

      refute has_element?(view, "#intake-preview")
      render_hook(view, "intake_commit", %{})
      assert has_element?(view, "#intake-error", "Preview the prospect before saving it.")
      assert count("owner_prospect_intakes") == 0
    end

    test "pre-fill needs the company page first", ctx do
      view =
        ctx |> open() |> open_search() |> companies_shown() |> confirm_company() |> people_shown()

      view |> element("#prefill-p1") |> render_click()
      assert has_element?(view, "#search-error")
      refute has_element?(view, "#owner-intake-form")
    end

    test "the company page shows the literal excerpt it will cite", ctx do
      view = ctx |> open() |> open_search() |> companies_shown() |> confirm_company()
      company_page(view)

      assert has_element?(
               view,
               "#company-source [data-excerpt]",
               "Cedar Tools builds developer tools for small teams."
             )
    end

    test "pre-fill opens the existing form with cited sources, a blank email and no preview",
         ctx do
      before = counts()

      view =
        ctx |> open() |> open_search() |> companies_shown() |> confirm_company() |> people_shown()

      company_page(view)
      view |> element("#prefill-p1") |> render_click()

      assert has_element?(view, "#owner-intake-form")
      refute has_element?(view, "#intake-preview")
      form = "#owner-intake-form"
      assert has_element?(view, "#{form} input[name='intake[company_name]'][value='Cedar Tools']")
      assert has_element?(view, "#{form} input[name='intake[domain]'][value='cedar-search.test']")

      assert has_element?(
               view,
               "#{form} input[name='intake[website_url]'][value='https://cedar-search.test/']"
             )

      assert has_element?(view, "#{form} input[name='intake[first_name]'][value='Jordan']")
      assert has_element?(view, "#{form} input[name='intake[last_name]'][value='Testperson']")
      assert has_element?(view, "#{form} input[name='intake[title]'][value='Founder']")
      refute has_element?(view, "#{form} input[name='intake[email]'][value]:not([value=''])")

      assert has_element?(
               view,
               "#{form} input[name='intake[sources][0][url]'][value='https://cedar-search.test/']"
             )

      assert has_element?(
               view,
               "#{form} select[name='intake[sources][0][source_type]'] option[selected][value='company_site']"
             )

      assert has_element?(
               view,
               "#{form} input[name='intake[sources][1][url]'][value='https://www.linkedin.com/in/jordan-testperson']"
             )

      assert has_element?(
               view,
               "#{form} select[name='intake[sources][1][source_type]'] option[selected][value='directory']"
             )

      assert counts() == before, "search or pre-fill wrote business rows"
    end

    test "after the owner adds the work email, the unchanged intake previews and saves", ctx do
      view =
        ctx |> open() |> open_search() |> companies_shown() |> confirm_company() |> people_shown()

      company_page(view)
      view |> element("#prefill-p1") |> render_click()

      params = %{
        "company_name" => "Cedar Tools",
        "domain" => "cedar-search.test",
        "website_url" => "https://cedar-search.test/",
        "first_name" => "Jordan",
        "last_name" => "Testperson",
        "title" => "Founder",
        "email" => "jordan@cedar-search.test",
        "sources" => %{
          "0" => %{
            "url" => "https://cedar-search.test/",
            "source_type" => "company_site",
            "retrieved_on" => Date.to_iso8601(today()),
            "excerpt" => "Cedar Tools builds developer tools for small teams."
          },
          "1" => %{
            "url" => "https://www.linkedin.com/in/jordan-testperson",
            "source_type" => "directory",
            "retrieved_on" => Date.to_iso8601(today()),
            "excerpt" => "Jordan leads Cedar."
          }
        }
      }

      view |> form("#owner-intake-form", intake: params) |> render_submit()
      assert has_element?(view, "#intake-preview", "jordan@cedar-search.test")
      view |> element("#intake-commit") |> render_click()
      assert_redirect(view)
      assert count("owner_prospect_intakes") == 1
    end

    test "pre-fill uses the server-held card, never a forged one from the event", ctx do
      view =
        ctx |> open() |> open_search() |> companies_shown() |> confirm_company() |> people_shown()

      company_page(view)

      render_hook(view, "prefill", %{
        "id" => "p1",
        "first_name" => "Forged",
        "candidate" => %{"first_name" => "Forged", "employer_match?" => true}
      })

      assert has_element?(
               view,
               "#owner-intake-form input[name='intake[first_name]'][value='Jordan']"
             )

      refute render(view) =~ "Forged"

      view = ctx |> open() |> open_search() |> companies_shown() |> confirm_company()
      company_page(view)
      render_hook(view, "prefill", %{"id" => "not-a-card"})
      refute has_element?(view, "#owner-intake-form")
    end

    test "a revoked owner cannot pre-fill", ctx do
      view =
        ctx |> open() |> open_search() |> companies_shown() |> confirm_company() |> people_shown()

      company_page(view)
      assert {:ok, _} = H.disable(ctx, ctx.enrolled.owner.id, actor: ctx.user)
      # The existing session guard ends a revoked owner's view on any event.
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               render_hook(view, "prefill", %{"id" => "p1"})
    end
  end
end
