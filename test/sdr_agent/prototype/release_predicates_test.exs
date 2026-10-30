defmodule SdrAgent.Prototype.ReleasePredicatesTest do
  @moduledoc """
  RED-b2d r2 (`claude-d237-s2-b2d-r2-plan-20261029.md`; Codex entity PASS
  and review m_1793232377033550042_b77cba82, R1-R3 over r1; scope
  m_1793230811118886583_3b0d18e9), D-237 slice S2: the worker predicates
  `ResultGate.unreleased_invocations/1` and `ResultGate.unreleased?/1` over
  real committed `released_unverified` releases (`ResultGate.finalize/4` on
  S1's real provisioning), beyond the genuine-path case of
  `SdrAgent.Prototype.ReleaseReadersTest` (its `:213`, unchanged).

  The worker predicates:

  - **Mixed rows in one run.** The verified release leaves the list; an
    undecided invocation and a release whose original basis is tampered
    stay, in call order, and the boolean agrees with the list.
  - **A caller's transaction.** Inside an open `Audit.transaction/1` the
    verified row counts released and, after a live binding drift,
    unreleased; the refusal never aborts the caller, whose work persists.
  - **Asking writes nothing**, verified or refused: no DML, lock or other
    non-read statement is sent (only plain reads, transaction control and
    the verifier's state probe, scope marker and transaction-state read),
    and the tenant's events, releases, Failures, invocations and charge
    and the run, invocation and release values are unchanged.
  - **The partition.** In the ordinary runtime of this build the
    predicates never run the verifier (no state probe, no scope marker); in
    prototype runtime they run it once per call (the oracle's positive
    control).
  - **A technical error stays one.** A live-read abort inside the verifier
    (S1's `TestSeam.with_live_fault/3` at `:identity_read`, `:abort`) is
    the list's typed `in_failed_sql_transaction` error, unchanged, and the
    boolean is `true` (fail closed). The owner trace: one fault, no write
    and no scope marker before it, then exactly the failed identity read,
    the failed state probe and the owner's rollback. This is a
    predicate-level control only: a real worker's `{:ok, :ok} =`
    transaction wrapper can still raise a MatchError on an aborted
    transaction (`agent_worker.ex:89`, `reply_worker.ex:48`); no fix of
    those callers is claimed.

  The stale-run sweeper (`StaleRunSweeper.sweep/1`; Codex Q4 and R1), on a
  run assigned and abandoned through real APIs
  (`PrototypeGateFixtures.assigned!/1`, `abandon!/1`):

  - **A verified release takes the existing crash path**, once: the run
    fails `:crash` and its Operation fails and is discarded on the run's
    attention Failure; the release, its one original event, the charge and
    the invocations are unchanged, and no released or withheld decision is
    made. The verifier runs in the unlocked prefilter and again under the
    run lock, before the Operation lock and the first append (the locked
    recheck).
  - **An invalid or drifted release is never a crash:** the gate path
    refuses it with the verifier's own reason and nothing is written; the
    prefilter's verifier is reached.
  - **A technical error in the prefilter's verifier** halts the pass with
    an error, never an absence or a crash, and nothing is written.

  Messages are value-free: labels, booleans, counts, digests and closed
  codes. No real content: the output is the synthetic fixture completion.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Audit.Kernel
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.Prototype.Authority.TestSeam
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.SDR.StaleRunSweeper

  @marker "SELECT set_config($1, '1', true)"
  @xact "SELECT pg_current_xact_id()::text, current_setting($1, true)"
  @abort "SELECT 1 / 0"
  @identity_sql "SELECT current_database()::text, d.oid::bigint, " <>
                  "(pg_control_system()).system_identifier FROM pg_database d " <>
                  "WHERE d.datname = current_database()"
  @control ~w(begin commit rollback)
  @release_body [
    :id,
    :model_invocation_id,
    :disposition,
    :reason,
    :wire_witness_link_id,
    :projection_version,
    :method,
    :evidence_sha256,
    :decided_at
  ]
  @run_fields [:status, :status_reason, :attention_failure_id, :updated_at]
  @operation_fields [:status, :last_failure_id, :attempts, :updated_at]
  @invocation_fields [:id, :status, :updated_at]

  setup do
    %{fx: G.prototype!()}
  end

  ## Helpers

  defp released!(fx, run, invocation) do
    result = G.finalize(invocation, run)

    assert match?({:released, %{disposition: :released_unverified}, _}, result),
           "prerequisite: the release: #{inspect(G.summary(result))}"

    {:released, release, _output} = result
    assert [event] = G.release_events(fx, "model.result.released_unverified", release)
    {release, event}
  end

  # Both predicates on the re-read run: {unreleased?, the unreleased
  # invocations' labels in list order}.
  defp predicates(run, labels) do
    run = Ash.get!(AgentRun, run.id, authorize?: false)
    {:ok, unreleased} = ResultGate.unreleased_invocations(run)
    {ResultGate.unreleased?(run), Enum.map(unreleased, &Map.get(labels, &1.id, :other))}
  end

  defp labels(ctx), do: %{ctx.invocation.id => :a}

  # Labelled tamper of an original released_unverified event: the basis
  # changed, its digest not updated.
  defp tamper_basis!(event) do
    path = ["basis", "invocation", "purpose"]
    arguments = put_in(event.payload["arguments"], path, "evidence_extraction")

    tamper!(
      "UPDATE audit_events SET payload = jsonb_set(payload, '{arguments}', $2::text::jsonb) WHERE id = $1",
      [Ecto.UUID.dump!(event.id), Jason.encode!(arguments)]
    )
  end

  # Every statement this process sent while `fun` ran, as binaries.
  defp capture(fun) do
    {result, sql} = GateFixtures.capture(fun)
    {result, Enum.map(sql, &IO.iodata_to_binary/1)}
  end

  # Everything asking a predicate could write: the tenant's events, releases
  # and Failures (ids), its invocations and the grant's charge (counts), and
  # the mutable values of the run, the invocation and its release.
  defp writes(fx, s) do
    tenant_id = fx.tenant.id

    ids = fn resource ->
      resource
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.read!(Kernel.opts(tenant_id))
      |> Enum.map(& &1.id)
      |> Enum.sort()
    end

    %{
      events: fx.tenant |> events() |> Enum.map(& &1.id),
      releases: ids.(ModelResultRelease),
      failures: ids.(Failure),
      invocations: G.invocations(fx),
      charged: G.charged(fx),
      run: AgentRun |> Ash.get!(s.run.id, authorize?: false) |> Map.take(@run_fields),
      invocation:
        ModelInvocation
        |> Ash.get!(s.invocation.id, Kernel.opts(tenant_id))
        |> Map.take(@invocation_fields),
      release: s.invocation |> G.release() |> Map.take(@release_body)
    }
  end

  # One captured statement as a closed category: transaction control, the
  # verifier's state probe, scope marker or transaction-state read, a plain
  # read (a SELECT with no row-lock clause and no state-setting function),
  # else :other (every write form, lock or unrecognized statement).
  defp category(sql) do
    cond do
      sql in @control -> :control
      sql == G.state_probe() -> :probe
      sql == @marker -> :marker
      sql == @xact -> :xact
      plain_read?(sql) -> :read
      true -> :other
    end
  end

  defp plain_read?(sql) do
    String.starts_with?(sql, "SELECT ") and not GateFixtures.lock?(sql) and
      not String.contains?(sql, ["set_config", "nextval", "setval", "pg_advisory"])
  end

  # The statements' categories as counts (a value-free failure message).
  defp shape(sql), do: sql |> Enum.map(&category/1) |> Enum.frequencies()

  # The verifier's own raw statements (`ReleasedScope.run/3`), in order, as
  # closed categories: its state probe and its scope marker.
  defp verifier_statements(sql) do
    probe = G.state_probe()

    Enum.flat_map(sql, fn
      ^probe -> [:probe]
      @marker -> [:marker]
      _other -> []
    end)
  end

  # The owner trace of one faulted call (Codex R2), value-free: the number
  # of faults, the non-read statements and the verifier statements before
  # the first one, and every statement after it, in order.
  defp fault_trace(sql) do
    {before, from} = Enum.split_while(sql, &(&1 != @abort))

    %{
      faults: Enum.count(sql, &(&1 == @abort)),
      writes_before: Enum.count(before, &(category(&1) == :other)),
      verifier_before: verifier_statements(before),
      after: from |> Enum.drop(1) |> Enum.map(&step/1)
    }
  end

  defp step("rollback"), do: :rollback
  defp step("commit"), do: :commit
  defp step(@identity_sql), do: :identity
  defp step(sql), do: category(sql)

  # `call` under one :identity_read :abort scope inside an owning
  # Audit.transaction, which then rolls back with {result, fault hits}.
  defp faulted_owner(call) do
    SdrAgent.Audit.transaction(fn ->
      inside =
        TestSeam.with_live_fault(:identity_read, :abort, fn ->
          {call.(), TestSeam.live_fault_hits(:identity_read)}
        end)

      SdrAgent.Repo.rollback(inside)
    end)
  end

  # A value-free shape of one rolled-back fault outcome.
  defp fault_shape({:error, {inner, hits}}), do: {:rolled_back, code(inner), hits}
  defp fault_shape(other), do: G.summary(other)

  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: {:error, code}
  defp code({:ok, list}) when is_list(list), do: {:ok, length(list)}
  defp code(value) when is_boolean(value), do: value
  defp code(other), do: G.summary(other)

  ## Sweeper helpers

  defp sweep(fx), do: StaleRunSweeper.sweep(fx.tenant.id)

  defp row_lock?(sql, table) do
    String.starts_with?(sql, "SELECT") and String.contains?(sql, ~s(FROM "#{table}")) and
      String.contains?(sql, "FOR UPDATE")
  end

  defp unlocked?(sql), do: not row_lock?(sql, "agent_runs")

  # The statements before the pass's first run lock (the unlocked prefilter).
  defp prefilter(sql), do: Enum.take_while(sql, &unlocked?/1)

  # The crash path's order: the verifier in the prefilter, then again
  # between the run lock and the first Operation lock after it (the locked
  # recheck), and whether the first chain-head statement after the run lock
  # (the first append) follows that Operation lock.
  defp recheck(sql) do
    with {before, [_run_lock | locked]} <- Enum.split_while(sql, &unlocked?/1),
         op when is_integer(op) <- GateFixtures.index(locked, &row_lock?(&1, "operations")),
         append when is_integer(append) <-
           GateFixtures.index(locked, &String.contains?(&1, ~s("audit_chain_heads"))) do
      %{
        prefilter: verifier_statements(before),
        locked_recheck: locked |> Enum.take(op) |> verifier_statements(),
        append_after_locks: append > op
      }
    else
      _missing -> :lock_or_append_missing
    end
  end

  # Where the injected fault ran: in the unlocked prefilter, under a run
  # lock, or nowhere.
  defp fault_site(sql) do
    {before, rest} = Enum.split_while(sql, &unlocked?/1)

    cond do
      @abort in before -> :prefilter
      @abort in rest -> :under_run_lock
      true -> :not_reached
    end
  end

  defp operation(a), do: Ash.get!(Operation, a.run.operation_id, Kernel.opts(a.run.tenant_id))

  defp typed(fx, type, subject_id),
    do: fx.tenant |> events_of_type(type) |> Enum.count(&(&1.subject_id == subject_id))

  # What the sweeper never changes for the release: the release, its
  # original events (id and argument digest), the released and withheld
  # decisions, the invocations and the charge.
  defp gate_state(ctx) do
    fx = ctx.fx
    originals = G.release_events(fx, "model.result.released_unverified", ctx.release)

    %{
      release: ctx.assigned.invocation |> G.release() |> Map.take(@release_body),
      originals: Enum.map(originals, &{&1.id, G.canonical_hex(&1.payload["arguments"])}),
      released: length(events_of_type(fx.tenant, "model.result.released")),
      withheld: length(events_of_type(fx.tenant, "model.result.withheld")),
      invocations: G.invocations(fx),
      charged: G.charged(fx)
    }
  end

  # What a refused or failed pass leaves as it is: the run, its Operation,
  # the tenant's Failures and its whole event chain.
  defp held_state(ctx) do
    a = ctx.assigned
    tenant_id = a.run.tenant_id

    %{
      run: AgentRun |> Ash.get!(a.run.id, authorize?: false) |> Map.take(@run_fields),
      operation: a |> operation() |> Map.take(@operation_fields),
      failures:
        Failure
        |> Ash.Query.filter(tenant_id == ^tenant_id)
        |> Ash.read!(Kernel.opts(tenant_id))
        |> Enum.map(& &1.id)
        |> Enum.sort(),
      events: ctx.fx.tenant |> events() |> Enum.map(& &1.id)
    }
  end

  defp spoil!(:tampered_basis, ctx), do: tamper_basis!(ctx.event)
  defp spoil!(:drifted_binding, _ctx), do: G.drift!()

  ## The worker predicates

  describe "the worker predicates" do
    setup %{fx: fx} do
      run = G.run!(fx)
      invocation = G.completed!(fx, run)
      _released = released!(fx, run, invocation)
      %{run: run, invocation: invocation}
    end

    test "mixed rows in one run: only the verified release leaves the list", ctx do
      undecided = G.completed!(ctx.fx, ctx.run)
      invalid = G.completed!(ctx.fx, ctx.run)
      {_release, invalid_event} = released!(ctx.fx, ctx.run, invalid)
      tamper_basis!(invalid_event)

      named = Map.merge(labels(ctx), %{undecided.id => :undecided, invalid.id => :invalid})
      assert predicates(ctx.run, named) == {true, [:undecided, :invalid]}
    end

    test "in a caller's transaction: released, then unreleased after a drift; its work persists",
         ctx do
      result =
        SdrAgent.Audit.transaction(fn ->
          work = GateFixtures.cause!(ctx.invocation, operation_id: ctx.run.operation_id)
          verified = predicates(ctx.run, labels(ctx))
          G.drift!()
          refused = predicates(ctx.run, labels(ctx))
          {work.id, verified, refused, SdrAgent.Repo.query!("SELECT 1").rows}
        end)

      shape =
        case result do
          {:ok, {_work_id, verified, refused, select}} -> {:ok, verified, refused, select}
          other -> G.summary(other)
        end

      assert shape == {:ok, {false, []}, {true, [:a]}, [[1]]}
      {:ok, {work_id, _verified, _refused, _select}} = result
      assert Ash.get!(Failure, work_id, authorize?: false).id == work_id
    end

    test "asking the predicates writes nothing, verified or refused", ctx do
      before = writes(ctx.fx, ctx)

      {{verified, refused}, sql} =
        capture(fn ->
          verified = predicates(ctx.run, labels(ctx))
          G.drift!()
          {verified, predicates(ctx.run, labels(ctx))}
        end)

      assert Map.get(shape(sql), :other, 0) == 0, "statements: #{inspect(shape(sql))}"
      assert writes(ctx.fx, ctx) == before
      assert {verified, refused} == {{false, []}, {true, [:a]}}
    end

    test "ordinary runtime: the predicates never run the verifier (control)", ctx do
      :ok = PrototypeFixtures.leave_runtime()
      {result, sql} = capture(fn -> predicates(ctx.run, labels(ctx)) end)

      assert result == {true, [:a]}
      assert verifier_statements(sql) == []
    end

    test "prototype runtime: each predicate call runs the verifier once (positive control)",
         ctx do
      {result, sql} = capture(fn -> predicates(ctx.run, labels(ctx)) end)

      assert result == {false, []}
      assert verifier_statements(sql) == [:probe, :marker, :probe, :marker]
    end

    test "a live-read abort inside the verifier: the list's typed error, the boolean true, no write",
         ctx do
      run = Ash.get!(AgentRun, ctx.run.id, authorize?: false)

      outcomes =
        for {label, predicate} <- [
              list: &ResultGate.unreleased_invocations/1,
              boolean: &ResultGate.unreleased?/1
            ] do
          {result, sql} = capture(fn -> faulted_owner(fn -> predicate.(run) end) end)
          {label, fault_shape(result), fault_trace(sql), TestSeam.live_fault_hits(:identity_read)}
        end

      trace = %{
        faults: 1,
        writes_before: 0,
        verifier_before: [:probe],
        after: [:identity, :probe, :rollback]
      }

      assert outcomes == [
               {:list, {:rolled_back, {:error, :in_failed_sql_transaction}, 1}, trace, 0},
               {:boolean, {:rolled_back, true, 1}, trace, 0}
             ]
    end
  end

  ## The stale-run sweeper (Codex Q4, R1)

  describe "the stale-run sweeper" do
    setup %{fx: fx} do
      a = G.assigned!(fx)
      {release, event} = released!(fx, a.run, a.invocation)
      %{assigned: a, release: release, event: event}
    end

    test "a verified release takes the existing crash path once; the release stands", ctx do
      a = ctx.assigned
      G.abandon!(a)
      before = gate_state(ctx)
      {result, sql} = capture(fn -> sweep(ctx.fx) end)

      assert result == :ok, "sweep: #{inspect(G.summary(result))}"
      run = Ash.get!(AgentRun, a.run.id, authorize?: false)
      assert {run.status, run.status_reason} == {:failed, :crash}
      op = operation(a)
      assert op.status == :discarded, "Operation: #{inspect(op.status)}"
      assert op.last_failure_id == run.attention_failure_id, "the Operation's Failure"
      attention = Ash.get!(Failure, run.attention_failure_id, Kernel.opts(run.tenant_id))
      assert attention.status == :open, "attention: #{inspect(attention.status)}"

      once = %{
        run_failed: typed(ctx.fx, "agents.run.failed", run.id),
        operation_failed: typed(ctx.fx, "operations.operation.failed", op.id),
        operation_discarded: typed(ctx.fx, "operations.operation.discarded", op.id)
      }

      assert once == %{run_failed: 1, operation_failed: 1, operation_discarded: 1}
      assert gate_state(ctx) == before, "the release, a decision, an invocation or the charge"

      assert recheck(sql) == %{
               prefilter: [:probe, :marker],
               locked_recheck: [:probe, :marker],
               append_after_locks: true
             }

      events = ctx.fx.tenant |> events() |> Enum.map(& &1.id)
      assert sweep(ctx.fx) == :ok
      assert ctx.fx.tenant |> events() |> Enum.map(& &1.id) == events, "a second pass appended"
    end

    for {label, reason, reached} <- [
          {:tampered_basis, :basis_invalid, [:probe]},
          {:drifted_binding, :binding_mismatch, [:probe, :probe]}
        ] do
      test "a #{label} release is never a crash: the gate path refuses it, nothing is written",
           ctx do
        a = ctx.assigned
        spoil!(unquote(label), ctx)
        G.abandon!(a)
        before = {held_state(ctx), gate_state(ctx)}
        {result, sql} = capture(fn -> sweep(ctx.fx) end)

        assert result == {:error, unquote(reason)}, "sweep: #{inspect(G.summary(result))}"
        assert {held_state(ctx), gate_state(ctx)} == before, "the pass wrote"
        # Reached: the prefilter's own verifier refused the candidate.
        assert verifier_statements(prefilter(sql)) == unquote(reached)
      end
    end

    test "a technical error in the prefilter's verifier halts the pass; no crash, nothing written",
         ctx do
      a = ctx.assigned
      G.abandon!(a)
      before = {held_state(ctx), gate_state(ctx)}

      {{result, hits}, sql} =
        capture(fn ->
          TestSeam.with_live_fault(:identity_read, :abort, fn ->
            {sweep(ctx.fx), TestSeam.live_fault_hits(:identity_read)}
          end)
        end)

      assert hits == 1, "fault hits: #{hits}"
      assert fault_site(sql) == :prefilter
      assert G.summary(result) == {:error, :rollback}
      assert fault_trace(sql).after == [:identity, :probe, :rollback]
      assert {held_state(ctx), gate_state(ctx)} == before, "the pass wrote"
    end
  end
end
