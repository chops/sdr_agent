defmodule SdrAgent.Outreach.SuppressionMatch do
  @moduledoc """
  Source-owned suppression matching for the single-address read and its
  bounded Home batch. Changing the domain's matching semantics must change
  this one rule, not a second Home policy. No write/authorization authority.
  """

  import Ash.Expr, only: [expr: 1]

  @doc "Normalize the caller's email exactly as Outreach.matching_suppressions/2."
  def normalize(email), do: email |> to_string() |> String.trim() |> String.downcase()

  @doc "The source :matching filter; accepts a value or an Ash argument expression."
  def filter(email) do
    expr(
      (scope == :email and value == ^email) or
        (scope == :domain and value == fragment("split_part(?, '@', 2)", ^email))
    )
  end

  @doc "Union the same source rule for a caller-bounded list of normalized addresses."
  def batch_filter(emails) do
    Enum.reduce(emails, expr(false), fn email, acc ->
      rule = filter(email)
      expr(^acc or ^rule)
    end)
  end

  @doc "Match selected metadata from the batch to its address using the same exact-domain rule."
  def covers?(suppression, email) do
    email = normalize(email)

    expected =
      if suppression.scope == :domain, do: Enum.at(String.split(email, "@"), 1), else: email

    to_string(suppression.value) == expected
  end
end
