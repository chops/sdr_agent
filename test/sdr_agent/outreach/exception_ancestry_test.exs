defmodule SdrAgent.Outreach.ExceptionAncestryTest do
  @moduledoc """
  C2* slice S4 RED-1, the rule (plan r2 §5.1 `covered/1`, §7 T-M7; handback
  r3 §1.1 "Classification" and T-M9; ADR-0005 C2* addendum 2, decisions
  1-3 and 6).

  `SdrAgent.Outreach.ExceptionAncestry.covered/1` is pure: no database, no
  clock, no selector, no Source. Its input is the loader's facts, and this
  file pins that shape (handback r3 L1-L6):

      %{
        start: revision_id,           # R
        tenant_id: tenant_id,         # the tenant the facts were read in
        revisions: [%DraftRevision{}],        # L1: R's draft's revisions
        citations: [%RevisionCitation{}],     # L2: draft_revision_id, evidence_claim_id
        claims: [%EvidenceClaim{}],           # L3: id, tenant_id, model_invocation_id
        invocations: [%ModelInvocation{}],    # L4 ∪ L5 (an id may appear twice)
        releases: [%ModelResultRelease{}]     # L6: the optional release of each
      }

  It returns `{:ok, [{release, invocation}]}`, one pair per covered release
  (deduplicated by release id, in any order), or an error, never an empty
  list for bad facts:

    * `{:error, :lineage_malformed}` when R's lineage breaks decision 1
      (tenant and draft, parent = n - 1, baseline an agent revision with a
      lower number, no parent exactly at number 1, an agent member naming
      its run, Decision and an invocation of that run), including a parent
      or baseline outside the loaded revisions (plan r2 §5.1);
    * `{:error, :lineage_unavailable}` when a fact named by an id is not in
      the facts: R itself, an agent member's own invocation, a cited claim,
      or the invocation a claim names (decision 6).

  An invocation that is read and has no release, or a released, withheld or
  calibration release, is a fact, not an error, and is never covered.

  RED report labels: every test fails on its guard at this head
  (structural: `ExceptionAncestry` is absent). There is no `control:` test
  in this file. Each guarded call runs bounded (2 s) so a looping GREEN
  fails as an assertion, not a timeout.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Outreach.DraftRevision
  alias SdrAgent.Outreach.RevisionCitation
  alias SdrAgent.Research.EvidenceClaim

  @ancestry SdrAgent.Outreach.ExceptionAncestry

  @malformed [
    :cross_draft_parent,
    :number_gap,
    :baseline_human,
    :baseline_not_lower,
    :foreign_tenant_member,
    :agent_without_invocation,
    :agent_without_run,
    :agent_without_decision,
    :invocation_of_another_run,
    :parent_outside_loaded_set,
    :baseline_outside_loaded_set,
    :second_without_parent,
    :first_with_parent,
    :parent_cycle
  ]

  @unavailable [
    :start_absent,
    :own_invocation_absent,
    :claim_absent,
    :cited_invocation_absent
  ]

  describe "rule: covered releases (A2 decisions 1-3)" do
    test "T-M7 valid chains 1, 1<-2 and 1<-2<-3: the origin run up to the agent revision's own call, plus the cited claims" do
      c = chain()
      expected = sorted([c.release.x1, c.release.y1])

      for n <- 1..3 do
        assert covered(facts(c, c.r[n])) == {:ok, expected},
               "revision #{n}: the origin-run demo release before the proposal and the cited claim's"
      end
    end

    test "T-M7 the sequence bound: the agent revision's own call counts, a later call of the run does not" do
      c = chain()

      rows =
        c.rows
        |> change(:releases, c.release.x1.id, disposition: :released)
        |> change(:releases, c.release.x3.id, disposition: :demo_exception)

      # X4 (sequence 4, after the proposal X3) keeps its demo release.
      for n <- 1..3 do
        assert covered(facts(c, c.r[n], rows)) ==
                 {:ok, sorted([c.release.x3, c.release.y1])},
               "revision #{n}: X3 (own call) and Y1 (cited) only; X4 is after the proposal"
      end
    end

    test "T-M7 only R's lineage counts: a citation of a later revision is not covered from an earlier one" do
      c = chain()
      z1 = invocation(c.w, Ecto.UUID.generate(), 1)
      z1_release = release(c.w, z1, :demo_exception)
      cz = claim(c.w, z1.id)

      rows =
        c.rows
        |> add(:invocations, z1)
        |> add(:releases, z1_release)
        |> add(:claims, cz)
        |> add(:citations, citation(c.r[3], cz))

      assert covered(facts(c, c.r[3], rows)) ==
               {:ok, sorted([c.release.x1, c.release.y1, z1_release])}

      for n <- 1..2 do
        assert covered(facts(c, c.r[n], rows)) == {:ok, sorted([c.release.x1, c.release.y1])},
               "revision #{n} does not descend from revision 3"
      end
    end

    test "T-M7 deduplicated by release id: an origin-run release also cited twice, and an invocation read twice" do
      c = chain()
      c2 = claim(c.w, c.x[1].id)
      c3 = claim(c.w, c.x[1].id)

      rows =
        c.rows
        |> add(:claims, c2)
        |> add(:claims, c3)
        |> add(:citations, citation(c.r[1], c2))
        |> add(:citations, citation(c.r[1], c3))
        # L4 (named) and L5 (origin run) both return X1 and X3.
        |> add(:invocations, c.x[1])
        |> add(:invocations, c.x[3])

      assert covered(facts(c, c.r[1], rows)) == {:ok, sorted([c.release.x1, c.release.y1])}
    end

    test "T-M7 a claim naming no invocation is not covered and is not an error" do
      c = chain()
      none = claim(c.w, nil)
      rows = c.rows |> add(:claims, none) |> add(:citations, citation(c.r[1], none))

      assert covered(facts(c, c.r[1], rows)) == {:ok, sorted([c.release.x1, c.release.y1])}
    end

    test "T-M7 every agent member contributes its own run and its own bound" do
      c = chain()
      run_w = Ecto.UUID.generate()
      w1 = invocation(c.w, run_w, 1)
      w2 = invocation(c.w, run_w, 2)
      w1_release = release(c.w, w1, :demo_exception)
      w2_release = release(c.w, w2, :demo_exception)

      # Revision 3 is an agent revision of run W whose own call is W1.
      rows =
        c.rows
        |> change(:revisions, c.r[3].id,
          author_type: :agent,
          agent_run_id: run_w,
          decision_id: Ecto.UUID.generate(),
          model_invocation_id: w1.id,
          ai_baseline_revision_id: nil
        )
        |> add(:invocations, w1)
        |> add(:invocations, w2)
        |> add(:releases, w1_release)
        |> add(:releases, w2_release)

      assert covered(facts(c, c.r[3], rows)) ==
               {:ok, sorted([c.release.x1, c.release.y1, w1_release])},
             "X1 (run X, up to X3), Y1 (cited) and W1 (run W, up to W1); not X4 or W2"

      assert covered(facts(c, c.r[1], rows)) == {:ok, sorted([c.release.x1, c.release.y1])}
    end

    test "T-M9 Fake, released, withheld, calibration and no-release invocations are readable, never covered, never errors" do
      c = chain()
      fake = invocation(c.w, Ecto.UUID.generate(), 1, provider: :fake, ledger_generation: 2)
      undecided = invocation(c.w, Ecto.UUID.generate(), 1)
      withheld = invocation(c.w, Ecto.UUID.generate(), 1)
      cited = [fake, undecided, withheld]
      claims = Enum.map(cited, &claim(c.w, &1.id))

      rows =
        c.rows
        |> change(:releases, c.release.x1.id, disposition: :released)
        |> change(:releases, c.release.x4.id, disposition: :withheld)
        |> change(:releases, c.release.y1.id, disposition: :calibration)
        |> add(:releases, release(c.w, withheld, :withheld))
        |> add_all(:invocations, cited)
        |> add_all(:claims, claims)
        |> add_all(:citations, Enum.map(claims, &citation(c.r[1], &1)))

      for n <- 1..3 do
        assert covered(facts(c, c.r[n], rows)) == {:ok, []},
               "revision #{n}: not exception-derived, and not an error"
      end
    end
  end

  describe "rule: malformed lineage (A2 decision 1)" do
    for kind <- @malformed do
      test "T-M7 malformed: #{kind}" do
        assert covered(malformed(unquote(kind))) == {:error, :lineage_malformed}
      end
    end
  end

  describe "rule: unavailable facts (A2 decision 6)" do
    for kind <- @unavailable do
      test "T-M7 unavailable: #{kind}" do
        assert covered(unavailable(unquote(kind))) == {:error, :lineage_unavailable}
      end
    end
  end

  ## The valid chain

  # Revision 1 is the agent revision of run X whose own call is X3; 2 and 3
  # are human revisions with baseline 1. Run X: X1 demo, X2 released, X3 the
  # proposal (released), X4 demo after the proposal. Every revision cites
  # claim C1, which names Y1 (run Y, demo).
  defp chain do
    w = %{
      tenant: Ecto.UUID.generate(),
      draft: Ecto.UUID.generate(),
      run_x: Ecto.UUID.generate(),
      run_y: Ecto.UUID.generate()
    }

    x = Map.new(1..4, &{&1, invocation(w, w.run_x, &1)})
    y1 = invocation(w, w.run_y, 1)
    r1 = revision(w, 1, author_type: :agent, agent_run_id: w.run_x, model_invocation_id: x[3].id)
    r2 = revision(w, 2, parent_revision_id: r1.id, ai_baseline_revision_id: r1.id)
    r3 = revision(w, 3, parent_revision_id: r2.id, ai_baseline_revision_id: r1.id)
    c1 = claim(w, y1.id)

    releases = %{
      x1: release(w, x[1], :demo_exception),
      x2: release(w, x[2], :released),
      x3: release(w, x[3], :released),
      x4: release(w, x[4], :demo_exception),
      y1: release(w, y1, :demo_exception)
    }

    %{
      w: w,
      x: x,
      y1: y1,
      r: %{1 => r1, 2 => r2, 3 => r3},
      c1: c1,
      release: releases,
      rows: %{
        revisions: [r1, r2, r3],
        citations: Enum.map([r1, r2, r3], &citation(&1, c1)),
        claims: [c1],
        invocations: Map.values(x) ++ [y1],
        releases: Map.values(releases)
      }
    }
  end

  ## Malformed and unavailable variants of the chain

  defp malformed(:cross_draft_parent) do
    c = chain()
    other = %{c.r[1] | id: Ecto.UUID.generate(), draft_id: Ecto.UUID.generate()}

    rows =
      c.rows
      |> add(:revisions, other)
      |> change(:revisions, c.r[2].id, parent_revision_id: other.id)

    facts(c, c.r[2], rows)
  end

  defp malformed(:number_gap) do
    c = chain()
    facts(c, c.r[3], change(c.rows, :revisions, c.r[3].id, parent_revision_id: c.r[1].id))
  end

  defp malformed(:baseline_human) do
    c = chain()
    facts(c, c.r[3], change(c.rows, :revisions, c.r[3].id, ai_baseline_revision_id: c.r[2].id))
  end

  # Revision 3 becomes an agent revision; revision 2 names it as its baseline.
  defp malformed(:baseline_not_lower) do
    c = chain()

    rows =
      c.rows
      |> change(:revisions, c.r[3].id,
        author_type: :agent,
        agent_run_id: c.w.run_x,
        decision_id: Ecto.UUID.generate(),
        model_invocation_id: c.x[3].id,
        ai_baseline_revision_id: nil
      )
      |> change(:revisions, c.r[2].id, ai_baseline_revision_id: c.r[3].id)

    facts(c, c.r[2], rows)
  end

  defp malformed(:foreign_tenant_member) do
    c = chain()
    facts(c, c.r[2], change(c.rows, :revisions, c.r[1].id, tenant_id: Ecto.UUID.generate()))
  end

  defp malformed(:agent_without_invocation) do
    c = chain()
    facts(c, c.r[1], change(c.rows, :revisions, c.r[1].id, model_invocation_id: nil))
  end

  defp malformed(:agent_without_run) do
    c = chain()
    facts(c, c.r[1], change(c.rows, :revisions, c.r[1].id, agent_run_id: nil))
  end

  defp malformed(:agent_without_decision) do
    c = chain()
    facts(c, c.r[1], change(c.rows, :revisions, c.r[1].id, decision_id: nil))
  end

  defp malformed(:invocation_of_another_run) do
    c = chain()
    facts(c, c.r[1], change(c.rows, :invocations, c.x[3].id, agent_run_id: c.w.run_y))
  end

  defp malformed(:parent_outside_loaded_set) do
    c = chain()

    facts(
      c,
      c.r[2],
      change(c.rows, :revisions, c.r[2].id, parent_revision_id: Ecto.UUID.generate())
    )
  end

  defp malformed(:baseline_outside_loaded_set) do
    c = chain()

    facts(
      c,
      c.r[3],
      change(c.rows, :revisions, c.r[3].id, ai_baseline_revision_id: Ecto.UUID.generate())
    )
  end

  defp malformed(:second_without_parent) do
    c = chain()
    facts(c, c.r[2], change(c.rows, :revisions, c.r[2].id, parent_revision_id: nil))
  end

  defp malformed(:first_with_parent) do
    c = chain()
    facts(c, c.r[1], change(c.rows, :revisions, c.r[1].id, parent_revision_id: c.r[2].id))
  end

  # 3 -> 2 is a valid step; 2 -> 3 is not (3 is not 2 - 1). Must terminate.
  defp malformed(:parent_cycle) do
    c = chain()
    facts(c, c.r[3], change(c.rows, :revisions, c.r[2].id, parent_revision_id: c.r[3].id))
  end

  defp unavailable(:start_absent) do
    c = chain()
    %{facts(c, c.r[1]) | start: Ecto.UUID.generate()}
  end

  defp unavailable(:own_invocation_absent) do
    c = chain()
    facts(c, c.r[1], remove(c.rows, :invocations, c.x[3].id))
  end

  defp unavailable(:claim_absent) do
    c = chain()
    facts(c, c.r[1], remove(c.rows, :claims, c.c1.id))
  end

  defp unavailable(:cited_invocation_absent) do
    c = chain()
    facts(c, c.r[1], remove(c.rows, :invocations, c.y1.id))
  end

  ## Rows

  defp revision(w, number, attrs) do
    struct(
      DraftRevision,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          tenant_id: w.tenant,
          draft_id: w.draft,
          revision_number: number,
          parent_revision_id: nil,
          ai_baseline_revision_id: nil,
          author_type: :human,
          agent_run_id: nil,
          decision_id: if(attrs[:author_type] == :agent, do: Ecto.UUID.generate()),
          model_invocation_id: nil
        },
        Map.new(attrs)
      )
    )
  end

  defp invocation(w, run_id, sequence, attrs \\ []) do
    struct(
      ModelInvocation,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          tenant_id: w.tenant,
          agent_run_id: run_id,
          sequence_in_run: sequence,
          status: :completed,
          validation_status: :valid,
          ledger_generation: 2,
          provider: :claude_cli,
          purpose: :evidence_extraction
        },
        Map.new(attrs)
      )
    )
  end

  defp release(w, invocation, disposition) do
    struct(ModelResultRelease, %{
      id: Ecto.UUID.generate(),
      tenant_id: w.tenant,
      model_invocation_id: invocation.id,
      disposition: disposition
    })
  end

  defp claim(w, invocation_id) do
    struct(EvidenceClaim, %{
      id: Ecto.UUID.generate(),
      tenant_id: w.tenant,
      model_invocation_id: invocation_id
    })
  end

  defp citation(revision, claim) do
    struct(RevisionCitation, %{
      id: Ecto.UUID.generate(),
      tenant_id: revision.tenant_id,
      draft_revision_id: revision.id,
      evidence_claim_id: claim.id
    })
  end

  defp facts(c, start, rows \\ nil),
    do: Map.merge(%{start: start.id, tenant_id: c.w.tenant}, rows || c.rows)

  defp add(rows, kind, row), do: Map.update!(rows, kind, &(&1 ++ [row]))
  defp add_all(rows, kind, new), do: Map.update!(rows, kind, &(&1 ++ new))

  defp remove(rows, kind, id),
    do: Map.update!(rows, kind, fn list -> Enum.reject(list, &(&1.id == id)) end)

  defp change(rows, kind, id, changes),
    do: Map.update!(rows, kind, &Enum.map(&1, fn row -> changed(row, id, changes) end))

  defp changed(%{id: id} = row, id, changes), do: struct(row, changes)
  defp changed(row, _id, _changes), do: row

  ## The guarded call

  defp covered(facts) do
    assert Code.ensure_loaded?(@ancestry) and function_exported?(@ancestry, :covered, 1),
           "C2* S4: #{inspect(@ancestry)}.covered/1 is not implemented"

    facts |> bounded() |> normalize()
  end

  defp bounded(facts) do
    task =
      Task.async(fn ->
        try do
          {:returned, invoke(@ancestry, :covered, [facts])}
        rescue
          error -> {:raised, error}
        catch
          kind, value -> {:caught, kind, value}
        end
      end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:returned, result}} -> result
      {:ok, other} -> other
      nil -> :did_not_terminate
    end
  end

  defp invoke(module, fun, args), do: apply(module, fun, args)

  defp normalize({:ok, pairs}) when is_list(pairs),
    do: {:ok, pairs |> Enum.map(&pair_ids/1) |> Enum.sort()}

  defp normalize(other), do: other

  defp pair_ids({%{id: release, model_invocation_id: id}, %{id: id}}), do: {release, id}
  defp pair_ids(other), do: {:not_a_release_and_its_invocation, other}

  defp sorted(releases),
    do: releases |> Enum.map(&{&1.id, &1.model_invocation_id}) |> Enum.sort()
end
