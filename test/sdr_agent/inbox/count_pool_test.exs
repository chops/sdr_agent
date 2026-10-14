defmodule SdrAgent.Inbox.CountPoolTest do
  @moduledoc """
  C1 pool wait is part of the API deadline, not fixture checkout time.
  This sole async:false module temporarily enables automatic checkout,
  restores manual mode even on failure, and proves manual mode at every
  test's start. Other contention tests keep independent sandbox:false
  checkouts. Committed fixtures are cleaned only by their owned ids.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SdrAgent.InboxConcurrencyFixtures, as: F
  alias SdrAgent.InboxFixtures
  alias SdrAgent.Repo

  setup do
    assert_manual_mode!(System.monotonic_time(:millisecond) + 250)
    pool_size = Repo.config()[:pool_size]
    assert is_integer(pool_size) and pool_size >= 2
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> :ok = Sandbox.mode(Repo, :manual) end)
    ctx = F.seed!()
    on_exit(fn -> F.connection(fn -> F.cleanup!(ctx) end) end)
    # Automatic checkout is owned until process exit/checkin. Return setup's
    # connection before holders occupy every slot; otherwise only N-1 fit.
    :ok = Sandbox.checkin(Repo)
    Map.put(ctx, :pool_size, pool_size)
  end

  for {label, deadline, statement} <- [{"lowered", 150, 100}, {"default", 2_500, 2_000}] do
    test "#{label} deadline includes a fully occupied pool and cancels queued work", ctx do
      F.require_count!()
      holders = for _ <- 1..ctx.pool_size, do: F.hold!("SELECT 1", [], false)
      assert length(Enum.uniq(Enum.map(holders, & &1.backend))) == ctx.pool_size

      F.observer(fn observer ->
        assert F.count_queries(observer) == 0

        {_, queries} =
          InboxFixtures.trace_queries(fn ->
            try do
              assert {{:error, :timeout}, elapsed} =
                       F.timed(fn ->
                         F.count(
                           actor: ctx.admin,
                           count_timeout_ms: unquote(deadline),
                           statement_timeout_ms: unquote(statement)
                         )
                       end)

              assert elapsed <= unquote(deadline) + 250
              F.assert_no_count_query!(observer)
            after
              F.release!(holders)
            end

            # Keep telemetry attached briefly after unblocking the pool: even
            # a fast orphan/retry must not execute after the timeout return.
            for _ <- 1..20 do
              assert F.count_queries(observer) == 0
              Process.sleep(5)
            end
          end)

        refute Enum.any?(queries, fn {sql, _} ->
                 String.downcase(sql) =~ "count(" and sql =~ ~s(FROM "failures")
               end)
      end)

      F.assert_no_count_query!()
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    end
  end

  # A previous sandbox owner's DOWN may race the next setup. Retry only
  # that exact teardown exit; success still requires OwnershipError (never
  # an arbitrary checkout failure or a successful automatic checkout).
  defp assert_manual_mode!(deadline) do
    assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
  catch
    :exit, {{:shutdown, message}, {DBConnection.Holder, :checkout, [_pool, _opts]}} = reason
    when is_binary(message) ->
      if Regex.match?(~r/\Aowner #PID<\d+\.\d+\.\d+> exited\z/, message) and
           System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        assert_manual_mode!(deadline)
      else
        exit(reason)
      end
  end
end
