defmodule SdrAgent.Outreach.UnsubscribeRule do
  @moduledoc """
  The deterministic unsubscribe rule for replies (S2 Reply: "Deterministic
  unsubscribe rule (versioned, recorded as unsubscribe_rule Decision) →
  Suppression"; spec §8: the model never decides legal suppression).

  Version 1: the subject and body are lowercased, quoted lines (`>`)
  are dropped and whitespace is collapsed; the reply asks to unsubscribe
  when any phrase of `phrases/0` occurs. `evaluate/2` returns the outcome
  (`"unsubscribe"` or `"none"`) and the matched phrases, which the Decision
  records with the body hash. The rule only ever adds a suppression.
  """

  @id "outreach.unsubscribe_rule"
  @version "1"
  @phrases [
    "unsubscribe",
    "opt out",
    "opt-out",
    "remove me",
    "take me off",
    "stop emailing",
    "stop contacting",
    "do not contact",
    "don't contact",
    "no more emails"
  ]

  @doc "Rule id recorded on the Decision."
  def id, do: @id

  @doc "Rule version recorded on the Decision."
  def version, do: @version

  @doc "The phrases of this rule version."
  def phrases, do: @phrases

  @doc "`{outcome, matched_phrases}` for a reply's `subject` and `body`."
  @spec evaluate(String.t() | nil, String.t()) :: {String.t(), [String.t()]}
  def evaluate(subject, body) do
    text = normalise((subject || "") <> "\n" <> body)
    matched = Enum.filter(@phrases, &String.contains?(text, &1))
    {if(matched == [], do: "none", else: "unsubscribe"), matched}
  end

  defp normalise(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), ">"))
    |> Enum.join(" ")
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end
end
