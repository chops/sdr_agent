defmodule SdrAgent.Outreach.ExceptionAncestryLoaderTest do
  @moduledoc """
  C2* slice S4 RED-1, fact collection and its consumers' first read (plan
  r2 §4.3, §5.1 `load/2` and `propose_facts/2`, §7 "loader" and T-Q1;
  handback r3 §1.1-§1.3, T-M9-T-M11; Codex S4 r3 binding details 2, 3, 5
  and 6; ADR-0005 C2* addendum 2, decisions 1-3, 6 and 7).

  Interfaces this file pins (`SdrAgent.Outreach.ExceptionAncestry`):

    * `load([{revision_id, draft_id}], tenant_id)` → `{:ok, %{revision_id
      => facts}}` (facts as `covered/1` takes them, see
      `exception_ancestry_test.exs`) or `{:error, _}`. Six single-table
      plain reads (L1-L6), each batched by `in ^ids`, whatever the batch.
    * `propose_facts(propose_args, tenant_id)` → `{:ok, facts}` for the
      prospective revision 1 of `Draft :propose` (`origin_agent_run_id`,
      `decision_id`, `model_invocation_id`, `citations`), or `{:error, _}`.
      Five single-table plain reads (P0, P3-P6). P0 validates the
      Decision: this tenant, this run, `:draft_proposal`, `:llm` and
      exactly the named invocation (binding 2).
    * `SdrAgent.Outreach.exception_derived(revisions, actor: actor)` →
      `{:ok, MapSet.t(revision_id)}` or `{:error, _}`, over revisions the
      actor already read (binding 2): never a set for no actor, a
      tenantless operator or an operator of another tenant.

  Outcomes are always read through `covered/1`: `{:ok, pairs}` with the
  covered `{release, invocation}` pairs, or `{:error, :lineage_unavailable}`
  (a named row not found in the tenant), `{:error, :lineage_malformed}` (a
  corrupted lineage) or another `{:error, _}` (a query fault). Never an
  empty set for bad facts.

  Statement counts (T-Q1, binding 5) are PHYSICAL statements: every
  `[:sdr_agent, :repo, :query]` event in the VM during exactly one
  `load/2` or `propose_facts/2` call (`InboxFixtures.trace_queries/1`;
  `config :ash, disable_async?: true` in test, so relationship and lazy
  loads would appear there too). Each must be a plain SELECT naming one
  table, with no lock clause and no output or content column. The
  per-pair use-authority reads and the full edit cost (T-Q1 (iii),
  `6 + 3k` / `3k`) need the check sites and are RED-2.

  Fixtures: `SdrAgent.DemoDraftFixtures`. The `:ordinary` describes need
  nothing from S3. The "exception-derived" describes and T-Q1 (i) need
  S3's H2 harness ("S3 dependency" there); until that resolves at the
  rebased base they fail on the RED dependency message, not on an S4 guard.

  RED report labels: every test fails on its S4 guard
  (`ExceptionAncestry.<fun>/<n>` or `Outreach.exception_derived/2` "is not
  implemented"), placed after its fixtures: structural. There is no
  `control:` test in this file.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.DemoDraftFixtures
  import SdrAgent.OutreachFixtures, only: [operator!: 2]

  alias Ecto.Adapters.SQL
  alias SdrAgent.Agents
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.GateFixtures
  alias SdrAgent.InboxFixtures
  alias SdrAgent.Outreach

  @moduletag ownership_timeout: 900_000

  @ancestry SdrAgent.Outreach.ExceptionAncestry
  @content_columns ~w(parsed_output validation_errors refusal error usage subject body_text
                      angle cta diff_from_parent diff_from_ai_baseline quote claim text
                      source_location rationale outcome_detail)
  @load_tables %{
    "draft_revisions" => 1,
    "revision_citations" => 1,
    "evidence_claims" => 1,
    "model_invocations" => 2,
    "model_result_releases" => 1
  }
  @propose_tables %{
    "decisions" => 1,
    "evidence_claims" => 1,
    "model_invocations" => 2,
    "model_result_releases" => 1
  }
  @fault_tables ~w(draft_revisions revision_citations evidence_claims model_invocations
                   model_result_releases)
  @reloaded ["model_invocations", "model_result_releases"]
  @release_fields [
    :id,
    :tenant_id,
    :model_invocation_id,
    :disposition,
    :exception_policy_id,
    :exception_expires_at,
    :exception_basis,
    :exception_basis_sha256
  ]
  @invocation_fields [
    :id,
    :tenant_id,
    :agent_run_id,
    :sequence_in_run,
    :status,
    :validation_status,
    :ledger_generation,
    :provider,
    :purpose
  ]

  describe "loader: ordinary facts (L1-L6)" do
    setup ctx, do: %{base: ctx |> base!(6) |> env!(:ordinary)}

    test "T-M9 Fake, released, withheld, failed and off-purpose no-release facts are never covered, never errors",
         %{base: base} do
      [step | _] = base.steps
      d = ordinary_draft!(base, step, edits: 2)
      t = tenant(base)

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), t, rev.id) == {:ok, []},
               "revision #{rev.revision_number}: not exception-derived, and not an error"
      end

      assert outcome(pairs([base.revision]), t, base.revision.id) == {:ok, []},
             "the Fake hand-off draft: not exception-derived"
    end

    test "T-M10 a cited claim naming an invocation of another tenant is unavailable", %{
      base: base
    } do
      [step | _] = base.steps
      d = draft!(base, step, cite: [{:cross, :fake}], edits: 1)
      [entry] = d.cited
      move_to_foreign_tenant!(:model_invocations, entry.invocation.id)

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), tenant(base), rev.id) == {:error, :lineage_unavailable},
               "revision #{rev.revision_number}"
      end
    end

    test "T-M10 a cited claim not found in the tenant is unavailable", %{base: base} do
      [step | _] = base.steps
      d = draft!(base, step, cite: [{:cross, :released}], edits: 1)
      [claim] = d.claims
      move_to_foreign_tenant!(:evidence_claims, claim.id)

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), tenant(base), rev.id) == {:error, :lineage_unavailable},
               "revision #{rev.revision_number}"
      end
    end

    test "T-M10 an agent revision's own invocation not found in the tenant is unavailable",
         %{base: base} do
      [step | _] = base.steps
      d = draft!(base, step, proposal: :fake, edits: 1)
      move_to_foreign_tenant!(:model_invocations, d.proposal.invocation.id)

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), tenant(base), rev.id) == {:error, :lineage_unavailable},
               "revision #{rev.revision_number}"
      end
    end

    test "binding 2: a pair whose revision is not in the named draft is unavailable",
         %{base: base} do
      [step | _] = base.steps
      %{revisions: [rev]} = draft!(base, step)

      assert outcome([{rev.id, base.draft.id}], tenant(base), rev.id) ==
               {:error, :lineage_unavailable}
    end

    test "A2 decision 1: a corrupted lineage (a parent in another draft) is malformed",
         %{base: base} do
      [step | _] = base.steps
      %{revisions: [_rev1, rev2]} = draft!(base, step, edits: 1)
      reparent!(rev2, base.revision.id)

      assert outcome(pairs([rev2]), tenant(base), rev2.id) == {:error, :lineage_malformed}
    end

    test "A2 decision 6: a query fault in any of the reads is an error, never facts",
         %{base: base} do
      [step | _] = base.steps
      d = draft!(base, step, cite: [{:cross, :released}], edits: 1)
      start = List.last(d.revisions)

      for table <- @fault_tables do
        result = with_fault(table, fn -> outcome(pairs(d.revisions), tenant(base), start.id) end)
        assert match?({:error, _}, result), "#{table} unreadable: #{inspect(result)}"
      end
    end

    test "T-Q1 an ordinary batch: exactly six single-table plain reads, no output or content column",
         %{base: base} do
      [one, two | _] = base.steps
      a = ordinary_draft!(base, one, edits: 2)
      b = cross_ordinary!(base, two)
      starts = [List.last(a.revisions), List.last(b.revisions), base.revision]
      {result, queries} = traced(:load, [pairs(starts), tenant(base)])

      assert match?({:ok, %{}}, result), inspect(result)
      assert_fact_reads(queries, @load_tables, "an ordinary batch of three drafts")
    end
  end

  describe "loader: exception-derived facts (S3 H2)" do
    setup ctx, do: %{base: ctx |> base!(8) |> env!(:demo)}

    test "T-M7 a demo proposal covers every revision of its draft with the same release",
         %{base: base} do
      [step | _] = base.steps
      d = demo_draft!(base, step, edits: 2)
      expected = {:ok, Enum.sort(demo_pairs([d.proposal]))}

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), tenant(base), rev.id) == expected,
               "revision #{rev.revision_number}: a human edit never removes the fact"
      end
    end

    test "T-M7 the sequence bound: a demo call after the proposal covers nothing", %{base: base} do
      [step | _] = base.steps
      d = draft!(base, step, after: [{:demo, :qualification}], edits: 1)

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), tenant(base), rev.id) == {:ok, []},
               "revision #{rev.revision_number}"
      end
    end

    test "T-M1 a mixed run: the extraction's demo release covers the released proposal's draft, once",
         %{base: base} do
      [step | _] = base.steps
      d = mixed_draft!(base, step, edits: 2)
      expected = {:ok, Enum.sort(demo_pairs(d.origin))}

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), tenant(base), rev.id) == expected,
               "revision #{rev.revision_number}: origin-run and cited, deduplicated"
      end
    end

    test "T-M5 T-M9 cross run: only the demo-extracted claim of another run covers the draft",
         %{base: base} do
      [step | _] = base.steps
      d = cross_run_draft!(base, step, edits: 1)
      expected = {:ok, Enum.sort(demo_pairs(d.cited))}
      assert length(demo_pairs(d.cited)) == 1, "the fixture cites exactly one demo release"

      for rev <- d.revisions do
        assert outcome(pairs(d.revisions), tenant(base), rev.id) == expected,
               "revision #{rev.revision_number}: Fake, released, withheld and failed cover nothing"
      end
    end

    test "T-M4 another run of the lead with a demo release, neither origin nor cited, covers nothing",
         %{base: base} do
      [step | _] = base.steps
      _uncited = cross!(base, :demo)
      d = draft!(base, step, origin: [{:withheld, :qualification}], cite: [{:cross, :released}])

      assert outcome(pairs(d.revisions), tenant(base), hd(d.revisions).id) == {:ok, []}
    end

    test "binding 6: every covered pair carries the metadata use_authority/3 reads, with no reload",
         %{base: base} do
      [step | _] = base.steps

      d =
        draft!(base, step,
          origin: [{:demo, :evidence_extraction}],
          cite: [{:origin, 0}, {:cross, :demo}],
          edits: 1
        )

      start = List.last(d.revisions)
      result = raw(pairs(d.revisions), tenant(base), start.id)
      assert match?({:ok, [_, _]}, result), inspect(result)
      {:ok, covered} = result

      for {release, invocation} <- covered do
        assert_loaded(release, @release_fields, "release")
        assert_loaded(invocation, @invocation_fields, "invocation")
      end

      assert Code.ensure_loaded?(DemoException) and
               function_exported?(DemoException, :use_authority, 3),
             "C2* S4 RED dependency (S3, not S4): DemoException.use_authority/3 is not available"

      for {release, invocation} <- covered do
        args = [release, invocation, SdrAgent.Clock.utc_now()]

        {authority, queries} =
          InboxFixtures.trace_queries(fn -> apply(DemoException, :use_authority, args) end)

        assert authority == :ok, "use authority over the loaded pair: #{inspect(authority)}"
        reread = for {sql, _} <- queries, Enum.any?(tables_of(sql), &(&1 in @reloaded)), do: sql
        assert reread == [], "the pair is not reloaded: #{inspect(reread)}"
      end
    end

    test "T-M11 propose_facts/2: an earlier demo call and a cited demo claim are covered, a later one is not",
         %{base: base} do
      [step | _] = base.steps
      run = run!(base)
      early = invocation!(base, run, {:demo, :evidence_extraction})
      _withheld = invocation!(base, run, {:withheld, :qualification})
      proposal = invocation!(base, run, {:released, :outreach_proposal})
      _late = invocation!(base, run, {:demo, :qualification})
      decision = proposal_decision!(base, run, proposal.invocation)
      cited = cross!(base, :demo)
      claims = [claim!(base, cited.invocation.id), claim!(base, early.invocation.id)]
      args = propose_attrs(base, step, run, decision, claims)

      assert propose_outcome(args, tenant(base)) == {:ok, Enum.sort(demo_pairs([early, cited]))}
    end

    test "Outreach.exception_derived/2: exactly the demo, mixed and cross-run drafts' revisions, for admin, reviewer and auditor",
         %{base: base} = ctx do
      [s1, s2, s3, s4 | _] = base.steps
      derived = [demo_draft!(base, s1, edits: 2), mixed_draft!(base, s2, edits: 1)]
      derived = derived ++ [cross_run_draft!(base, s3)]

      ordinary =
        draft!(base, s4, origin: [{:withheld, :qualification}], cite: [{:cross, :released}])

      revisions = Enum.flat_map(derived ++ [ordinary], & &1.revisions) ++ [base.revision]
      expected = derived |> Enum.flat_map(& &1.revisions) |> MapSet.new(& &1.id)

      for role <- [:admin, :reviewer, :auditor] do
        assert exception_derived(revisions, operator!(ctx, role)) == {:ok, expected}, "#{role}"
      end
    end
  end

  describe "T-Q1 physical statements of fact collection (binding 5)" do
    @tag timeout: 1_800_000
    test "(i) load/2: exactly six single-table statements for 1 and for 30 starting revisions across 30 drafts (S3 H2)",
         ctx do
      base = ctx |> base!(32) |> env!(:demo)
      t = tenant(base)
      cross = Enum.map([:demo, :released, :withheld, :failed, :fake], &cross!(base, &1))
      shared = Enum.map(cross, &{claim!(base, &1.invocation.id), &1})

      drafts =
        for {step, i} <- base.steps |> Enum.take(30) |> Enum.with_index() do
          {claim, entry} = Enum.at(shared, rem(i, 5))

          draft!(base, step,
            origin: [{:demo, :evidence_extraction}, {:withheld, :qualification}],
            cite: [{:claim, claim, entry}],
            edits: 2
          )
        end

      starts = Enum.map(drafts, &List.last(&1.revisions))
      assert length(starts) == 30
      assert Enum.all?(drafts, &match?([_, _, _], &1.revisions))

      {one, one_queries} = traced(:load, [pairs([hd(starts)]), t])
      assert_fact_reads(one_queries, @load_tables, "1 starting revision")
      {all, all_queries} = traced(:load, [pairs(starts), t])
      assert_fact_reads(all_queries, @load_tables, "30 starting revisions across 30 drafts")

      assert covered_from(one, hd(starts).id) == expected(hd(drafts))

      mismatches =
        for {d, start} <- Enum.zip(drafts, starts),
            covered_from(all, start.id) != expected(d),
            do: {start.id, covered_from(all, start.id), expected(d)}

      assert mismatches == []
    end

    test "(ii) propose_facts/2: exactly five single-table statements for 1 and for 20 citations, cross-run included",
         ctx do
      base = ctx |> base!(2) |> env!(:ordinary)
      [step | _] = base.steps
      run = run!(base)
      origin = [{:withheld, :qualification}, {:released, :evidence_extraction}]
      origin = Enum.map(origin, &invocation!(base, run, &1))
      proposal = invocation!(base, run, {:released, :outreach_proposal})
      decision = proposal_decision!(base, run, proposal.invocation)
      cross = [:fake, :released, :withheld, {:none, :evidence_extraction}, :released]
      named = origin ++ Enum.map(cross, &cross!(base, &1))

      claims =
        for i <- 0..19, do: claim!(base, Enum.at(named, rem(i, length(named))).invocation.id)

      cross_claim = List.last(claims)
      t = tenant(base)

      {one, one_queries} =
        traced(:propose_facts, [propose_attrs(base, step, run, decision, [cross_claim]), t])

      assert_fact_reads(one_queries, @propose_tables, "1 citation (cross-run)")

      {all, all_queries} =
        traced(:propose_facts, [propose_attrs(base, step, run, decision, claims), t])

      assert_fact_reads(all_queries, @propose_tables, "20 citations")
      assert facts_outcome(one) == {:ok, []}
      assert facts_outcome(all) == {:ok, []}
    end
  end

  describe "propose_facts/2: P0, P3-P6 (ordinary)" do
    setup ctx, do: %{base: ctx |> base!(2) |> env!(:ordinary)}

    test "T-M11 Fake, released, withheld and no-release origin-run or cited calls are classified not covered",
         %{base: base} do
      [step | _] = base.steps
      run = run!(base)
      origin = [{:withheld, :qualification}, {:none, :evidence_extraction}]
      origin = Enum.map(origin, &invocation!(base, run, &1))
      proposal = invocation!(base, run, {:released, :outreach_proposal})
      decision = proposal_decision!(base, run, proposal.invocation)
      cross = Enum.map([:fake, :released, :withheld, {:none, :qualification}], &cross!(base, &1))
      claims = Enum.map(origin ++ cross, &claim!(base, &1.invocation.id)) ++ [claim!(base, nil)]

      assert propose_outcome(propose_attrs(base, step, run, decision, claims), tenant(base)) ==
               {:ok, []}
    end

    test "T-M11 a claim naming another tenant's invocation, a claim not in the tenant and an unknown claim are unavailable",
         %{base: base} do
      [step | _] = base.steps
      run = run!(base)
      proposal = invocation!(base, run, {:released, :outreach_proposal})
      decision = proposal_decision!(base, run, proposal.invocation)
      foreign = cross!(base, :fake)
      names_foreign = claim!(base, foreign.invocation.id)
      move_to_foreign_tenant!(:model_invocations, foreign.invocation.id)
      moved = claim!(base, cross!(base, :released).invocation.id)
      move_to_foreign_tenant!(:evidence_claims, moved.id)

      for {label, claim} <- [
            {"a claim naming another tenant's invocation", names_foreign},
            {"a claim not in the tenant", moved},
            {"an unknown claim id", %{id: Ash.UUIDv7.generate()}}
          ] do
        args = propose_attrs(base, step, run, decision, [claim])

        assert propose_outcome(args, tenant(base)) == {:error, :lineage_unavailable}, label
      end
    end

    test "binding 2: P0 requires this run's :llm :draft_proposal Decision on exactly the named invocation",
         %{base: base} do
      [step | _] = base.steps
      run = run!(base)
      proposal = invocation!(base, run, {:released, :outreach_proposal})
      sibling = invocation!(base, run, {:released, :evidence_extraction})
      decision = proposal_decision!(base, run, proposal.invocation)
      other_run = run!(base)
      other = proposal_decision!(base, other_run, invocation!(base, other_run, :fake).invocation)
      angle = decision!(base, run, kind: :angle, mode: :llm, invocation: proposal.invocation)
      rule = decision!(base, run, kind: :draft_proposal, mode: :deterministic)
      args = propose_attrs(base, step, run, decision, [])
      t = tenant(base)

      malformed = [
        {"a Decision of another run",
         %{args | decision_id: other.id, model_invocation_id: other.model_invocation_id}},
        {"another invocation than the Decision's",
         %{args | model_invocation_id: sibling.invocation.id}},
        {"an :angle Decision", %{args | decision_id: angle.id}},
        {"a deterministic Decision", %{args | decision_id: rule.id}}
      ]

      for {label, bad} <- malformed do
        assert propose_outcome(bad, t) == {:error, :lineage_malformed}, label
      end

      assert propose_outcome(%{args | decision_id: Ash.UUIDv7.generate()}, t) ==
               {:error, :lineage_unavailable},
             "an unknown Decision"

      assert propose_outcome(args, t) == {:ok, []}, "the valid inputs"
    end
  end

  describe "Outreach.exception_derived/2 (ordinary)" do
    setup ctx, do: %{base: ctx |> base!(4) |> env!(:ordinary)}

    test "not derived is a fact: an ordinary draft and the Fake hand-off draft give the empty set",
         %{base: base} = ctx do
      [step | _] = base.steps
      d = ordinary_draft!(base, step, edits: 1)
      revisions = d.revisions ++ [base.revision]

      for role <- [:admin, :reviewer, :auditor] do
        assert exception_derived(revisions, operator!(ctx, role)) == {:ok, MapSet.new()},
               "#{role}"
      end
    end

    test "A2 decision 6: a lineage error in any revision is an error, never a set",
         %{base: base} = ctx do
      [one, two | _] = base.steps
      broken = draft!(base, one, cite: [{:cross, :fake}], edits: 1)
      [entry] = broken.cited
      ordinary = ordinary_draft!(base, two)
      move_to_foreign_tenant!(:model_invocations, entry.invocation.id)

      assert exception_derived(ordinary.revisions ++ broken.revisions, operator!(ctx, :admin)) ==
               {:error, :lineage_unavailable}
    end

    test "binding 2: no actor, a tenantless operator and an operator of another tenant get an error, never a set",
         %{base: base} = ctx do
      [step | _] = base.steps
      d = ordinary_draft!(base, step)
      reviewer = operator!(ctx, :reviewer)

      for actor <- [
            nil,
            %{reviewer | tenant_id: nil},
            %{reviewer | tenant_id: Ash.UUIDv7.generate()}
          ] do
        result = exception_derived(d.revisions, actor)

        assert match?({:error, _}, result),
               "#{inspect(actor && actor.tenant_id)}: #{inspect(result)}"
      end
    end
  end

  ## Fixture shorthands

  # A second ordinary draft, citing only another run's released claim.
  defp cross_ordinary!(base, step),
    do: draft!(base, step, origin: [{:released, :qualification}], cite: [{:cross, :released}])

  defp decision!(base, run, opts) do
    invocation = Keyword.get(opts, :invocation)

    provenance =
      case Keyword.fetch!(opts, :mode) do
        :llm -> %{model_invocation_id: invocation.id, output_pointer: ""}
        :deterministic -> %{rule_id: "c2star-s4-fixture", rule_version: "1"}
      end

    attrs =
      Map.merge(provenance, %{
        agent_run_id: run.id,
        kind: Keyword.fetch!(opts, :kind),
        mode: Keyword.fetch!(opts, :mode),
        subject_resource: "SdrAgent.Sales.Lead",
        subject_id: base.lead.id,
        inputs: %{"fixture" => "c2star-s4"},
        outcome: "fixture",
        idempotency_key: "c2star-s4:decision:#{System.unique_integer([:positive])}"
      })

    {:ok, decision} = Agents.record_decision(attrs, actor: base.ctx.agent)
    decision
  end

  defp tenant(base), do: base.ctx.tenant.id

  defp expected(d), do: {:ok, Enum.sort(demo_pairs(d.origin ++ d.cited))}

  ## The guarded calls

  defp guard!(fun, arity) do
    assert Code.ensure_loaded?(@ancestry) and function_exported?(@ancestry, fun, arity),
           "C2* S4: #{inspect(@ancestry)}.#{fun}/#{arity} is not implemented"
  end

  defp call(fun, args) do
    guard!(fun, length(args))
    attempt(fn -> apply(@ancestry, fun, args) end)
  end

  defp traced(fun, args) do
    guard!(fun, length(args))
    InboxFixtures.trace_queries(fn -> attempt(fn -> apply(@ancestry, fun, args) end) end)
  end

  defp exception_derived(revisions, actor) do
    assert Code.ensure_loaded?(Outreach) and function_exported?(Outreach, :exception_derived, 2),
           "C2* S4: SdrAgent.Outreach.exception_derived/2 is not implemented"

    args = [revisions, [actor: actor]]
    attempt(fn -> apply(Outreach, :exception_derived, args) end)
  end

  # load/2 for `input` ({revision_id, draft_id} pairs), then covered/1 of
  # `start`'s facts.
  defp raw(input, tenant_id, start) do
    case call(:load, [input, tenant_id]) do
      {:ok, %{} = by_start} -> covered_of(Map.fetch(by_start, start), start)
      {:error, _} = error -> error
      other -> {:unexpected_load_result, other}
    end
  end

  defp covered_of({:ok, facts}, _start), do: call(:covered, [facts])
  defp covered_of(:error, start), do: {:no_facts_for_start, start}

  defp outcome(input, tenant_id, start), do: input |> raw(tenant_id, start) |> normalize()

  defp covered_from({:ok, %{} = by_start}, start),
    do: by_start |> Map.fetch(start) |> covered_of(start) |> normalize()

  defp covered_from(other, _start), do: {:unexpected_load_result, other}

  defp propose_outcome(args, tenant_id),
    do: facts_outcome(call(:propose_facts, [args, tenant_id]))

  defp facts_outcome({:ok, facts}), do: normalize(call(:covered, [facts]))
  defp facts_outcome({:error, _} = error), do: error
  defp facts_outcome(other), do: {:unexpected_propose_facts_result, other}

  defp normalize({:ok, pairs}) when is_list(pairs),
    do: {:ok, pairs |> Enum.map(&pair_ids/1) |> Enum.sort()}

  defp normalize(other), do: other

  defp pair_ids({%{id: release, model_invocation_id: id}, %{id: id}}), do: {release, id}
  defp pair_ids(other), do: {:not_a_release_and_its_invocation, other}

  defp attempt(fun) do
    fun.()
  rescue
    error -> {:raised, error}
  catch
    kind, value -> {:caught, kind, value}
  end

  # Runs `fun` with `table` renamed inside a savepoint (rolled back with the
  # rename), so every read of it fails as a real query error.
  defp with_fault(table, fun) when table in @fault_tables do
    Repo.transaction(fn ->
      SQL.query!(Repo, ~s(ALTER TABLE "#{table}" RENAME TO "#{table}_c2star_fault"), [])
      Repo.rollback({:result, fun.()})
    end)
    |> case do
      {:error, {:result, result}} -> result
      other -> {:fault_fixture_failed, other}
    end
  end

  ## Statement and field checks

  defp assert_fact_reads(queries, expected, label) do
    sql = Enum.map(queries, &elem(&1, 0))
    tables = Enum.map(sql, &tables_of/1)
    count = expected |> Map.values() |> Enum.sum()

    assert length(sql) == count,
           "#{label}: #{length(sql)} statements, not #{count}: #{inspect(tables)}"

    assert Enum.all?(tables, &match?([_], &1)),
           "#{label}: one table per statement: #{inspect(tables)}"

    assert tables |> List.flatten() |> Enum.frequencies() == expected, label
    Enum.each(sql, &assert_plain_metadata_read(&1, label))
  end

  defp assert_plain_metadata_read(sql, label) do
    assert sql =~ ~r/\A\s*SELECT\b/, "#{label}: a plain read: #{sql}"
    refute GateFixtures.lock?(sql), "#{label}: no lock clause: #{sql}"
    selected = Enum.filter(@content_columns, &String.contains?(sql, ~s(."#{&1}")))
    assert selected == [], "#{label}: no output or content column: #{inspect(selected)}: #{sql}"
  end

  defp tables_of(sql) do
    ~r/\b(?:FROM|JOIN)\s+"([a-z_]+)"/
    |> Regex.scan(sql, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp assert_loaded(record, fields, label) do
    missing =
      fields
      |> Enum.map(&{&1, Map.get(record, &1, :absent)})
      |> Enum.filter(fn {_field, value} -> not loaded?(value) end)

    assert missing == [],
           "#{label}: fields use_authority/3 reads are not loaded: #{inspect(missing)}"
  end

  defp loaded?(value) when value in [nil, :absent], do: false
  defp loaded?(%Ash.NotLoaded{}), do: false
  defp loaded?(%Ash.ForbiddenField{}), do: false
  defp loaded?(_value), do: true
end
