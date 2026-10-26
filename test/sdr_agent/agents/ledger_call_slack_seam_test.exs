defmodule SdrAgent.Agents.LedgerCallSlackSeamTest do
  @moduledoc """
  #230 RED (plan D, `tmp/claude-230-classification-r3.md`): the test-only
  `client_slack_ms:` option of `SdrAgent.Agents.LedgerCall` sets the
  transaction's client-side watchdog (the budget left at the call plus the
  slack, 250 ms by default), so a test may hold a write past the default
  watchdog without losing its connection.

  Every observation here is a real one: the acknowledged `ROLLBACK` in the
  call's own query log (`{"rollback", :ok}`), and the pool's own timeout
  message for this call ("client #PID<…> timed out because it queued and
  checked out the connection for longer than Nms"), bound to the calling
  process's pid and required to be unique in the capture (the log capture
  is global, so another client's message is never taken for this call's).
  Nothing is inferred from elapsed time: the hold is an input (900 ms, past
  the 650 ms default bound of a 400 ms budget), the outcome is read from the
  log and the message. The bound the message names is checked as carrying
  the slack (more than the slack alone, at most the budget plus the slack);
  the exact value depends on the milliseconds between the deadline and the
  transaction's start, which is not asserted. Both outcomes of a watchdog
  loss before `COMMIT` that the sources allow (DBConnection 2.10.2's
  `run_transaction/5` keeps an explicit rollback reason even when the
  `ROLLBACK` itself fails on the lost connection; or the connection error
  escapes to `LedgerCall`'s rescue) are accepted by the control and never
  chosen between.

  The pool's watchdog is the thing under test, so the SQL sandbox runs in
  `:auto` mode for this module (synchronous; restored to `:manual`
  afterwards), as `SdrAgent.Agents.ProfileSwitchResolveRaceTest` does. No
  table is written: every body returns without a query, and the spent
  budget rolls the call back.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  import SdrAgent.Test.ResolveHarness,
    only: [query_log!: 1, logged: 1, mark_caller: 1, caller_query: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.Agents.LedgerCall
  alias SdrAgent.Repo

  @moduletag :issue_230
  @moduletag timeout: 60_000

  @budget_ms 400
  @default_slack_ms 250
  # Past the default bound of a 400 ms budget (400 + 250 = 650 ms); a finite
  # margin inside the widened bound, not a guarantee.
  @hold_ms 900
  @wide_slack_ms 5_000
  @timeout_tail "timed out because it queued and checked out the connection for longer than"

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  # The body of every held call: keeps the open transaction for @hold_ms
  # without a query, then returns; LedgerCall's last budget step finds the
  # budget spent and rolls the call back — the pre-commit refusal of test 13's
  # write (`{:rolled_back, :ledger_timeout}`), without a coordinator.
  defp hold do
    fn ->
      Process.sleep(@hold_ms)
      {:ok, :held}
    end
  end

  ## 1. The seam keeps the connection: an acknowledged own rollback

  test "1. with client_slack_ms the held call outlives the default watchdog and its own rollback is acknowledged" do
    mark_caller(:slack_1)
    log = query_log!(caller_query(:slack_1))

    {result, captured} =
      with_log(fn ->
        LedgerCall.attempt(hold(), budget_ms: @budget_ms, client_slack_ms: @wide_slack_ms)
      end)

    queries = logged(log)

    assert {"rollback", :ok} in queries,
           "the call's own rollback was acknowledged (no connection loss); queries: " <>
             inspect(queries)

    assert own_timeout_bound(captured, self()) == :missing,
           "the widened watchdog did not fire for this call; log: #{captured}"

    refute {"commit", :ok} in queries, "nothing committed"

    assert result == {:rolled_back, :ledger_timeout},
           "the spent budget is the call's own pre-commit refusal; got #{inspect(result)}"
  end

  ## 2. The seam is the transaction's own bound

  test "2. client_slack_ms sets the transaction's own bound: the pool's timeout names budget plus slack" do
    mark_caller(:slack_2)
    log = query_log!(caller_query(:slack_2))
    slack = 100

    {result, captured} =
      with_log(fn ->
        LedgerCall.attempt(hold(), budget_ms: @budget_ms, client_slack_ms: slack)
      end)

    own = own_timeout_bound(captured, self())

    assert match?({:ok, _}, own),
           "this call's own watchdog message (exactly one, bound to #{inspect(self())}) is " <>
             "required after a #{@hold_ms} ms hold; got #{inspect(own)}; log: #{captured}"

    {:ok, bound} = own

    assert bound in (slack + 1)..(@budget_ms + slack),
           "the enforced checkout timeout carries the given slack (more than #{slack} ms, " <>
             "at most #{@budget_ms + slack} ms); got #{bound}ms"

    queries = logged(log)
    refute {"rollback", :ok} in queries, "after a watchdog loss the rollback is not acknowledged"
    refute {"commit", :ok} in queries, "nothing committed"

    assert not_committed?(result),
           "after a watchdog loss the outcome is one of the two source-derived shapes; " <>
             "got #{inspect(result)}"
  end

  ## 3. Direct-entry enforcement: invalid values are refused before any query

  for {value, label} <- [
        {0, "zero"},
        {-1, "negative"},
        {30_001, "above 30 s"},
        {:infinity, "infinity"},
        {"5", "not an integer"}
      ] do
    test "3. attempt/2 refuses client_slack_ms #{label} (#{inspect(value)}) before any query" do
      mark_caller(:slack_3)
      log = query_log!(caller_query(:slack_3))

      assert_raise ArgumentError, ~r/client_slack_ms/, fn ->
        LedgerCall.attempt(fn -> {:ok, :never} end,
          budget_ms: @budget_ms,
          client_slack_ms: unquote(value)
        )
      end

      assert logged(log) == [], "refused before any query"
    end
  end

  test "3b. run/2 refuses an invalid client_slack_ms the same way, before any query" do
    mark_caller(:slack_3b)
    log = query_log!(caller_query(:slack_3b))

    assert_raise ArgumentError, ~r/client_slack_ms/, fn ->
      LedgerCall.run(fn -> {:ok, :never} end, budget_ms: @budget_ms, client_slack_ms: 0)
    end

    assert logged(log) == [], "refused before any query"
  end

  ## Control (not RED): the default bound, observed at the pool

  test "control: without the option the bound is the budget plus the default 250 ms slack, and the held call loses its connection" do
    mark_caller(:slack_control)
    log = query_log!(caller_query(:slack_control))

    default_bound = @budget_ms + @default_slack_ms

    {result, captured} = with_log(fn -> LedgerCall.attempt(hold(), budget_ms: @budget_ms) end)

    own = own_timeout_bound(captured, self())

    assert match?({:ok, _}, own),
           "this call's own default watchdog message (exactly one, bound to #{inspect(self())}) " <>
             "is required after a #{@hold_ms} ms hold; got #{inspect(own)}; log: #{captured}"

    {:ok, bound} = own

    assert bound in (@default_slack_ms + 1)..default_bound,
           "the default checkout timeout carries the 250 ms default slack (more than 250 ms, " <>
             "at most #{default_bound} ms); got #{bound}ms"

    queries = logged(log)
    refute {"rollback", :ok} in queries, "after a watchdog loss the rollback is not acknowledged"
    refute {"commit", :ok} in queries, "nothing committed"

    assert not_committed?(result),
           "after a watchdog loss the outcome is one of the two source-derived shapes; " <>
             "got #{inspect(result)}"
  end

  ## Controls (not RED): the legal endpoints of the option are accepted

  for slack <- [1, 30_000] do
    test "control: client_slack_ms #{slack} (a legal endpoint) is accepted and the quick call commits" do
      mark_caller(:"slack_endpoint_#{unquote(slack)}")
      log = query_log!(caller_query(:"slack_endpoint_#{unquote(slack)}"))

      result =
        LedgerCall.attempt(fn -> {:ok, :quick} end,
          budget_ms: @budget_ms,
          client_slack_ms: unquote(slack)
        )

      assert result == {:ok, :quick},
             "a quick body commits under the option; got #{inspect(result)}"

      assert {"commit", :ok} in logged(log), "the quick call's commit was acknowledged"
    end
  end

  ## Controls (not RED, DB-free): the matcher binds the pool's message to this call

  test "matcher control: another client's timeout message is not this call's" do
    other = :c.pid(0, 9_999, 0)
    assert own_timeout_bound(timeout_line(other, 650), self()) == :missing
  end

  test "matcher control: an unrelated client's message before this call's does not displace it" do
    other = :c.pid(0, 9_999, 0)
    captured = timeout_line(other, 650) <> "\n" <> timeout_line(self(), 500)
    assert own_timeout_bound(captured, self()) == {:ok, 500}
  end

  test "matcher control: no message is :missing, two own messages are :ambiguous" do
    assert own_timeout_bound("", self()) == :missing
    assert own_timeout_bound("[error] something else\n", self()) == :missing

    captured = timeout_line(self(), 650) <> "\n" <> timeout_line(self(), 500)
    assert own_timeout_bound(captured, self()) == {:ambiguous, [650, 500]}
  end

  test "matcher control: a registered client's name between the pid and the message is accepted" do
    captured =
      "client #{inspect(self())} (SdrAgent.AI.ModelProvider.Coordinator) #{@timeout_tail} 650ms"

    assert own_timeout_bound(captured, self()) == {:ok, 650}
  end

  # The pool's own timeout diagnostic for THIS call. DBConnection 2.10.2 logs,
  # from the connection process, "client #PID<a.b.c> [(registered name)] timed
  # out because it queued and checked out the connection for longer than Nms"
  # (connection_pool.ex:188-194, ownership/proxy.ex:65-71); the client is the
  # calling process. The capture is global, so the match is bound to `pid`
  # and must be unique: {:ok, n} | :missing | {:ambiguous, [n]}. A missing or
  # ambiguous match is never resolved by taking the first message.
  defp own_timeout_bound(captured, pid) do
    re = ~r/client #{Regex.escape(inspect(pid))}(?: \([^)\n]*\))? #{@timeout_tail} (\d+)ms/

    case Regex.scan(re, captured, capture: :all_but_first) do
      [[n]] -> {:ok, String.to_integer(n)}
      [] -> :missing
      many -> {:ambiguous, Enum.map(many, fn [n] -> String.to_integer(n) end)}
    end
  end

  # A synthetic line in the pool's exact format, for the matcher controls.
  defp timeout_line(pid, len), do: "client #{inspect(pid)} #{@timeout_tail} #{len}ms"

  # The two outcomes the sources allow for a watchdog loss before COMMIT (#230
  # r2 review, C3-a): DBConnection 2.10.2's run_transaction/5 returns the
  # explicit rollback reason even when the ROLLBACK itself fails on the lost
  # connection, or the connection error escapes to LedgerCall's rescue. No
  # COMMIT was sent either way; which one occurs is not inferred.
  defp not_committed?({:rolled_back, :ledger_timeout}), do: true
  defp not_committed?({:unknown, %DBConnection.ConnectionError{}}), do: true
  defp not_committed?(_other), do: false
end
