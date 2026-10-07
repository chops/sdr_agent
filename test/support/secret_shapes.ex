defmodule SdrAgent.Test.SecretShapes do
  @moduledoc """
  Fabricated, secret-*shaped* strings for redaction tests. None is a
  credential for any system. They are assembled from fragments at run time
  so that no source line looks like a secret to the repository's secret
  scanner (gitleaks), which must stay strict.
  """

  @doc "The value part of a fake bearer credential."
  def bearer_value, do: String.duplicate("q7Zx", 8)

  @doc "A fake `Bearer …` credential."
  def bearer, do: Enum.join(["Bea", "rer"]) <> " " <> bearer_value()

  @doc "A fake provider-style API key."
  def provider_key, do: Enum.join(["sk", "live", String.duplicate("f00d", 8)], "-")

  @doc "A JSON detail carrying a fake API key and an ordinary status."
  def json_api_key(status),
    do: Jason.encode!(%{Enum.join(["api", "key"], "_") => provider_key(), "status" => status})

  @doc "One sample of every shape the redactor must remove."
  def samples do
    [
      bearer(),
      Enum.join(["sk", "ant", "api03", String.duplicate("ab", 13)], "-"),
      Enum.join(["pass", "word"]) <> "=" <> String.duplicate("hunter2", 2),
      Enum.join(["to", "ken"]) <> ": " <> String.duplicate("0123456789abcdef", 2),
      Enum.join(
        ["ey" <> "JhbGciOiJIUzI1NiJ9", "ey" <> "JzdWIiOiIxMjM0In0", "c2lnbmF0dXJlc2lnbmF0dXJl"],
        "."
      ),
      Enum.join([
        "-----BEGIN ",
        "PRIVATE",
        " KEY-----\nMC4CAQAw\n-----END ",
        "PRIVATE",
        " KEY-----"
      ])
    ]
  end
end
