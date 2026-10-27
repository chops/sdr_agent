defmodule SdrAgent.Agents.ReleaseCampaignFactsTest do
  @moduledoc """
  C2* slice S3, the release-migration campaign driver's decision core (Codex
  599d9bcd rulings 1-5 and "driver authoring scope"; phase 2, authoring
  only): `SdrAgent.ReleaseMigration.CampaignFacts`, pure. The private,
  pinned one-attempt driver gathers raw observations (its own CREATE,
  disposal and catalog receipts, the test's suite verdict, the published
  `RM-RECEIPT` lines, the harness exports) and hands them to this core,
  which derives exactly four target records (the parent pair, DB #1, DB #2)
  from positive evidence only, classifies the run with
  `SdrAgent.ReleaseMigration.CampaignExit` and plans every lease.

  CPU-only and injected: no driver, no database, no process. Covered:
  exact pins; the strict observation and receipt grammars; success; no
  effect; collision before any effect; partial create (cleaned and
  retained); uncertain create, claim and child; an interrupted run;
  truncated or missing receipts never disposed; substituted, extra or
  missing records; evidence incomplete or inconsistent; failure and
  cleanup outcomes kept apart; the lease plan per resource.
  """
  use ExUnit.Case, async: true

  @module SdrAgent.ReleaseMigration.CampaignFacts
  @suffixes %{parent: "_rm0123456789", db1: "_wm0123456789", db2: "_wmabcdef0123"}
  @parent "sdr_agent_test_rm0123456789"
  @demo "sdr_agent_test_rm0123456789_demo"
  @db1 "sdr_agent_test_wm0123456789"
  @db2 "sdr_agent_test_wmabcdef0123"
  @names [@parent, @demo, @db1, @db2]

  # Calls the core only when it exists (RED: structural).
  defp core(function, args) do
    if Code.ensure_loaded?(@module) and function_exported?(@module, function, length(args)),
      do: apply(@module, function, args),
      else: {:not_implemented, function}
  end

  ## Fixtures: one successful campaign, as the driver observes it

  defp observed(overrides \\ %{}) do
    Map.merge(
      %{
        "pin.parent_suffix" => "_rm0123456789",
        "pin.db1_suffix" => "_wm0123456789",
        "pin.db2_suffix" => "_wmabcdef0123",
        "launch" => "launched",
        "interrupted" => "no",
        "driver_evidence" => "ok",
        "suite" => "pass",
        "result_line" => "Result: 3 passed",
        "parent.create" => "created",
        "parent.disposal" => "dropped",
        "parent_demo.create" => "created",
        "parent_demo.disposal" => "dropped",
        "db1.evidence_dir" => "present",
        "db1.export" => "sealed_verified",
        "db1.catalog" => "absent",
        "db2.evidence_dir" => "present",
        "db2.export" => "sealed_verified",
        "db2.catalog" => "absent"
      },
      overrides
    )
  end

  defp db_receipts(prefix, database) do
    %{
      "#{prefix}.target_database" => database,
      "#{prefix}.child.claim" => "exit:0",
      "#{prefix}.cleanup.drop_attempted" => "true",
      "#{prefix}.cleanup.drop_mode" => "normal",
      "#{prefix}.cleanup.drop_result" => "ok",
      "#{prefix}.cleanup.drop_receipt" => "valid",
      "#{prefix}.cleanup.drop_protocol" => "2",
      "#{prefix}.cleanup.blocking_before_drop" => "0",
      "#{prefix}.cleanup.database_absent_after_drop" => "true",
      "#{prefix}.cleanup.temp_folder" => "removed",
      "#{prefix}.evidence.export" => "sealed",
      "#{prefix}.outcome" => "ok"
    }
  end

  defp receipts(overrides \\ %{}) do
    %{"targets.db1" => @db1, "targets.db2" => @db2}
    |> Map.merge(db_receipts("db1", @db1))
    |> Map.merge(db_receipts("db2", @db2))
    |> Map.merge(overrides)
    |> Enum.reject(fn {_key, value} -> value == :delete end)
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> "RM-RECEIPT #{key}=#{value}" end)
  end

  defp facts_text(map), do: Enum.map_join(Enum.sort(map), "\n", fn {k, v} -> "#{k}=#{v}" end)

  # The whole decision from the two text inputs the driver writes.
  defp decide(observations \\ observed(), receipt_lines \\ receipts()) do
    result = core(:classify_text, [facts_text(observations), Enum.join(receipt_lines, "\n")])
    assert is_map(result), "CampaignFacts.classify_text/2: #{inspect(result)}"
    result
  end

  defp target(result, name), do: Enum.find(result.targets, &(&1.database == name))

  defp plan(result), do: Map.new(result.plan, &{&1.resource, &1.action})

  describe "pins: exactly four distinct names from three predeclared suffixes" do
    test "the parent pair and the two harness targets" do
      assert core(:pins, [@suffixes]) ==
               {:ok, %{parent: @parent, parent_demo: @demo, db1: @db1, db2: @db2}}
    end

    test "a malformed, misplaced or repeated suffix is refused" do
      for {label, suffixes, reason} <- [
            {"parent not _rm", %{@suffixes | parent: "_wm0123456789"},
             {:invalid_suffix, :parent}},
            {"parent upper-case", %{@suffixes | parent: "_rm0123456789A"},
             {:invalid_suffix, :parent}},
            {"db1 not _wm", %{@suffixes | db1: "_rm0123456789"}, {:invalid_suffix, :db1}},
            {"db2 short", %{@suffixes | db2: "_wmabcdef012"}, {:invalid_suffix, :db2}},
            {"db2 newline", %{@suffixes | db2: "_wmabcdef0123\n"}, {:invalid_suffix, :db2}},
            {"identical targets", %{@suffixes | db2: "_wm0123456789"}, :targets_identical},
            {"an extra key", Map.put(@suffixes, :db3, "_wm0000000000"), :invalid_pins}
          ] do
        assert core(:pins, [suffixes]) == {:error, reason}, label
      end
    end
  end

  describe "the strict observation and receipt grammars" do
    test "a missing, repeated, unknown or out-of-set observation is refused" do
      for {label, text} <- [
            {"missing", facts_text(Map.delete(observed(), "db2.catalog"))},
            {"repeated", facts_text(observed()) <> "\nlaunch=launched"},
            {"unknown key", facts_text(Map.put(observed(), "force", "yes"))},
            {"out of set", facts_text(observed(%{"parent.create" => "maybe"}))},
            {"not key=value", facts_text(observed()) <> "\nnoise"}
          ] do
        assert match?({:error, _}, core(:parse_observations, [text])), label
      end

      assert {:ok, %{launch: :launched, parent: %{create: :created}}} =
               core(:parse_observations, [facts_text(observed())])
    end

    test "receipts: strict lines, known prefixes, one value per key" do
      assert {:ok, %{"db1" => %{"child.claim" => "exit:0"}, "targets" => %{"db1" => @db1}}} =
               core(:parse_receipts, [Enum.join(receipts(), "\n")])

      for {label, lines} <- [
            {"a repeated key", receipts() ++ ["RM-RECEIPT db1.child.claim=exit:0"]},
            {"an unknown prefix", receipts() ++ ["RM-RECEIPT db3.outcome=ok"]},
            {"a malformed line", receipts() ++ ["RM-RECEIPT db1.child.claim"]},
            {"a value with a space", receipts() ++ ["RM-RECEIPT db1.note=a b"]},
            {"another line", receipts() ++ ["noise"]}
          ] do
        assert match?({:error, _}, core(:parse_receipts, [Enum.join(lines, "\n")])), label
      end
    end
  end

  describe "the four records, derived from positive evidence only" do
    test "a passing campaign: every target owned and dropped, rc 0, every lease released" do
      result = decide()
      assert match?(%{rc: 0, leases: :release, test: :pass, evidence: :complete}, result)
      assert Enum.map(result.targets, & &1.database) == @names

      for name <- @names,
          do:
            assert(target(result, name) == %{database: name, owned: true, disposition: :dropped})

      assert Enum.all?(result.plan, &(&1.action == :release))

      assert Enum.sort(Map.keys(plan(result))) ==
               Enum.sort(
                 ~w(campaign root:new root:old slot1 slot2 heavy) ++
                   Enum.map(@names, &("name:" <> &1))
               )
    end

    test "a stop before any effect: rc 3, nothing owned, every lease released" do
      result =
        decide(
          observed(%{
            "launch" => "not_run",
            "suite" => "not_run",
            "result_line" => "none",
            "parent.create" => "not_attempted",
            "parent.disposal" => "none",
            "parent_demo.create" => "not_attempted",
            "parent_demo.disposal" => "none",
            "db1.evidence_dir" => "absent",
            "db1.export" => "missing",
            "db2.evidence_dir" => "absent",
            "db2.export" => "missing"
          }),
          []
        )

      assert match?(%{rc: 3, leases: :release, test: :not_run}, result), inspect(result)

      for name <- @names,
          do:
            assert(
              target(result, name) == %{database: name, owned: false, disposition: :not_created}
            )

      assert Enum.all?(result.plan, &(&1.action == :release))
    end

    test "a collision at the first CREATE: no effect (rc 3), but the name stays a collision marker" do
      result =
        decide(
          observed(%{
            "launch" => "not_run",
            "suite" => "not_run",
            "result_line" => "none",
            "parent.create" => "collision",
            "parent.disposal" => "none",
            "parent_demo.create" => "not_attempted",
            "parent_demo.disposal" => "none",
            "db1.evidence_dir" => "absent",
            "db1.export" => "missing",
            "db2.evidence_dir" => "absent",
            "db2.export" => "missing"
          }),
          []
        )

      assert match?(%{rc: 3, leases: :release}, result), inspect(result)
      assert target(result, @parent) == %{database: @parent, owned: false, disposition: :foreign}
      plan = plan(result)
      assert plan["name:" <> @parent] == :keep_collision
      assert plan["campaign"] == :keep_quarantined, "a collision is reviewed before any reuse"

      for resource <- ~w(root:new root:old slot1 slot2 heavy),
          do: assert(plan[resource] == :release, resource)
    end

    test "a partial create: an owned member dropped is rc 1; retained is rc 4; the collision kept" do
      partial = %{
        "launch" => "not_run",
        "suite" => "not_run",
        "result_line" => "none",
        "parent.create" => "created",
        "parent.disposal" => "dropped",
        "parent_demo.create" => "collision",
        "parent_demo.disposal" => "none",
        "db1.evidence_dir" => "absent",
        "db1.export" => "missing",
        "db2.evidence_dir" => "absent",
        "db2.export" => "missing"
      }

      result = decide(observed(partial), [])
      assert match?(%{rc: 1, leases: :release}, result), inspect(result)
      assert target(result, @parent).disposition == :dropped
      assert target(result, @demo) == %{database: @demo, owned: false, disposition: :foreign}
      assert plan(result)["name:" <> @demo] == :keep_collision
      assert plan(result)["name:" <> @parent] == :release

      result = decide(observed(%{partial | "parent.disposal" => "retained"}), [])
      assert match?(%{rc: 4, leases: :quarantine}, result), inspect(result)
      assert plan(result)["name:" <> @parent] == :keep_quarantined
      assert plan(result)["campaign"] == :keep_quarantined
      assert plan(result)["slot1"] == :release
    end

    test "an uncertain CREATE, an absent-before-drop member, or an interruption keeps everything" do
      for {label, overrides} <- [
            {"CREATE outcome unknown",
             %{"parent.create" => "unknown", "parent.disposal" => "none"}},
            {"absent before the driver's drop", %{"parent_demo.disposal" => "absent"}},
            {"disposal never ran", %{"parent.disposal" => "not_attempted"}},
            {"drop rc 0, absence unproven", %{"parent.disposal" => "uncertain"}},
            {"interrupted", %{"interrupted" => "yes"}}
          ] do
        result = decide(observed(overrides))
        assert match?(%{rc: 5, leases: :keep}, result), "#{label}: #{inspect(result)}"
        assert Enum.all?(result.plan, &(&1.action == :keep_uncertain)), label
      end
    end
  end

  describe "the harness targets: claim, cleanup receipts and catalog" do
    test "a claim collision is foreign: never adopted, kept as a collision marker" do
      result =
        decide(
          observed(%{"suite" => "fail", "result_line" => "Result: 2/3 passed"}),
          receipts(%{
            "db1.child.claim" => "exit:3",
            "db1.cleanup.drop_attempted" => "false",
            "db1.cleanup.drop_mode" => :delete,
            "db1.cleanup.drop_result" => :delete,
            "db1.cleanup.drop_receipt" => :delete,
            "db1.cleanup.drop_protocol" => :delete,
            "db1.cleanup.blocking_before_drop" => :delete,
            "db1.cleanup.database_absent_after_drop" => :delete,
            "db1.outcome" => "error"
          })
        )

      assert target(result, @db1) == %{database: @db1, owned: false, disposition: :foreign}
      assert match?(%{rc: 1, test: :fail}, result), inspect(result)
      assert plan(result)["name:" <> @db1] == :keep_collision
    end

    test "a claim that raised, timed out unconfirmed or ended otherwise is unknown ownership" do
      for claim <- ~w(raised timeout:unconfirmed timeout:confirmed exit:1 unknown) do
        result = decide(observed(%{"suite" => "fail"}), receipts(%{"db1.child.claim" => claim}))

        assert target(result, @db1) == %{database: @db1, owned: :unknown, disposition: :uncertain},
               claim

        assert match?(%{rc: 5, leases: :keep}, result), claim
      end
    end

    test "a claim refused or never spawned is not ownership" do
      for claim <- ~w(exit:4 not_started) do
        result = decide(observed(%{"suite" => "fail"}), receipts(%{"db1.child.claim" => claim}))
        assert target(result, @db1) == %{database: @db1, owned: false, disposition: :not_created}
      end

      result =
        decide(
          observed(%{"suite" => "fail", "db1.catalog" => "present"}),
          receipts(%{"db1.child.claim" => "not_started"})
        )

      assert target(result, @db1).disposition == :foreign, "present, never ours"
    end

    test "owned and still present: retained after a typed failed drop, uncertain after an unconfirmed child" do
      result =
        decide(
          observed(%{"suite" => "fail", "db1.catalog" => "present"}),
          receipts(%{
            "db1.cleanup.drop_result" => "failed",
            "db1.cleanup.drop_receipt" => "not_verified",
            "db1.cleanup.database_absent_after_drop" => "unreported",
            "db1.cleanup.temp_folder" => "retained",
            "db1.cleanup.temp_folder_retained_reason" => "drop_failed",
            "db1.outcome" => "error"
          })
        )

      assert target(result, @db1) == %{database: @db1, owned: true, disposition: :retained}
      assert match?(%{rc: 4, leases: :quarantine, test: :fail}, result), inspect(result)

      result =
        decide(
          observed(%{"suite" => "fail", "db1.catalog" => "present"}),
          receipts(%{
            "db1.cleanup.drop_attempted" => "false",
            "db1.cleanup.drop_mode" => :delete,
            "db1.cleanup.drop_result" => :delete,
            "db1.cleanup.drop_receipt" => :delete,
            "db1.cleanup.drop_protocol" => :delete,
            "db1.cleanup.blocking_before_drop" => :delete,
            "db1.cleanup.database_absent_after_drop" => :delete,
            "db1.cleanup.temp_folder" => "retained",
            "db1.cleanup.temp_folder_retained_reason" => "unconfirmed_child",
            "db1.outcome" => "error"
          })
        )

      assert target(result, @db1).disposition == :uncertain
      assert match?(%{rc: 5, leases: :keep}, result)
    end

    test "absent is dropped only with the strict v2 drop receipts; truncated receipts never dispose" do
      for {label, overrides} <- [
            {"no drop result", %{"db1.cleanup.drop_result" => :delete}},
            {"receipt not valid", %{"db1.cleanup.drop_receipt" => "facts_missing"}},
            {"absence not reported", %{"db1.cleanup.database_absent_after_drop" => "unreported"}},
            {"v1 protocol", %{"db1.cleanup.drop_protocol" => :delete}},
            {"a blocker", %{"db1.cleanup.blocking_before_drop" => "1"}},
            {"no outcome (truncated)", %{"db1.outcome" => :delete}}
          ] do
        result = decide(observed(), receipts(overrides))
        assert target(result, @db1).disposition == :uncertain, label
        refute match?(%{rc: 0}, result), label
      end
    end

    test "receipts that say dropped against a present catalog are inconsistent and uncertain" do
      result = decide(observed(%{"db2.catalog" => "present"}))
      assert target(result, @db2).disposition == :uncertain
      assert match?(%{rc: 5, evidence: :inconsistent}, result), inspect(result)
    end

    test "an unknown catalog read never disposes an owned target" do
      result = decide(observed(%{"db1.catalog" => "unknown"}))
      assert target(result, @db1).disposition == :uncertain
      assert match?(%{rc: 5}, result)
    end

    test "no evidence directory: the claim was never reached; absent is not created, present is foreign" do
      no_db2 = %{
        "suite" => "fail",
        "db2.evidence_dir" => "absent",
        "db2.export" => "missing"
      }

      lines = Enum.reject(receipts(), &String.starts_with?(&1, "RM-RECEIPT db2."))
      result = decide(observed(no_db2), lines)
      assert target(result, @db2) == %{database: @db2, owned: false, disposition: :not_created}

      result = decide(observed(Map.put(no_db2, "db2.catalog", "present")), lines)
      assert target(result, @db2).disposition == :foreign
    end

    test "an evidence directory without receipts, or receipts without a claim line" do
      lines = Enum.reject(receipts(), &String.starts_with?(&1, "RM-RECEIPT db2."))
      result = decide(observed(%{"suite" => "fail"}), lines)
      assert target(result, @db2) == %{database: @db2, owned: :unknown, disposition: :uncertain}
      assert match?(%{rc: 5, leases: :keep}, result), "a filtered subset never succeeds"

      # A complete receipt (its outcome recorded) with no claim child: the
      # harness stopped before the claim.
      result =
        decide(
          observed(%{"suite" => "fail", "db2.export" => "sealed_verified"}),
          receipts(%{
            "db2.child.claim" => :delete,
            "db2.cleanup.drop_attempted" => "false",
            "db2.cleanup.drop_mode" => :delete,
            "db2.cleanup.drop_result" => :delete,
            "db2.cleanup.drop_receipt" => :delete,
            "db2.cleanup.drop_protocol" => :delete,
            "db2.cleanup.blocking_before_drop" => :delete,
            "db2.cleanup.database_absent_after_drop" => :delete,
            "db2.outcome" => "error"
          })
        )

      assert target(result, @db2) == %{database: @db2, owned: false, disposition: :not_created}
    end

    test "a substituted target name is inconsistent and uncertain, never disposed" do
      for overrides <- [
            %{"targets.db1" => "sdr_agent_test_wm0000000000"},
            %{"db1.target_database" => "sdr_agent_test_wm0000000000"}
          ] do
        result = decide(observed(), receipts(overrides))
        assert target(result, @db1).disposition == :uncertain, inspect(overrides)
        assert match?(%{rc: 5, evidence: :inconsistent}, result), inspect(result)
      end
    end

    test "malformed receipts are inconsistent: every harness target uncertain" do
      result = decide(observed(), receipts() ++ ["RM-RECEIPT db1.child.claim=exit:0"])
      assert match?(%{rc: 5, evidence: :inconsistent}, result), inspect(result)
      assert target(result, @db1).disposition == :uncertain
      assert target(result, @db2).disposition == :uncertain
    end
  end

  describe "test outcome and evidence: kept apart from every disposition" do
    test "only the exact campaign result line is a pass" do
      for line <- ["Result: 2 passed", "Result: 3 passed, 1 excluded", "none"] do
        result = decide(observed(%{"result_line" => line}))
        assert match?(%{rc: 5, test: :incomplete}, result), "#{line}: #{inspect(result)}"
      end
    end

    test "a failed test with everything dropped and complete evidence is rc 1" do
      result = decide(observed(%{"suite" => "fail", "result_line" => "Result: 2/3 passed"}))
      assert match?(%{rc: 1, leases: :release, test: :fail, evidence: :complete}, result)
    end

    test "evidence trouble: rc 6 with the pass and every dropped record kept" do
      for {label, overrides, evidence} <- [
            {"an export mismatch", %{"db2.export" => "mismatch"}, :inconsistent},
            {"an unsealed export", %{"db1.export" => "unsealed"}, :incomplete},
            {"a missing export", %{"db1.export" => "missing"}, :incomplete},
            {"driver evidence failed", %{"driver_evidence" => "failed"}, :incomplete}
          ] do
        result = decide(observed(overrides))

        assert match?(%{rc: 6, leases: :release, test: :pass, evidence: ^evidence}, result),
               "#{label}: #{inspect(result)}"

        assert Enum.all?(result.targets, &(&1.disposition == :dropped)), label
      end
    end

    test "evidence trouble never overrides a retained target" do
      result =
        decide(
          observed(%{"parent.disposal" => "retained", "db2.export" => "mismatch"}),
          receipts()
        )

      assert match?(%{rc: 4, leases: :quarantine, evidence: :inconsistent}, result)
    end
  end

  describe "exact membership: one record per pinned name" do
    test "a missing, extra, substituted or repeated record is refused" do
      assert {:ok, pins} = core(:pins, [@suffixes])
      record = &%{database: &1, owned: true, disposition: :dropped}
      four = Enum.map(@names, record)

      for {label, records} <- [
            {"missing", Enum.take(four, 3)},
            {"extra", four ++ [record.("sdr_agent_test_wm0000000000")]},
            {"substituted", List.replace_at(four, 3, record.("sdr_agent_test_wm0000000000"))},
            {"repeated", List.replace_at(four, 3, record.(@db1))}
          ] do
        raised =
          try do
            core(:exact_targets!, [pins, records])
          rescue
            error in ArgumentError -> error
          end

        assert match?(%ArgumentError{}, raised), "#{label}: #{inspect(raised)}"
      end

      assert core(:exact_targets!, [pins, Enum.reverse(four)]) == :ok
    end

    test "the rendered classification: closed lines, four targets, every lease, end" do
      lines = core(:render, [decide()])
      assert is_list(lines), inspect(lines)
      assert List.first(lines) == "rc=0"
      assert List.last(lines) == "end"
      assert Enum.count(lines, &String.starts_with?(&1, "target=")) == 4
      assert Enum.count(lines, &String.starts_with?(&1, "lease=")) == 10

      assert "target=#{@db2} owned=true disposition=dropped" in lines
      assert "lease=name:#{@parent} action=release" in lines

      for line <- lines,
          do: assert(line =~ ~r/\A[a-z_]+=[A-Za-z0-9_:.=\- ]+\z/ or line == "end", line)
    end

    test "the driver's classification step: the pure core, an exclusive private file, typed refusal" do
      script =
        Path.expand("../../support/release_migration/campaign_classify.exs", __DIR__)

      assert File.regular?(script), "test/support/release_migration/campaign_classify.exs"
      source = File.read!(script)
      {:__block__, _, statements} = Code.string_to_quoted!(source)
      calls = statements |> Macro.prewalk([], &collect_call/2) |> elem(1)

      for call <- [:classify_text, :render, :write, :chmod, :halt],
          do: assert(call in calls, "#{call}")

      refute Enum.any?(calls, &(&1 in [:ensure_all_started, :start_link, :cmd, :query])),
             "no application, connection or process"

      assert source =~ "File.write(out, rendered, [:exclusive])"
      assert source =~ "File.chmod(out, 0o600)"
      assert source =~ "System.halt(2)"
    end
  end

  defp collect_call({{:., _, [_module, name]}, _, _args} = node, acc) when is_atom(name),
    do: {node, [name | acc]}

  defp collect_call(node, acc), do: {node, acc}
end
