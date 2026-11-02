defmodule SdrAgent.Integrations.WikidataTest do
  @moduledoc """
  Discovery RED-B (design r1 §1a): the pure halves of
  `SdrAgent.Integrations.Wikidata`, the no-key company search source.

    * `companies_query/2` builds the SPARQL for industry and country QIDs
      (each `Q` plus digits, 1..20 of each) and a limit of 1..200; any other
      input is `{:error, :invalid_query}` and nothing is interpolated.
    * `parse_companies/1` reads a SPARQL JSON result into one candidate per
      company QID, in first-seen order: `qid`, `name`, `website_host`
      (lower-cased host of the first official website whose host passes the
      dossier host rule; http and https both name a host, the fetch is
      always https; a website with a port or userinfo is unusable) and `employees` (the largest stated count, or nil).
      Rows without a usable host are dropped; a malformed document is
      `{:error, :invalid_response}`.
  """
  use ExUnit.Case, async: true

  @mod SdrAgent.Integrations.Wikidata

  defp call(fun, args) do
    assert Code.ensure_loaded?(@mod), "SdrAgent.Integrations.Wikidata is not defined"
    apply(Function.capture(@mod, fun, length(args)), args)
  end

  defp row(qid, label, site, emp \\ nil) do
    base = %{
      "c" => %{"type" => "uri", "value" => "http://www.wikidata.org/entity/" <> qid},
      "cLabel" => %{"type" => "literal", "value" => label},
      "site" => %{"type" => "uri", "value" => site}
    }

    if emp, do: Map.put(base, "emp", %{"type" => "literal", "value" => emp}), else: base
  end

  defp doc(rows),
    do: %{
      "head" => %{"vars" => ["c", "cLabel", "site", "emp"]},
      "results" => %{"bindings" => rows}
    }

  test "the query names exactly the given industries and countries and the limit" do
    assert {:ok, q} =
             call(:companies_query, [
               %{industries: ["Q177777", "Q492886"], countries: ["Q30", "Q16"]},
               200
             ])

    assert q =~ "wd:Q177777"
    assert q =~ "wd:Q492886"
    assert q =~ "wd:Q30"
    assert q =~ "wd:Q16"
    assert q =~ "wdt:P856"
    assert q =~ ~r/LIMIT 200\s*\z/
  end

  test "invalid QIDs, empty lists and out-of-range limits are refused" do
    good = %{industries: ["Q1"], countries: ["Q30"]}

    for {spec, limit} <- [
          {%{good | industries: ["Q1 } DELETE"]}, 10},
          {%{good | industries: ["q1"]}, 10},
          {%{good | industries: ["Q01"]}, 10},
          {%{good | countries: []}, 10},
          {%{good | industries: Enum.map(1..21, &"Q#{&1}")}, 10},
          {good, 0},
          {good, 201},
          {%{industries: ["Q1"]}, 10}
        ] do
      assert call(:companies_query, [spec, limit]) == {:error, :invalid_query},
             inspect({spec, limit})
    end
  end

  test "results become one candidate per company with a usable host" do
    rows = [
      row("Q1", "Acme Logistics", "https://www.Acme-Logistics.example.com/", "120"),
      row("Q1", "Acme Logistics", "https://acme.example.com/", "150"),
      row("Q2", "Beta Freight", "http://beta.example.net"),
      row("Q3", "Gamma Ltd", "https://192.0.2.10/"),
      row("Q4", "Delta Co", "https://intranet/"),
      row("Q5", "Epsilon", "https://epsilon.example.org:8443/x")
    ]

    assert call(:parse_companies, [doc(rows)]) ==
             {:ok,
              [
                %{
                  qid: "Q1",
                  name: "Acme Logistics",
                  website_host: "www.acme-logistics.example.com",
                  employees: 150
                },
                %{
                  qid: "Q2",
                  name: "Beta Freight",
                  website_host: "beta.example.net",
                  employees: nil
                }
              ]}
  end

  # Codex GREEN-A review (important): a malformed count is unknown, and a
  # malformed binding value never raises.
  test "a count with a non-numeric tail is unknown" do
    for emp <- ["50garbage", "12 people", "", "-5", "1e3x"] do
      assert call(:parse_companies, [doc([row("Q1", "Acme", "https://acme.example.com/", emp)])]) ==
               {:ok,
                [%{qid: "Q1", name: "Acme", website_host: "acme.example.com", employees: nil}]},
             emp
    end

    assert {:ok, [%{employees: 1000}]} =
             call(:parse_companies, [
               doc([row("Q1", "Acme", "https://acme.example.com/", "1000")])
             ])
  end

  test "malformed binding values are skipped without raising" do
    good = row("Q2", "Beta", "https://beta.example.net/")

    bad = [
      %{
        "c" => "http://www.wikidata.org/entity/Q1",
        "site" => %{"value" => "https://a.example.com"}
      },
      %{
        "c" => %{"value" => "http://www.wikidata.org/entity/Q3"},
        "site" => "https://c.example.com"
      },
      %{"c" => %{"value" => "http://www.wikidata.org/entity/Q4"}, "site" => %{"value" => 7}},
      %{
        "c" => %{"value" => "http://www.wikidata.org/entity/Q5"},
        "site" => %{"value" => "https://e.example.com"},
        "emp" => "9"
      },
      "row",
      nil
    ]

    assert {:ok, candidates} = call(:parse_companies, [doc(bad ++ [good])])
    hosts = Enum.map(candidates, &Map.take(&1, [:qid, :website_host]))
    assert %{qid: "Q2", website_host: "beta.example.net"} in hosts
    refute Enum.any?(candidates, &(&1.qid in ["Q1", "Q3", "Q4"]))
  end

  test "a malformed document is refused" do
    for bad <- [%{}, %{"results" => %{}}, %{"results" => %{"bindings" => "x"}}, nil] do
      assert call(:parse_companies, [bad]) == {:error, :invalid_response}, inspect(bad)
    end
  end
end
