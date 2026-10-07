defmodule SdrAgent.Integrations.Fixtures do
  @moduledoc """
  Deterministic research sources over the S5 demo seed
  (`SdrAgent.Demo.Fixtures`): for every fictional company, its CRM record,
  its website page, one news article and the search results pointing at
  both. Everything is derived from the seed rows and `Fixtures.epoch/0`, so
  every run produces byte-identical content; every URL is a reserved
  (synthetic) host or `fixture://`.

  The text states the facts the designated outcomes rest on — employee
  count, industry and geography on the website, and a buying trigger
  ("hiring SDRs", "recent funding round") only for accounts designated to
  qualify (or to qualify and then be suppressed by S8).
  """

  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Demo.Fixtures

  @geographies %{
    "US" => "the United States",
    "Canada" => "Canada",
    "Germany" => "Germany"
  }

  @doc "The CRM record of a contact by CRM id, or nil."
  def crm_record(crm_id) do
    with %{} = contact <- Enum.find(Fixtures.contacts(), &(&1.crm_external_id == crm_id)) do
      account = Enum.find(Fixtures.accounts(), &(&1.id == contact.account_id))
      contact_fields = crm_contact(contact)
      account_fields = crm_account(account)
      activities = activities(contact, account)

      %{
        source_url: "fixture://fake-crm/contacts/#{crm_id}",
        title: "CRM record: #{contact.first_name} #{contact.last_name}",
        content:
          Canonical.encode!(%{
            "contact" => contact_fields,
            "account" => account_fields,
            "activities" => activities
          }),
        contact: contact_fields,
        account: account_fields,
        activities: activities
      }
    end
  end

  @doc "Every fixture page keyed by normalized URL."
  def pages do
    Fixtures.accounts()
    |> Enum.flat_map(&[website(&1), news(&1)])
    |> Map.new(&{normalize(&1.url), &1})
  end

  @doc "Search results for a company (matched by `domain`, else by name)."
  def search_results(query, domain) do
    Fixtures.accounts()
    |> Enum.filter(&(&1.domain == domain or String.downcase(&1.name) == String.downcase(query)))
    |> Enum.flat_map(fn account ->
      for page <- [news(account), website(account)] do
        %{
          url: page.url,
          title: page.title,
          snippet: first_sentence(page.content),
          published_at: page.published_at
        }
      end
    end)
  end

  @doc "A URL without a trailing slash, for lookups."
  def normalize(url), do: String.trim_trailing(url, "/")

  defp website(account) do
    %{
      url: account.website_url,
      title: "#{account.name} — #{account.industry}",
      content:
        "#{account.name} is a #{account.industry} company serving mid-market shippers. " <>
          "The company has #{account.employee_count} employees and is based in " <>
          "#{Map.fetch!(@geographies, account.geography)}. " <> hiring(account),
      content_type: "text/plain",
      published_at: nil,
      source_type: :company_website,
      trust_level: :medium
    }
  end

  defp news(account) do
    {title, content} =
      if trigger?(account) do
        {"#{account.name} raises a growth round and expands its revenue team",
         "#{account.name} closed a recent funding round to expand its revenue team. " <>
           "The company plans to add SDRs and a Head of Revenue Operations this year."}
      else
        {"#{account.name} posts a quarterly update",
         "#{account.name} reported steady results for the quarter. " <>
           "The company did not announce new sales hiring."}
      end

    %{
      url: "https://news.example.test/#{slug(account)}/revenue-team",
      title: title,
      content: content,
      content_type: "text/plain",
      published_at: DateTime.add(Fixtures.epoch(), -7, :day),
      source_type: :news,
      trust_level: :medium
    }
  end

  defp hiring(account) do
    if trigger?(account),
      do: "#{account.name} is hiring SDRs to grow its outbound team this quarter.",
      else: "#{account.name} has no open sales roles this quarter."
  end

  defp trigger?(account), do: account.expected_outcome in [:qualify, :suppressed]

  defp crm_contact(contact) do
    %{
      "crm_external_id" => contact.crm_external_id,
      "first_name" => contact.first_name,
      "last_name" => contact.last_name,
      "email" => contact.email,
      "title" => contact.title,
      "timezone" => contact.timezone
    }
  end

  defp crm_account(account) do
    %{
      "crm_external_id" => account.crm_external_id,
      "name" => account.name,
      "domain" => account.domain,
      "industry" => account.industry,
      "employee_count" => account.employee_count,
      "geography" => account.geography
    }
  end

  defp activities(contact, account) do
    [
      %{
        "type" => "note",
        "occurred_at" => DateTime.to_iso8601(DateTime.add(Fixtures.epoch(), -30, :day)),
        "text" =>
          "#{contact.first_name} #{contact.last_name} (#{contact.title}) imported from the " <>
            "fixture CRM for #{account.name}. No previous outreach."
      }
    ]
  end

  defp slug(account), do: account.domain |> String.split(".") |> hd()

  defp first_sentence(content) do
    case String.split(content, ". ", parts: 2) do
      [sentence, _rest] -> sentence <> "."
      [only] -> only
    end
  end
end
