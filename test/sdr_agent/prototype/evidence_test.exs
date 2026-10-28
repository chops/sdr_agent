defmodule SdrAgent.Prototype.EvidenceTest do
  @moduledoc """
  IF-6 mapping and evidence partition of one eligible row
  (`SdrAgent.Prototype.DossierParser.import_plan/4`; interfaces r6
  "Mapping", "Tables", "Evidence"; plan r7 section 6 "Evidence"): only
  verified excerpts reach a source's content, one source per content, and
  inference, `why_fit` and unconfirmed facts go to the notes only; the
  three claim records keep each claim's source type, basis and spot-check
  result exactly; Account size, industry and geography are never set.
  Synthetic fixtures; pure. The database side (DossierSource content,
  DossierWeb pages, ResearchArtifact) is in the import and adapter tests.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.DossierParser

  defp plan(rows, row_id, edit) do
    dossier = F.dossier(rows)
    sha = F.sha256(F.encode(dossier))
    manifest = F.parsed_manifest(edit.(F.manifest({dossier, sha})))
    DossierParser.import_plan(dossier, manifest, row_id, F.scratch_dir!())
  end

  defp plan!(rows, row_id, edit \\ & &1) do
    result = plan(rows, row_id, edit)
    assert match?({:ok, %{}}, result), "import_plan/4 returned #{inspect(result)}"
    {:ok, plan} = result
    plan
  end

  describe "mapping" do
    test "the contact: first token, the rest, the role as title, the trimmed lowercase email" do
      # The claims carry the renamed person, so the row stays eligible (R2).
      name = "Ana de Souza Testperson"

      row =
        F.company(1)
        |> F.put(["contact", "name"], name)
        |> F.put(["contact", "email"], "Ana.Souza@acme1.test")
        |> F.put(["contact", "evidence", "name", "excerpt"], "#{name}, Head of Growth")
        |> F.put(["contact", "evidence", "role", "excerpt"], "#{name}, Head of Growth")
        |> F.put(["contact", "evidence", "email", "excerpt"], "#{name}: Ana.Souza@acme1.test")

      plan = plan!([row], "row-1")

      assert plan.contact == %{
               first_name: "Ana",
               last_name: "de Souza Testperson",
               title: "Head of Growth",
               email: "ana.souza@acme1.test"
             }
    end

    test "the account: name, domain and the first company-site final URL; no size, industry or geography" do
      row =
        F.company(1)
        |> Map.update!("sources", fn [team, about] ->
          [F.source("s3", "https://news.test/acme1", "third_party"), about, team]
        end)

      plan = plan!([row], "row-1")

      assert plan.account == %{
               name: "Acme 1 Logistics Software",
               domain: "acme1.test",
               website_url: "https://www.acme1.test/about"
             }
    end

    test "the entry carries the row's key and contact labels, never promoted" do
      plan = plan!([F.company(1)], "row-1")
      assert plan.row_id == "row-1"

      assert plan.entry == %{
               email_kind: :personal_work,
               contact_classification: :unverified,
               contact_confidence: :high
             }
    end
  end

  describe "claims" do
    test "exactly three records, name, role and email, each with its source and spot-check result" do
      plan = plan!([F.company(1)], "row-1")
      assert Enum.map(plan.claims, & &1["field"]) == ["name", "role", "email"]

      for claim <- plan.claims do
        assert Map.keys(claim) |> Enum.sort() ==
                 Enum.sort(
                   ~w(field source_id source_type basis attribution_excerpt original_url final_url excerpt artifact_sha256 checked_at result relation)
                 )
      end

      email = Enum.find(plan.claims, &(&1["field"] == "email"))

      assert %{
               "source_id" => "s1",
               "source_type" => "company_site",
               "basis" => "company_published",
               "attribution_excerpt" => nil,
               "original_url" => "https://acme1.test/team",
               "final_url" => "https://acme1.test/team",
               "excerpt" => "Jordan Testperson: jordan@acme1.test",
               "artifact_sha256" => nil,
               "checked_at" => "2026-10-27T10:00:00-06:00",
               "result" => "verified",
               "relation" => "person_address_linked"
             } = email
    end
  end

  describe "sources and notes" do
    test "only sources with a verified excerpt, holding only their own verified excerpts" do
      unverified_f3 = fn manifest ->
        F.update(manifest, ["results"], fn rs ->
          Enum.map(
            rs,
            &if(&1["row_id"] == "row-1" and &1["item"] == "fact:f3",
              do: %{&1 | "result" => "not_found"},
              else: &1
            )
          )
        end)
      end

      plan = plan!([F.company(1)], "row-1", unverified_f3)

      # s1 (the team page) carries claims only; s2 carries the two verified facts.
      assert [source] = plan.sources
      assert source.source_id == "s2"
      assert source.source_type == "company_site"
      assert source.final_url == "https://www.acme1.test/about"
      assert source.retrieved_on == ~D[2026-10-26]
      assert source.checked_at == ~U[2026-10-27 16:00:00.000000Z]

      assert source.excerpts == [
               %{
                 "fact_id" => "f1",
                 "kind" => "quote",
                 "excerpt" => "Acme 1 has a team of 24 people."
               },
               %{
                 "fact_id" => "f2",
                 "kind" => "fact",
                 "excerpt" => "Our whole team works from Denver, Colorado."
               }
             ]

      assert source.content ==
               "Acme 1 has a team of 24 people.\n\n" <>
                 "Our whole team works from Denver, Colorado."

      # R1: the bytes are the excerpts only; kind and fact id stay outside them.
      refute source.content =~ ~r/\[(quote|fact) f\d/
      refute source.content =~ "freight brokers"
      refute source.content =~ "outbound help"
    end

    test "inference, why_fit and unconfirmed facts go to the notes only" do
      unverified_f3 = fn manifest ->
        F.update(manifest, ["results"], fn rs ->
          Enum.map(
            rs,
            &if(&1["item"] == "fact:f3", do: %{&1 | "result" => "unreachable"}, else: &1)
          )
        end)
      end

      plan = plan!([F.company(1)], "row-1", unverified_f3)

      assert plan.notes == %{
               "why_fit" => "Synthetic fit note 1: a small B2B software vendor.",
               "inferences" => ["Probably needs outbound help soon."],
               "unconfirmed" => [
                 %{
                   "fact_id" => "f3",
                   "kind" => "fact",
                   "text" => "Acme 1 sells routing software to freight brokers."
                 }
               ]
             }

      for source <- plan.sources do
        refute source.content =~ "Synthetic fit note"
        refute source.content =~ "Probably needs"
      end
    end

    test "each source's content is its own excerpts, never mixed across pages" do
      row =
        F.company(1)
        |> F.put(["facts", 2, "source_id"], "s1")

      plan = plan!([row], "row-1")
      by_id = Map.new(plan.sources, &{&1.source_id, &1})

      assert by_id["s1"].content == "We build routing software for freight brokers."
      refute by_id["s2"].content =~ "freight brokers"
    end
  end
end
