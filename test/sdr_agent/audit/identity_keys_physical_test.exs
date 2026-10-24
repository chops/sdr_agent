defmodule SdrAgent.Audit.IdentityKeysPhysicalTest do
  @moduledoc """
  C3-02 RED-1, plan r8 section 11 B [P] (T-B1..T-B3): the identity-key pass
  on independent physical connections (`Sandbox.checkout(Repo, sandbox:
  false)`, the pattern of `test/sdr_agent/audit/concurrency_test.exs:22-27`),
  where the application scope is the physical transaction.

  These tests commit no rows: the keys hash random synthetic tenant ids
  (no tenant row is needed), the advisory locks are transaction-scoped and
  every transaction here ends by COMMIT or ROLLBACK, and each test asserts
  that its backends hold no advisory lock afterwards. The database name is
  checked before any work (`InboxConcurrencyFixtures.assert_test_database!/0`).

  RED form and the interface names chosen for review are those of
  `SdrAgent.Audit.IdentityKeysTest` (`IdentityKeys.id/3`, `pass/2` and
  `require_held/2` returning `:ok`, `IdentityKeys.TestFaults.with_fault/2`).
  Every subject is guarded before any call or any spawned contender.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Audit
  alias SdrAgent.InboxConcurrencyFixtures
  alias SdrAgent.Repo

  @keys SdrAgent.Audit.IdentityKeys
  @faults SdrAgent.Audit.IdentityKeys.TestFaults
  @scope_key {SdrAgent.Audit.IdentityKeys, :scope}

  @late SdrAgent.Audit.IdentityKeys.LateAcquisition
  @inconsistent SdrAgent.Audit.IdentityKeys.PassInconsistent
  @failed SdrAgent.Audit.IdentityKeys.AcquisitionFailed
  @exceptions [@late, @inconsistent, @failed]

  @record_format ~r/^v1;[0-9a-f]{32};\d+;(-?\d+(,-?\d+)*)?$/

  # Section 2.4, verbatim.
  @state_sql """
  SELECT current_setting('sdr.identity_pass', true),
         pg_backend_pid(),
         coalesce(array_agg((l.classid::bigint << 32) | l.objid::bigint)
                  FILTER (WHERE l.pid IS NOT NULL), '{}')
  FROM (SELECT 1) AS one
  LEFT JOIN pg_locks l
    ON  l.locktype = 'advisory'
    AND l.database = (SELECT oid FROM pg_database WHERE datname = current_database())
    AND l.pid      = pg_backend_pid()
    AND l.objsubid = 1
    AND l.mode     = 'ExclusiveLock'
    AND l.granted
  """

  # T-A1's vector: raw `www.www.acme.test` for this tenant has the preimage
  # `www.acme.test` and the negative id below (computed with `shasum -a 256`
  # outside the VM; see identity_keys_test.exs).
  @vector_tenant "00000000-0000-4000-8000-00000000c302"
  @negative_raw "www.www.acme.test"
  @negative_id -4_314_510_134_007_135_717

  @wait_ms 10_000

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    InboxConcurrencyFixtures.assert_test_database!()
    :ok
  end

  describe "T-B1" do
    test "T-B1 a reused backend starts each application scope clean" do
      guard_keys!()
      t = tenant()
      first = {:domain, "t-b1-first.test"}
      second = {:domain, "t-b1-second.test"}
      backend = backend()

      assert {:ok, :ok} = Repo.transaction(fn -> pass(t, [first]) end)

      assert {:error, :c302_rolled_back} =
               Repo.transaction(fn ->
                 assert pass(t, [second]) == :ok
                 Repo.rollback(:c302_rolled_back)
               end)

      assert {:ok, {start, outcome, manifest}} =
               Repo.transaction(fn ->
                 start = {backend(), setting(), held()}
                 {start, pass(t, [second]), record().ids}
               end)

      assert start == {backend, nil, MapSet.new()},
             "C3-02: a new physical transaction on the same backend carries no keys or record"

      assert outcome == :ok
      assert manifest == MapSet.new([id(t, second)])
      assert Process.get(@scope_key) == nil
      assert_no_advisory_locks!([backend])
    end
  end

  describe "T-B2 the T-A3..A11 and T-A18 matrix on a physical connection" do
    for scenario <- ~w(a3 a4 a5 a6 a7a a7b a8 a9 a10 a11)a do
      @tag scenario: scenario
      test "T-B2 #{scenario}", %{scenario: scenario} do
        guard_keys!()
        backend = backend()
        scenario!(scenario, tenant())
        assert Process.get(@scope_key) == nil
        assert_no_advisory_locks!([backend])
      end
    end

    for {label, point} <- [
          before_first_lock: :before_first_lock,
          after_one_of_two_locks: {:after_locks, 1},
          at_publication: :at_publication
        ],
        control <- [:rescue, :savepoint, :rollback] do
      @tag fault_point: point, control: control
      test "T-B2 a18 fault #{label}, control #{control}",
           %{fault_point: point, control: control} do
        guard_keys!()
        present!(@faults, :with_fault, 2)
        backend = backend()
        fault_control!(control, point, tenant())
        assert Process.get(@scope_key) == nil
        assert_no_advisory_locks!([backend])
      end
    end
  end

  describe "T-B3" do
    test "T-B3 a negative id is held under the signed classid/objid conversion" do
      guard_keys!()
      assert key_id(@vector_tenant, :domain, @negative_raw) == @negative_id
      unsigned = @negative_id + 0x1_0000_0000_0000_0000
      classid = Bitwise.bsr(unsigned, 32)
      objid = Bitwise.band(unsigned, 0xFFFF_FFFF)

      assert {:ok, {rows, held, required}} =
               Repo.transaction(fn ->
                 assert pass(@vector_tenant, [{:domain, @negative_raw}]) == :ok

                 %{rows: rows} =
                   Repo.query!(
                     """
                     SELECT classid::bigint, objid::bigint, objsubid, mode, granted
                     FROM pg_locks
                     WHERE locktype = 'advisory' AND pid = pg_backend_pid()
                     """,
                     []
                   )

                 {rows, held(), require_held(@vector_tenant, [{:domain, @negative_raw}])}
               end)

      assert [classid, objid, 1, "ExclusiveLock", true] in rows
      assert @negative_id in held
      assert required == :ok
    end

    test "T-B3 a _shared advisory lock is not a held key" do
      guard_keys!()
      t = tenant()
      x = {:domain, "t-b3-exclusive.test"}
      shared = id(t, {:domain, "t-b3-shared.test"})

      assert {:ok, {shared_visible?, outcome}} =
               Repo.transaction(fn ->
                 Repo.query!("SELECT pg_advisory_xact_lock_shared($1::bigint)", [shared])
                 assert pass(t, [x]) == :ok
                 %{token: token, pid: pid} = record()
                 forge!("v1;#{token};#{pid};#{Enum.join(Enum.sort([id(t, x), shared]), ",")}")

                 {shared in held(),
                  outcome(fn -> require_held(t, [{:domain, "t-b3-shared.test"}]) end)}
               end)

      refute shared_visible?, "C3-02: the state query must exclude _shared advisory locks"
      assert outcome == {:raised, @inconsistent}
    end

    test "T-B3 a contended key waits on an advisory lock, then passes" do
      guard_keys!()
      t = tenant()
      key = {:domain, "t-b3-contended.test"}
      parent = self()

      holder =
        Task.async(fn ->
          with_connection(fn ->
            Repo.transaction(fn ->
              :ok = pass(t, [key])
              send(parent, {:c302_holder, backend()})

              receive do
                :c302_release -> :released
              after
                @wait_ms -> :holder_timeout
              end
            end)
          end)
        end)

      assert_receive {:c302_holder, holder_backend}, @wait_ms

      waiter =
        Task.async(fn ->
          with_connection(fn ->
            send(parent, {:c302_waiter, backend()})
            Repo.transaction(fn -> pass(t, [key]) end)
          end)
        end)

      assert_receive {:c302_waiter, waiter_backend}, @wait_ms
      wait = await_lock_wait!(waiter_backend)
      send(holder.pid, :c302_release)

      assert wait == %{type: "Lock", event: "advisory", blocked_by: [holder_backend]}
      assert Task.await(holder, @wait_ms) == {:ok, :released}
      assert Task.await(waiter, @wait_ms) == {:ok, :ok}
      assert_no_advisory_locks!([holder_backend, waiter_backend])
    end
  end

  ## T-B2 scenarios (T-A3..A11 on the physical transaction)

  defp scenario!(:a3, t) do
    first = {:domain, "t-b2-a3-first.test"}
    second = {:domain, "t-b2-a3-second.test"}
    assert {:ok, {:ok, record1}} = Repo.transaction(fn -> {pass(t, [first]), record()} end)

    assert {:ok, {clean, :ok, record2}} =
             Repo.transaction(fn -> {{setting(), held()}, pass(t, [second]), record()} end)

    assert clean == {nil, MapSet.new()}
    refute record1.token == record2.token
    assert record2.ids == MapSet.new([id(t, second)])
  end

  defp scenario!(:a4, t) do
    assert_raise @late, fn ->
      Audit.transaction(fn ->
        assert pass(t, [{:domain, "t-b2-a4-first.test"}]) == :ok
        pass(t, [{:domain, "t-b2-a4-second.test"}])
      end)
    end
  end

  defp scenario!(:a5, t) do
    company = {:domain, "t-b2-a5.test"}
    person = {:email, "jo@t-b2-a5.test"}

    assert {:ok, :both} =
             Audit.transaction(fn ->
               assert pass(t, [person, company]) == :ok
               assert pass(t, [company]) == :ok
               assert require_held(t, [person, company]) == :ok
               :both
             end)
  end

  defp scenario!(:a6, t) do
    assert {:ok, outcomes} =
             Repo.transaction(fn ->
               {outcome(fn -> pass(t, []) end),
                outcome(fn -> pass(t, [{:domain, "t-b2-a6.test"}]) end)}
             end)

    assert outcomes == {:ok, {:raised, @late}}
  end

  defp scenario!(:a7a, t) do
    a = {:domain, "t-b2-a7a-a.test"}
    b = {:domain, "t-b2-a7a-b.test"}

    assert {:ok, {released?, reverted, :ok, manifest}} =
             Repo.transaction(fn ->
               savepoint!("c302_t_b2")
               assert pass(t, [a]) == :ok
               rollback_to!("c302_t_b2")
               {id(t, a) not in held(), setting(), pass(t, [b]), record().ids}
             end)

    assert released?
    assert reverted == nil
    assert manifest == MapSet.new([id(t, b)])
  end

  defp scenario!(:a7b, t) do
    x = {:domain, "t-b2-a7b.test"}

    assert {:ok, {before, reverted, :ok, manifest}} =
             Repo.transaction(fn ->
               before = setting()
               savepoint!("c302_t_b2")
               assert pass(t, []) == :ok
               rollback_to!("c302_t_b2")
               {before, setting(), pass(t, [x]), record().ids}
             end)

    assert before == nil
    assert reverted == nil, "C3-02: a rolled-back first empty pass must read as absent"
    assert manifest == MapSet.new([id(t, x)])
  end

  defp scenario!(:a8, t) do
    a = {:domain, "t-b2-a8-a.test"}
    b = {:domain, "t-b2-a8-b.test"}

    assert {:ok, outcomes} =
             Repo.transaction(fn ->
               assert pass(t, [a, b]) == :ok
               published = setting()
               savepoint!("c302_t_b2")
               assert require_held(t, [a]) == :ok
               rollback_to!("c302_t_b2")

               {setting() == published, outcome(fn -> require_held(t, [a, b]) end),
                outcome(fn -> pass(t, [{:domain, "t-b2-a8-c.test"}]) end)}
             end)

    assert outcomes == {true, :ok, {:raised, @late}}
  end

  defp scenario!(:a9, t) do
    a = {:domain, "t-b2-a9.test"}
    unheld = id(t, {:domain, "t-b2-a9-unheld.test"})

    assert {:ok, outcome} =
             Repo.transaction(fn ->
               assert pass(t, [a]) == :ok
               %{token: token, pid: pid} = record()
               forge!("v1;#{token};#{pid};#{Enum.join(Enum.sort([id(t, a), unheld]), ",")}")
               outcome(fn -> require_held(t, [a]) end)
             end)

    assert outcome == {:raised, @inconsistent}
  end

  defp scenario!(:a10, t) do
    a = {:domain, "t-b2-a10.test"}

    assert {:ok, outcome} =
             Repo.transaction(fn ->
               assert pass(t, [a]) == :ok
               %{pid: pid} = record()
               forge!("v1;#{String.duplicate("ab", 16)};#{pid};#{id(t, a)}")
               outcome(fn -> require_held(t, [a]) end)
             end)

    assert outcome == {:raised, @inconsistent}
  end

  defp scenario!(:a11, t) do
    a = {:domain, "t-b2-a11-a.test"}

    assert {:ok, outcome} =
             Repo.transaction(fn ->
               assert pass(t, [a]) == :ok
               forge!("")
               outcome(fn -> pass(t, [{:domain, "t-b2-a11-c.test"}]) end)
             end)

    assert outcome == {:raised, @inconsistent}
  end

  ## T-B2 fault controls (T-A18 (i)-(iii) on the physical transaction)

  defp fault_control!(:rescue, point, t) do
    keys = fault_keys()

    assert {:ok, outcomes} =
             Repo.transaction(fn ->
               {faulted(point, t, keys), setting(), outcome(fn -> pass(t, keys) end),
                outcome(fn -> require_held(t, keys) end)}
             end)

    assert outcomes ==
             {{:raised, @failed}, nil, {:raised, @inconsistent}, {:raised, @inconsistent}}
  end

  defp fault_control!(:savepoint, point, t) do
    keys = fault_keys()

    assert {:ok, outcomes} =
             Repo.transaction(fn ->
               savepoint!("c302_t_b2")
               failure = faulted(point, t, keys)
               rollback_to!("c302_t_b2")

               {failure, MapSet.disjoint?(held(), MapSet.new(keys, &id(t, &1))),
                outcome(fn -> pass(t, keys) end)}
             end)

    assert outcomes == {{:raised, @failed}, true, {:raised, @inconsistent}}
  end

  defp fault_control!(:rollback, point, t) do
    keys = fault_keys()

    assert_raise @failed, fn ->
      Repo.transaction(fn -> fault_pass(point, t, keys) end)
    end

    assert {:ok, {clean, :ok, manifest}} =
             Repo.transaction(fn -> {{setting(), held()}, pass(t, keys), record().ids} end)

    assert clean == {nil, MapSet.new()}
    assert manifest == MapSet.new(keys, &id(t, &1))
  end

  defp fault_pass(point, t, keys), do: with_fault(point, fn -> pass(t, keys) end)
  defp faulted(point, t, keys), do: outcome(fn -> fault_pass(point, t, keys) end)

  defp fault_keys, do: [{:domain, "t-b2-a18-a.test"}, {:domain, "t-b2-a18-b.test"}]

  ## Presence guards and calls

  defp present!(module, function, arity) do
    assert Code.ensure_loaded?(module), "C3-02: #{inspect(module)} is not available"

    assert function_exported?(module, function, arity),
           "C3-02: #{inspect(module)}.#{function}/#{arity} is not implemented"

    module
  end

  defp guard_keys! do
    present!(@keys, :pass, 2)
    present!(@keys, :require_held, 2)
    present!(@keys, :id, 3)

    for exception <- @exceptions do
      assert Code.ensure_loaded?(exception) and function_exported?(exception, :exception, 1),
             "C3-02: exception #{inspect(exception)} is not defined"
    end
  end

  defp call(module, function, args) do
    present!(module, function, length(args))
    apply(module, function, args)
  end

  defp pass(tenant, keys), do: call(@keys, :pass, [tenant, keys])
  defp require_held(tenant, keys), do: call(@keys, :require_held, [tenant, keys])
  defp key_id(tenant, kind, raw), do: call(@keys, :id, [tenant, kind, raw])
  defp id(tenant, {kind, raw}), do: key_id(tenant, kind, raw)
  defp with_fault(point, fun), do: call(@faults, :with_fault, [point, fun])

  defp outcome(fun) do
    case fun.() do
      :ok -> :ok
      other -> {:returned, other}
    end
  rescue
    error -> {:raised, error.__struct__}
  end

  ## Physical connections and database state

  defp tenant, do: Ecto.UUID.generate()

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp backend do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp state do
    %{rows: [[setting, pid, ids]]} = Repo.query!(@state_sql)
    %{setting: setting, pid: pid, held: MapSet.new(ids)}
  end

  defp held, do: state().held

  defp setting do
    case state().setting do
      "" -> nil
      value -> value
    end
  end

  defp record do
    value = setting()
    assert is_binary(value) and value =~ @record_format, "C3-02: no v1 record was published"
    [_version, token, pid, ids] = String.split(value, ";")
    %{token: token, pid: String.to_integer(pid), ids: parse_ids(ids)}
  end

  defp parse_ids(""), do: MapSet.new()
  defp parse_ids(ids), do: ids |> String.split(",") |> MapSet.new(&String.to_integer/1)

  # Test-only: simulates a record no trusted writer would publish.
  defp forge!(value),
    do: Repo.query!("SELECT set_config('sdr.identity_pass', $1, true)", [value])

  defp savepoint!(name), do: Repo.query!("SAVEPOINT #{name}")
  defp rollback_to!(name), do: Repo.query!("ROLLBACK TO SAVEPOINT #{name}")

  defp await_lock_wait!(waiter) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    poll_lock_wait(waiter, deadline)
  end

  defp poll_lock_wait(waiter, deadline) do
    %{rows: [[type, event, blocked_by]]} =
      Repo.query!(
        """
        SELECT wait_event_type, wait_event, pg_blocking_pids(pid)
        FROM pg_stat_activity WHERE pid = $1
        """,
        [waiter]
      )

    cond do
      type == "Lock" ->
        %{type: type, event: event, blocked_by: blocked_by}

      System.monotonic_time(:millisecond) > deadline ->
        flunk("C3-02: the waiter never waited on a lock (#{inspect({type, event})})")

      true ->
        Process.sleep(20)
        poll_lock_wait(waiter, deadline)
    end
  end

  defp assert_no_advisory_locks!(backends) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = ANY($1::int[])",
        [backends]
      )

    assert count == 0, "C3-02: an advisory lock outlived its transaction"
  end
end
