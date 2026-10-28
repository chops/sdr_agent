defmodule SdrAgent.Prototype.DossierPrepareTest do
  @moduledoc """
  `SdrAgent.Prototype.DossierImport.prepare/5` (interfaces r6 IF-6;
  supplement 1 r2 §5): the import rows of a selection, built from a parsed
  dossier and a parsed manifest by composing `DossierParser.select/4` and
  `DossierParser.import_plan/4`, never by re-implementing them.

  - Success: one row per selected id, in selection order, each
    `%{row_id:, row_index:, dossier_sha256:, spotcheck_sha256:, plan:}`,
    where `row_index` is the row's index in the dossier, `dossier_sha256`
    the argument, `spotcheck_sha256` the parsed manifest's own digest and
    `plan` exactly `DossierParser.import_plan/4`'s.
  - Refusals are the parser's, unchanged and value-free: the selection
    bounds, an unknown or repeated row, an unflagged selected row, and any
    flagged row failing the importable rule (the whole input is refused).

  Inputs come through the real parsers (encoded bytes →
  `DossierParser.parse/1` and `SpotcheckManifest.parse/3`). Pure: no
  database, no network.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.DossierFixtures, as: F
  alias SdrAgent.Prototype.DossierImport
  alias SdrAgent.Prototype.DossierParser
  alias SdrAgent.Prototype.SpotcheckManifest

  @marker "ZZQMARKERZZ"

  # The parsed inputs of `companies`, through the real parsers.
  defp parsed!(companies) do
    dossier = F.dossier(companies)
    bytes = F.encode(dossier)
    sha = F.sha256(bytes)

    {:ok, parsed} = DossierParser.parse(bytes)

    {:ok, manifest} =
      SpotcheckManifest.parse(F.encode(F.manifest({dossier, sha})), parsed, sha)

    %{dossier: parsed, manifest: manifest, sha: sha, dir: F.scratch_dir!()}
  end

  defp prepare(inputs, row_ids),
    do: DossierImport.prepare(inputs.dossier, inputs.sha, inputs.manifest, row_ids, inputs.dir)

  defp refused!(result, path, rule) do
    assert result == {:error, {path, rule}},
           "expected the refusal {#{inspect(path)}, #{inspect(rule)}}, got #{inspect(result)}"

    refute inspect(result) =~ @marker, "the refusal echoed a value"
  end

  describe "a valid selection" do
    test "one row per selected id, in selection order, with the parser's plan" do
      inputs = parsed!([F.company(1), F.company(2), F.company(3)])
      result = prepare(inputs, ["row-3", "row-1"])
      assert match?({:ok, [_, _]}, result), "prepare/5 returned #{inspect(result)}"
      {:ok, [third, first]} = result

      for {row, id, index} <- [{third, "row-3", 2}, {first, "row-1", 0}] do
        {:ok, plan} = DossierParser.import_plan(inputs.dossier, inputs.manifest, id, inputs.dir)

        assert row == %{
                 row_id: id,
                 row_index: index,
                 dossier_sha256: inputs.sha,
                 spotcheck_sha256: inputs.manifest.sha256,
                 plan: plan
               }
      end
    end

    test "the plan carries the C1 website and only verified excerpts" do
      inputs = parsed!([F.company(1)])
      result = prepare(inputs, ["row-1"])
      assert match?({:ok, [_]}, result), "prepare/5 returned #{inspect(result)}"
      {:ok, [row]} = result

      assert row.plan.account.website_url == "https://www.acme1.test/about"
      assert [%{source_id: "s2", source_type: "company_site"}] = row.plan.sources
    end
  end

  describe "refusals are the parser's" do
    test "the selection bounds: none, or more than three rows" do
      inputs = parsed!(for i <- 1..4, do: F.company(i))
      refused!(prepare(inputs, []), "rows", :count)
      refused!(prepare(inputs, ~w(row-1 row-2 row-3 row-4)), "rows", :count)
    end

    test "an unknown or repeated row" do
      inputs = parsed!([F.company(1), F.company(2)])
      refused!(prepare(inputs, ["row-1", @marker]), "rows[1]", :unknown_row)
      refused!(prepare(inputs, ["row-1", "row-1"]), "rows[1]", :duplicate)
    end

    test "an unflagged selected row is refused with its skip reason" do
      unflagged = F.company(2, %{"importable" => false, "skip_reason" => "not_selected"})
      inputs = parsed!([F.company(1), unflagged])
      refused!(prepare(inputs, ["row-2"]), "companies[1]", :not_selected)
    end

    test "a flagged row failing the importable rule refuses the whole input, selected or not" do
      # Row 2 is flagged but every verified fact sits on a third-party page,
      # so no company-site source is retained (honestly labelled hosts).
      broken =
        F.company(2)
        |> Map.update!(
          "sources",
          &(&1 ++ [F.source("s3", "https://news.test/acme2", "third_party")])
        )
        |> F.update(["facts"], fn facts ->
          Enum.map(facts, &if(&1["source_id"] == "s2", do: %{&1 | "source_id" => "s3"}, else: &1))
        end)

      inputs = parsed!([F.company(1), broken])

      refused!(prepare(inputs, ["row-1"]), "companies[1]", :insufficient_source)
      refused!(prepare(inputs, ["row-2"]), "companies[1]", :insufficient_source)
    end
  end

  test "prepare/5 composes the parser and evaluates nothing (source check)" do
    source = File.read!("lib/sdr_agent/prototype/dossier_import.ex")
    refute source =~ ~r/Code\.eval|:erlang\.binary_to_term|String\.to_atom|Req\b|:httpc/
  end
end
