defmodule SdrAgent.Prototype.DossierImportTest do
  @moduledoc """
  The above-domain import coordinator `SdrAgent.Prototype.DossierImport`
  (interfaces r6 IF-6 "Binding-wide contact cap", "Mapping", "Tables";
  supplement 1 r2 §5, R9; plan r7 section 6 F3 cap and Dossier/import):
  one `Audit.transaction` per row under the binding lock, the authoritative
  per-row cap recheck, idempotent replay by `(dossier_sha256, row_id)`,
  `:dossier_conflict`, the scoped Payload writes, explicit rollback of the
  whole row (no Sales row, no Payload reference, no cap slot), preserved
  denial records, and live operator and binding checks at both entries;
  and `cap_used/1`, the summary count of the binding's distinct imported
  contacts for the live operator only.
  Synthetic `.test` fixtures in a sandboxed prototype binding.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.DossierFixtures, as: F

  @import SdrAgent.Prototype.DossierImport
  @business_events "event_type LIKE 'sales.%' OR event_type LIKE 'research.%'"

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

  # A result, or any raise captured as {:raised, module, frames, shape}: the
  # exception module, the first three stack frames as {module, function,
  # arity, line}, and the shape of an unmatched term (tuple tags, atoms and
  # struct names only), never a value, so a failure names where and on what
  # it was raised.
  defp capture(fun) do
    fun.()
  rescue
    error ->
      {:raised, error.__struct__, frames(__STACKTRACE__), shape(Map.get(error, :term))}
  end

  defp shape(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.map(&shape/1)
  defp shape(%module{}), do: module
  defp shape(term) when is_atom(term), do: term
  defp shape(term) when is_list(term), do: :list
  defp shape(term) when is_map(term), do: :map
  defp shape(_term), do: :value

  defp frames(stacktrace) do
    for {module, function, arity, location} <- Enum.take(stacktrace, 3),
        do:
          {module, function, if(is_list(arity), do: length(arity), else: arity), location[:line]}
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

    # Codex 22958123: a later session's valid delegation (S1's
    # enter_session/2) replays the row: the original rows and their
    # attribution stay, no event is appended, no row, Payload or slot is used.
    test "an identical replay by a second valid delegation keeps the original attribution", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)

      entered = SdrAgent.Prototype.enter_session(:codex_cli, "codex-session:s3-replay-0002")

      assert match?({:ok, _}, entered),
             "prerequisite: enter_session/2 returned #{inspect(entered)}"

      {:ok, second_id} = entered
      {:ok, second} = SdrAgent.Prototype.operator_actor(second_id)
      refute second.id == ctx.actor.id

      tables = ~w(accounts contacts leads dossier_entries dossier_sources payloads)
      before = {Map.new(tables, &{&1, count(&1)}), length(events(ctx.tenant))}

      assert import!([row], second) == %{imported: [], replayed: ["row-1"]}

      assert {:ok, :replay, %{entry_id: entry_id}} =
               call(@import, :import_row, [row, second])

      assert {Map.new(tables, &{&1, count(&1)}), length(events(ctx.tenant))} == before

      %{rows: [[delegation_id]]} =
        Repo.query!("SELECT delegation_id FROM dossier_entries WHERE id = $1", [
          Ecto.UUID.dump!(entry_id)
        ])

      assert Ecto.UUID.cast!(delegation_id) == ctx.actor.id
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
      accesses = count("audit_accesses")
      events = count("audit_events", @business_events)

      assert {:error, %{failed_row: "row-1", imported: []}} =
               call(@import, :import, [[broken], ctx.actor])

      assert count("accounts", "domain = $1", ["acme1.test"]) == 0
      assert count("contacts") == 0
      assert count("leads") == 0
      assert count("dossier_entries") == 0
      assert count("dossier_sources") == 0
      assert count("payloads") == payloads
      # No access record and none of the row's business events survive.
      assert count("audit_accesses") == accesses

      assert count("audit_events", @business_events) == events

      # The slot was not consumed: three fresh rows still fit.
      rows = rows!(for(i <- 1..3, do: F.company(i)), ~w(row-1 row-2 row-3))
      assert import!(rows, ctx.actor).imported == ~w(row-1 row-2 row-3)
    end

    # Codex e7a0a7f1 (Q1): a genuine policy refusal of a Research write mid-row
    # is audited through the deferred denial path; the row's Audit.transaction
    # rolls everything else back and the one queued denial is flushed after it.
    test "a policy denial mid-row: exactly one authz.denied survives, nothing else", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      # audit_accesses is counted for completeness only: nothing on this path
      # creates an access, so its equality proves nothing (Codex 3b2a6b6f).
      tables = ~w(accounts contacts leads dossier_entries dossier_sources payloads audit_accesses)
      before = Map.new(tables, &{&1, count(&1)})
      events = count("audit_events", @business_events)
      denials = length(events_of_type(ctx.tenant, "authz.denied"))

      # Test-seam build: the live database identity drifts after the Sales
      # writes, so the operator gate refuses the Research write.
      drift = fn -> :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{database_oid: 1}) end
      result = call(@import, :import_row, [row, ctx.actor, [after_sales: drift]])
      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{})

      # The injected refusal is exactly the Research gate's Forbidden.
      assert result == {:error, :forbidden}, "import_row/3 returned #{inspect(result)}"

      assert Map.new(tables, &{&1, count(&1)}) == before
      # The Sales writes' sales.* events (account, contact, lead) were rolled back.
      assert count("audit_events", @business_events) == events

      new = Enum.drop(events_of_type(ctx.tenant, "authz.denied"), denials)
      assert [denial] = new, "expected exactly one new authz.denied, got #{length(new)}"

      assert {denial.actor_type, denial.actor_id} == {:prototype_operator, ctx.actor.id}
      assert denial.subject_resource == "SdrAgent.Research.DossierEntry"
      assert denial.action == "import"

      echoed = inspect(denial)

      for value <- [row.plan.contact.email, row.plan.contact.last_name, row.plan.account.domain] do
        refute echoed =~ value, "the denial echoed an input value"
      end
    end
  end

  # Codex 22958123 (C2 and the closure items): the failure boundary, the
  # authoritative per-row cap, same-key conflicts, nested calls and the
  # locked binding re-check.
  describe "closure: failure boundary, per-row cap, conflicts, nesting, locked re-check" do
    test "a real PostgreSQL failure late in the row is :import_failed, with no survivor and a usable connection",
         ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      tables = ~w(accounts contacts leads dossier_entries dossier_sources payloads)
      before = Map.new(tables, &{&1, count(&1)})
      events = count("audit_events", @business_events)
      denials = length(events_of_type(ctx.tenant, "authz.denied"))

      # A real PostgreSQL error (division_by_zero) after the Sales writes,
      # which leaves the row's transaction aborted.
      fail = fn ->
        assert {:error, %Postgrex.Error{}} = Repo.query("SELECT 1 / 0", [])
        :ok
      end

      result =
        capture(fn -> call(@import, :import_row, [row, ctx.actor, [after_sales: fail]]) end)

      assert result == {:error, :import_failed}, "import_row/3 returned #{inspect(result)}"

      assert Map.new(tables, &{&1, count(&1)}) == before
      assert count("audit_events", @business_events) == events
      assert length(events_of_type(ctx.tenant, "authz.denied")) == denials

      # The connection is usable and no slot was used: the row imports.
      assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
      assert import!([row], ctx.actor) == %{imported: ["row-1"], replayed: []}
    end

    test "the per-row recheck refuses a direct import_row over the cap, without the precheck",
         ctx do
      rows = rows!(for(i <- 1..3, do: F.company(i)), ~w(row-1 row-2 row-3))
      assert import!(rows, ctx.actor).imported == ~w(row-1 row-2 row-3)
      [fourth] = rows!([F.company(4)], ["row-4"])
      before = {count("accounts"), count("contacts"), count("dossier_entries"), count("payloads")}

      assert call(@import, :import_row, [fourth, ctx.actor]) == {:error, :contact_cap_exceeded}

      assert {count("accounts"), count("contacts"), count("dossier_entries"), count("payloads")} ==
               before
    end

    test "the same key with a changed manifest, claims or notes is :dossier_conflict, writing nothing",
         ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)
      before = {count("dossier_entries"), count("dossier_sources"), count("payloads")}

      changed = [
        manifest: %{row | spotcheck_sha256: String.duplicate("e", 64)},
        claims:
          update_in(row, [:plan, :claims], fn [claim | rest] ->
            [Map.put(claim, "basis", "changed") | rest]
          end),
        notes: put_in(row, [:plan, :notes, "why_fit"], "A changed note.")
      ]

      for {label, other} <- changed do
        assert call(@import, :import_row, [other, ctx.actor]) == {:error, :dossier_conflict},
               "changed #{label}"
      end

      assert {count("dossier_entries"), count("dossier_sources"), count("payloads")} == before
    end

    test "a call inside an open transaction is refused before any write; that transaction stays usable",
         ctx do
      [row] = rows!([F.company(1)], ["row-1"])

      for {label, open} <- [repo: &Repo.transaction/1, audit: &SdrAgent.Audit.transaction/1] do
        {:ok, {whole, one}} =
          open.(fn ->
            whole = capture(fn -> call(@import, :import, [[row], ctx.actor]) end)
            one = capture(fn -> call(@import, :import_row, [row, ctx.actor]) end)
            assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
            {whole, one}
          end)

        assert whole ==
                 {:error, %{code: :import_failed, failed_row: nil, imported: [], replayed: []}},
               "#{label}: import/2 returned #{inspect(whole)}"

        assert one == {:error, :import_failed}, "#{label}: import_row/2 returned #{inspect(one)}"
      end

      assert {count("accounts"), count("dossier_entries"), count("payloads")} == {0, 0, 0}
    end

    test "a binding drift between the entry check and the lock refuses, even a replay", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)
      events = length(events(ctx.tenant))

      drift = fn -> :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{database_oid: 1}) end

      result =
        capture(fn -> call(@import, :import_row, [row, ctx.actor, [before_lock: drift]]) end)

      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{})

      assert result == {:error, :binding_mismatch}, "import_row/3 returned #{inspect(result)}"
      assert length(events(ctx.tenant)) == events
    end
  end

  # The import summary's cap_used count (IF-8 :import_summary): the binding's
  # distinct imported contacts, read for the live operator only. Proposed
  # contract (this RED): {:ok, count} or a closed {:error, code}, never a
  # bare count for an unchecked caller. A count only, never authority: the
  # cap is decided per row under the lock.
  describe "cap_used/1" do
    test "counts the binding's distinct imported contacts; a replay adds nothing", ctx do
      assert call(@import, :cap_used, [ctx.actor]) == {:ok, 0}

      rows = rows!([F.company(1), F.company(2)], ~w(row-1 row-2))
      assert import!(rows, ctx.actor).imported == ~w(row-1 row-2)
      assert call(@import, :cap_used, [ctx.actor]) == {:ok, 2}

      assert import!(rows, ctx.actor).replayed == ~w(row-1 row-2)
      assert call(@import, :cap_used, [ctx.actor]) == {:ok, 2}
    end

    test "a failed row adds nothing; the count is the binding's, for every live delegation",
         ctx do
      [good] = rows!([F.company(1)], ["row-1"])
      [bad] = rows!([F.company(2)], ["row-2"])
      broken = put_in(bad, [:plan, :sources], [%{hd(bad.plan.sources) | source_id: "s!"}])

      assert {:error, %{failed_row: "row-2"}} =
               call(@import, :import, [[good, broken], ctx.actor])

      assert call(@import, :cap_used, [ctx.actor]) == {:ok, 1}

      entered = SdrAgent.Prototype.enter_session(:codex_cli, "codex-session:s3-cap-0002")

      assert match?({:ok, _}, entered),
             "prerequisite: enter_session/2 returned #{inspect(entered)}"

      {:ok, second_id} = entered
      {:ok, second} = SdrAgent.Prototype.operator_actor(second_id)
      assert call(@import, :cap_used, [second]) == {:ok, 1}
    end

    test "an entry of another tenant is not counted", ctx do
      rows = rows!([F.company(1), F.company(2)], ~w(row-1 row-2))
      import!(rows, ctx.actor)

      # The database admits one tenant: a real entry is moved to another
      # tenant id (AuditCase.tamper!/2, one statement).
      tamper!(
        "UPDATE dossier_entries SET tenant_id = $1 WHERE id = " <>
          "(SELECT id FROM dossier_entries WHERE row_id = 'row-2')",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      assert call(@import, :cap_used, [ctx.actor]) == {:ok, 1}
    end

    test "a caller that is not the live operator gets a closed code, never a count", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)

      assert call(@import, :cap_used, [%{ctx.actor | id: Ecto.UUID.generate()}]) ==
               {:error, :forbidden}

      assert call(@import, :cap_used, [SdrAgent.Actor.system(:agent_runtime, ctx.tenant.id)]) ==
               {:error, :forbidden}

      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{database_oid: 1})
      drifted = call(@import, :cap_used, [ctx.actor])
      :ok = SdrAgent.PrototypeFixtures.put_live_identity(%{})
      assert drifted == {:error, :binding_mismatch}

      :ok = SdrAgent.PrototypeFixtures.leave_runtime()
      assert call(@import, :cap_used, [ctx.actor]) == {:error, :not_prototype_runtime}
    end

    test "it reads only: no row, Payload or event is written", ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)
      tables = ~w(accounts contacts leads dossier_entries dossier_sources payloads audit_accesses)
      before = {Map.new(tables, &{&1, count(&1)}), length(events(ctx.tenant))}

      assert call(@import, :cap_used, [ctx.actor]) == {:ok, 1}
      assert {Map.new(tables, &{&1, count(&1)}), length(events(ctx.tenant))} == before
    end

    # Codex 6d1ead6d (option 2, superseding the :import_failed expectation of
    # 79ff218 on dependency evidence): a real failed count read gives no
    # count, no closed code and nothing written; the actual Ash error is
    # raised. The sandbox runs each top-level query under its own savepoint
    # (postgrex_query), so the failed read leaves the test transaction
    # usable; the test then restores the exact prior search path (the seam's
    # SET LOCAL survives that savepoint's release) and checks that nothing
    # was written. A call inside an
    # open transaction, where a failed Ash read would roll the caller back by
    # throw, is still refused before any read with :import_failed.
    test "a real failed count read raises its Ash error: no count, no code, nothing written",
         ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)
      tables = ~w(accounts contacts leads dossier_entries dossier_sources payloads audit_accesses)
      before = {Map.new(tables, &{&1, count(&1)}), length(events(ctx.tenant))}

      # A real PostgreSQL failure of the count read: the test-build seam sets
      # an empty search path just before it, so the table is not found.
      fail = fn ->
        Repo.query!("SET LOCAL search_path TO pg_catalog", [])
        :ok
      end

      %{rows: [[path]]} = Repo.query!("SHOW search_path", [])
      result = capture(fn -> call(@import, :cap_used, [ctx.actor, [before_count: fail]]) end)
      Repo.query!("SELECT set_config('search_path', $1, true)", [path])

      assert match?({:raised, Ash.Error.Unknown, _, _}, result),
             "cap_used/2 returned #{inspect(result)}"

      assert {Map.new(tables, &{&1, count(&1)}), length(events(ctx.tenant))} == before
    end

    test "inside an open transaction it is refused before any read; that transaction stays usable",
         ctx do
      [row] = rows!([F.company(1)], ["row-1"])
      import!([row], ctx.actor)

      for {label, open} <- [repo: &Repo.transaction/1, audit: &SdrAgent.Audit.transaction/1] do
        {:ok, result} =
          open.(fn ->
            result = capture(fn -> call(@import, :cap_used, [ctx.actor]) end)
            assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
            result
          end)

        assert result == {:error, :import_failed},
               "#{label}: cap_used/1 returned #{inspect(result)}"
      end
    end

    # Codex 42f5b1e0 / 6d1ead6d: the evidence (discovered at cdaed31, whose
    # expected nested Postgrex struct was wrong): a real failed count read
    # returns an Ash.Error.Unknown whose only leaf is an UnknownError holding
    # a BINARY. Splode formats the raised exception (splode.ex:526-531), so
    # the typed database cause is gone and a formatted programming error
    # looks the same. No classifier recovers it from that text. Then the
    # mapping, through the test-seam count fault (no query runs): an exact
    # Forbidden is :forbidden; every other returned error, the observed
    # lossy shape included, is raised as itself, never :import_failed.
    test "evidence: a failed count read returns an Ash.Error.Unknown whose only leaf holds a binary",
         ctx do
      query =
        SdrAgent.Research.DossierEntry
        |> Ash.Query.for_read(:read, %{}, SdrAgent.Audit.Kernel.opts(ctx.tenant.id))
        |> Ash.Query.filter(tenant_id == ^ctx.tenant.id)
        |> Ash.Query.select([:contact_id])

      Repo.query!("SET LOCAL search_path TO pg_catalog", [])
      result = Ash.read(query)

      leaves =
        case result do
          {:error, %Ash.Error.Unknown{errors: errors}} ->
            Enum.map(errors, &{&1.__struct__, leaf(Map.get(&1, :error))})

          other ->
            shape(other)
        end

      assert leaves == [{Ash.Error.Unknown.UnknownError, :value}], "observed #{inspect(leaves)}"
      assert [%Ash.Error.Unknown.UnknownError{error: text}] = elem(result, 1).errors
      assert is_binary(text)
    end

    test "an exact Forbidden read is :forbidden", ctx do
      assert count_faulted(ctx, {:error, Ash.Error.Forbidden.exception([])}) ==
               {:error, :forbidden}
    end

    test "any other returned error keeps its identity: raised, never :import_failed", ctx do
      # The observed lossy shape (a binary leaf) and two wrapped programming
      # errors are all raised as the injected Ash error itself: the class
      # first, then (Codex d59fb7a3) the exact caught == injected exception,
      # so a newly constructed Ash.Error.Unknown cannot pass.
      for {label, wrapped} <- [
            neutral_binary: "formatted failure text",
            programming_binary: "synthetic programming error",
            programming_exception: %RuntimeError{message: "synthetic programming error"}
          ] do
        error =
          Ash.Error.Unknown.exception(
            errors: [Ash.Error.Unknown.UnknownError.exception(error: wrapped)]
          )

        result = count_faulted(ctx, {:error, error})

        assert match?({:raised, Ash.Error.Unknown, _, _}, result),
               "#{label}: returned #{inspect(result)}"

        assert raises_injected?(ctx, error),
               "#{label}: the caught exception is not the injected one"
      end
    end
  end

  # Whether cap_used, with its count read replaced by {:error, injected},
  # raises exactly `injected` (the same exception, not a reconstruction). A
  # boolean, so no assertion ever prints the exception or its contents.
  defp raises_injected?(ctx, injected) do
    Process.put({@import, :count_fault}, {:error, injected})

    try do
      call(@import, :cap_used, [ctx.actor])
      false
    rescue
      caught -> caught == injected
    after
      Process.delete({@import, :count_fault})
    end
  end

  defp leaf(%module{}), do: module
  defp leaf(other), do: shape(other)

  # cap_used with its count read replaced by `fault` (test-seam build).
  defp count_faulted(ctx, fault) do
    Process.put({@import, :count_fault}, fault)

    try do
      capture(fn -> call(@import, :cap_used, [ctx.actor]) end)
    after
      Process.delete({@import, :count_fault})
    end
  end

  describe "layering and inputs (source checks)" do
    # Codex R7 layering: Sales stays below the import coordinator and never
    # reaches the dossier Research resources or names. (Existing, unrelated
    # qualification checks may read Research; this rule is about the import.)
    test "Sales never reaches the dossier import or its Research resources" do
      files = ["lib/sdr_agent/sales.ex" | Path.wildcard("lib/sdr_agent/sales/**/*.ex")]
      import_path = ~r/Prototype\.DossierImport|Research\.Dossier|record_dossier_|DossierSources/

      for file <- files do
        refute File.read!(file) =~ import_path, "#{file} reaches the dossier import path"
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
