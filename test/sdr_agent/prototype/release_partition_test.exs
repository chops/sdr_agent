defmodule SdrAgent.Prototype.ReleasePartitionTest do
  @moduledoc """
  IF-4 release partition (interfaces r6; amendment items 5 and 6; Codex A1),
  D-237 slice S2.

  - **The pairs.** `:released_unverified` pairs only with
    `:owner_prototype_unverified`; `:withheld` also pairs with the new
    `:prototype_authority_refused`. No ordinary pair changes, and neither new
    value pairs with an ordinary one. S1's freeze adds the values; the pair
    rule is S2's behaviour.

  - **Ordinary runtime** refuses both prototype values at decision time
    (the RED-a pair gap; a landing blocker), and the `:reconciled`
    classification outside the prototype `witness_mode_mismatch` refusal.
  - **Prototype runtime, before provisioning** (RED-b1): an invocation
    reserved and completed before prototype runtime records no prototype
    authority, so it is refused `authority_unrecorded`, never released; a
    reconciled receipt is `witness_mode_mismatch` with the true
    classification `reconciled`; a live binding drift is
    `binding_mismatch`; the ordinary `:released` decision and a
    `released_unverified` decision outside the prototype gate's own context
    are refused; Recovery never releases; and the refusal branch locks its
    gate cause before the head, with no lock after it.

  The cases that need S1's provisioned grant (a release, each later refusal
  code, the bounded repeat seam and the release-branch lock order) follow
  as RED-b2.

  **The b1 own-context guard** (Codex 5a6fdd75; controls before RED-b2
  replaces it): until the closed basis exists, `released_unverified` is
  refused inside the prototype gate's own Prelocked context (finalizer
  `:prototype_gate`) with "needs its closed basis", and inside any other
  Prelocked context as not the gate's own; nothing is written.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.GateFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G

  # RED-b2c: a frozen decision instant inside the window.
  @at ~U[2026-11-01 00:00:00.000000Z]

  describe "the release pairs" do
    test "released_unverified pairs only with owner_prototype_unverified" do
      assert ModelResultRelease.allowed_pair?(:released_unverified, :owner_prototype_unverified),
             "{:released_unverified, :owner_prototype_unverified} is not an allowed pair"

      for reason <- [
            :reconciled,
            :calibration,
            :witness_mismatch,
            :gate_interrupted,
            :prototype_authority_refused
          ] do
        refute ModelResultRelease.allowed_pair?(:released_unverified, reason), inspect(reason)
      end

      for disposition <- [:released, :withheld, :calibration] do
        refute ModelResultRelease.allowed_pair?(disposition, :owner_prototype_unverified),
               inspect(disposition)
      end
    end

    test "withheld also pairs with prototype_authority_refused, and nothing else does" do
      assert ModelResultRelease.allowed_pair?(:withheld, :prototype_authority_refused),
             "{:withheld, :prototype_authority_refused} is not an allowed pair"

      for disposition <- [:released, :calibration] do
        refute ModelResultRelease.allowed_pair?(disposition, :prototype_authority_refused),
               inspect(disposition)
      end
    end
  end

  describe "ordinary runtime refuses the prototype decisions (the RED-a pair gap)" do
    setup do
      tenant = bootstrap!()
      AgentsFixtures.grant!(tenant)
      %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)
      invocation = AgentsFixtures.claude_completed!(run, agent, "ordinary-proto-1")
      %{tenant: tenant, agent: agent, invocation: invocation}
    end

    test "an ordinary withheld event records exactly its gate cause and classification", ctx do
      # Regression for the shared-file delta: the prototype refusal has its
      # own withheld AppendEvent; the ordinary withheld event's arguments
      # stay exactly these two, byte for byte.
      cause = GateFixtures.cause!(ctx.invocation)
      release = GateFixtures.withhold!(ctx.invocation, ctx.agent, cause)

      [event] =
        ctx.tenant
        |> events_of_type("model.result.withheld")
        |> Enum.filter(&(&1.subject_id == release.id))

      assert event.payload["arguments"] == %{
               "gate_cause_id" => cause.id,
               "gate_classification" => "inferred"
             }
    end

    test "a withheld prototype_authority_refused decision is refused outside prototype runtime",
         ctx do
      result =
        Agents.decide_result_release(
          %{
            model_invocation_id: ctx.invocation.id,
            disposition: :withheld,
            reason: :prototype_authority_refused
          },
          actor: ctx.agent
        )

      assert match?({:error, _}, result), "ordinary runtime decided it: #{inspect(result)}"
      assert G.release(ctx.invocation) == nil
    end

    test "a released_unverified decision is refused outside prototype runtime", ctx do
      result =
        Agents.decide_result_release(
          %{
            model_invocation_id: ctx.invocation.id,
            disposition: :released_unverified,
            reason: :owner_prototype_unverified
          },
          actor: ctx.agent
        )

      assert match?({:error, _}, result), "ordinary runtime decided it: #{inspect(result)}"
      assert G.release(ctx.invocation) == nil
    end

    test "a withheld :reconciled classification is refused outside the prototype refusal",
         ctx do
      # Codex 2c9450b7 ruling 3b: :reconciled is recorded only by the
      # prototype gate's witness_mode_mismatch refusal (S1 adds the value).
      cause = GateFixtures.cause!(ctx.invocation)
      tenant_id = ctx.invocation.tenant_id

      result =
        SdrAgent.Audit.transaction(fn ->
          {:ok, _held} =
            SdrAgent.Agents.ModelInvocation
            |> Ash.Query.for_read(:read, %{}, SdrAgent.Audit.Kernel.opts(tenant_id))
            |> Ash.Query.filter(id == ^ctx.invocation.id)
            |> Ash.Query.lock("FOR SHARE")
            |> Ash.read_one()

          {:ok, _head} = SdrAgent.Audit.Kernel.lock_head(tenant_id)

          bindings = %{
            tenant_id: tenant_id,
            model_invocation_id: ctx.invocation.id,
            receipt_id: cause.id
          }

          SdrAgent.Agents.ReleaseDecision.Prelocked.run(bindings, fn prelocked ->
            Agents.decide_result_release(
              %{
                model_invocation_id: ctx.invocation.id,
                disposition: :withheld,
                reason: :witness_missing,
                gate_cause_id: cause.id,
                gate_classification: :reconciled
              },
              actor: ctx.agent,
              prelocked: prelocked
            )
          end)
        end)

      refute match?({:ok, {:ok, _}}, result),
             "a :reconciled withheld was decided: #{inspect(result)}"

      assert G.release(ctx.invocation) == nil
    end
  end

  defp refused_code(fx, result, code) do
    with {:withheld, release, _run} <- result,
         true <-
           {release.disposition, release.reason} == {:withheld, :prototype_authority_refused},
         [event] <- G.release_events(fx, "model.result.withheld", release) do
      event.payload["arguments"]["prototype_refusal"] == Atom.to_string(code)
    else
      _ -> false
    end
  end

  defp run_status(run) do
    run = Ash.get!(SdrAgent.Agents.AgentRun, run.id, authorize?: false)
    {run.status, run.status_reason}
  end

  defp assert_refuses!(ctx, invocation, run, code) do
    result = G.finalize(invocation, run)
    assert refused_code(ctx.fx, result, code), "finalize: #{inspect(result)}"
    assert run_status(run) == {:failed, :witness_unreconciled}
    assert G.charged(ctx.fx) >= 1
  end

  describe "before provisioning: an invocation completed without prototype authority" do
    # Reserved, sent and completed through the ordinary domain path before
    # prototype runtime was entered (PrototypeGateFixtures.pre_runtime!/1):
    # its reservation event records no prototype authority, so the
    # prototype gate never releases it. These cases exercise what comes
    # before the authority, and the partition of the decision itself.
    setup do
      fx = G.pre_runtime!(auditor: true)
      %{fx: fx, run: fx.run, invocation: fx.invocation}
    end

    test "with no recorded authority it is refused authority_unrecorded, never released", ctx do
      result = G.finalize(ctx.invocation, ctx.run)
      assert refused_code(ctx.fx, result, :authority_unrecorded), "finalize: #{inspect(result)}"
      assert run_status(ctx.run) == {:failed, :witness_unreconciled}
    end

    test "a reconciled receipt is witness_mode_mismatch and never released", ctx do
      receipt = %{G.absent_receipt() | status: :reconciled}
      result = G.finalize(ctx.invocation, ctx.run, {:ok, receipt})

      assert refused_code(ctx.fx, result, :witness_mode_mismatch), "finalize: #{inspect(result)}"
      assert run_status(ctx.run) == {:failed, :witness_unreconciled}

      # Codex 2c9450b7 ruling 3b: the true observation, never :unclassified.
      {:withheld, release, _run} = result
      [event] = G.release_events(ctx.fx, "model.result.withheld", release)
      assert event.payload["arguments"]["gate_classification"] == "reconciled"
    end

    test "after a live binding drift: binding_mismatch (check_live row)", ctx do
      G.drift!()
      assert_refuses!(ctx, ctx.invocation, ctx.run, :binding_mismatch)
    end

    test "the ordinary :released decision is unreachable in prototype runtime", ctx do
      rec = system_actor(:reconciler, ctx.fx.tenant)
      link = AgentsFixtures.reconciled_link!(ctx.invocation, rec)

      result =
        Agents.decide_result_release(
          %{
            model_invocation_id: ctx.invocation.id,
            disposition: :released,
            reason: :reconciled,
            wire_witness_link_id: link.id
          },
          actor: ctx.fx.agent
        )

      assert match?({:error, _}, result), "prototype runtime released: #{inspect(result)}"
      assert G.release(ctx.invocation) == nil
    end

    test "released_unverified outside the prototype gate's own Prelocked context is refused",
         ctx do
      result =
        Agents.decide_result_release(
          %{
            model_invocation_id: ctx.invocation.id,
            disposition: :released_unverified,
            reason: :owner_prototype_unverified
          },
          actor: ctx.fx.agent
        )

      assert match?({:error, _}, result), "decided without the gate: #{inspect(result)}"
      assert G.release(ctx.invocation) == nil
    end

    # D-237 TF-1 (plan r3 section 1; Codex 3a5ca9cf): this expected the
    # superseded ordinary G5 withheld; in prototype runtime direct Recovery
    # with no release decides nothing.
    test "Recovery never decides a release of either kind", ctx do
      result = SdrAgent.Agents.ResultGate.Recovery.run(ctx.invocation, G.gate(ctx.run))

      assert result == {:error, :no_prototype_decision}, "recovery: #{inspect(result)}"
      assert G.release(ctx.invocation) == nil
      assert ctx.fx.tenant |> events_of_type("model.result.released_unverified") == []
    end

    test "refusal branch: the gate cause is locked before the head; none after", ctx do
      G.drift!()
      {result, sql} = GateFixtures.capture(fn -> G.finalize(ctx.invocation, ctx.run) end)
      assert match?({:withheld, _, _}, result), inspect(result)

      order = [
        {"agent_runs", "FOR UPDATE"},
        {"operations", "FOR SHARE"},
        {"model_invocations", "FOR SHARE"},
        {"failures", "FOR UPDATE"},
        {"audit_chain_heads", "FOR UPDATE"}
      ]

      assert_lock_order!(sql, order)
    end
  end

  defp assert_lock_order!(sql, order) do
    indices =
      for {table, mode} <- order,
          do:
            GateFixtures.index(sql, &GateFixtures.locks?(&1, table, mode)) ||
              flunk("#{table} #{mode}: #{inspect(sql)}")

    assert indices == Enum.sort(indices), inspect(Enum.zip(order, indices))

    after_head = Enum.drop(sql, List.last(indices) + 1)

    assert Enum.reject(
             Enum.filter(after_head, &GateFixtures.lock?/1),
             &GateFixtures.locks?(&1, "audit_chain_heads", "FOR UPDATE")
           ) == [],
           inspect(after_head)
  end

  describe "the b1 own-context guard (ReleaseDecision; Codex 5a6fdd75)" do
    # Until the closed basis exists (RED-b2), released_unverified is refused
    # even inside the prototype gate's own Prelocked context, and inside any
    # other Prelocked context it is refused as not the gate's own.
    setup do
      fx = G.pre_runtime!()
      %{fx: fx, run: fx.run, invocation: fx.invocation}
    end

    # RED-b2: inside the gate's own context a decision still needs its closed
    # basis; without one it is refused on :basis, and nothing is written.
    test "inside the prototype gate's own context (finalizer :prototype_gate) without a basis: refused",
         ctx do
      result = decide_under(ctx, :prototype_gate)

      assert refused_on?(result, :basis, "must be a valid d237-basis/1 with its digest"),
             "decided: #{inspect(result)}"

      assert G.release(ctx.invocation) == nil
      assert events_of_type(ctx.fx.tenant, "model.result.released_unverified") == []

      assert Agents.released_output(ctx.invocation, actor: ctx.fx.agent) ==
               {:error, :result_not_released}
    end

    test "inside another Prelocked context (no finalizer): refused as not the gate's own", ctx do
      result = decide_under(ctx, nil)

      assert refused_on?(
               result,
               :disposition,
               "is decided only by the prototype gate's own context"
             ),
             "decided: #{inspect(result)}"

      assert G.release(ctx.invocation) == nil
      assert events_of_type(ctx.fx.tenant, "model.result.released_unverified") == []
    end
  end

  describe "the own-context basis validator (RED-b2c; Codex 3122b0d4 G1-G3, R5)" do
    # A NEW decision (no release yet) inside the prototype gate's own
    # Prelocked context, on a call reserved, launched and completed through
    # the prototype path at a frozen instant inside the window: the action
    # rebuilds the basis from the locked rows and its own decision instant
    # and only compares the caller's (Q3). Each refusal writes nothing.
    # Messages are value-free (G.summary/1): no basis or raw error dump.
    setup do
      SdrAgent.Clock.freeze(@at)
      fx = G.prototype!()
      run = G.run!(fx)
      invocation = G.completed!(fx, run)
      %{fx: fx, run: run, invocation: invocation, basis: G.expected_basis(fx, invocation, @at)}
    end

    test "G0: exactly the rebuilt basis and its digest is decided released_unverified, with one event",
         ctx do
      sha = G.canonical_hex(ctx.basis)

      result =
        G.decide_own(ctx.fx, ctx.run, ctx.invocation, %{basis: ctx.basis, basis_sha256: sha})

      assert match?({:ok, %ModelResultRelease{disposition: :released_unverified}}, result),
             "decided: #{inspect(G.summary(result))}"

      {:ok, release} = result
      assert [event] = G.release_events(ctx.fx, "model.result.released_unverified", release)
      assert event.payload["arguments"] == %{"basis" => ctx.basis, "basis_sha256" => sha}
    end

    test "G1: a well-formed basis with its own digest that differs from the rebuilt one is refused on :basis",
         ctx do
      different = put_in(ctx.basis, ["funding", "grant_revision"], ctx.fx.grant.revision + 1)

      result =
        G.decide_own(ctx.fx, ctx.run, ctx.invocation, %{
          basis: different,
          basis_sha256: G.canonical_hex(different)
        })

      assert refused_on?(result, :basis, "must be a valid d237-basis/1 with its digest"),
             "decided: #{inspect(G.summary(result))}"

      assert nothing_written?(ctx)
    end

    test "G2: the rebuilt basis with a wrong digest is refused on :basis", ctx do
      result =
        G.decide_own(ctx.fx, ctx.run, ctx.invocation, %{
          basis: ctx.basis,
          basis_sha256: String.duplicate("0", 64)
        })

      assert refused_on?(result, :basis, "must be a valid d237-basis/1 with its digest"),
             "decided: #{inspect(G.summary(result))}"

      assert nothing_written?(ctx)
    end

    test "G3/R5: an extra key, a missing key, a null and an oversize value are refused on :basis, value-free",
         ctx do
      marker = "D237-S2-UNTRUSTED-MARKER"

      cases = [
        extra_key: Map.put(ctx.basis, "extra", marker),
        missing_key: Map.delete(ctx.basis, "label"),
        null: put_in(ctx.basis, ["identity", "cli_version"], nil),
        oversize:
          put_in(ctx.basis, ["identity", "cli_version"], marker <> String.duplicate("x", 9000))
      ]

      # Every case runs before any assertion; each digest is the case's own,
      # so the refusal is the shape or size, never the digest.
      outcomes =
        for {label, basis} <- cases do
          result =
            G.decide_own(ctx.fx, ctx.run, ctx.invocation, %{
              basis: basis,
              basis_sha256: G.canonical_hex(basis)
            })

          {label, refused_on?(result, :basis, "must be a valid d237-basis/1 with its digest"),
           match?({:error, _}, result) and not String.contains?(inspect(result), marker),
           G.summary(result)}
        end

      refused =
        for {label, refused?, _free?, summary} <- outcomes, not refused?, do: {label, summary}

      assert refused == [], "not refused on :basis: #{inspect(refused)}"

      leaking = for {label, _refused?, free?, _summary} <- outcomes, not free?, do: label
      assert leaking == [], "the refusal shows the caller's value: #{inspect(leaking)}"

      assert nothing_written?(ctx)
    end

    # The deny-only declaration's control (RED-b2c): a basis supplied on any
    # decision other than released_unverified is refused on :basis.
    test "a basis on a withheld decision is refused on :basis (deny-only control)", ctx do
      sha = G.canonical_hex(ctx.basis)

      result =
        Agents.decide_result_release(
          %{
            model_invocation_id: ctx.invocation.id,
            disposition: :withheld,
            reason: :prototype_authority_refused,
            prototype_refusal: :authority_mismatch,
            basis: ctx.basis,
            basis_sha256: sha
          },
          actor: ctx.fx.agent
        )

      assert refused_on?(result, :basis, "is recorded only for a released_unverified decision"),
             "decided: #{inspect(G.summary(result))}"

      assert nothing_written?(ctx)
    end
  end

  # A finalizer stand-in: the invocation FOR SHARE, the head, then a
  # released_unverified decision under a Prelocked context with `finalizer`.
  defp decide_under(ctx, finalizer) do
    tenant_id = ctx.invocation.tenant_id

    SdrAgent.Audit.transaction(fn ->
      {:ok, _held} =
        SdrAgent.Agents.ModelInvocation
        |> Ash.Query.for_read(:read, %{}, SdrAgent.Audit.Kernel.opts(tenant_id))
        |> Ash.Query.filter(id == ^ctx.invocation.id)
        |> Ash.Query.lock("FOR SHARE")
        |> Ash.read_one()

      {:ok, _head} = SdrAgent.Audit.Kernel.lock_head(tenant_id)

      bindings = %{
        tenant_id: tenant_id,
        model_invocation_id: ctx.invocation.id,
        finalizer: finalizer
      }

      SdrAgent.Agents.ReleaseDecision.Prelocked.run(bindings, &unverified_or_rollback(ctx, &1))
    end)
  end

  defp unverified_or_rollback(ctx, prelocked) do
    attrs = %{
      model_invocation_id: ctx.invocation.id,
      disposition: :released_unverified,
      reason: :owner_prototype_unverified
    }

    case Agents.decide_result_release(attrs, actor: ctx.fx.agent, prelocked: prelocked) do
      {:ok, release} -> release
      {:error, error} -> SdrAgent.Repo.rollback(error)
    end
  end

  # Nothing decided for the invocation: no release row, no released or
  # withheld event (RED-b2c).
  defp nothing_written?(ctx) do
    G.release(ctx.invocation) == nil and
      events_of_type(ctx.fx.tenant, "model.result.released_unverified") == [] and
      events_of_type(ctx.fx.tenant, "model.result.withheld") == []
  end

  # The transaction rolled back with an Invalid error on `field` with `message`.
  defp refused_on?({:error, error}, field, message) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&(Map.get(&1, :field) == field and Map.get(&1, :message) == message))
  end

  defp refused_on?(_result, _field, _message), do: false
end
