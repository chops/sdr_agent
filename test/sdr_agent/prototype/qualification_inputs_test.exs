defmodule SdrAgent.Prototype.QualificationInputsTest do
  @moduledoc """
  IF-6 importable rule 6, qualification inputs (interfaces r6; Codex seed-r4
  flag 3 and ruling 6; plan r7 section 6): an importable row needs one
  verified `size` fact marked `company_size_stated` and one verified
  `location` fact marked `company_location_stated`, each with an excerpt and
  a `stated_on` inside the freshness floor `2025-10-28 ≤ stated_on ≤
  date(checked_at)` (the date in `checked_at`'s own offset). A future date
  refuses the file; a null date or one before the floor is
  `insufficient_source`. Nothing is prefilled or coerced. Synthetic
  fixtures; pure.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.DossierParser

  # f1 is the size quote and f2 the location fact of `F.company/1`.
  defp select(row, edit \\ & &1) do
    dossier = F.dossier([row])
    sha = F.sha256(F.encode(dossier))
    manifest = F.parsed_manifest(edit.(F.manifest({dossier, sha})))
    DossierParser.select(dossier, manifest, [row["row_id"]], F.scratch_dir!())
  end

  defp dated(fact_index, date), do: F.put(F.company(1), ["facts", fact_index, "stated_on"], date)

  defp edit_result(item, fun) do
    fn manifest ->
      F.update(manifest, ["results"], fn results ->
        Enum.map(results, &if(&1["item"] == item, do: fun.(&1), else: &1))
      end)
    end
  end

  describe "the freshness floor (ruling 6), with the check on 2026-10-27 (-06:00)" do
    test "2025-10-27, the day before the floor, is insufficient_source" do
      assert select(dated(0, "2025-10-27")) == {:error, {"companies[0]", :insufficient_source}}
      assert select(dated(1, "2025-10-27")) == {:error, {"companies[0]", :insufficient_source}}
    end

    test "the floor itself and the check date both pass" do
      assert match?({:ok, [_]}, select(dated(0, "2025-10-28")))
      assert match?({:ok, [_]}, select(dated(1, "2026-10-27")))
    end

    test "a statement dated after its check refuses the file" do
      # 23:00 at -06:00 is already 2026-10-27 in UTC; the check date is the 26th.
      late = edit_result("fact:f1", &Map.put(&1, "checked_at", "2026-10-26T23:00:00-06:00"))

      assert select(dated(0, "2026-10-27"), late) ==
               {:error, {"companies[0].facts[0].stated_on", :future_date}}
    end

    test "a positive offset across midnight: the check date is the local date, not UTC's" do
      # 01:00 at +05:00 is still 2026-10-26 in UTC; the check date is the 27th.
      early = edit_result("fact:f1", &Map.put(&1, "checked_at", "2026-10-27T01:00:00+05:00"))
      assert match?({:ok, [_]}, select(dated(0, "2026-10-27"), early))
    end

    test "a null stated_on is insufficient_source" do
      assert select(dated(0, nil)) == {:error, {"companies[0]", :insufficient_source}}
      assert select(dated(1, nil)) == {:error, {"companies[0]", :insufficient_source}}
    end
  end

  describe "the relations and the verified excerpts" do
    test "a size or location fact without its relation mark is insufficient_source" do
      assert select(F.company(1), edit_result("fact:f1", &Map.put(&1, "relation", nil))) ==
               {:error, {"companies[0]", :insufficient_source}}

      assert select(F.company(1), edit_result("fact:f2", &Map.put(&1, "relation", nil))) ==
               {:error, {"companies[0]", :insufficient_source}}
    end

    test "an unverified size or location fact is insufficient_source" do
      for status <- ["not_found", "unreachable"] do
        assert select(F.company(1), edit_result("fact:f2", &Map.put(&1, "result", status))) ==
                 {:error, {"companies[0]", :insufficient_source}}
      end
    end

    test "a row with no size fact, or no location fact, is insufficient_source" do
      no_size = F.update(F.company(1), ["facts"], &List.delete_at(&1, 0))
      assert select(no_size) == {:error, {"companies[0]", :insufficient_source}}

      no_location = F.put(F.company(1), ["facts", 1, "topic"], "industry")
      assert select(no_location) == {:error, {"companies[0]", :insufficient_source}}
    end

    test "a directory may support the company size when the check confirms that statement" do
      row =
        F.company(1)
        |> Map.update!(
          "sources",
          &(&1 ++ [F.source("s3", "https://company-directory.test/acme1", "directory")])
        )
        |> F.put(["facts", 0, "source_id"], "s3")

      assert match?({:ok, [_]}, select(row))
    end
  end
end
