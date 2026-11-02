defmodule SdrAgent.Integrations.Wikidata do
  @moduledoc """
  The pure halves of the Wikidata company search (discovery design r1 §1a):
  building the SPARQL query and reading its JSON result. No network.

    * `companies_query/2` takes `%{industries: [qid], countries: [qid]}`
      (each a `Q` followed by digits without a leading zero, 1..20 of each)
      and a limit of 1..200, and returns a query for companies with an
      industry (P452) and country (P17) among them and an official website
      (P856), with the optional employee count (P1128). Anything else is
      `{:error, :invalid_query}`; only validated QIDs are interpolated.
    * `parse_companies/1` reads a SPARQL JSON result into candidates, one per
      company QID in first-seen order: `qid`, `name`, `website_host` (the
      lower-cased host of the first official website whose host passes the
      dossier host rule; http and https both name a host, a website with a
      port or userinfo is unusable) and `employees` (the largest stated
      count, or nil). A company without a usable host is dropped; a
      malformed document is `{:error, :invalid_response}`.

  Candidates are unverified search results: `employees` is a Wikidata
  statement with no recency, never proof of current headcount or ICP fit.
  """

  alias SdrAgent.Prototype.DossierParser.Rules

  @qid ~r/\AQ[1-9][0-9]*\z/

  @doc "The SPARQL query for the given industries and countries."
  @spec companies_query(map(), pos_integer()) :: {:ok, String.t()} | {:error, :invalid_query}
  def companies_query(%{industries: industries, countries: countries}, limit)
      when is_integer(limit) and limit in 1..200 do
    if qids?(industries) and qids?(countries) do
      {:ok,
       """
       SELECT ?c ?cLabel ?site ?emp WHERE {
         VALUES ?ind { #{values(industries)} }
         VALUES ?country { #{values(countries)} }
         ?c wdt:P452 ?ind; wdt:P17 ?country; wdt:P856 ?site.
         OPTIONAL { ?c wdt:P1128 ?emp }
         SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
       }
       LIMIT #{limit}
       """}
    else
      {:error, :invalid_query}
    end
  end

  def companies_query(_spec, _limit), do: {:error, :invalid_query}

  defp qids?(list),
    do:
      is_list(list) and length(list) in 1..20 and
        Enum.all?(list, &(is_binary(&1) and Regex.match?(@qid, &1)))

  defp values(qids), do: Enum.map_join(qids, " ", &("wd:" <> &1))

  @doc "Candidates from a SPARQL JSON result."
  @spec parse_companies(term()) :: {:ok, [map()]} | {:error, :invalid_response}
  def parse_companies(%{"results" => %{"bindings" => rows}}) when is_list(rows) do
    rows
    |> Enum.reduce({[], %{}}, &collect/2)
    |> then(fn {order, by_qid} ->
      candidates =
        order
        |> Enum.reverse()
        |> Enum.map(&Map.fetch!(by_qid, &1))
        |> Enum.filter(& &1.website_host)

      {:ok, candidates}
    end)
  end

  def parse_companies(_other), do: {:error, :invalid_response}

  defp collect(
         %{"c" => %{"value" => "http://www.wikidata.org/entity/" <> qid}} = row,
         {order, acc}
       )
       when is_binary(qid) do
    if Regex.match?(@qid, qid) do
      host = host(get_in(row, ["site", "value"]))
      emp = employees(get_in(row, ["emp", "value"]))

      case acc do
        %{^qid => known} ->
          known = %{
            known
            | website_host: known.website_host || host,
              employees: max_emp(known.employees, emp)
          }

          {order, Map.put(acc, qid, known)}

        _new ->
          name = get_in(row, ["cLabel", "value"])

          entry = %{
            qid: qid,
            name: if(is_binary(name), do: name, else: qid),
            website_host: host,
            employees: emp
          }

          {[qid | order], Map.put(acc, qid, entry)}
      end
    else
      {order, acc}
    end
  end

  defp collect(_row, acc), do: acc

  defp host(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, port: port}}
      when scheme in ["http", "https"] and is_binary(host) ->
        default = if scheme == "https", do: 443, else: 80
        host = String.downcase(host)
        explicit_port? = port != default or String.contains?(authority(url), ":")

        if not explicit_port? and Rules.public_host?(host), do: host, else: nil

      _ ->
        nil
    end
  end

  defp host(_url), do: nil

  defp authority(url),
    do:
      url
      |> String.split("://", parts: 2)
      |> List.last()
      |> String.split(["/", "?", "#"], parts: 2)
      |> hd()

  defp employees(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _rest} when n >= 0 -> trunc(n)
      _ -> nil
    end
  end

  defp employees(_value), do: nil

  defp max_emp(nil, b), do: b
  defp max_emp(a, nil), do: a
  defp max_emp(a, b), do: max(a, b)
end
