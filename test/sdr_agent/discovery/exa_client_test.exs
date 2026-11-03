defmodule SdrAgent.Discovery.ExaClientTest do
  use ExUnit.Case, async: false

  @client SdrAgent.Discovery.ExaClient
  @candidate SdrAgent.Discovery.Candidate
  @received ~D[2026-11-03]

  defp company do
    %{
      id: "company-card",
      name: "Cedar Tools",
      domain: "cedar.test",
      website_url: "https://cedar.test"
    }
  end

  defp company_row do
    %{
      "id" => "provider-company",
      "url" => "https://cedar.test",
      "title" => "Cedar tools homepage",
      "text" => "Cedar makes developer tools.\n",
      "publishedDate" => "2020-01-01",
      "entities" => [
        %{
          "type" => "company",
          "properties" => %{
            "name" => "Cedar Tools",
            "workforce" => %{"total" => 12},
            "headquarters" => %{"city" => "Denver", "country" => "US"}
          }
        }
      ]
    }
  end

  defp person_row(history \\ nil) do
    history =
      history ||
        [
          %{
            "title" => "Founder",
            "company" => %{"name" => "Cedar Tools"},
            "dates" => %{"to" => nil}
          }
        ]

    %{
      "id" => "provider-person",
      "url" => "https://www.linkedin.com/in/jordan-testperson",
      "title" => "Jordan Testperson - profile",
      "highlights" => ["Jordan leads Cedar."],
      "entities" => [
        %{
          "type" => "person",
          "properties" => %{
            "firstName" => "Jordan",
            "lastName" => "Testperson",
            "workHistory" => history
          }
        }
      ]
    }
  end

  defp search(rows, kind \\ :company, context \\ nil, extra \\ %{}) do
    assert Code.ensure_loaded?(@client), "missing Exa normalization contract"

    Function.capture(@client, :normalize_search, 4).(
      Map.merge(%{"results" => rows}, extra),
      kind,
      context,
      @received
    )
  end

  defp contents(rows, context \\ company()) do
    assert Code.ensure_loaded?(@client), "missing Exa contents contract"
    Function.capture(@client, :normalize_contents, 3).(%{"results" => rows}, context, @received)
  end

  test "company results retain source text separately from provider entity suggestions" do
    assert {:ok, %{kind: :company, candidates: [c], cost_dollars: nil}} = search([company_row()])
    assert c.name == "Cedar Tools"
    assert c.title == "Cedar tools homepage"
    assert c.employee_count == 12
    assert c.location == "Denver, US"
    assert c.excerpt == "Cedar makes developer tools.\n"
    assert c.retrieved_on == @received
    assert c.provider_date == "2020-01-01"
    assert is_binary(c.id)
    refute Map.has_key?(c, :email)
  end

  test "a page title without a company entity is not invented into a company name" do
    row = company_row() |> Map.delete("entities")
    assert {:ok, %{candidates: [c]}} = search([row])
    assert c.name == nil
  end

  test "directory source never supplies the company website or domain" do
    row = %{company_row() | "url" => "https://www.linkedin.com/company/cedar-tools"}
    assert {:ok, %{candidates: [c]}} = search([row])
    assert c.website_url == nil
    assert c.domain == nil
    assert c.name == "Cedar Tools"
  end

  test "response URLs must be safe HTTPS and duplicate URLs collapse" do
    rows =
      for url <- [
            "http://cedar.test",
            "https://127.0.0.1",
            "https://localhost",
            "https://u:p@cedar.test",
            "javascript:alert(1)"
          ] do
        %{company_row() | "url" => url}
      end

    assert {:ok, %{candidates: [c]}} = search(rows ++ [company_row(), company_row()])
    assert c.url == "https://cedar.test"
  end

  test "missing optional provider fields remain unknown" do
    row = %{"url" => "https://cedar.test", "title" => "Cedar"}
    assert {:ok, %{candidates: [c]}} = search([row])

    for field <- [:first_name, :last_name, :role, :employee_count, :location, :excerpt],
        do: assert(Map.fetch!(c, field) == nil)
  end

  test "people use exact current employer match, never the profile domain" do
    assert {:ok, %{kind: :people, candidates: [c]}} = search([person_row()], :people, company())
    assert c.first_name == "Jordan"
    assert c.last_name == "Testperson"
    assert c.role == "Founder"
    assert c.company_name == "Cedar Tools"
    assert c.employer_match?
    assert c.domain == nil
    assert c.website_url == nil
    assert c.excerpt == "Jordan leads Cedar."
  end

  test "ended, absent-date and mismatched employer histories are unconfirmed" do
    for history <- [
          [
            %{
              "title" => "Founder",
              "company" => %{"name" => "Cedar Tools"},
              "dates" => %{"to" => "2024-01-01"}
            }
          ],
          [%{"title" => "Founder", "company" => %{"name" => "Cedar Tools"}}],
          [
            %{
              "title" => "Founder",
              "company" => %{"name" => "Other Tools"},
              "dates" => %{"to" => nil}
            }
          ]
        ] do
      assert {:ok, %{candidates: [c]}} = search([person_row(history)], :people, company())
      refute c.employer_match?
      assert c.role == nil
    end
  end

  test "ambiguous current employer matches do not select a job title" do
    history =
      for title <- ["Founder", "Advisor"],
          do: %{
            "title" => title,
            "company" => %{"name" => "Cedar Tools"},
            "dates" => %{"to" => nil}
          }

    assert {:ok, %{candidates: [c]}} = search([person_row(history)], :people, company())
    refute c.employer_match?
    assert c.role == nil
  end

  test "missing or malformed nested dates and an absent end marker remain unconfirmed" do
    for dates <- [nil, %{}, %{"from" => "2020-01-01"}, [], "unknown", %{"to" => ""}] do
      history = [
        %{"title" => "Founder", "company" => %{"name" => "Cedar Tools"}, "dates" => dates}
      ]

      assert {:ok, %{candidates: [c]}} = search([person_row(history)], :people, company())
      refute c.employer_match?
      assert c.role == nil
      assert c.company_name == nil
    end
  end

  test "a flat null end marker cannot assert a current job or override a nested past job" do
    for extra <- [%{}, %{"dates" => %{"to" => "2024-01-01"}}] do
      entry = %{"title" => "Founder", "company" => %{"name" => "Cedar Tools"}, "to" => nil}
      history = [Map.merge(entry, extra)]

      assert {:ok, %{candidates: [c]}} = search([person_row(history)], :people, company())
      refute c.employer_match?
      assert c.role == nil
      assert c.company_name == nil
    end
  end

  test "employer equality ignores surrounding space and Unicode-normalized case only" do
    history = [
      %{
        "title" => "Founder",
        "company" => %{"name" => " CEDAR TOOLS "},
        "dates" => %{"to" => nil}
      }
    ]

    assert {:ok, %{candidates: [c]}} = search([person_row(history)], :people, company())
    assert c.employer_match?
  end

  test "malformed top-level response refuses while malformed individual rows drop" do
    assert Code.ensure_loaded?(@client), "missing Exa normalization contract"

    for body <- [nil, [], %{}, %{"results" => "not a list"}] do
      assert {:error, :invalid_response} =
               Function.capture(@client, :normalize_search, 4).(body, :company, nil, @received)
    end

    assert {:ok, %{candidates: []}} = search([nil, "wrong", %{"url" => 3}])
  end

  test "excerpts are literal byte-bounded valid UTF-8, never entity JSON prose" do
    text = String.duplicate("é", 1100)
    assert {:ok, %{candidates: [c]}} = search([Map.put(company_row(), "text", text)])
    assert String.valid?(c.excerpt)
    assert byte_size(c.excerpt) <= 2000
    assert String.starts_with?(text, c.excerpt)
  end

  test "cost metadata accepts only nonnegative numeric totals" do
    assert {:ok, %{cost_dollars: 0.007}} =
             search([], :company, nil, %{"costDollars" => %{"total" => 0.007}})

    for cost <- [-1, "credential-canary", %{}] do
      assert {:ok, %{cost_dollars: nil}} =
               search([], :company, nil, %{"costDollars" => %{"total" => cost}})
    end
  end

  test "contents preserves confirmed source URL, receipt date and literal excerpt" do
    assert {:ok, %{kind: :contents, source: source}} =
             contents([%{"url" => "https://cedar.test/", "text" => "Company page bytes"}])

    assert source == %{
             url: "https://cedar.test",
             source_type: :company_site,
             retrieved_on: @received,
             excerpt: "Company page bytes"
           }
  end

  test "contents rejects changed host, missing text and unsafe company context" do
    assert {:error, :source_mismatch} =
             contents([%{"url" => "https://other.test", "text" => "Wrong host"}])

    assert {:error, :invalid_response} =
             contents([%{"url" => "https://cedar.test", "text" => ""}])

    assert {:error, :invalid_input} =
             contents([], %{company() | website_url: "https://127.0.0.1"})
  end

  test "NFC and NFD employer names match after normalization" do
    context = %{company() | name: "Café Tools"}

    history = [
      %{
        "title" => "Founder",
        "company" => %{"name" => String.normalize(" CAFÉ TOOLS ", :nfd)},
        "dates" => %{"to" => nil}
      }
    ]

    assert {:ok, %{candidates: [c]}} = search([person_row(history)], :people, context)
    assert c.employer_match?
  end

  test "company context refuses mismatched website domain, HTTP and non-ASCII domain" do
    assert Code.ensure_loaded?(@candidate), "missing candidate/context contract"
    assert {:ok, %{candidates: [c]}} = search([company_row()])

    for input <- [
          %{website_url: "https://cedar.test", domain: "other.test"},
          %{website_url: "http://cedar.test", domain: "cedar.test"},
          %{website_url: "https://cedar.test", domain: "cédar.test"}
        ] do
      assert {:error, :invalid_input} =
               Function.capture(@candidate, :company_context, 2).(c, input)
    end
  end

  test "contents chooses one matching host and refuses ambiguous matching rows" do
    row = %{"url" => "https://cedar.test/", "text" => String.duplicate("é", 1100)}
    other = %{"url" => "https://other.test", "text" => "Different site"}
    assert {:ok, %{source: source}} = contents([other, row])
    assert byte_size(source.excerpt) <= 2000
    assert String.valid?(source.excerpt)
    assert String.starts_with?(row["text"], source.excerpt)
    assert {:error, :source_mismatch} = contents([row, row])
  end

  test "people need company context and search rejects unknown kinds" do
    assert {:error, :invalid_input} = search([person_row()], :people, nil)
    assert {:error, :invalid_input} = search([], :contents, company())
  end

  test "invalid or oversized structured names and roles stay unknown rather than truncated" do
    for bad <- [String.duplicate("x", 201), 42, "bad\0name", "bad\nname"] do
      row = put_in(company_row(), ["entities", Access.at(0), "properties", "name"], bad)
      assert {:ok, %{candidates: [c]}} = search([row])
      assert c.name == nil
      person = person_row()
      person = put_in(person, ["entities", Access.at(0), "properties", "firstName"], bad)
      person = put_in(person, ["entities", Access.at(0), "properties", "lastName"], bad)

      person =
        put_in(
          person,
          ["entities", Access.at(0), "properties", "workHistory", Access.at(0), "title"],
          bad
        )

      assert {:ok, %{candidates: [p]}} = search([person], :people, company())
      assert p.first_name == nil
      assert p.last_name == nil
      assert p.role == nil
    end
  end

  test "company context requires explicit website and domain and a company entity name" do
    assert Code.ensure_loaded?(@candidate), "missing candidate/context contract"
    assert {:ok, %{candidates: [c]}} = search([company_row()])

    assert {:ok, ctx} =
             Function.capture(@candidate, :company_context, 2).(
               c,
               %{website_url: "https://cedar.test", domain: "cedar.test"}
             )

    assert ctx.name == "Cedar Tools"
    assert ctx.id == c.id

    assert {:error, :invalid_input} =
             Function.capture(@candidate, :company_context, 2).(
               c,
               %{website_url: "https://www.linkedin.com/company/cedar", domain: "linkedin.com"}
             )

    assert {:error, :invalid_input} =
             Function.capture(@candidate, :company_context, 2).(
               %{c | name: nil},
               %{website_url: "https://cedar.test", domain: "cedar.test"}
             )
  end
end
