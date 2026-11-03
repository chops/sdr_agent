defmodule SdrAgent.Discovery.Candidate do
  @moduledoc """
  Pure validation of ephemeral Exa findings and owner-confirmed company context
  (ADR-0027). No persistence, network, authority or email inference.

  Directory/profile hosts never suggest or confirm an employer website:
  linkedin.com, crunchbase.com, x.com, twitter.com, facebook.com, github.com,
  wikipedia.org, wikidata.org, exa.ai, wellfound.com, ycombinator.com,
  bloomberg.com and pitchbook.com (including their subdomains).
  """

  alias SdrAgent.Prototype.DossierParser.Rules

  @directories ~w(linkedin.com crunchbase.com x.com twitter.com facebook.com github.com wikipedia.org wikidata.org exa.ai wellfound.com ycombinator.com bloomberg.com pitchbook.com)

  @doc "Validate the closed server-side action shape before any paid egress."
  def request(%{kind: :company, query: query} = request) when map_size(request) == 2 do
    if query?(query), do: {:ok, request}, else: {:error, :invalid_input}
  end

  def request(%{kind: :people, query: query, company: company} = request)
      when map_size(request) == 3 do
    with true <- query?(query),
         {:ok, company} <- validate_context(company) do
      {:ok, %{request | company: company}}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def request(%{kind: :contents, company: company} = request) when map_size(request) == 2 do
    with {:ok, company} <- validate_context(company), do: {:ok, %{request | company: company}}
  end

  def request(_), do: {:error, :invalid_input}

  defp query?(query) when is_binary(query) and byte_size(query) in 1..500,
    do: String.valid?(query) and String.trim(query) != "" and not String.contains?(query, <<0>>)

  defp query?(_), do: false

  @doc "A bounded public HTTPS source URL using existing intake rules."
  def safe_url?(url) when is_binary(url),
    do: String.valid?(url) and Rules.url(url, "") == :ok

  def safe_url?(_), do: false

  @doc "Whether a host is a known profile/directory, not an official-site suggestion."
  def directory_host?(host) when is_binary(host),
    do: Enum.any?(@directories, &(host == &1 or String.ends_with?(host, "." <> &1)))

  def directory_host?(_), do: true

  @doc "One intake-sized identity field, normalized or unknown; never truncated."
  def field(value) when is_binary(value) and byte_size(value) in 1..200 do
    if String.valid?(value) and not Regex.match?(~r/[\x00-\x1f\x7f]/u, value) do
      normalized = value |> String.trim() |> String.normalize(:nfc)
      if byte_size(normalized) in 1..200, do: normalized
    end
  end

  def field(_), do: nil

  @doc "One exact UTF-8-safe source-text prefix, or unknown; no synthesized text."
  def excerpt(value) when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      value |> binary_part(0, min(byte_size(value), 2000)) |> utf8_prefix()
    end
  end

  def excerpt(_), do: nil

  defp utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end

  @doc "Confirm explicit official-site inputs for a server-held company candidate."
  def company_context(%{kind: :company, id: id, name: name}, %{website_url: url, domain: domain}) do
    validate_context(%{id: id, name: name, website_url: url, domain: domain})
  end

  def company_context(_, _), do: {:error, :invalid_input}

  @doc "Revalidate company context before each provider operation."
  def validate_context(%{id: id, name: name, website_url: url, domain: domain})
      when is_binary(id) and byte_size(id) in 1..200 and is_binary(domain) do
    domain = String.downcase(String.trim(domain), :ascii)

    with name when is_binary(name) <- field(name),
         true <- safe_url?(url),
         true <- byte_size(domain) in 1..253 and byte_size(domain) == String.length(domain),
         true <- Rules.public_host?(domain),
         host <- URI.parse(url).host,
         false <- directory_host?(host),
         true <- Rules.company_host?(host, domain) do
      {:ok, %{id: id, name: name, domain: domain, website_url: url}}
    else
      _ -> {:error, :invalid_input}
    end
  rescue
    _ -> {:error, :invalid_input}
  end

  def validate_context(_), do: {:error, :invalid_input}
end
