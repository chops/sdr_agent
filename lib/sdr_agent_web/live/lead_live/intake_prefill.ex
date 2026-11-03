defmodule SdrAgentWeb.LeadLive.IntakePrefill do
  @moduledoc """
  Pure pre-fill for the owner's "Add prospect" form from a website search
  (ADR-0027). It turns one employer-matched person card, the confirmed
  CompanyContext and the provider company-page Source into the existing
  string-key form params of `SdrAgentWeb.LeadLive.OwnerIntakePanel`.

  The company page is source `"0"` (`company_site`, its URL must be the
  confirmed website). The person's literal excerpt, when present, is source
  `"1"` (`directory`). Email is always blank, and missing names or role are
  blank: the owner completes them. Nothing here reads or writes state, and
  the result is only a suggestion; the owner still previews and saves
  through `SdrAgent.Prototype.OwnerIntake`.
  """

  @person_keys [
    :kind,
    :url,
    :first_name,
    :last_name,
    :role,
    :employer_match?,
    :excerpt,
    :retrieved_on
  ]
  @company_keys [:name, :domain, :website_url]
  @source_keys [:url, :source_type, :retrieved_on, :excerpt]

  @type code :: :employer_unconfirmed | :source_missing | :source_mismatch | :invalid_input

  @doc "The form params, or a closed refusal code."
  @spec build(term(), term(), term()) :: {:ok, map()} | {:error, code()}
  def build(person, company, source) do
    with :ok <- shape(person, @person_keys),
         :ok <- shape(company, @company_keys),
         true <- Enum.all?(@company_keys, &is_binary(Map.fetch!(company, &1))),
         :ok <- matched(person),
         :ok <- page(source, company) do
      {:ok, params(person, company, source)}
    else
      false -> {:error, :invalid_input}
      {:error, code} -> {:error, code}
    end
  end

  defp shape(map, keys) when is_map(map),
    do: if(Enum.all?(keys, &Map.has_key?(map, &1)), do: :ok, else: {:error, :invalid_input})

  defp shape(_other, _keys), do: {:error, :invalid_input}

  defp matched(%{kind: :person, employer_match?: true}), do: :ok
  defp matched(_person), do: {:error, :employer_unconfirmed}

  defp page(nil, _company), do: {:error, :source_missing}

  defp page(source, %{website_url: website_url}) do
    with :ok <- shape(source, @source_keys),
         true <- is_binary(source.excerpt) and match?(%Date{}, source.retrieved_on) do
      if source.source_type == :company_site and source.url == website_url,
        do: :ok,
        else: {:error, :source_mismatch}
    else
      false -> {:error, :invalid_input}
      {:error, code} -> {:error, code}
    end
  end

  defp params(person, company, source) do
    %{
      "company_name" => company.name,
      "domain" => company.domain,
      "website_url" => company.website_url,
      "first_name" => text(person.first_name),
      "last_name" => text(person.last_name),
      "title" => text(person.role),
      "email" => "",
      "sources" => sources(person, source)
    }
  end

  defp sources(person, source) do
    site = entry(source.url, "company_site", source.retrieved_on, source.excerpt)

    if is_binary(person.excerpt) and person.excerpt != "" and is_binary(person.url) and
         match?(%Date{}, person.retrieved_on) do
      %{
        "0" => site,
        "1" => entry(person.url, "directory", person.retrieved_on, person.excerpt)
      }
    else
      %{"0" => site}
    end
  end

  defp entry(url, type, date, excerpt),
    do: %{
      "url" => url,
      "source_type" => type,
      "retrieved_on" => Date.to_iso8601(date),
      "excerpt" => excerpt
    }

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""
end
