defmodule SdrAgent.Prototype.OwnerIntakeInput do
  @moduledoc """
  Bounded, pure owner-intake/1 normalization. Identity fields normalize;
  validated source URLs and excerpt UTF-8 bytes remain exact. Existing dossier
  host rules admit reserved test hosts only in hermetic builds. Performs no input or output.
  """
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Prototype.DossierParser.Rules

  @keys ~w(company_name domain website_url first_name last_name title email sources)
  @source_keys ~w(url source_type retrieved_on excerpt)
  @types ~w(company_site person_authored attributed_third_party directory third_party)
  @roles ~w(admin billing careers contact hello help hr info jobs marketing office sales security support team webmaster noreply no-reply)
  @free ~w(gmail.com googlemail.com yahoo.com outlook.com hotmail.com icloud.com proton.me protonmail.com)

  @doc "Normalized input and canonical digest, or a value-free refusal."
  def normalize(params) when is_map(params) do
    with true <- Enum.sort(Map.keys(params)) == Enum.sort(@keys),
         {:ok, encoded} <- Jason.encode(params),
         true <- byte_size(encoded) <= 16_384,
         true <- Enum.all?(@keys -- ["sources"], &valid_string?(params[&1])),
         normalized <- normalize_fields(params),
         true <- valid_fields?(normalized),
         {:ok, sources} <- sources(normalized["sources"]) do
      input = Map.put(normalized, "sources", sources)
      {:ok, input, Canonical.sha256(%{"format" => "owner-intake/1", "input" => input})}
    else
      _ -> {:error, :invalid_input}
    end
  rescue
    _ -> {:error, :invalid_input}
  end

  def normalize(_), do: {:error, :invalid_input}

  defp normalize_fields(params) do
    params
    |> Map.update!("domain", &String.downcase(String.trim(&1), :ascii))
    |> Map.update!("email", &String.downcase(String.trim(&1), :ascii))
    |> then(fn map ->
      Enum.reduce(~w(company_name first_name last_name title), map, fn key, acc ->
        Map.update!(acc, key, &String.normalize(String.trim(&1), :nfc))
      end)
    end)
  end

  defp valid_fields?(p) do
    Enum.all?(~w(company_name first_name last_name), &(byte_size(p[&1]) in 1..200)) and
      byte_size(p["title"]) <= 200 and
      ascii?(p["domain"]) and Rules.public_host?(p["domain"]) and
      url?(p["website_url"]) and
      Rules.company_host?(URI.parse(p["website_url"]).host, p["domain"]) and
      email?(p["email"], p["domain"])
  end

  defp email?(email, domain) do
    with true <- ascii?(email) and byte_size(email) <= 254,
         [local, ^domain] <- String.split(email, "@"),
         true <- Regex.match?(~r/\A[a-z0-9.!#$%&'*+\/=?^_{|}~-]{1,64}\z/, local),
         false <- local in @roles,
         false <- hd(String.split(local, "+", parts: 2)) in @roles,
         false <- domain in @free do
      true
    else
      _ -> false
    end
  end

  defp sources(list) when is_list(list) and length(list) in 1..3 do
    if Enum.all?(list, &source?/1) and length(Enum.uniq_by(list, & &1["url"])) == length(list),
      do: {:ok, list},
      else: {:error, :invalid_input}
  end

  defp sources(_), do: {:error, :invalid_input}

  defp source?(source) when is_map(source) do
    with true <- Enum.sort(Map.keys(source)) == Enum.sort(@source_keys),
         true <- Enum.all?(@source_keys, &valid_string?(source[&1])),
         true <- url?(source["url"]),
         true <- source["source_type"] in @types,
         true <- byte_size(source["excerpt"]) in 1..2000,
         {:ok, date} <- Date.from_iso8601(source["retrieved_on"]),
         true <- Date.compare(date, SdrAgent.Clock.utc_now() |> DateTime.to_date()) != :gt do
      true
    else
      _ -> false
    end
  end

  defp source?(_), do: false
  defp url?(url), do: byte_size(url) <= 2048 and Rules.url(url, "") == :ok
  defp valid_string?(v), do: is_binary(v) and String.valid?(v) and not String.contains?(v, <<0>>)
  defp ascii?(v), do: byte_size(v) == String.length(v) and String.printable?(v)
end
