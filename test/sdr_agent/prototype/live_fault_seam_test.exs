defmodule SdrAgent.Prototype.LiveFaultSeamTest do
  @moduledoc """
  RED for the test-build-only live-read fault seam (proposal r2, Codex
  7ba6d116 F1-F5): `SdrAgent.Prototype.Authority.TestSeam.with_live_fault/3`
  and `live_fault_hits/1`, faults at the three real live reads
  (`:binding_read`, `:identity_read`, `:delegation_read`) of
  `SdrAgent.Prototype.Authority`.

  - Scope (F1, F2): one claim per scope across the owner and every
    `$callers` inheritor (parent then child, child then parent, concurrent
    siblings); a second read is real; a wrong stage, a malformed id, a dead
    or unrelated ancestry never fire; nested scopes restore the prior scope
    on return, raise, throw and exit; `clear/0` never disarms a scope.
  - Outcomes (F3, F4): a synthetic `:returned_error`/`:raise` executes no
    SQL and leaves a caller's transaction usable; `:abort` is a real
    `SELECT 1 / 0`, and its exact outcome is pinned by stage at the owner
    boundary (thrown to the owner, or returned and then a failed commit).
  - Raw layer (F5; Codex 7b7f4b1c T2/T3): the EXACT statement list of
    this process from Repo telemetry (closed labels and result codes only):
    the real reads before the stage, the injected statement with
    `Repo.in_transaction?/0` at that point and its `division_by_zero`, the
    faulted real read (25P02 in the owner), and then no later business
    statement, only the owner's rollback or commit. All of it is SQL
    Sandbox behaviour: the test's `Repo.transaction` is the logical owner
    (a savepoint inside the sandbox's transaction); nothing here claims
    unboxed or outermost rollback semantics.

  The seam is called after an export guard (`seam!/0`) once the fixture
  binds. At RED it is a test-build-only no-op declaration that never fires
  (`with_live_fault/3` runs the function, `live_fault_hits/1` is 0), so
  every seam test reaches and fails its behavioural assertions. The
  baselines B1-B3 and the no-seam control need no firing. Synthetic
  `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Operations.PrototypeDatabaseBinding
  alias SdrAgent.Operations.PrototypeDelegation
  alias SdrAgent.Prototype
  alias SdrAgent.Prototype.Authority.TestSeam

  @seam TestSeam
  @stages [:binding_read, :identity_read, :delegation_read]
  @mismatch {:error, :binding_mismatch}
  @identity_sql "SELECT current_database()::text, d.oid::bigint, " <>
                  "(pg_control_system()).system_identifier FROM pg_database d " <>
                  "WHERE d.datname = current_database()"
  @read_sources ["prototype_database_bindings", "prototype_delegations"]
  @counts [
    {"prototype_database_bindings", "SELECT count(*) FROM prototype_database_bindings"},
    {"prototype_delegations", "SELECT count(*) FROM prototype_delegations"},
    {"audit_events", "SELECT count(*) FROM audit_events"},
    {"users", "SELECT count(*) FROM users"}
  ]

  describe "baselines (raw layer, no seam)" do
    test "B1: SELECT 1 / 0 in the test's transaction aborts it; the owner returns {:error, :rollback}" do
      test = self()

      {owner, events} =
        with_queries(fn ->
          Repo.transaction(fn ->
            send(test, {:in_transaction, Repo.in_transaction?()})
            send(test, {:abort, code(probe("SELECT 1 / 0"))})
            send(test, {:next, code(probe("SELECT 1"))})
            :done
          end)
        end)

      assert_received {:in_transaction, true}
      assert_received {:abort, :division_by_zero}
      assert_received {:next, :in_failed_sql_transaction}
      assert owner == {:error, :rollback}

      assert events == [
               {:begin, :ok},
               {:probe, :division_by_zero},
               {:probe, :in_failed_sql_transaction},
               {:rollback, :ok}
             ]

      assert probe("SELECT 1") == {:ok, [[1]]}, "the sandbox connection was not recovered"
    end

    test "B3: a healthy transaction of the test is begin, its statements, commit" do
      {owner, events} =
        with_queries(fn -> Repo.transaction(fn -> {probe("SELECT 1"), :done} end) end)

      assert owner == {:ok, {{:ok, [[1]]}, :done}}
      assert events == [{:begin, :ok}, {:probe, :ok}, {:commit, :ok}]
    end

    test "B2: outside an explicit transaction the sandbox's per-query savepoint recovers" do
      refute Repo.in_transaction?()
      {results, events} = with_queries(fn -> {probe("SELECT 1 / 0"), probe("SELECT 1")} end)
      assert {code(elem(results, 0)), elem(results, 1)} == {:division_by_zero, {:ok, [[1]]}}
      assert events == [{:probe, :division_by_zero}, {:probe, :ok}]
    end
  end

  describe "no seam" do
    test "with no scope the live reads are real, nothing is injected and no hits are counted" do
      fx = bound!()

      {results, events} =
        with_queries(fn ->
          {Prototype.check_live(), Prototype.operator_actor(fx.delegation.id)}
        end)

      assert results == {:ok, {:ok, fx.actor}}

      assert events ==
               reads_before(:delegation_read) ++
                 reads_before(:delegation_read) ++ [{read_label(:delegation_read), :ok}]

      seam!()
      for stage <- @stages, do: assert(hits(stage) == 0, "#{stage} counted a hit with no scope")
    end
  end

  describe ":returned_error and :raise (synthetic: no SQL)" do
    test "outside a transaction each stage refuses with :binding_mismatch, once, and writes nothing" do
      fx = bound!()
      seam!()
      before = counts()

      for stage <- @stages, kind <- [:returned_error, :raise] do
        {result, events} =
          with_queries(fn ->
            fault(stage, kind, fn -> {call_stage(stage, fx), hits(stage)} end)
          end)

        assert result == {@mismatch, 1}, "#{stage}/#{kind}: #{inspect(result)}"

        assert events == reads_before(stage),
               "#{stage}/#{kind}: a statement at or after the faulted stage: #{inspect(events)}"

        assert call_stage(stage, fx) == ok_value(stage, fx), "#{stage}/#{kind}: scope outlived"
        assert hits(stage) == 0
      end

      assert counts() == before
    end

    test "inside the caller's transaction the refusal is returned and the transaction stays usable" do
      fx = bound!()
      seam!()
      before = counts()

      for stage <- @stages, kind <- [:returned_error, :raise] do
        {owner, events} =
          with_queries(fn ->
            fault(stage, kind, fn ->
              {in_owner(fn -> {call_stage(stage, fx), hits(stage)} end), hits(stage)}
            end)
          end)

        assert owner == {{:ok, {@mismatch, 1}}, 1}, "#{stage}/#{kind}: #{inspect(owner)}"
        assert_received {:returned, {@mismatch, 1}}
        assert_received {:probe, :ok}, "#{stage}/#{kind} left the caller's transaction unusable"

        assert events ==
                 [{:begin, :ok}] ++ reads_before(stage) ++ [{:probe, :ok}, {:commit, :ok}],
               "#{stage}/#{kind}: #{inspect(events)}"
      end

      assert counts() == before
    end
  end

  describe ":abort (a real SELECT 1 / 0)" do
    test "outside a transaction the sandbox recovers and the real read follows" do
      fx = bound!()
      seam!()
      before = counts()

      for stage <- @stages do
        {result, events} =
          with_queries(fn ->
            fault(stage, :abort, fn -> {call_stage(stage, fx), hits(stage)} end)
          end)

        assert result == {ok_value(stage, fx), 1}, "#{stage}: #{inspect(result)}"

        assert events ==
                 reads_before(stage) ++
                   [{{:fault, stage, false}, :division_by_zero}, {read_label(stage), :ok}] ++
                   reads_after(stage),
               "#{stage}: #{inspect(events)}"
      end

      assert counts() == before
    end

    test "binding stage in the caller's transaction: the real read's rollback throws to the owner" do
      fx = bound!()
      seam!()

      assert_aborted_owner(:binding_read, fx, fn owner ->
        assert {:error, %Ash.Query{resource: PrototypeDatabaseBinding, errors: [_ | _]}} = owner
        refute_received {:returned, _}
        refute_received {:probe, _}
      end)
    end

    test "identity stage in the caller's transaction: :binding_mismatch is returned, the commit fails" do
      fx = bound!()
      seam!()

      assert_aborted_owner(:identity_read, fx, fn owner ->
        assert owner == {:error, :rollback}
        assert_received {:returned, @mismatch}
        assert_received {:probe, :in_failed_sql_transaction}
      end)
    end

    test "delegation stage in the caller's transaction: the real read's rollback throws to the owner" do
      fx = bound!()
      seam!()

      assert_aborted_owner(:delegation_read, fx, fn owner ->
        assert {:error, %Ash.Query{resource: PrototypeDelegation, errors: [_ | _]}} = owner
        refute_received {:returned, _}
        refute_received {:probe, _}
      end)
    end
  end

  describe "scope (F1): one claim per scope" do
    test "a second read at the same stage is real" do
      fx = bound!()
      seam!()

      for stage <- @stages do
        result =
          fault(stage, :returned_error, fn ->
            {call_stage(stage, fx), call_stage(stage, fx), hits(stage)}
          end)

        assert result == {@mismatch, ok_value(stage, fx), 1}, "#{stage}: #{inspect(result)}"
      end
    end

    test "a wrong stage never fires; the scoped stage then does" do
      fx = bound!()
      seam!()

      result =
        fault(:delegation_read, :raise, fn ->
          {Prototype.check_live(), hits(:delegation_read),
           Prototype.operator_actor(fx.delegation.id), hits(:delegation_read)}
        end)

      assert result == {:ok, 0, @mismatch, 1}
    end

    test "a malformed delegation id short-circuits before the faulted read" do
      fx = bound!()
      seam!()

      result =
        fault(:delegation_read, :raise, fn ->
          {Prototype.operator_actor("not-a-uuid"), hits(:delegation_read),
           Prototype.operator_actor(fx.delegation.id), hits(:delegation_read)}
        end)

      assert result == {{:error, :delegation_not_found}, 0, @mismatch, 1}
    end

    test "parent then child, and child then parent: one firing" do
      _fx = bound!()
      seam!()

      parent_first =
        fault(:binding_read, :raise, fn ->
          own = Prototype.check_live()
          child = Task.await(Task.async(&Prototype.check_live/0))
          {own, child, hits(:binding_read)}
        end)

      assert parent_first == {@mismatch, :ok, 1}

      child_first =
        fault(:binding_read, :raise, fn ->
          child = Task.await(Task.async(fn -> {Prototype.check_live(), hits(:binding_read)} end))
          {child, Prototype.check_live(), hits(:binding_read)}
        end)

      assert child_first == {{@mismatch, 1}, :ok, 1}
    end

    test "concurrent sibling Tasks share the claim: exactly one fires" do
      _fx = bound!()
      seam!()
      parent = self()

      {results, n} =
        fault(:binding_read, :raise, fn ->
          tasks =
            for _ <- 1..8 do
              Task.async(fn ->
                send(parent, {:ready, self()})
                receive do: (:go -> Prototype.check_live())
              end)
            end

          for _ <- tasks, do: assert_receive({:ready, _}, 2_000)
          for task <- tasks, do: send(task.pid, :go)
          {Enum.map(tasks, &Task.await(&1, 10_000)), hits(:binding_read)}
        end)

      assert Enum.frequencies(results) == %{:ok => 7, @mismatch => 1}
      assert n == 1
    end

    test "a live ancestor's scope fires; a dead ancestor's and an unrelated process's never do" do
      fx = bound!()
      seam!()
      test = self()

      owner =
        spawn(fn ->
          fault(:binding_read, :raise, fn ->
            send(test, :armed)
            receive do: (:release -> :ok)
          end)
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)
      assert_receive :armed, 2_000
      via_owner = fn -> {Prototype.check_live(), hits(:binding_read)} end
      assert in_task([owner], via_owner) == {@mismatch, 1}

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 2_000
      assert in_task([owner], via_owner) == {:ok, 0}

      fault(:binding_read, :raise, fn ->
        spawn(fn ->
          PrototypeFixtures.enter_runtime(fx.snapshot)
          send(test, {:unrelated, Prototype.check_live(), hits(:binding_read)})
        end)

        assert_receive {:unrelated, :ok, 0}, 5_000
        assert Prototype.check_live() == @mismatch
      end)
    end
  end

  describe "scope (F2): nesting, unwinding and clear/0" do
    test "a same-stage inner scope shadows the outer one, which is restored armed" do
      _fx = bound!()
      seam!()
      keys = seam_keys()

      # The inner scope's second read is real: a claimed inner scope never
      # falls through to the outer one.
      result =
        fault(:binding_read, :raise, fn ->
          inner =
            fault(:binding_read, :returned_error, fn ->
              {Prototype.check_live(), Prototype.check_live(), hits(:binding_read)}
            end)

          {inner, hits(:binding_read), Prototype.check_live(), hits(:binding_read)}
        end)

      assert result == {{@mismatch, :ok, 1}, 0, @mismatch, 1}
      assert {Prototype.check_live(), hits(:binding_read), seam_keys()} == {:ok, 0, keys}
    end

    test "a different-stage inner scope composes with the outer one" do
      fx = bound!()
      seam!()
      id = fx.delegation.id

      result =
        fault(:delegation_read, :raise, fn ->
          inner =
            fault(:binding_read, :raise, fn ->
              {Prototype.operator_actor(id), hits(:binding_read), hits(:delegation_read)}
            end)

          {inner, hits(:binding_read), Prototype.operator_actor(id), hits(:delegation_read)}
        end)

      assert result == {{@mismatch, 1, 0}, 0, @mismatch, 1}
    end

    test "an inner raise, throw or exit passes through unchanged and restores the outer scope" do
      _fx = bound!()
      seam!()

      for ending <- [:raise, :throw, :exit] do
        result =
          fault(:binding_read, :returned_error, fn ->
            caught =
              caught(fn ->
                fault(:binding_read, :raise, fn ->
                  send(self(), {:inner, Prototype.check_live(), hits(:binding_read)})
                  finish(ending)
                end)
              end)

            {caught, hits(:binding_read), Prototype.check_live(), hits(:binding_read)}
          end)

        assert_received {:inner, @mismatch, 1}
        assert result == {ended(ending), 0, @mismatch, 1}, "#{ending}: #{inspect(result)}"
      end
    end

    test "a scope returns its value; a raising scope leaves no seam state" do
      _fx = bound!()
      seam!()
      keys = seam_keys()
      value = {:value, make_ref()}

      assert fault(:binding_read, :raise, fn ->
               send(self(), {:fired, Prototype.check_live()})
               value
             end) == value

      assert_received {:fired, @mismatch}

      assert_raise RuntimeError, "d237 outer end", fn ->
        fault(:binding_read, :raise, fn ->
          send(self(), {:fired, Prototype.check_live()})
          raise "d237 outer end"
        end)
      end

      assert_received {:fired, @mismatch}
      assert {seam_keys(), Prototype.check_live(), hits(:binding_read)} == {keys, :ok, 0}
    end

    test "clear/0 in the scope or in a Task leaves the scope armed" do
      fx = bound!()
      seam!()

      in_scope =
        fault(:binding_read, :raise, fn ->
          assert TestSeam.clear() == :ok
          enter!(fx)
          {Prototype.check_live(), hits(:binding_read)}
        end)

      assert in_scope == {@mismatch, 1}

      in_child =
        fault(:binding_read, :raise, fn ->
          assert Task.await(Task.async(&TestSeam.clear/0)) == :ok
          {Prototype.check_live(), hits(:binding_read)}
        end)

      assert in_child == {@mismatch, 1}
    end
  end

  ## The seam, called only after its export guard

  defp seam! do
    loaded!(@seam)

    for {fun, arity} <- [with_live_fault: 3, live_fault_hits: 1] do
      assert function_exported?(@seam, fun, arity),
             "#{inspect(@seam)}.#{fun}/#{arity} is not exported (the live-fault seam is absent)"
    end
  end

  defp fault(stage, kind, fun),
    do: Function.capture(@seam, :with_live_fault, 3).(stage, kind, fun)

  defp hits(stage), do: Function.capture(@seam, :live_fault_hits, 1).(stage)

  ## Calls and expected values by stage

  defp call_stage(:delegation_read, fx), do: Prototype.operator_actor(fx.delegation.id)
  defp call_stage(_stage, _fx), do: Prototype.check_live()

  defp ok_value(:delegation_read, fx), do: {:ok, fx.actor}
  defp ok_value(_stage, _fx), do: :ok

  defp read_label(:binding_read), do: {:read, "prototype_database_bindings"}
  defp read_label(:identity_read), do: :identity
  defp read_label(:delegation_read), do: {:read, "prototype_delegations"}

  # The real reads a stage's call issues before reaching that stage
  # (`check_live/0`: the binding read, then the identity query;
  # `operator_actor/1`: `check_live/0`, then the delegation read), and after
  # it when the faulted read succeeds.
  defp reads_before(:binding_read), do: []
  defp reads_before(:identity_read), do: [{read_label(:binding_read), :ok}]

  defp reads_before(:delegation_read),
    do: [{read_label(:binding_read), :ok}, {read_label(:identity_read), :ok}]

  defp reads_after(:binding_read), do: [{read_label(:identity_read), :ok}]
  defp reads_after(_stage), do: []

  # The `:abort` case in the test's transaction: the outcome callback pins
  # the owner's result and the in-fun observers; here the exact statement
  # list of this process (the owner's begin, the real reads before the
  # stage, the injected statement with the transaction state at that point,
  # the faulted real read's 25P02, then only the identity stage's observer
  # probe and exactly one rollback: no later business statement), the hit,
  # and the business rows unchanged.
  defp assert_aborted_owner(stage, fx, outcome) do
    before = counts()

    {{owner, n}, events} =
      with_queries(fn ->
        fault(stage, :abort, fn -> {in_owner(fn -> call_stage(stage, fx) end), hits(stage)} end)
      end)

    outcome.(owner)
    assert n == 1

    expected =
      [{:begin, :ok}] ++
        reads_before(stage) ++
        [
          {{:fault, stage, true}, :division_by_zero},
          {read_label(stage), :in_failed_sql_transaction}
        ] ++
        if(stage == :identity_read, do: [{:probe, :in_failed_sql_transaction}], else: []) ++
        [{:rollback, :ok}]

    assert events == expected
    assert probe("SELECT 1") == {:ok, [[1]]}, "the sandbox connection was not recovered"
    assert counts() == before
  end

  # The test's own `Repo.transaction` (the logical owner): observers record
  # the in-fun result and a `SELECT 1` probe without changing either; a
  # throw skips both.
  defp in_owner(fun) do
    test = self()

    Repo.transaction(fn ->
      assert Repo.in_transaction?()
      result = fun.()
      send(test, {:returned, result})
      send(test, {:probe, code(probe("SELECT 1"))})
      result
    end)
  end

  defp in_task(ancestors, fun) do
    Task.await(
      Task.async(fn ->
        Process.put(:"$callers", ancestors ++ Process.get(:"$callers", []))
        fun.()
      end)
    )
  end

  defp finish(:raise), do: raise("d237 inner end")
  defp finish(:throw), do: throw(:d237_inner_end)
  defp finish(:exit), do: exit(:d237_inner_end)

  defp ended(:raise), do: {:raised, "d237 inner end"}
  defp ended(:throw), do: {:thrown, :d237_inner_end}
  defp ended(:exit), do: {:exited, :d237_inner_end}

  defp caught(fun) do
    fun.()
    :returned
  rescue
    error in RuntimeError -> {:raised, error.message}
  catch
    :throw, value -> {:thrown, value}
    :exit, reason -> {:exited, reason}
  end

  defp seam_keys,
    do: Process.get_keys() |> Enum.filter(&match?({SdrAgent.Prototype, _}, &1)) |> Enum.sort()

  ## Raw layer

  defp probe(sql) do
    case Repo.query(sql, [], telemetry_options: [d237_probe: true]) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      other -> other
    end
  end

  defp code({:ok, _}), do: :ok
  defp code({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code
  defp code(_other), do: :error

  defp counts do
    for {table, sql} <- @counts, into: %{} do
      {:ok, [[n]]} = probe(sql)
      {table, n}
    end
  end

  @doc false
  def handle_query(_event, _measurements, metadata, test) do
    if self() == test, do: send(test, {:d237_query, classify(metadata)})
  end

  # A closed label and result code per Repo statement of this process; no
  # SQL text, parameter or row leaves the handler. It runs in the emitting
  # process during the statement, so an injected statement's label carries
  # `Repo.in_transaction?/0` at the fault point.
  defp classify(%{query: query, source: source, result: result} = metadata) do
    options = Map.get(metadata, :options) || []
    {control(query) || tagged(options) || statement(query, source), code(result)}
  end

  defp control("begin"), do: :begin
  defp control("commit"), do: :commit
  defp control("rollback"), do: :rollback
  defp control(_query), do: nil

  defp tagged(options) do
    cond do
      Keyword.has_key?(options, :d237_live_fault) ->
        {:fault, options[:d237_live_fault], Repo.in_transaction?()}

      Keyword.get(options, :d237_probe) == true ->
        :probe

      true ->
        nil
    end
  end

  # A closed oracle (Codex 2026-10-28 R3): only the exact identity query and
  # a SELECT on one of the two live-read tables are recognized; every other
  # statement (any write form included) is `:unknown`, so an exact list
  # assertion fails on it.
  defp statement(@identity_sql, nil), do: :identity
  defp statement("SELECT " <> _rest, source) when source in @read_sources, do: {:read, source}
  defp statement(_query, _source), do: :unknown

  defp with_queries(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, [:sdr_agent, :repo, :query], &__MODULE__.handle_query/4, self())

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(events) do
    receive do
      {:d237_query, event} -> drain([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
