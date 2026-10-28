defmodule SdrAgent.Prototype.LiveFaultConsumerTest do
  @moduledoc """
  TF-2 RED (trace r3, `claude-d237-s2-tf2-consumer-trace-r3-20261028.md`;
  Codex c83a34e9), D-237 slice S2: a live-read fault at S2's ACTUAL
  consumer sites, through their public APIs, with S1's existing
  `SdrAgent.Prototype.Authority.TestSeam.with_live_fault/3` armed around the
  consumer call only (never around fixture creation).

  The sites:
  - **R1**, `Agents.reserve_model_invocation/3`. It is top level, so
    `Kernel.in_transaction/1` is the owner. **R1i** runs the same call inside
    an allowed `SdrAgent.Audit.transaction/1` owner (inherited).
  - **L1**, `Agents.admit_launch/3`; its owner is `audit_transact/1`.
  - **F1d**, `ResultGate.finalize/4` with `{:ok, receipt}`; its owner is the
    release attempt.
  - **F1f**, `ResultGate.gate/3`, the facade.

  The stage and owner split (S1's pinned semantics, 5a6daa6):
  - **`:returned_error` and `:raise`, either stage:** synthetic and
    non-aborting. The current conservative `binding_mismatch` refusal is
    pinned as a CONTROL.
  - **`:binding_read` `:abort`:** the tagged `SELECT 1 / 0`, then the real
    binding `Ash.read`, which fails and throws the rollback to the owner
    (`{:error, %Ash.Query{resource: PrototypeDatabaseBinding}}`). There is no
    refusal, no continuation and no probe. Pinned as a CONTROL.
  - **`:identity_read` `:abort`:** the tagged abort, then the real identity
    query, which fails and returns, so the conservative `binding_mismatch`
    comes back on an ABORTED transaction.
    - At top-level R1 it is rolled back by the owner, and the refusal is
      recorded in its own later transaction. That is a CONTROL of current
      behaviour (Codex Q-T2 KEEP; S1 P1).
    - At L1, F1d, F1f and R1i, the oracle is that no business statement
      follows the failed read before the owner's rollback; at most one state
      probe is allowed. These are the RED candidates.

  Every case asserts:
  - exactly one hit of the stage INSIDE the scope, zero hits of a
    `:delegation_read` tripwire scope around it, and the scope restored
    after it;
  - the closed statement labels of this process, from Repo telemetry:
    `begin`, `commit` and `rollback`; the tagged fault, with
    `Repo.in_transaction?/0` at that point; the EXACT text of each live read
    (taken from a real `check_live/0` beforehand); the exact state probe
    `SELECT 1`; anything else is `{:other, verb}`, never whitelisted by
    table;
  - the exact before and after values: the run (status, reason, attention,
    reservation counter, `updated_at`), the invocation (status, `sent_at`),
    the tenant's invocation count, the charge, the Failure ids, the event
    ids and types, and the pending prototype registrations.

  Results are relayed as closed identities only: the wrapper, the module,
  the resource and the closed codes. Synthetic `.test` data only; no model
  call.
  """
  use SdrAgent.PrototypeCase, async: false

  require Ash.Query

  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.PrototypeDatabaseBinding
  alias SdrAgent.Prototype.Admission, as: PrototypeAdmission
  alias SdrAgent.Prototype.Authority.TestSeam
  alias SdrAgent.PrototypeGateFixtures, as: G

  @reservation_refusal ["operations.failure.opened", "model.reservation.refused"]
  @launch_refusal ["model.invocation.failed", "operations.failure.opened", "model.launch.refused"]
  @release_refusal ["operations.failure.opened", "model.result.withheld", "agents.run.failed"]
  @identity_failed {{:live_read, :identity_read}, :in_failed_sql_transaction}
  @binding_failed {{:live_read, :binding_read}, :in_failed_sql_transaction}
  @state_probe_failed {:state_probe, :in_failed_sql_transaction}

  setup do
    %{fx: G.prototype!()}
  end

  ## The seam: one scope around the consumer only

  # `kind` at `stage` around `fun`, inside a `:delegation_read` tripwire
  # scope; the hits of both are read INSIDE the scopes.
  defp armed(stage, kind, fun) do
    TestSeam.with_live_fault(:delegation_read, :returned_error, fn ->
      TestSeam.with_live_fault(stage, kind, fn ->
        result = fun.()
        {result, TestSeam.live_fault_hits(stage), TestSeam.live_fault_hits(:delegation_read)}
      end)
    end)
  end

  defp reached!(stage, hits, tripwire) do
    assert {hits, tripwire} == {1, 0},
           "prerequisite: #{stage} hits #{hits}, delegation hits #{tripwire}"

    assert TestSeam.live_fault_hits(stage) == 0, "the #{stage} scope outlived its call"
  end

  ## Statements (Repo telemetry of this process; text never leaves the test)

  @doc false
  def handle_query(_event, _measurements, metadata, test) do
    if self() == test do
      row =
        {metadata.query, Map.get(metadata, :source), Map.get(metadata, :options) || [],
         code(metadata.result), Repo.in_transaction?()}

      send(test, {:d237_tf2_query, row})
    end
  end

  defp code({:ok, _}), do: :ok
  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code
  defp code(_other), do: :error

  defp raw(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:sdr_agent, :repo, :query], &__MODULE__.handle_query/4, self())

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(rows) do
    receive do
      {:d237_tf2_query, row} -> drain([row | rows])
    after
      0 -> Enum.reverse(rows)
    end
  end

  # The exact texts of the two live reads, from one real `check_live/0`.
  defp live_texts! do
    {result, rows} = raw(&SdrAgent.Prototype.check_live/0)
    assert result == :ok, "prerequisite: check_live"
    assert length(rows) == 2, "prerequisite: two live reads, got #{length(rows)}"
    [{binding, binding_source, _, :ok, _}, {identity, identity_source, _, :ok, _}] = rows
    assert {binding_source, identity_source} == {"prototype_database_bindings", nil}
    %{binding_read: binding, identity_read: identity}
  end

  defp captured(fun, texts) do
    {result, rows} = raw(fun)
    {result, Enum.map(rows, &label(&1, texts))}
  end

  defp label({query, source, options, code, in_tx}, texts) do
    {kind(query, source, options, in_tx, texts), code}
  end

  defp kind("begin", _source, _options, _in_tx, _texts), do: :begin
  defp kind("commit", _source, _options, _in_tx, _texts), do: :commit
  defp kind("rollback", _source, _options, _in_tx, _texts), do: :rollback

  defp kind(query, source, options, in_tx, texts) do
    cond do
      Keyword.has_key?(options, :d237_live_fault) ->
        {:fault, options[:d237_live_fault], in_tx}

      query == texts.binding_read and source == "prototype_database_bindings" ->
        {:live_read, :binding_read}

      query == texts.identity_read and is_nil(source) ->
        {:live_read, :identity_read}

      query == "SELECT 1" and is_nil(source) ->
        :state_probe

      true ->
        {:other, verb(query)}
    end
  end

  defp verb(query) do
    case query
         |> String.trim_leading()
         |> String.split(" ", parts: 2)
         |> hd()
         |> String.upcase() do
      "SELECT" -> :select
      "INSERT" -> :insert
      "UPDATE" -> :update
      "DELETE" -> :delete
      _other -> :other
    end
  end

  # Exactly one tagged fault, inside a transaction, every statement before
  # it successful; returns the statements after it.
  defp after_fault!(events, stage) do
    faults = Enum.filter(events, &match?({{:fault, _, _}, _}, &1))
    assert faults == [{{:fault, stage, true}, :division_by_zero}], "faults: #{inspect(faults)}"
    {pre, [_fault | post]} = Enum.split_while(events, &(not match?({{:fault, _, _}, _}, &1)))
    failed = for {label, code} <- pre, code != :ok, do: label
    assert failed == [], "failed before the fault: #{inspect(failed)}"
    post
  end

  # Synthetic kinds: no tagged fault, no failed statement, and no SQL at
  # the faulted stage.
  defp synthetic!(events, stage) do
    failed = for {label, code} <- events, code != :ok, do: label
    assert failed == [], "a statement failed: #{inspect(failed)}"
    refute Enum.any?(events, &match?({{:fault, _, _}, _}, &1)), "a tagged fault ran"

    refute Enum.any?(events, &match?({{:live_read, ^stage}, _}, &1)),
           "the faulted #{stage} read ran"
  end

  # The no-business-statement oracle after a failed read: at most one
  # state probe, then the owner's rollback, and nothing else.
  defp owner_only!(post, failed_read) do
    assert post in [
             [failed_read, {:rollback, :ok}],
             [failed_read, @state_probe_failed, {:rollback, :ok}]
           ],
           "after the failed read: #{inspect(post)}"
  end

  # Exactly one later transaction of its own (Codex 7e2eb9ab): one `begin`
  # first, one `commit` last, no `rollback` and no other boundary, and
  # between them only successful business statements (no fault, live read
  # or probe).
  defp own_transaction!(segment) do
    labels = Enum.map(segment, &elem(&1, 0))
    delimiters = for label <- labels, label in [:begin, :commit, :rollback], do: label

    assert delimiters == [:begin, :commit],
           "refusal transaction delimiters: #{inspect(delimiters)}"

    assert match?([{:begin, :ok} | _], segment), "the refusal transaction: #{inspect(segment)}"
    assert List.last(segment) == {:commit, :ok}, "the refusal transaction: #{inspect(segment)}"
    interior = segment |> Enum.drop(1) |> Enum.drop(-1)
    assert interior != [], "the refusal transaction is empty"
    foreign = for {label, _code} <- interior, not match?({:other, _}, label), do: label
    assert foreign == [], "inside the refusal transaction: #{inspect(foreign)}"
    failed = for {label, code} <- segment, code != :ok, do: label
    assert failed == [], "the refusal transaction failed: #{inspect(failed)}"
  end

  ## State (kernel reads)

  defp kernel(fx), do: SdrAgent.Audit.Kernel.opts(fx.tenant.id)

  defp snapshot(fx, run, invocation) do
    %{
      run: run_state(fx, run),
      invocation: invocation && invocation_state(fx, invocation),
      invocations: G.invocations(fx),
      charged: G.charged(fx),
      failures: failure_ids(fx),
      events: fx.tenant |> events() |> Enum.map(& &1.id),
      pending: PrototypeAdmission.pending()
    }
  end

  defp run_state(fx, run) do
    r = Ash.get!(AgentRun, run.id, kernel(fx))

    {r.status, r.status_reason, r.attention_failure_id, r.budget.model_calls_reserved,
     r.updated_at}
  end

  defp invocation_state(fx, invocation) do
    i = Ash.get!(ModelInvocation, invocation.id, kernel(fx))
    {i.status, i.sent_at}
  end

  defp failure_ids(fx) do
    Failure
    |> Ash.Query.filter(tenant_id == ^fx.tenant.id)
    |> Ash.read!(kernel(fx))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp new_types(fx, before) do
    fx.tenant |> events() |> Enum.reject(&(&1.id in before.events)) |> Enum.map(& &1.event_type)
  end

  defp new_failures(fx, before), do: failure_ids(fx) -- before.failures

  # Nothing written: every value exactly as before.
  defp nothing!(fx, run, invocation, before) do
    now = snapshot(fx, run, invocation)
    assert new_types(fx, before) == [], "events appended: #{inspect(new_types(fx, before))}"
    assert new_failures(fx, before) == [], "a Failure was opened"
    assert now.run == before.run, "the run changed"
    assert now.invocation == before.invocation, "the invocation changed"
    assert {now.invocations, now.charged} == {before.invocations, before.charged}
    assert now.pending == 0, "registrations pending: #{now.pending}"
  end

  # A closed identity of a result: wrapper, module, resource, closed codes.
  defp ident({:error, %Refused{} = r}), do: {:error, Refused, r.stage, r.reason, r.check}
  defp ident({:error, %Ash.Query{resource: resource}}), do: {:error, Ash.Query, resource}

  defp ident({:error, %{__struct__: module} = error}),
    do: {:error, module, Enum.map(Map.get(error, :errors, []), &leaf/1)}

  defp ident({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp ident({tag, %{__struct__: module}, _}) when is_atom(tag), do: {tag, module}
  defp ident({:ok, %{__struct__: module}}), do: {:ok, module}
  defp ident(_other), do: :other

  defp leaf(%{__struct__: module}), do: module
  defp leaf(_other), do: :term

  defp binding_throw?(result),
    do: match?({:error, %Ash.Query{resource: PrototypeDatabaseBinding, errors: [_ | _]}}, result)

  defp refused?(result, stage),
    do:
      match?(
        {:error,
         %Refused{reason: :prototype_not_authorized, check: :binding_mismatch, stage: ^stage}},
        result
      )

  defp refusal_code(fx, release) do
    [event] = G.release_events(fx, "model.result.withheld", release)
    event.payload["arguments"]["prototype_refusal"]
  end

  ## The consumer calls

  defp reserve(fx, run), do: G.reserve(fx, run)

  defp release_call(:direct, invocation, run), do: G.finalize(invocation, run)
  defp release_call(:facade, invocation, run), do: ResultGate.gate(invocation, G.gate(run))

  ## No fault (controls)

  describe "no fault: the reads are real and no scope fires" do
    test "R1, L1, F1d and F1f with only the delegation tripwire armed", %{fx: fx} do
      run = G.run!(fx)

      {reserved, 0} =
        TestSeam.with_live_fault(:delegation_read, :raise, fn ->
          {reserve(fx, run), TestSeam.live_fault_hits(:delegation_read)}
        end)

      assert match?({:ok, %ModelInvocation{status: :reserved}}, reserved),
             inspect(ident(reserved))

      {:ok, reserved} = reserved

      {sent, 0} =
        TestSeam.with_live_fault(:delegation_read, :raise, fn ->
          {G.launch(fx, reserved), TestSeam.live_fault_hits(:delegation_read)}
        end)

      assert match?({:ok, %ModelInvocation{status: :sent}}, sent), inspect(ident(sent))

      for path <- [:direct, :facade] do
        run = G.run!(fx)
        invocation = G.completed!(fx, run)

        {decided, 0} =
          TestSeam.with_live_fault(:delegation_read, :raise, fn ->
            {release_call(path, invocation, run), TestSeam.live_fault_hits(:delegation_read)}
          end)

        assert match?({tag, _, _} when tag in [:released, :withheld], decided),
               inspect(ident(decided))

        {_tag, release, _} = decided

        refute release.disposition == :withheld and
                 refusal_code(fx, release) == "binding_mismatch",
               "#{path}: a live mismatch with no fault"
      end
    end
  end

  ## R1: the reservation (top level: Kernel.in_transaction owns)

  describe "R1 reservation, top level" do
    for stage <- [:binding_read, :identity_read], kind <- [:returned_error, :raise] do
      test "#{stage}/#{kind}: the conservative refusal, uncharged, recorded once (control)",
           %{fx: fx} do
        texts = live_texts!()
        run = G.run!(fx)
        before = snapshot(fx, run, nil)

        {{result, hits, trip}, events} =
          captured(
            fn -> armed(unquote(stage), unquote(kind), fn -> reserve(fx, run) end) end,
            texts
          )

        reached!(unquote(stage), hits, trip)
        synthetic!(events, unquote(stage))
        assert refused?(result, :reservation), "reserve: #{inspect(ident(result))}"
        {:error, refused} = result
        now = snapshot(fx, run, nil)

        assert {now.run, now.invocations, now.charged, now.pending} ==
                 {before.run, before.invocations, before.charged, 0}

        assert new_failures(fx, before) == [refused.failure_id]
        assert new_types(fx, before) == @reservation_refusal
      end
    end

    test "binding_read/abort: the real read's rollback throws to the owner; no refusal (control)",
         %{fx: fx} do
      texts = live_texts!()
      run = G.run!(fx)
      before = snapshot(fx, run, nil)

      {{result, hits, trip}, events} =
        captured(fn -> armed(:binding_read, :abort, fn -> reserve(fx, run) end) end, texts)

      reached!(:binding_read, hits, trip)
      assert after_fault!(events, :binding_read) == [@binding_failed, {:rollback, :ok}]
      assert binding_throw?(result), "reserve: #{inspect(ident(result))}"
      nothing!(fx, run, nil, before)
    end

    test "identity_read/abort: owner rollback, then the refusal in its own transaction (control, Q-T2 KEEP)",
         %{fx: fx} do
      texts = live_texts!()
      run = G.run!(fx)
      before = snapshot(fx, run, nil)

      {{result, hits, trip}, events} =
        captured(fn -> armed(:identity_read, :abort, fn -> reserve(fx, run) end) end, texts)

      reached!(:identity_read, hits, trip)
      {owner, refusal_tx} = Enum.split(after_fault!(events, :identity_read), 2)
      assert owner == [@identity_failed, {:rollback, :ok}], "owner: #{inspect(owner)}"
      own_transaction!(refusal_tx)
      assert refused?(result, :reservation), "reserve: #{inspect(ident(result))}"
      {:error, refused} = result
      now = snapshot(fx, run, nil)

      assert {now.run, now.invocations, now.charged, now.pending} ==
               {before.run, before.invocations, before.charged, 0}

      assert new_failures(fx, before) == [refused.failure_id]
      assert new_types(fx, before) == @reservation_refusal
    end
  end

  ## R1i: the reservation inside an allowed Audit.transaction owner

  describe "R1i reservation, inherited owner (SdrAgent.Audit.transaction/1)" do
    test "binding_read/abort: the rollback throws to the inherited owner; nothing written (control)",
         %{fx: fx} do
      texts = live_texts!()
      run = G.run!(fx)
      before = snapshot(fx, run, nil)

      {{owner, hits, trip}, events} =
        captured(
          fn ->
            armed(:binding_read, :abort, fn ->
              SdrAgent.Audit.transaction(fn -> reserve(fx, run) end)
            end)
          end,
          texts
        )

      reached!(:binding_read, hits, trip)
      assert after_fault!(events, :binding_read) == [@binding_failed, {:rollback, :ok}]
      assert binding_throw?(owner), "owner: #{inspect(ident(owner))}"
      nothing!(fx, run, nil, before)
    end

    test "identity_read/abort: no business statement after the failed read before the owner's rollback",
         %{fx: fx} do
      texts = live_texts!()
      run = G.run!(fx)
      before = snapshot(fx, run, nil)

      {{owner, hits, trip}, events} =
        captured(
          fn ->
            armed(:identity_read, :abort, fn ->
              SdrAgent.Audit.transaction(fn -> reserve(fx, run) end)
            end)
          end,
          texts
        )

      reached!(:identity_read, hits, trip)
      owner_only!(after_fault!(events, :identity_read), @identity_failed)
      assert match?({:error, _}, owner), "owner: #{inspect(ident(owner))}"
      nothing!(fx, run, nil, before)
    end
  end

  ## L1: the launch

  describe "L1 launch" do
    setup %{fx: fx} do
      run = G.run!(fx)
      {:ok, reserved} = reserve(fx, run)
      %{run: run, reserved: reserved}
    end

    for stage <- [:binding_read, :identity_read], kind <- [:returned_error, :raise] do
      test "#{stage}/#{kind}: the conservative launch refusal, charged, recorded once (control)",
           ctx do
        texts = live_texts!()
        before = snapshot(ctx.fx, ctx.run, ctx.reserved)

        {{result, hits, trip}, events} =
          captured(
            fn ->
              armed(unquote(stage), unquote(kind), fn -> G.launch(ctx.fx, ctx.reserved) end)
            end,
            texts
          )

        reached!(unquote(stage), hits, trip)
        synthetic!(events, unquote(stage))
        assert refused?(result, :launch), "launch: #{inspect(ident(result))}"
        {:error, refused} = result
        now = snapshot(ctx.fx, ctx.run, ctx.reserved)
        assert now.invocation == {:failed, nil}, "invocation: #{inspect(elem(now.invocation, 0))}"

        assert {now.run, now.invocations, now.charged, now.pending} ==
                 {before.run, before.invocations, before.charged, 0}

        assert new_failures(ctx.fx, before) == [refused.failure_id]
        assert new_types(ctx.fx, before) == @launch_refusal
      end
    end

    test "binding_read/abort: the real read's rollback throws to the owner; no refusal (control)",
         ctx do
      texts = live_texts!()
      before = snapshot(ctx.fx, ctx.run, ctx.reserved)

      {{result, hits, trip}, events} =
        captured(
          fn -> armed(:binding_read, :abort, fn -> G.launch(ctx.fx, ctx.reserved) end) end,
          texts
        )

      reached!(:binding_read, hits, trip)
      assert after_fault!(events, :binding_read) == [@binding_failed, {:rollback, :ok}]
      assert binding_throw?(result), "launch: #{inspect(ident(result))}"
      nothing!(ctx.fx, ctx.run, ctx.reserved, before)
    end

    test "identity_read/abort: no business statement after the failed read before the owner's rollback",
         ctx do
      texts = live_texts!()
      before = snapshot(ctx.fx, ctx.run, ctx.reserved)

      {{result, hits, trip}, events} =
        captured(
          fn -> armed(:identity_read, :abort, fn -> G.launch(ctx.fx, ctx.reserved) end) end,
          texts
        )

      reached!(:identity_read, hits, trip)
      owner_only!(after_fault!(events, :identity_read), @identity_failed)
      assert match?({:error, _}, result) and not refused?(result, :launch)
      nothing!(ctx.fx, ctx.run, ctx.reserved, before)
    end
  end

  ## F1: the release refusal code (direct finalize and the facade)

  for path <- [:direct, :facade] do
    describe "F1 release, #{path}" do
      setup %{fx: fx} do
        run = G.run!(fx)
        %{run: run, invocation: G.completed!(fx, run)}
      end

      for stage <- [:binding_read, :identity_read], kind <- [:returned_error, :raise] do
        test "#{stage}/#{kind}: withheld binding_mismatch, the run stopped (control)", ctx do
          texts = live_texts!()
          before = snapshot(ctx.fx, ctx.run, ctx.invocation)

          {{result, hits, trip}, events} =
            captured(
              fn ->
                armed(unquote(stage), unquote(kind), fn ->
                  release_call(unquote(path), ctx.invocation, ctx.run)
                end)
              end,
              texts
            )

          reached!(unquote(stage), hits, trip)
          synthetic!(events, unquote(stage))

          assert match?(
                   {:withheld, %{reason: :prototype_authority_refused},
                    %{status: :failed, status_reason: :witness_unreconciled}},
                   result
                 ),
                 "release: #{inspect(ident(result))}"

          {:withheld, release, stopped} = result
          assert refusal_code(ctx.fx, release) == "binding_mismatch"
          assert new_failures(ctx.fx, before) == [stopped.attention_failure_id]
          assert new_types(ctx.fx, before) == @release_refusal
          now = snapshot(ctx.fx, ctx.run, ctx.invocation)

          assert {now.invocations, now.charged, now.pending} ==
                   {before.invocations, before.charged, 0}
        end
      end

      test "binding_read/abort: the real read's rollback throws to the owner; nothing decided (control)",
           ctx do
        texts = live_texts!()
        before = snapshot(ctx.fx, ctx.run, ctx.invocation)

        {{result, hits, trip}, events} =
          captured(
            fn ->
              armed(:binding_read, :abort, fn ->
                release_call(unquote(path), ctx.invocation, ctx.run)
              end)
            end,
            texts
          )

        reached!(:binding_read, hits, trip)
        assert after_fault!(events, :binding_read) == [@binding_failed, {:rollback, :ok}]
        assert binding_throw?(result), "release: #{inspect(ident(result))}"
        assert G.release(ctx.invocation) == nil
        nothing!(ctx.fx, ctx.run, ctx.invocation, before)
      end

      test "identity_read/abort: no business statement after the failed read before the owner's rollback",
           ctx do
        texts = live_texts!()
        before = snapshot(ctx.fx, ctx.run, ctx.invocation)

        {{result, hits, trip}, events} =
          captured(
            fn ->
              armed(:identity_read, :abort, fn ->
                release_call(unquote(path), ctx.invocation, ctx.run)
              end)
            end,
            texts
          )

        reached!(:identity_read, hits, trip)
        owner_only!(after_fault!(events, :identity_read), @identity_failed)
        assert match?({:error, _}, result), "release: #{inspect(ident(result))}"
        assert G.release(ctx.invocation) == nil
        nothing!(ctx.fx, ctx.run, ctx.invocation, before)
      end
    end
  end
end
