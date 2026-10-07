defmodule SdrAgent.Integrations.ProvidersTest do
  @moduledoc """
  Fixture-backed integration providers (spec §17 anti-corruption layer):
  FakeCRM, FixtureSearch and FixtureWeb are deterministic over the S5 demo
  seed, never touch the network, return only reserved (synthetic) hosts or
  `fixture://` URLs, and refuse CRM write-back (DEFERRED in S2).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Demo.Fixtures
  alias SdrAgent.Integrations
  alias SdrAgent.Integrations.FakeCRM
  alias SdrAgent.Integrations.FixtureSearch
  alias SdrAgent.Integrations.FixtureWeb
  alias SdrAgent.Sales.Synthetic

  defp first_account, do: hd(Fixtures.accounts())

  test "the configured providers default to the fixtures" do
    assert Integrations.crm() == FakeCRM
    assert Integrations.search() == FixtureSearch
    assert Integrations.web() == FixtureWeb
  end

  test "FakeCRM returns the seeded contact, account and history deterministically" do
    contact = hd(Fixtures.contacts())
    account = first_account()

    assert {:ok, record} = FakeCRM.fetch_contact(contact.crm_external_id)
    assert {:ok, ^record} = FakeCRM.fetch_contact(contact.crm_external_id)
    assert record.source_url == "fixture://fake-crm/contacts/#{contact.crm_external_id}"
    assert record.contact["email"] == contact.email
    assert record.account["domain"] == account.domain
    assert record.account["employee_count"] == account.employee_count
    assert is_list(record.activities) and record.activities != []
    assert {:ok, decoded} = Jason.decode(record.content)
    assert decoded["contact"]["crm_external_id"] == contact.crm_external_id
    assert {:error, :not_found} = FakeCRM.fetch_contact("fake-crm-contact-unknown")
  end

  test "FakeCRM is read-only" do
    assert {:error, :read_only} = FakeCRM.update_contact("fake-crm-contact-01", %{title: "x"})
    assert {:error, :read_only} = FakeCRM.record_activity(%{type: "email"})
  end

  test "every seeded account has a website page and at least one recent search result" do
    for account <- Fixtures.accounts() do
      assert {:ok, page} = FixtureWeb.fetch(account.website_url), account.name
      assert page.url == account.website_url
      assert page.title =~ account.name
      assert page.content =~ account.name

      assert {:ok, [_ | _] = results} = FixtureSearch.search(account.name, domain: account.domain)

      for result <- results do
        assert Synthetic.fixture_url?(result.url), result.url
        assert {:ok, fetched} = FixtureWeb.fetch(result.url)
        assert String.contains?(fetched.content, result.snippet)
      end
    end
  end

  test "pages state the facts the qualification fixtures depend on" do
    for account <- Fixtures.accounts() do
      {:ok, page} = FixtureWeb.fetch(account.website_url)
      assert page.content =~ "#{account.employee_count} employees"
      assert page.content =~ account.industry
    end
  end

  test "search and fetch are deterministic; unknown inputs are refused" do
    account = first_account()

    assert FixtureSearch.search(account.name, domain: account.domain) ==
             FixtureSearch.search(account.name, domain: account.domain)

    assert {:ok, []} = FixtureSearch.search("No Such Company", domain: "nothing.test")
    assert {:error, :not_found} = FixtureWeb.fetch("https://nothing-here.test/")
    assert {:error, :host_not_allowed} = FixtureWeb.fetch("https://www.google.com/")
    assert {:error, :host_not_allowed} = FixtureWeb.fetch("ftp://brightpath-freight.test/")
  end
end
