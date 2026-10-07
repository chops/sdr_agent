defmodule SdrAgent.Research.AppendOnlyTest do
  @moduledoc "S2 APPEND-ONLY for the Research tables S5 creates: raw SQL cannot change history."
  use SdrAgent.AuditCase, async: false

  alias Ecto.Adapters.SQL
  alias SdrAgent.SalesFixtures, as: F

  @tables ~w(research_artifacts evidence_claims qualifications qualification_evidences)

  test "every Research table carries its UPDATE/DELETE and TRUNCATE triggers" do
    for table <- @tables do
      %{rows: rows} =
        SQL.query!(
          SdrAgent.Repo,
          """
          SELECT tgname FROM pg_trigger
           WHERE tgrelid = $1::text::regclass AND NOT tgisinternal AND tgenabled = 'O'
          """,
          [table]
        )

      names = List.flatten(rows)
      assert "#{table}_guard_row" in names, "#{table} lacks its row trigger: #{inspect(names)}"
      assert "#{table}_guard_truncate" in names, "#{table} lacks its truncate trigger"
    end
  end

  describe "raw SQL" do
    setup do
      tenant = bootstrap!()
      _ = F.qualified_lead!(tenant)
      :ok
    end

    test "UPDATE, DELETE and TRUNCATE are rejected" do
      for {table, column} <- [
            {"research_artifacts", "title"},
            {"evidence_claims", "claim"},
            {"qualifications", "reason"},
            {"qualification_evidences", "trace_id"}
          ] do
        for sql <- [
              "UPDATE #{table} SET #{column} = 'x'",
              "DELETE FROM #{table}",
              "TRUNCATE #{table} CASCADE"
            ] do
          assert {:error, %Postgrex.Error{postgres: %{message: message}}} = raw_error(sql)
          assert message =~ "append-only", "#{sql}: #{message}"
        end
      end
    end
  end
end
