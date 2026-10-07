defmodule SdrAgent.Sales.Synthetic do
  @moduledoc """
  The synthetic-data guard (ADR-0009 §9, S2 Account/Contact/Campaign): in the
  MVP every account domain, contact email and sender address — and every
  research source host — must be under a reserved name, so no fixture can
  point at a real organisation or mailbox.

  Reserved names: the top-level domains `.test`, `.example`, `.invalid`
  (RFC 2606/6761) and the second-level domains `example.com`, `example.net`,
  `example.org` with any subdomain. A domain is a lowercase host name of at
  least two labels with no scheme, port or path.
  """

  @reserved_tlds ~w(test example invalid)
  @reserved_domains ~w(example.com example.net example.org)
  @label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @host ~r/^(?=.{1,253}$)#{@label}(?:\.#{@label})+$/

  @doc "Human-readable rule, used in validation messages."
  def rule, do: "must be under a reserved name (.test, .example, .invalid, example.com/.net/.org)"

  @doc "True when `domain` is a host name under a reserved name."
  @spec reserved_domain?(String.t()) :: boolean()
  def reserved_domain?(domain) when is_binary(domain) do
    domain = String.downcase(domain)

    Regex.match?(@host, domain) and
      (tld(domain) in @reserved_tlds or
         Enum.any?(@reserved_domains, &(domain == &1 or String.ends_with?(domain, "." <> &1))))
  end

  def reserved_domain?(_other), do: false

  @doc "True when `email` is `local@domain` with a reserved domain."
  @spec reserved_email?(String.t()) :: boolean()
  def reserved_email?(email) when is_binary(email) do
    case String.split(email, "@") do
      [local, domain] -> Regex.match?(~r/^[^\s@]+$/, local) and reserved_domain?(domain)
      _ -> false
    end
  end

  def reserved_email?(_other), do: false

  @doc """
  True when `url` is a fixture URL (`fixture://…`) or an http(s) URL whose
  host is reserved.
  """
  @spec fixture_url?(String.t()) :: boolean()
  def fixture_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "fixture", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] -> reserved_domain?(host)
      _ -> false
    end
  end

  def fixture_url?(_other), do: false

  defp tld(domain), do: domain |> String.split(".") |> List.last()
end
