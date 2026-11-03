defmodule SdrAgent.Discovery.ExaClient do
  @moduledoc """
  Normalizes provider-indexed company/person findings for interactive discovery
  (ADR-0027). Structured entity fields are unverified provider suggestions, not
  quotations. Excerpts remain literal; dates refer to response receipt, not an
  independently verified page crawl. This path never infers an email address.
  """

  alias SdrAgent.Discovery.Candidate
  alias SdrAgent.Discovery.Config
  alias SdrAgent.Discovery.ExaTransport

  @doc "Execute one validated fixed-endpoint operation; no retries or persistent effects."
  def execute(request) do
    with {:ok, request} <- Candidate.request(request),
         key when is_binary(key) and byte_size(key) > 0 <- Config.key() do
      execute_valid(request, key)
    else
      {:error, _} = error -> error
      _ -> {:error, :unavailable}
    end
  end

  defp execute_valid(%{kind: :contents, company: company}, key) do
    with {:ok, body} <-
           ExaTransport.post(
             "/contents",
             %{
               "urls" => [company.website_url],
               "text" => %{"maxCharacters" => 4000}
             },
             key
           ) do
      normalize_contents(body, company, Date.utc_today())
    end
  end

  defp execute_valid(%{kind: kind, query: query} = request, key) do
    company = Map.get(request, :company)
    query = if kind == :people, do: query <> " at " <> company.name, else: query

    payload = %{
      "query" => query,
      "category" => Atom.to_string(kind),
      "type" => "auto",
      "numResults" => 10,
      "contents" => %{"text" => %{"maxCharacters" => 4000}}
    }

    with {:ok, body} <- ExaTransport.post("/search", payload, key) do
      normalize_search(body, kind, company, Date.utc_today())
    end
  end

  @doc "Normalize one bounded search response; malformed individual findings are dropped."
  def normalize_search(%{"results" => rows} = body, kind, context, %Date{} = date)
      when is_list(rows) and kind in [:company, :people] do
    with :ok <- context_ok(kind, context) do
      candidates =
        rows
        |> Enum.take(100)
        |> Enum.flat_map(&candidate(&1, kind, context, date))
        |> Enum.uniq_by(& &1.url)
        |> Enum.take(10)

      {:ok, %{kind: kind, candidates: candidates, cost_dollars: cost(body)}}
    end
  end

  def normalize_search(_, kind, _, _) when kind not in [:company, :people],
    do: {:error, :invalid_input}

  def normalize_search(_, _, _, _), do: {:error, :invalid_response}

  defp context_ok(:company, _), do: :ok

  defp context_ok(:people, context) do
    case Candidate.validate_context(context) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_input}
    end
  end

  defp candidate(%{"url" => url, "title" => title} = row, kind, context, date)
       when is_binary(title) do
    if Candidate.safe_url?(url) and is_binary(Candidate.field(title)) do
      base = %{
        id: Ecto.UUID.generate(),
        kind: if(kind == :company, do: :company, else: :person),
        provider_id: Candidate.field(row["id"]),
        url: url,
        title: title,
        name: nil,
        first_name: nil,
        last_name: nil,
        role: nil,
        company_name: nil,
        website_url: nil,
        domain: nil,
        employee_count: nil,
        location: nil,
        employer_match?: false,
        excerpt: excerpt(row),
        retrieved_on: date,
        provider_date: Candidate.field(row["publishedDate"])
      }

      [Map.merge(base, fields(kind, row, context))]
    else
      []
    end
  end

  defp candidate(_, _, _, _), do: []

  defp properties(row, type) do
    case row["entities"] do
      entities when is_list(entities) ->
        case Enum.filter(
               entities,
               &match?(%{"type" => ^type, "properties" => props} when is_map(props), &1)
             ) do
          [%{"properties" => properties}] -> properties
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp fields(:company, row, _) do
    props = properties(row, "company")
    host = URI.parse(row["url"]).host
    website? = not Candidate.directory_host?(host)

    %{
      name: Candidate.field(props["name"]),
      website_url: if(website?, do: row["url"]),
      domain: if(website?, do: String.replace_prefix(host, "www.", "")),
      employee_count: workforce(props["workforce"]),
      location: location(props["headquarters"])
    }
  end

  defp fields(:people, row, context) do
    props = properties(row, "person")
    first = Candidate.field(props["firstName"])
    last = Candidate.field(props["lastName"])
    history = current_history(props["workHistory"], context.name)

    %{
      name: [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> Candidate.field(),
      first_name: first,
      last_name: last,
      role: history_field(history, "title"),
      company_name: if(history, do: context.name),
      employer_match?: not is_nil(history)
    }
  end

  defp current_history(history, company) when is_list(history) do
    matches =
      Enum.filter(history, fn
        %{"dates" => %{"to" => nil}, "company" => %{"name" => name}} ->
          case Candidate.field(name) do
            nil -> false
            value -> normalized(value) == normalized(company)
          end

        _ ->
          false
      end)

    case matches do
      [one] -> one
      _ -> nil
    end
  end

  defp current_history(_, _), do: nil

  defp normalized(value),
    do: value |> String.trim() |> String.normalize(:nfc) |> String.downcase()

  defp history_field(nil, _), do: nil
  defp history_field(history, key), do: Candidate.field(history[key])
  defp workforce(%{"total" => n}) when is_integer(n) and n >= 0, do: n
  defp workforce(_), do: nil

  defp location(%{} = hq) do
    [Candidate.field(hq["city"]), Candidate.field(hq["country"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> Candidate.field()
  end

  defp location(_), do: nil

  defp excerpt(row) do
    Candidate.excerpt(row["text"]) ||
      case row["highlights"] do
        list when is_list(list) -> Enum.find_value(list, &Candidate.excerpt/1)
        _ -> nil
      end
  end

  @doc "One literal company-page source with the confirmed source URL and matching reported host."
  def normalize_contents(%{"results" => rows} = body, context, %Date{} = date)
      when is_list(rows) do
    with {:ok, context} <- Candidate.validate_context(context),
         {:ok, row} <- matching_contents(rows, context),
         text when is_binary(text) <- excerpt(row) do
      {:ok,
       %{
         kind: :contents,
         cost_dollars: cost(body),
         source: %{
           url: context.website_url,
           source_type: :company_site,
           retrieved_on: date,
           excerpt: text
         }
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def normalize_contents(_, _, _), do: {:error, :invalid_response}

  defp matching_contents([], _), do: {:error, :invalid_response}

  defp matching_contents(rows, context) do
    host = URI.parse(context.website_url).host

    matches =
      Enum.filter(rows, fn
        %{"url" => url} -> Candidate.safe_url?(url) and URI.parse(url).host == host
        _ -> false
      end)

    case matches do
      [row] -> {:ok, row}
      _ -> {:error, :source_mismatch}
    end
  end

  defp cost(%{"costDollars" => %{"total" => n}}) when is_number(n) and n >= 0 and n <= 1_000_000,
    do: n

  defp cost(_), do: nil
end
