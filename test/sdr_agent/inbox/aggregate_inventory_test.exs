defmodule SdrAgent.Inbox.AggregateInventoryTest do
  @moduledoc "The reviewed metadata exception never becomes an output-field aggregate waiver."
  use ExUnit.Case, async: true

  alias SdrAgent.Test.ResultAggregateInventory, as: Inventory

  @external_resource "lib/sdr_agent/outreach/inbox.ex"
  @source File.read!(@external_resource)

  test "the actual source has exactly one explicitly field-authorized metadata aggregate" do
    assert %{violations: [], approved_count: 1} = Inventory.scan(@source)
  end

  test "field, kind, authorization, extra-site and function-name mutants are rejected" do
    mutants = [
      String.replace(@source, "{:total, :count}", "{:total, :max, field: :parsed_output}"),
      String.replace(
        @source,
        "expr_type: :integer",
        "field: :parsed_output, expr_type: :integer"
      ),
      String.replace(@source, "{:invalid, :sum,", "{:invalid, :max,"),
      String.replace(@source, "authorize_fields?: true", "authorize_fields?: false"),
      String.replace(@source, "authorize?: true", "authorize?: false"),
      String.replace(@source, "def count_drafts(opts)", "def renamed_count(opts)"),
      String.replace(@source, "def count_drafts(opts)", "def count_drafts(opts, extra)"),
      String.replace(
        @source,
        "defp base(actor) do",
        "defp base(actor) do\n Ash.max(actor, :parsed_output)"
      )
    ]

    extra_sites =
      for call <- [
            "Ash.aggregate!(actor, [])",
            "Query.aggregate(actor, :secret, :max, field: :parsed_output)",
            "Ash.Query.aggregate(actor, :secret, :max, field: :parsed_output)"
          ],
          do: String.replace(@source, "defp base(actor) do", "defp base(actor) do\n #{call}")

    # The formatting-only control is intentionally not a mutant. It proves
    # structural comparison ignores formatting, not security options.
    for mutant <- mutants ++ extra_sites do
      refute Inventory.scan(mutant).violations == []
    end

    assert Inventory.scan("# harmless formatting control\n" <> @source).violations == []
  end

  test "an identical approved-looking second call site is refused" do
    source =
      String.replace(@source, "defp base(actor) do", """
      def count_drafts(opts) do
        Ash.aggregate([
          {:total, :count},
          {:invalid, :sum, expr: expr(if(^invalid, do: 1, else: 0)), expr_type: :integer, default: 0},
          {:withheld, :sum, expr: expr(if(^withheld, do: 1, else: 0)), expr_type: :integer, default: 0}
        ], timeout: timeout, authorize?: true, authorize_fields?: true)
      end
      defp base(actor) do
      """)

    refute Inventory.scan(source).violations == []
  end
end
