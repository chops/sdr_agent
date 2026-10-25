defmodule SdrAgent.Agents.LedgerCallSlackSeamTest do
  @moduledoc """
  #230 RED (plan D, `tmp/claude-230-classification-r3.md`): the test-only
  `client_slack_ms:` option of `SdrAgent.Agents.LedgerCall` sets the
  transaction's client-side watchdog (the budget left at the call plus the
  slack, 250 ms by default), so a test may hold a write past the default
  watchdog without losing its connection.

  Every observation here is a real one: the acknowledged `ROLLBACK` in the
  call's own query log (`{"rollback", :ok}`), and the pool's own timeout
  message, which names the checkout timeout it enforced ("checked out the
  connection for longer than Nms"). Nothing is inferred from elapsed time:
  the hold is an input (900 ms, past the 650 ms default bound of a 400 ms
  budget), the outcome is read from the log and the message. Both outcomes
  of a watchdog loss before `COMMIT` that the sources allow (DBConnection
  2.10.2's `run_transaction/5` keeps an explicit rollback reason even when
  the `ROLLBACK` itself fails on the lost connection; or the connection
  error escapes to `LedgerCall`'s rescue) are accepted by the control and
  never chosen between.

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
  @timeout_message ~r/checked out the connection for longer than (\d+)ms/

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

    refute captured =~ @timeout_message, "the widened watchdog did not fire; log: #{captured}"
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

    assert [bound] = Regex.run(@timeout_message, captured, capture: :all_but_first),
           "the pool's watchdog fired on a #{@budget_ms + slack} ms bound held for #{@hold_ms} ms; " <>
             "log: #{captured}"

    assert String.to_integer(bound) in (@budget_ms + slack - 5)..(@budget_ms + slack),
           "the enforced checkout timeout is the budget left at the call plus the given slack; " <>
             "got #{bound}ms"

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

    assert [bound] = Regex.run(@timeout_message, captured, capture: :all_but_first),
           "the pool's default watchdog fired on a #{default_bound} ms bound " <>
             "held for #{@hold_ms} ms; log: #{captured}"

    assert String.to_integer(bound) in (default_bound - 5)..default_bound,
           "the default checkout timeout is the budget left at the call plus 250 ms; got #{bound}ms"

    queries = logged(log)
    refute {"rollback", :ok} in queries, "after a watchdog loss the rollback is not acknowledged"
    refute {"commit", :ok} in queries, "nothing committed"

    assert not_committed?(result),
           "after a watchdog loss the outcome is one of the two source-derived shapes; " <>
             "got #{inspect(result)}"
  end

  # The two outcomes the sources allow for a watchdog loss before COMMIT (#230
  # r2 review, C3-a): DBConnection 2.10.2's run_transaction/5 returns the
  # explicit rollback reason even when the ROLLBACK itself fails on the lost
  # connection, or the connection error escapes to LedgerCall's rescue. No
  # COMMIT was sent either way; which one occurs is not inferred.
  defp not_committed?({:rolled_back, :ledger_timeout}), do: true
  defp not_committed?({:unknown, %DBConnection.ConnectionError{}}), do: true
  defp not_committed?(_other), do: false
end
