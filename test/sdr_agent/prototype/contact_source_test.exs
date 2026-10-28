defmodule SdrAgent.Prototype.ContactSourceTest do
  @moduledoc """
  IF-6 importable rule under contact-source ruling B (interfaces r6; Codex
  rulings 4 and 5; plan r7 section 6): a person-to-address link published
  on a qualifying page, inside one literal UTF-8 byte window of at most 300
  bytes, AND confirmed by the spot-check's `person_address_linked` mark; a
  current role confirmed by `person_role_current`; no directory, no
  conflict, no mention-only page; selection of at most 3 eligible rows;
  zero eligible rows reported, never weakened. Synthetic fixtures; pure.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.DossierParser

  @email "jordan@acme1.test"

  # The parsed dossier (the decoded map, as `parse/1` returns it) and the
  # parsed manifest (default: every claim and excerpt fact of the flagged
  # rows verified with its relation), after `edit` (a function of the
  # manifest map). Built without the parsers, so these tests reach the
  # importable rule directly.
  defp inputs(rows, edit \\ & &1) do
    dossier = F.dossier(rows)
    sha = F.sha256(F.encode(dossier))
    {dossier, F.parsed_manifest(edit.(F.manifest({dossier, sha})))}
  end

  defp select(rows, edit \\ & &1, dir \\ F.scratch_dir!()) do
    {dossier, manifest} = inputs(rows, edit)
    DossierParser.select(dossier, manifest, Enum.map(rows, & &1["row_id"]), dir)
  end

  defp edit_result(row_id, item, fun),
    do: fn manifest -> F.update(manifest, ["results"], &edit_matching(&1, row_id, item, fun)) end

  defp edit_matching(results, row_id, item, fun),
    do:
      Enum.map(
        results,
        &if(&1["row_id"] == row_id and &1["item"] == item, do: fun.(&1), else: &1)
      )

  defp email_excerpt(row, excerpt),
    do: F.put(row, ["contact", "evidence", "email", "excerpt"], excerpt)

  # Renames the contact of `row` everywhere its claims need the name.
  defp with_name(row, name) do
    row
    |> F.put(["contact", "name"], name)
    |> F.put(["contact", "evidence", "name", "excerpt"], "#{name}, Head of Growth")
    |> F.put(["contact", "evidence", "role", "excerpt"], "#{name}, Head of Growth")
    |> email_excerpt("#{name}: #{@email}")
  end

  test "a row passing the whole rule is selected", _ctx do
    assert match?({:ok, [%{"row_id" => "row-1"}]}, select([F.company(1)]))
  end

  describe "the email claim: an explicit published person-to-address link" do
    test "a mention-only page (the name without the address) is link_unconfirmed" do
      row = email_excerpt(F.company(1), "Jordan Testperson spoke at the synthetic meetup.")
      assert select([row]) == {:error, {"companies[0]", :link_unconfirmed}}
    end

    test "an address shown without the person is link_unconfirmed" do
      row = email_excerpt(F.company(1), "Write to us: #{@email}")
      assert select([row]) == {:error, {"companies[0]", :link_unconfirmed}}
    end

    test "the bound passes the bytes, but no person_address_linked mark is link_unconfirmed" do
      unmarked = edit_result("row-1", "claim:email", &Map.put(&1, "relation", nil))
      assert select([F.company(1)], unmarked) == {:error, {"companies[0]", :link_unconfirmed}}
    end

    test "a byline and an unrelated mailbox inside one window are refused without the mark" do
      row =
        email_excerpt(
          F.company(1),
          "By Jordan Testperson. Questions? #{@email} reaches our front desk."
        )

      unmarked = edit_result("row-1", "claim:email", &Map.put(&1, "relation", nil))
      assert select([row], unmarked) == {:error, {"companies[0]", :link_unconfirmed}}
    end

    test "the window is exactly 300 bytes at most; 301 is refused" do
      name = "Jordan Testperson"
      ok = email_excerpt(F.company(1), name <> String.duplicate("x", 300 - 17 - 17) <> @email)
      assert byte_size(get_in(ok, ["contact", "evidence", "email", "excerpt"])) == 300
      assert match?({:ok, [_]}, select([ok]))

      # Two-byte "ë": 300 characters, 301 bytes.
      multibyte = "Zoë Testperson"

      over =
        with_name(F.company(1), multibyte)
        |> email_excerpt(multibyte <> String.duplicate("x", 269) <> @email)

      excerpt = get_in(over, ["contact", "evidence", "email", "excerpt"])
      assert {String.length(excerpt), byte_size(excerpt)} == {300, 301}
      assert select([over]) == {:error, {"companies[0]", :link_unconfirmed}}

      at =
        with_name(F.company(1), multibyte)
        |> email_excerpt(multibyte <> String.duplicate("x", 268) <> @email)

      assert match?({:ok, [_]}, select([at]))
    end

    test "the window may come from any pair of occurrences, never stitched across them" do
      name = "Jordan Testperson"

      near =
        email_excerpt(
          F.company(1),
          name <> String.duplicate("y", 280) <> " — " <> name <> " " <> @email
        )

      assert match?({:ok, [_]}, select([near]))
    end

    test "an artifact's bytes may carry the link when the excerpt is null" do
      dir = F.scratch_dir!()
      name = "Jordan Testperson"

      ref =
        F.artifact!(
          dir,
          "s1.txt",
          "Header\n" <> name <> String.duplicate("z", 266) <> @email <> "\nFooter"
        )

      row =
        F.company(1)
        |> F.put(["contact", "evidence", "email", "excerpt"], nil)
        |> F.put(["contact", "evidence", "email", "artifact"], ref)

      assert match?({:ok, [_]}, select([row], & &1, dir))

      far = F.artifact!(dir, "s1-far.txt", name <> String.duplicate("z", 267) <> @email)
      row = F.put(row, ["contact", "evidence", "email", "artifact"], far)
      assert select([row], & &1, dir) == {:error, {"companies[0]", :link_unconfirmed}}
    end

    test "a person_authored page and an attributed post qualify with their own basis" do
      authored =
        F.company(1)
        |> Map.update!(
          "sources",
          &(&1 ++ [F.source("s3", "https://jordan-writes.test/contact", "person_authored")])
        )
        |> F.put(
          ["contact", "evidence", "email"],
          F.claim(
            "s3",
            "person_authored",
            "Written by Jordan Testperson",
            "Jordan Testperson: #{@email}"
          )
        )

      assert match?({:ok, [_]}, select([authored]))

      post =
        F.company(1)
        |> Map.update!(
          "sources",
          &(&1 ++ [F.source("s3", "https://news.test/acme1-post", "attributed_third_party")])
        )
        |> F.put(
          ["contact", "evidence", "email"],
          F.claim(
            "s3",
            "attributed_post",
            "Posted by Jordan Testperson",
            "Jordan Testperson: #{@email}"
          )
        )

      assert match?({:ok, [_]}, select([post]))
    end
  end

  describe "the role and name claims" do
    test "a role excerpt without the role, or without the name, is role_unconfirmed" do
      no_role =
        F.put(
          F.company(1),
          ["contact", "evidence", "role", "excerpt"],
          "Jordan Testperson works here."
        )

      assert select([no_role]) == {:error, {"companies[0]", :role_unconfirmed}}

      no_name =
        F.put(F.company(1), ["contact", "evidence", "role", "excerpt"], "Our Head of Growth")

      assert select([no_name]) == {:error, {"companies[0]", :role_unconfirmed}}
    end

    test "a role without person_role_current is role_unconfirmed" do
      unmarked = edit_result("row-1", "claim:role", &Map.put(&1, "relation", nil))
      assert select([F.company(1)], unmarked) == {:error, {"companies[0]", :role_unconfirmed}}
    end
  end

  describe "conflicts and contact kinds" do
    test "another person's name next to the address is other_person_source" do
      row = F.put(F.company(1), ["contact", "conflict"], "other_person_source")

      assert DossierParser.parse(F.encode(F.dossier([row]))) ==
               {:error, {"companies[0]", :other_person_source}}
    end

    test "any other conflict is source_conflict" do
      for conflict <- ["address_link_mismatch", "other"] do
        row = F.put(F.company(1), ["contact", "conflict"], conflict)

        assert DossierParser.parse(F.encode(F.dossier([row]))) ==
                 {:error, {"companies[0]", :source_conflict}}
      end
    end

    test "a declared type the spot-check did not confirm is not importable" do
      conflicted = edit_result("row-1", "claim:email", &Map.put(&1, "result", "conflict"))
      assert select([F.company(1)], conflicted) == {:error, {"companies[0]", :source_conflict}}
    end

    test "a flagged role mailbox or unavailable email refuses the file" do
      row = F.put(F.company(1), ["contact", "email_kind"], "role_mailbox")

      assert DossierParser.parse(F.encode(F.dossier([row]))) ==
               {:error, {"companies[0]", :role_mailbox}}

      row =
        F.company(1)
        |> F.put(["contact", "email_kind"], "unavailable")
        |> F.put(["contact", "email"], nil)
        |> F.put(["contact", "evidence", "email"], nil)

      assert DossierParser.parse(F.encode(F.dossier([row]))) ==
               {:error, {"companies[0]", :email_unavailable}}
    end
  end

  describe "usable evidence" do
    test "no verified company-site quote or fact with an excerpt is insufficient_source" do
      third =
        F.company(1)
        |> Map.update!(
          "sources",
          &(&1 ++ [F.source("s3", "https://news.test/acme1", "third_party")])
        )
        |> F.update(["facts"], fn facts ->
          Enum.map(facts, &if(&1["source_id"] == "s2", do: %{&1 | "source_id" => "s3"}, else: &1))
        end)

      assert select([third]) == {:error, {"companies[0]", :insufficient_source}}
    end
  end

  describe "any invalid flagged row refuses the input, whichever rows are selected (R2)" do
    # row-1 is valid and selected; row-2 is flagged importable but fails.
    defp refused_everywhere!(rows, edit, dir, expected) do
      {dossier, manifest} = inputs(rows, edit)

      for {name, result} <- [
            {"select/4", DossierParser.select(dossier, manifest, ["row-1"], dir)},
            {"eligible_rows/3", DossierParser.eligible_rows(dossier, manifest, dir)},
            {"import_plan/4", DossierParser.import_plan(dossier, manifest, "row-1", dir)},
            {"eligibility/4", DossierParser.eligibility(dossier, manifest, "row-1", dir)}
          ] do
        assert result == expected,
               "#{name} returned #{inspect(result)} past an invalid flagged row-2, " <>
                 "expected #{inspect(expected)}"
      end
    end

    test "another flagged row without its person_address_linked mark" do
      unmarked = edit_result("row-2", "claim:email", &Map.put(&1, "relation", nil))

      refused_everywhere!(
        [F.company(1), F.company(2)],
        unmarked,
        F.scratch_dir!(),
        {:error, {"companies[1]", :link_unconfirmed}}
      )
    end

    test "another flagged row missing its role result" do
      missing = fn manifest ->
        F.update(manifest, ["results"], fn results ->
          Enum.reject(results, &(&1["row_id"] == "row-2" and &1["item"] == "claim:role"))
        end)
      end

      refused_everywhere!(
        [F.company(1), F.company(2)],
        missing,
        F.scratch_dir!(),
        {:error, {"companies[1]", :role_unconfirmed}}
      )
    end

    test "another flagged row that was never spot-checked" do
      {dossier, _} = inputs([F.company(1), F.company(2)])
      sha = F.sha256(F.encode(dossier))
      only_row_1 = fn _manifest -> F.manifest({dossier, sha}, rows: ["row-1"]) end

      refused_everywhere!(
        [F.company(1), F.company(2)],
        only_row_1,
        F.scratch_dir!(),
        {:error, {"companies[1]", :link_unconfirmed}}
      )
    end

    test "another flagged row naming an invalid artifact" do
      dir = F.scratch_dir!()
      ref = F.artifact!(dir, "row-2-team.txt", "Riley Testperson: riley@acme2.test")
      bad = %{ref | "sha256" => F.sha256("other bytes")}
      row_2 = F.put(F.company(2), ["contact", "evidence", "email", "artifact"], bad)

      refused_everywhere!(
        [F.company(1), row_2],
        & &1,
        dir,
        {:error, {"companies[1].contact.evidence.email.artifact", :artifact_invalid}}
      )
    end

    test "an unflagged company-only row stays representable beside a valid selection" do
      company_only =
        F.company(2, %{
          "importable" => false,
          "skip_reason" => "no_named_person",
          "contact" => nil
        })

      {dossier, manifest} = inputs([F.company(1), company_only])
      dir = F.scratch_dir!()

      assert match?(
               {:ok, [%{"row_id" => "row-1"}]},
               DossierParser.select(dossier, manifest, ["row-1"], dir)
             )

      assert DossierParser.eligible_rows(dossier, manifest, dir) == {:ok, ["row-1"]}
    end
  end

  describe "selection" do
    test "more than 3 rows, an unknown row or a repeated row is refused before writes" do
      rows = for i <- 1..4, do: F.company(i)
      {dossier, manifest} = inputs(rows)
      dir = F.scratch_dir!()

      assert DossierParser.select(dossier, manifest, ~w(row-1 row-2 row-3 row-4), dir) ==
               {:error, {"rows", :count}}

      assert DossierParser.select(dossier, manifest, ~w(row-1 row-9), dir) ==
               {:error, {"rows[1]", :unknown_row}}

      assert DossierParser.select(dossier, manifest, ~w(row-1 row-1), dir) ==
               {:error, {"rows[1]", :duplicate}}

      assert match?(
               {:ok, [_, _, _]},
               DossierParser.select(dossier, manifest, ~w(row-3 row-1 row-2), dir)
             )
    end

    test "selecting an unflagged row reports its skip reason" do
      rows = [
        F.company(1),
        F.company(2, %{"importable" => false, "skip_reason" => "not_selected"})
      ]

      {dossier, manifest} = inputs(rows)

      assert DossierParser.select(dossier, manifest, ["row-2"], F.scratch_dir!()) ==
               {:error, {"companies[1]", :not_selected}}

      assert DossierParser.eligibility(dossier, manifest, "row-2", F.scratch_dir!()) ==
               {:not_importable, :not_selected}
    end

    test "zero eligible rows: none qualify is reported, and the rule is not weakened" do
      rows = [
        F.company(1, %{"importable" => false, "skip_reason" => "link_unconfirmed"}),
        F.company(2, %{
          "importable" => false,
          "skip_reason" => "no_named_person",
          "contact" => nil
        })
      ]

      dossier = F.dossier(rows)
      sha = F.sha256(F.encode(dossier))
      manifest = F.parsed_manifest(F.manifest({dossier, sha}, rows: ["row-1"]))

      assert DossierParser.eligible_rows(dossier, manifest, F.scratch_dir!()) == {:ok, []}
    end

    test "eligible rows are listed in file order" do
      rows = [
        F.company(1),
        F.company(2, %{"importable" => false, "skip_reason" => "not_selected"}),
        F.company(3)
      ]

      {dossier, manifest} = inputs(rows)

      assert DossierParser.eligible_rows(dossier, manifest, F.scratch_dir!()) ==
               {:ok, ["row-1", "row-3"]}
    end
  end
end
