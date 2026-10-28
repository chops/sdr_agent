defmodule SdrAgent.Prototype.ReleaseReadersTest do
  @moduledoc """
  RED-b2 r6, the readers and consumers of a `released_unverified` output
  (interfaces r6 IF-4; amendment item 6; Codex A3; Codex ff812f6d ruling d;
  Codex 0c545b20 R1, R2; Codex 3603b76f M1, M3; Codex 92332009 N1), D-237 slice S2, over a real committed release
  (`ResultGate.finalize/4` on S1's real provisioning; never a permissive
  fixture release). The verified read scope is the one proposed in
  `claude-d237-s2-mechanism-note-r3-20261028.md`
  (`SdrAgent.Prototype.ReleasedScope`). It does not exist yet: every call
  first asserts the export, so a missing API is a STRUCTURAL failure, never
  a reached read-path RED.

  **Inventory** (every lib path that reads a gated model output or decides
  whether one is released, at 4aa3317). The coverage column is what these
  tests execute; a path reached only through `ReleasedOutput.fetch/2` is
  source inheritance, not an executed case.

  | Path | Reads through | Executed here |
  |---|---|---|
  | `SdrAgent.Agents.released_output/2` | `ReleasedOutput.fetch/2` | yes: prototype, ordinary, drift, every basis variant |
  | `SdrAgent.Agents.ResultGate.finalize/4` (replay) | `ReleasedOutput.fetch/2` | yes: every basis variant, drift |
  | `SdrAgent.Agents.ResultGate.Recovery.run/3` | `ReleasedOutput.fetch/2` | yes: every basis variant, drift |
  | `ResultGate.unreleased?/1`, `unreleased_invocations/1` (agent worker, reply worker, stale-run sweeper) | `disposition == :released` filter | yes: both predicates, every case |
  | `ModelInvocation` field policy on `parsed_output`, `validation_errors`, `refusal` | `ReleasedOutputRead` mark + `exists(… :released)` | yes: no context, false, copied, forged, stale and wrong-row scopes; every basis variant |
  | `SdrAgent.Agents.Changes.DecisionRules` (decisions) | `ReleasedOutput.fetch/2` | inherited only, not executed |
  | `SdrAgent.Outreach.Changes.AssessmentRules` (reply assessments) | `ReleasedOutput.fetch/2` | inherited only, not executed |
  | `SdrAgent.SDR.Model` settle | `ReleasedOutput.gated?/1`, then the gate | inherited only, not executed |
  | `SdrAgent.Outreach.Inbox` (`inbox.ex:219` filter, `:354` loaded-row predicate) | `disposition == :released` | **open joint S2/S4 integration gate** (Codex 0c545b20): it withholds unverified outputs today; no journey or app-view PASS until S4 and S2 pin its path; ordinary withholding and the non-reserved-contact restrictions stay |

  **Cases.**

  - **The genuine verified path.** In prototype runtime with the live
    binding, `released_output/2` returns the output and both worker
    predicates count the run released; the decision, its one event and the
    basis stay unverified; no `model.result.released` event exists.
  - **Raw reads never pass on a marker.** With a valid basis, a raw read of
    `parsed_output`, `validation_errors` and `refusal` is
    `Ash.ForbiddenField` with no context, a `false` marker, a copied
    `ReleasedOutputRead.context/0`, a forged scope, a stale scope (returned
    after its `run/3` ended) and another invocation's scope (wrong row).
  - **The scope alone authorizes** (N1): a read with ONLY `context(scope)`
    returns the output; the new clause precedes the marker rule, so the
    old Boolean marker is neither needed nor sufficient. A list read under
    A's scope, with and without the old marker, forbids B's output.
  - **A refusal never aborts the caller:** inside a caller's transaction a
    refused `run/3` returns `{:error, _}`, the caller's work persists and
    the connection stays usable.
  - **The verified scope** is row-aware and short-lived: a list read with no
    id filter under A's scope shows A's output and B's three output fields as
    `ForbiddenField`; the scope ends when `run/3` returns (even inside a
    shared outer transaction) or its function raises; another tenant's
    actor gets `:not_found` (the caller's row policy holds).
  - **Ordinary runtime never relabels it:** `released_output/2` is
    `result_not_released` and both predicates count it unreleased.
  - **Fail closed** after a live binding drift and for every original-basis
    variant (labelled tampers of the original event): tampered (digest not
    updated), missing, malformed, wrong digest, a duplicate original event,
    and self-consistent rewrites with a recomputed canonical digest of the
    binding, the invocation, the charge and the identity. Each refuses at
    `released_output/2`, replay, Recovery and the copied-marker raw read,
    leaves both predicates unreleased, and writes no new decision or event.
    Every stage runs and is recorded before any assertion, so the sealed
    log names each failed stage.

  No real content: the output is the synthetic fixture completion.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Checks.ReleasedOutputRead
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.ResultGate.Recovery
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.PrototypeGateFixtures, as: G

  @scope SdrAgent.Prototype.ReleasedScope
  @output_fields [:parsed_output, :validation_errors, :refusal]

  setup do
    fx = G.prototype!()
    run = G.run!(fx)
    invocation = G.completed!(fx, run)
    %{fx: fx, run: run, invocation: invocation} |> Map.merge(released!(fx, run, invocation))
  end

  ## Helpers

  defp released!(fx, run, invocation) do
    result = G.finalize(invocation, run)

    assert match?({:released, %{disposition: :released_unverified}, _}, result),
           "prerequisite: the release: #{inspect(result)}"

    {:released, release, output} = result
    assert [event] = G.release_events(fx, "model.result.released_unverified", release)
    %{release: release, output: output, event: event}
  end

  defp canonical_hex(term), do: Base.encode16(Canonical.sha256(term), case: :lower)

  defp reread_run(run), do: Ash.get!(SdrAgent.Agents.AgentRun, run.id, authorize?: false)

  # Both worker predicates: {unreleased?, invocation among the unreleased}.
  defp predicates(ctx) do
    run = reread_run(ctx.run)
    {:ok, unreleased} = ResultGate.unreleased_invocations(run)
    {ResultGate.unreleased?(run), Enum.any?(unreleased, &(&1.id == ctx.invocation.id))}
  end

  # A raw read of `invocation_id` as the agent with `context`: the three
  # output-bearing fields.
  defp raw_read(ctx, invocation_id, context) do
    row =
      ModelInvocation
      |> Ash.Query.for_read(:read, %{}, actor: ctx.fx.agent, context: context)
      |> Ash.Query.filter(id == ^invocation_id)
      |> Ash.read_one!()

    Map.take(row, @output_fields)
  end

  defp forbidden?(fields),
    do: Enum.all?(@output_fields, &match?(%Ash.ForbiddenField{}, Map.fetch!(fields, &1)))

  # Labelled tamper of the original released_unverified event's arguments.
  defp rewrite_arguments!(event, arguments) do
    tamper!(
      "UPDATE audit_events SET payload = jsonb_set(payload, '{arguments}', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(event.id), Jason.encode!(arguments)]
    )
  end

  # A second ORIGINAL released_unverified event for the release, appended
  # through the audit kernel with the same payload.
  defp duplicate_original!(ctx) do
    e = ctx.event

    SdrAgent.Audit.Kernel.append(
      %{
        event_type: e.event_type,
        category: :model,
        subject_resource: e.subject_resource,
        subject_id: e.subject_id,
        action: e.action,
        model_invocation_id: ctx.invocation.id,
        agent_run_id: ctx.run.id,
        payload: e.payload
      },
      actor: ctx.fx.agent,
      tenant_id: ctx.invocation.tenant_id
    )
  end

  # A self-consistent rewrite: `path` set to `value`, the digest recomputed.
  defp recomputed(ctx, path, value) do
    basis = put_in(ctx.event.payload["arguments"]["basis"], path, value)
    %{"basis" => basis, "basis_sha256" => canonical_hex(basis)}
  end

  # Every stage runs and is recorded BEFORE any assertion, so the sealed log
  # shows which stage failed (Codex 3603b76f test gate).
  defp assert_fails_closed!(ctx, label) do
    released_before = length(events_of_type(ctx.fx.tenant, "model.result.released_unverified"))

    stages = [
      released_output: Agents.released_output(ctx.invocation, actor: ctx.fx.agent),
      replay: G.finalize(ctx.invocation, ctx.run),
      recovery: Recovery.run(ctx.invocation, G.gate(ctx.run)),
      raw_read_forbidden:
        forbidden?(raw_read(ctx, ctx.invocation.id, ReleasedOutputRead.context())),
      predicates_unreleased: predicates(ctx),
      released_events_unchanged:
        length(events_of_type(ctx.fx.tenant, "model.result.released_unverified")) ==
          released_before,
      no_withheld: events_of_type(ctx.fx.tenant, "model.result.withheld") == []
    ]

    expected = fn
      {reader, result} when reader in [:released_output, :replay, :recovery] ->
        match?({:error, _}, result)

      {:predicates_unreleased, value} ->
        value == {true, true}

      {_check, value} ->
        value == true
    end

    failed = Enum.reject(stages, expected)

    assert failed == [],
           "#{label}: failed stages #{inspect(Keyword.keys(failed))}: #{inspect(stages)}"
  end

  # A function of the proposed scope API, asserted exported first: a missing
  # API is STRUCTURAL, never a reached read-path RED.
  defp scope_api!(fun, arity) do
    assert Code.ensure_loaded?(@scope) and function_exported?(@scope, fun, arity),
           "structural: #{inspect(@scope)}.#{fun}/#{arity} is not exported"

    Function.capture(@scope, fun, arity)
  end

  ## The genuine verified path

  describe "the genuine verified path" do
    test "prototype runtime: the output, both predicates released, the decision unverified",
         ctx do
      assert Agents.released_output(ctx.invocation, actor: ctx.fx.agent) == {:ok, ctx.output}
      assert predicates(ctx) == {false, false}

      assert {ctx.release.disposition, ctx.release.reason} ==
               {:released_unverified, :owner_prototype_unverified}

      basis = ctx.event.payload["arguments"]["basis"]
      assert {basis["assurance"], basis["label"]} == {"unverified", "UNVERIFIED (PROTOTYPE)"}
      assert events_of_type(ctx.fx.tenant, "model.result.released") == []
    end
  end

  ## Raw reads

  describe "raw reads never pass on a marker or a reused scope" do
    test "no context, a false marker and a copied marker read forbidden fields", ctx do
      contexts = [
        none: %{},
        false_marker: %{sdr_released_output_read: false},
        copied_marker: ReleasedOutputRead.context()
      ]

      reads =
        for {label, context} <- contexts, do: {label, raw_read(ctx, ctx.invocation.id, context)}

      assert Enum.all?(reads, fn {_label, fields} -> forbidden?(fields) end), inspect(reads)
    end

    test "a forged scope reads forbidden fields", ctx do
      forged = %{
        sdr_prototype_released_scope: %{
          tenant_id: ctx.invocation.tenant_id,
          model_invocation_id: ctx.invocation.id,
          release_id: ctx.release.id,
          basis_sha256: ctx.event.payload["arguments"]["basis_sha256"]
        }
      }

      assert forbidden?(
               raw_read(ctx, ctx.invocation.id, Map.merge(ReleasedOutputRead.context(), forged))
             )
    end

    test "a stale scope (after its run ended) reads forbidden fields", ctx do
      run = scope_api!(:run, 3)
      context = scope_api!(:context, 1)
      stale = run.(ctx.invocation, ctx.fx.agent, fn scope -> scope end)
      assert match?({:ok, _scope}, stale), "prerequisite: a verified scope: #{inspect(stale)}"
      {:ok, scope} = stale

      fields =
        raw_read(ctx, ctx.invocation.id, Map.merge(ReleasedOutputRead.context(), context.(scope)))

      assert forbidden?(fields)
    end

    test "another invocation's scope (wrong row) reads forbidden fields", ctx do
      other_run = G.run!(ctx.fx)
      other = G.completed!(ctx.fx, other_run)
      _other_release = released!(ctx.fx, other_run, other)
      run = scope_api!(:run, 3)
      context = scope_api!(:context, 1)

      result =
        run.(ctx.invocation, ctx.fx.agent, fn scope ->
          raw_read(ctx, other.id, Map.merge(ReleasedOutputRead.context(), context.(scope)))
        end)

      assert match?({:ok, _fields}, result), "prerequisite: a verified scope: #{inspect(result)}"
      {:ok, fields} = result
      assert forbidden?(fields)
    end
  end

  ## The scope's lifecycle and row authorization (Codex 3603b76f M1, M3)

  describe "the verified scope" do
    test "a read with ONLY context(scope) returns A's output (the clause precedes the marker rule)",
         ctx do
      run = scope_api!(:run, 3)
      context = scope_api!(:context, 1)

      result =
        run.(ctx.invocation, ctx.fx.agent, fn scope ->
          raw_read(ctx, ctx.invocation.id, context.(scope))
        end)

      assert match?({:ok, %{}}, result), "prerequisite: a verified scope: #{inspect(result)}"
      {:ok, fields} = result
      assert fields.parsed_output == ctx.output, inspect(fields)
    end

    for marker? <- [false, true] do
      test "a list under A's scope (old marker #{marker?}) shows A's output, forbids B's, no id filter",
           ctx do
        other_run = G.run!(ctx.fx)
        other = G.completed!(ctx.fx, other_run)
        _b = released!(ctx.fx, other_run, other)
        run = scope_api!(:run, 3)
        context = scope_api!(:context, 1)

        result =
          run.(ctx.invocation, ctx.fx.agent, fn scope ->
            scope_context =
              if unquote(marker?),
                do: Map.merge(ReleasedOutputRead.context(), context.(scope)),
                else: context.(scope)

            ModelInvocation
            |> Ash.Query.for_read(:read, %{}, actor: ctx.fx.agent, context: scope_context)
            |> Ash.Query.filter(provider == :claude_cli)
            |> Ash.read!()
          end)

        assert match?({:ok, [_, _ | _]}, result), "prerequisite: the list: #{inspect(result)}"
        {:ok, rows} = result
        a = Enum.find(rows, &(&1.id == ctx.invocation.id))
        b = Enum.find(rows, &(&1.id == other.id))

        assert a.parsed_output == ctx.output
        assert forbidden?(Map.take(b, @output_fields)), inspect(Map.take(b, @output_fields))
      end
    end

    test "a refusal inside a caller's transaction writes nothing and keeps the caller's work",
         ctx do
      run = scope_api!(:run, 3)
      G.drift!()

      result =
        SdrAgent.Audit.transaction(fn ->
          caller_work =
            SdrAgent.GateFixtures.cause!(ctx.invocation, operation_id: ctx.run.operation_id)

          refusal = run.(ctx.invocation, ctx.fx.agent, & &1)
          {caller_work, refusal, SdrAgent.Repo.query!("SELECT 1").rows}
        end)

      assert match?({:ok, {_work, {:error, :binding_mismatch}, [[1]]}}, result), inspect(result)
      {:ok, {caller_work, _refusal, _select}} = result

      assert Ash.get!(SdrAgent.Operations.Failure, caller_work.id, authorize?: false).id ==
               caller_work.id
    end

    test "a scope ends when run/3 returns, even inside a shared outer transaction", ctx do
      run = scope_api!(:run, 3)
      verify = scope_api!(:verify, 1)

      result =
        SdrAgent.Audit.transaction(fn ->
          {:ok, scope} = run.(ctx.invocation, ctx.fx.agent, & &1)
          verify.(scope)
        end)

      assert result == {:ok, {:error, :scope_invalid}}, inspect(result)
    end

    test "a scope ends when the function given to run/3 raises", ctx do
      run = scope_api!(:run, 3)
      verify = scope_api!(:verify, 1)

      raised =
        try do
          run.(ctx.invocation, ctx.fx.agent, fn scope ->
            send(self(), {:scope, scope})
            raise "synthetic"
          end)
        rescue
          error -> {:raised, Exception.message(error)}
        end

      assert raised == {:raised, "synthetic"}, inspect(raised)
      assert_received {:scope, scope}
      assert verify.(scope) == {:error, :scope_invalid}
    end

    # RED-b2c (Codex 3122b0d4 R4): no scope is registered before the trust
    # checks pass, and the function never runs on a refusal.
    test "a refused run/3 never calls its function and leaves no scope", ctx do
      run = scope_api!(:run, 3)
      G.drift!()

      result = run.(ctx.invocation, ctx.fx.agent, fn scope -> send(self(), {:called, scope}) end)

      assert result == {:error, :binding_mismatch}, inspect(G.summary(result))
      refute_received {:called, _scope}
    end

    # R4: the function's own result is passed through inside {:ok, _}, never
    # read as a refusal; a programming error in it is re-raised unchanged.
    test "the function's error result is passed through and its raise is not a refusal", ctx do
      run = scope_api!(:run, 3)

      passed = run.(ctx.invocation, ctx.fx.agent, fn _scope -> {:error, :binding_mismatch} end)
      assert passed == {:ok, {:error, :binding_mismatch}}, inspect(G.summary(passed))

      assert_raise ArgumentError, "d237-s2 synthetic programming error", fn ->
        run.(ctx.invocation, ctx.fx.agent, fn _scope ->
          raise ArgumentError, "d237-s2 synthetic programming error"
        end)
      end
    end

    # R4: a nested run/3 keeps the outer scope; both end with their calls.
    test "a nested run/3 preserves the outer scope until its own call returns", ctx do
      run = scope_api!(:run, 3)
      verify = scope_api!(:verify, 1)

      result =
        run.(ctx.invocation, ctx.fx.agent, fn outer ->
          inner = run.(ctx.invocation, ctx.fx.agent, &verify.(&1))
          {inner, verify.(outer), outer}
        end)

      assert match?({:ok, {{:ok, {:ok, _inner}}, {:ok, _outer}, _scope}}, result),
             inspect(G.summary(result))

      {:ok, {_inner, _outer_valid, outer}} = result
      assert verify.(outer) == {:error, :scope_invalid}
    end

    # R4: an actual SQL failure in the caller's transaction is a technical
    # error, never one of the closed refusals, and the function never runs.
    # (No typed DB identity is assumed: Codex 6d1ead6d.)
    test "after the caller's transaction aborted, run/3 is a technical error, not a refusal",
         ctx do
      run = scope_api!(:run, 3)

      result =
        SdrAgent.Audit.transaction(fn ->
          {:error, _aborted} = SdrAgent.Repo.query("SELECT 1/0")

          inside =
            run.(ctx.invocation, ctx.fx.agent, fn scope -> send(self(), {:called, scope}) end)

          SdrAgent.Repo.rollback({:inside, inside})
        end)

      assert {:error, {:inside, inside}} = result
      assert match?({:error, _}, inside), inspect(G.summary(inside))
      {:error, reason} = inside
      refute reason in [:not_found, :not_released, :basis_invalid, :binding_mismatch]
      refute_received {:called, _scope}
    end

    test "the caller's row policy holds: another tenant's actor gets not_found", ctx do
      run = scope_api!(:run, 3)
      foreign = SdrAgent.Actor.system(:agent_runtime, Ecto.UUID.generate())

      assert run.(ctx.invocation, foreign, & &1) == {:error, :not_found}
    end
  end

  ## Ordinary runtime

  describe "ordinary runtime" do
    test "never relabels it released", ctx do
      :ok = PrototypeFixtures.leave_runtime()

      assert Agents.released_output(ctx.invocation, actor: ctx.fx.agent) ==
               {:error, :result_not_released}

      assert predicates(ctx) == {true, true}
      assert forbidden?(raw_read(ctx, ctx.invocation.id, ReleasedOutputRead.context()))
    end
  end

  ## Fail closed

  describe "fail closed" do
    test "after a live binding drift", ctx do
      G.drift!()
      assert_fails_closed!(ctx, "drift")
    end

    test "with a duplicate original event", ctx do
      appended = duplicate_original!(ctx)
      assert match?({:ok, _}, appended), "prerequisite: duplicate event: #{inspect(appended)}"
      assert_fails_closed!(ctx, "duplicate")
    end

    # RED-b2c (Codex 3122b0d4 R3): the original event's identity is its
    # tenant, resource, action, subject (the release) and invocation/run
    # correlation, not its type alone. Labelled tampers of the event row.
    for {label, column} <- [wrong_subject: "subject_id", wrong_correlation: "model_invocation_id"] do
      test "with the original event's #{label} (labelled tamper)", ctx do
        tamper!(
          "UPDATE audit_events SET #{unquote(column)} = $2 WHERE id = $1",
          [Ecto.UUID.dump!(ctx.event.id), Ecto.UUID.dump!(Ecto.UUID.generate())]
        )

        assert_fails_closed!(ctx, unquote(Atom.to_string(label)))
      end
    end

    for variant <- [
          :tampered,
          :missing,
          :malformed,
          :wrong_digest,
          :wrong_binding,
          :invocation,
          :charge,
          :identity
        ] do
      test "with a #{variant} original basis (labelled tamper)", ctx do
        args = ctx.event.payload["arguments"]

        rewritten =
          case unquote(variant) do
            :tampered ->
              put_in(args, ["basis", "invocation", "purpose"], "evidence_extraction")

            :missing ->
              Map.delete(args, "basis")

            :malformed ->
              Map.put(args, "basis", "not-a-basis")

            :wrong_digest ->
              Map.put(args, "basis_sha256", String.duplicate("0", 64))

            :wrong_binding ->
              recomputed(ctx, ["prototype", "binding_id"], Ecto.UUID.generate())

            :invocation ->
              recomputed(ctx, ["invocation", "response_sha256"], String.duplicate("a", 64))

            :charge ->
              recomputed(ctx, ["funding", "allocation_id"], Ecto.UUID.generate())

            :identity ->
              recomputed(ctx, ["identity", "model_id"], "claude-synthetic-other")
          end

        rewrite_arguments!(ctx.event, rewritten)
        assert_fails_closed!(ctx, unquote(Atom.to_string(variant)))
      end
    end
  end
end
