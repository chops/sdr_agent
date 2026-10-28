defmodule SdrAgent.Prototype.DossierImportTest do
  @moduledoc """
  The above-domain import coordinator `SdrAgent.Prototype.DossierImport`
  (interfaces r6 IF-6 "Binding-wide contact cap", "Mapping", "Tables";
  supplement 1 r2 §5, R9; plan r7 section 6 F3 cap and Dossier/import):
  one `Audit.transaction` per row under the binding lock, the authoritative
  per-row cap recheck, idempotent replay by `(dossier_sha256, row_id)`,
  `:dossier_conflict`, the scoped Payload writes, explicit rollback of the
  whole row (no Sales row, no Payload reference, no cap slot), preserved
  denial records, and live operator and binding checks at both entries.
  Synthetic `.test` fixtures in a sandboxed prototype binding.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.DossierFixtures, as: F

  @import SdrAgent.Prototype.DossierImport

  setup do
    fixture = bound!()
    %{fixture: fixture, actor: fixture.actor, tenant: fixture.tenant}
  end

  # The coordinator's rows through the real route (supplement 2 §1):
  # bytes → parse → prepare (`F.route_rows!/2`); no plan is built by hand.
  defp rows!(companies, ids), do: F.route_rows!(companies, ids)

  defp count(table, where \\ "TRUE", params \\ []) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE #{where}", params)
    n
  end

  defp import!(rows, actor) do
    result = call(@import, :import, [rows, actor])

    assert match?({:ok, %{imported: _, replayed: _}}, result),
           "import/2 returned #{inspect(result)}"

    {:ok, summary} = result
    summary
  end

  describe "one row" do
    test "writes the account, contact, lead, entry and verified sources as the operator", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      assert import!([row], ctx.actor) == %{imported: ["row-1"], replayed: []}

      %{rows: [[account_id, source, industry, employees, geography, website]]} =
        Repo.query!(
          "SELECT id, source, industry, employee_count, geography, website_url FROM accounts WHERE domain = $1",
          ["acme1.test"]
        )

      assert {source, industry, employees, geography} == {"dossier", nil, nil, nil}
      # Supplement 2 C1: s1 (team) has claims only; s2 (about) is the first
      # retained company-site source.
      assert website == "https://www.acme1.test/about"

      %{rows: [[first, last, title, email]]} =
        Repo.query!(
          "SELECT first_name, last_name, title, email FROM contacts WHERE account_id = $1",
          [account_id]
        )

      assert {first, last, title, email} ==
               {"Jordan", "Testperson", "Head of Growth", "jordan@acme1.test"}

      assert count("leads", "account_id = $1 AND source = 'dossier' AND status = 'new'", [
               account_id
             ]) == 1

      %{rows: [[entry_sha, entry_row, spot, kind, class, conf, delegation_id]]} =
        Repo.query!(
          "SELECT dossier_sha256, row_id, spotcheck_sha256, email_kind, contact_classification, " <>
            "contact_confidence, delegation_id FROM dossier_entries WHERE account_id = $1",
          [account_id]
        )

      assert {entry_sha, entry_row, spot} == {row.dossier_sha256, "row-1", row.spotcheck_sha256}
      assert {kind, class, conf} == {"personal_work", "unverified", "high"}
      assert Ecto.UUID.cast!(delegation_id) == ctx.actor.id

      # s2 is the only source with verified excerpts; its Payload holds exactly them.
      %{rows: sources} =
        Repo.query!(
          "SELECT s.source_id, s.source_type, p.content FROM dossier_sources s " <>
            "JOIN payloads p ON p.tenant_id = s.tenant_id AND p.sha256 = s.content_sha256",
          []
        )

      assert sources == [
               ["s2", "company_site", hd(row.plan.sources).content]
             ]
    end

    test "every event is attributed to the operator's delegation, never the anchor", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)

      for type <- ~w(sales.account.created sales.contact.created sales.lead.created) do
        assert [event] = events_of_type(ctx.tenant, type)
        assert event.actor_type == :prototype_operator
        assert event.actor_id == ctx.actor.id
        refute event.actor_id == ctx.fixture.anchor.id
      end
    end

    test "the claims and notes Payloads hold the plan's records exactly", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)

      %{rows: [[claims, notes]]} =
        Repo.query!(
          "SELECT c.content, n.content FROM dossier_entries e " <>
            "JOIN payloads c ON c.tenant_id = e.tenant_id AND c.sha256 = e.claims_sha256 " <>
            "JOIN payloads n ON n.tenant_id = e.tenant_id AND n.sha256 = e.notes_sha256",
          []
        )

      assert Jason.decode!(claims) == %{"claims" => row.plan.claims}
      assert Jason.decode!(notes) == row.plan.notes
      refute claims =~ "verified\":\"promoted"
    end
  end

  describe "replay and conflict" do
    test "an identical replay returns the existing rows and uses no slot", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)
      before = {count("accounts"), count("contacts"), count("leads"), count("dossier_entries")}

      assert import!([row], ctx.actor) == %{imported: [], replayed: ["row-1"]}

      assert {count("accounts"), count("contacts"), count("leads"), count("dossier_entries")} ==
               before

      assert match?(
               {:ok, :replay, %{entry_id: _, lead_id: _}},
               call(@import, :import_row, [row, ctx.actor])
             )
    end

    test "the same domain or email from another dossier is :dossier_conflict and writes nothing",
         ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)
      before = count("accounts")

      other =
        F.company(1)
        |> Map.put("row_id", "other-1")
        |> Map.put("why_fit", "A second dossier with the same company.")

      [again] = rows!([other], ["other-1"])
      refute again.dossier_sha256 == row.dossier_sha256

      assert {:error, %{code: :dossier_conflict, failed_row: "other-1"}} =
               call(@import, :import, [[again], ctx.actor])

      assert count("accounts") == before
    end
  end

  describe "the binding-wide cap of 3 distinct contacts" do
    test "a second command or a second dossier cannot pass the cap; a replay at the cap uses no slot",
         ctx do
      rows = rows!(for(i <- 1..3, do: F.company(i)), ~w(row-1 row-2 row-3))
      assert import!(rows, ctx.actor).imported == ~w(row-1 row-2 row-3)

      [fourth] = rows!([F.company(4)], ["row-4"])

      assert {:error, %{code: :contact_cap_exceeded, imported: [], replayed: []}} =
               call(@import, :import, [[fourth], ctx.actor])

      assert count("contacts") == 3
      assert count("dossier_entries") == 3
      assert import!([hd(rows)], ctx.actor) == %{imported: [], replayed: ["row-1"]}
    end

    test "the precheck refuses an over-cap selection before any write", ctx do
      [first] = rows!([F.company(1)], ["row-1"])
      import!([first], ctx.actor)

      rows = rows!(for(i <- 2..4, do: F.company(i)), ~w(row-2 row-3 row-4))

      assert {:error, %{code: :contact_cap_exceeded, imported: [], failed_row: nil}} =
               call(@import, :import, [rows, ctx.actor])

      assert count("contacts") == 1
    end

    test "two concurrent imports serialize on the binding lock; the per-row recheck holds the cap",
         ctx do
      a = rows!([F.company(1), F.company(2)], ~w(row-1 row-2))
      b = rows!([F.company(3), F.company(4)], ~w(row-3 row-4))

      results =
        [a, b]
        |> Enum.map(fn rows ->
          Task.async(fn -> call(@import, :import, [rows, ctx.actor]) end)
        end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert count("contacts") == 3
      assert count("dossier_entries") == 3

      assert Enum.count(results, &match?({:error, %{code: :contact_cap_exceeded}}, &1)) == 1,
             "expected exactly one cap refusal: #{inspect(results)}"
    end

    test "after a partial failure the same command resumes: committed rows replay, the failed row retries",
         ctx do
      [good] = rows!([F.company(1)], ["row-1"])
      [bad] = rows!([F.company(2)], ["row-2"])
      broken = put_in(bad, [:plan, :sources], [%{hd(bad.plan.sources) | source_id: "s!"}])

      assert {:error, %{failed_row: "row-2", imported: ["row-1"]}} =
               call(@import, :import, [[good, broken], ctx.actor])

      assert import!([good, bad], ctx.actor) == %{imported: ["row-2"], replayed: ["row-1"]}
      assert count("contacts") == 2
    end
  end

  describe "the whole row is atomic (R9)" do
    test "a Research write failing mid-row leaves no Sales row, no Payload reference and no cap slot",
         ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      broken = put_in(row, [:plan, :sources], [%{hd(row.plan.sources) | source_id: "s!"}])
      payloads = count("payloads")

      assert {:error, %{failed_row: "row-1", imported: []}} =
               call(@import, :import, [[broken], ctx.actor])

      assert count("accounts", "domain = $1", ["acme1.test"]) == 0
      assert count("contacts") == 0
      assert count("leads") == 0
      assert count("dossier_entries") == 0
      assert count("dossier_sources") == 0
      assert count("payloads") == payloads

      # The slot was not consumed: three fresh rows still fit.
      rows = rows!(for(i <- 1..3, do: F.company(i)), ~w(row-1 row-2 row-3))
      assert import!(rows, ctx.actor).imported == ~w(row-1 row-2 row-3)
    end
  end

  describe "layering and inputs (source checks)" do
    test "Sales never references Research" do
      files = ["lib/sdr_agent/sales.ex" | Path.wildcard("lib/sdr_agent/sales/**/*.ex")]

      for file <- files do
        refute File.read!(file) =~ "SdrAgent.Research", "#{file} references SdrAgent.Research"
      end
    end

    test "the import path makes no network call and evaluates nothing" do
      for file <-
            ~w(lib/sdr_agent/prototype/dossier_import.ex lib/mix/tasks/sdr.prototype.import.ex) do
        source = File.read!(file)
        refute source =~ ~r/\bReq\b|:httpc|Finch|Mint|Code\.eval|:os\.cmd|System\.cmd/, "#{file}"
      end
    end
  end
end
