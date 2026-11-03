defmodule SdrAgentWeb.LeadLive.IntakePrefillTest do
  @moduledoc """
  RED (ADR-0027; shared contract e3f72d8c "Web prefill builder"): the pure
  `SdrAgentWeb.LeadLive.IntakePrefill.build/3`. From one employer-matched
  person card, the confirmed CompanyContext and the provider company-page
  Source, it builds the existing string-key Add prospect form params. Email
  stays blank, missing names stay blank, and the company page is the
  company_site source, with the person excerpt as an optional directory
  source. It never invents an excerpt, employer or address.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.OwnerIntakeInput
  alias SdrAgentWeb.LeadLive.OwnerIntakePanel

  @module SdrAgentWeb.LeadLive.IntakePrefill

  defp today, do: DateTime.utc_now() |> DateTime.to_date()

  defp person(overrides \\ %{}) do
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

  defp company,
    do: %{
      id: "c1",
      name: "Cedar Tools",
      domain: "cedar-search.test",
      website_url: "https://cedar-search.test/"
    }

  defp source(overrides \\ %{}) do
    Map.merge(
      %{
        url: "https://cedar-search.test/",
        source_type: :company_site,
        retrieved_on: today(),
        excerpt: "Cedar Tools builds developer tools for small teams."
      },
      overrides
    )
  end

  defp build(person, company, source) do
    assert Code.ensure_loaded?(@module), "missing SdrAgentWeb.LeadLive.IntakePrefill"
    Function.capture(@module, :build, 3).(person, company, source)
  end

  test "builds the existing form params from the matched person, company and page" do
    date = Date.to_iso8601(today())

    assert {:ok, params} = build(person(), company(), source())

    assert params == %{
             "company_name" => "Cedar Tools",
             "domain" => "cedar-search.test",
             "website_url" => "https://cedar-search.test/",
             "first_name" => "Jordan",
             "last_name" => "Testperson",
             "title" => "Founder",
             "email" => "",
             "sources" => %{
               "0" => %{
                 "url" => "https://cedar-search.test/",
                 "source_type" => "company_site",
                 "retrieved_on" => date,
                 "excerpt" => "Cedar Tools builds developer tools for small teams."
               },
               "1" => %{
                 "url" => "https://www.linkedin.com/in/jordan-testperson",
                 "source_type" => "directory",
                 "retrieved_on" => date,
                 "excerpt" => "Jordan leads Cedar."
               }
             }
           }
  end

  test "missing names and role stay blank for the owner to complete" do
    assert {:ok, params} = build(person(%{last_name: nil, role: nil}), company(), source())
    assert params["first_name"] == "Jordan"
    assert params["last_name"] == ""
    assert params["title"] == ""
  end

  test "a person without an excerpt cites only the company page" do
    assert {:ok, %{"sources" => sources}} = build(person(%{excerpt: nil}), company(), source())
    assert Map.keys(sources) == ["0"]
  end

  test "an employer-unconfirmed or non-person card is refused" do
    assert {:error, :employer_unconfirmed} =
             build(person(%{employer_match?: false}), company(), source())

    assert {:error, :employer_unconfirmed} =
             build(person(%{kind: :company}), company(), source())
  end

  test "the company page must exist, be company_site and match the confirmed website" do
    assert {:error, :source_missing} = build(person(), company(), nil)

    assert {:error, :source_mismatch} =
             build(person(), company(), source(%{url: "https://other-search.test/"}))

    assert {:error, :source_mismatch} =
             build(person(), company(), source(%{source_type: :directory}))
  end

  test "malformed inputs are refused, never partially built" do
    for {p, c, s} <- [
          {%{}, company(), source()},
          {person(), %{name: "Cedar Tools"}, source()},
          {person(), company(), %{url: "https://cedar-search.test/"}},
          {nil, nil, nil}
        ] do
      assert {:error, :invalid_input} = build(p, c, s)
    end
  end

  test "once the owner adds the work email, the existing intake normalizer accepts it" do
    assert {:ok, params} = build(person(), company(), source())
    form = Map.put(params, "email", "jordan@cedar-search.test")
    assert {:ok, input, _hash} = OwnerIntakeInput.normalize(OwnerIntakePanel.params(form))
    assert length(input["sources"]) == 2
  end

  test "without the email the existing intake refuses it, so nothing is guessed" do
    assert {:ok, params} = build(person(), company(), source())
    assert {:error, :invalid_input} = OwnerIntakeInput.normalize(OwnerIntakePanel.params(params))
  end
end
