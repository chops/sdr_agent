defmodule SdrAgent.Test.ResolveHarnessAwaitSwitchTest do
  @moduledoc """
  #188: `ResolveHarness.await_switch!/4`'s observation path, through its
  injected reader (`await_switch_with!/4`), with no database.

  - The exact shared-sandbox queue drop seen in CI (run 39162215483) is a
    transient observation: the wait polls on, under one deadline.
  - Every other error fails on its first read.
  - The matching observation itself is returned, with no further read, and a
    match that arrives after the deadline is not accepted.

  This proves the handling of the observed error shape and its refusal
  boundaries. It does not prove the inferred restart-burst mechanism.
  """
  use ExUnit.Case, async: true

  alias Ash.Error.Unknown.UnknownError
  alias SdrAgent.Test.ResolveHarness

  # Verbatim from the CI failure, with its PIDs.
  @drop "** (DBConnection.ConnectionError) could not checkout the connection owned by " <>
          "#PID<0.445626.0> ({:sql_sandbox_owner, %{started_by: #PID<0.445622.0>}}). When " <>
          "using the sandbox, connections are shared, so this may imply another process is " <>
          "using a connection. Reason: connection not available and request was dropped " <>
          "from queue after 343ms. You can configure how long requests wait in the queue " <>
          "using :queue_target and :queue_interval. See DBConnection.start_link/2 for more " <>
          "information"

  @target %{id: "sw-1", status: :blocked}
  @other %{id: "sw-2", status: :blocked}

  defp unknown(errors), do: {:error, %Ash.Error.Unknown{errors: errors}}
  defp cause(message), do: %UnknownError{error: message}
  defp drop, do: unknown([cause(@drop)])

  # A scripted reader: each call takes the next response (the last one
  # repeats) and records when it started. `{:after, ms, response}` answers
  # late.
  defp reader(responses) do
    {:ok, pid} = Agent.start_link(fn -> %{left: responses, starts: []} end)

    read = fn ->
      now = System.monotonic_time(:millisecond)

      response =
        Agent.get_and_update(pid, fn %{left: left, starts: starts} = state ->
          {next, rest} =
            case left do
              [only] -> {only, [only]}
              [next | rest] -> {next, rest}
            end

          {next, %{state | left: rest, starts: [now | starts]}}
        end)

      case response do
        {:after, ms, late} ->
          Process.sleep(ms)
          late

        response ->
          response
      end
    end

    {read, pid}
  end

  defp starts(pid), do: pid |> Agent.get(& &1.starts) |> Enum.reverse()

  defp await(read, timeout),
    do: ResolveHarness.await_switch_with!(read, "sw-1", :blocked, timeout)

  test "two sandbox queue drops, then the matching row: that row, after exactly three reads" do
    {read, pid} = reader([drop(), drop(), {:ok, [@other, @target]}])

    assert await(read, 2_000) == @target
    assert length(starts(pid)) == 3, "#188: no fourth read after the match"
  end

  test "a wrong status and then an absent row stay pending until the matching row" do
    {read, pid} =
      reader([{:ok, [%{@target | status: :preflighted}]}, {:ok, [@other]}, {:ok, [@target]}])

    assert await(read, 2_000) == @target
    assert length(starts(pid)) == 3, "#188: the matching observation is returned, not re-read"
  end

  test "a persistent sandbox queue drop flunks at the deadline, naming it; no read starts after it" do
    {read, pid} = reader([drop()])
    entered = System.monotonic_time(:millisecond)

    error = assert_raise ExUnit.AssertionError, fn -> await(read, 200) end

    assert error.message =~ "sandbox_queue_drop"
    assert length(starts(pid)) >= 2
    assert Enum.max(starts(pid)) <= entered + 200 + 20
  end

  test "a matching row that arrives after the deadline is not accepted" do
    {read, pid} = reader([{:after, 300, {:ok, [@target]}}])

    assert_raise ExUnit.AssertionError, fn -> await(read, 100) end
    assert length(starts(pid)) == 1
  end

  # Controls: these already fail at once under the old strict match. They
  # pin the classifier's refusal boundaries against widening.
  refused = [
    {"an owner exit", "exited",
     {:unknown, "** (DBConnection.ConnectionError) owner #PID<0.1.0> exited"}},
    {"a disabled queue", "queuing is disabled",
     {:unknown,
      "** (DBConnection.ConnectionError) connection not available and queuing is disabled"}},
    {"a refused connection", "econnrefused",
     {:unknown,
      "** (DBConnection.ConnectionError) tcp connect (localhost:5520): connection refused - :econnrefused"}},
    {"a plain queue drop with no sandbox owner", "dropped from queue",
     {:unknown,
      "** (DBConnection.ConnectionError) connection not available and request was dropped " <>
        "from queue after 343ms. You can configure how long requests wait in the queue using " <>
        ":queue_target and :queue_interval. See DBConnection.start_link/2 for more information"}},
    {"a Postgrex error", "deadlock_detected",
     {:unknown, "** (Postgrex.Error) ERROR 40P01 (deadlock_detected) deadlock detected"}},
    {"the sandbox drop under another Ash wrapper", "Ash.Error.Invalid", :invalid_wrapper},
    {"the sandbox drop as a bare connection error", "DBConnection.ConnectionError", :bare},
    {"two causes, both sandbox drops", "sql_sandbox_owner", :two_drops},
    {"mixed causes", "query_canceled", :mixed},
    {"a non-binary cause", ":boom", :non_binary}
  ]

  for {name, token, shape} <- refused do
    test "control: #{name} fails on the first read" do
      {read, pid} = reader([response(unquote(Macro.escape(shape))), {:ok, [@target]}])

      raised =
        try do
          await(read, 2_000)
          :returned
        rescue
          error -> error
        end

      refute raised == :returned, "#{unquote(name)} must not be retried into a match"
      assert Exception.message(raised) =~ unquote(token)
      assert length(starts(pid)) == 1
    end
  end

  defp response({:unknown, message}), do: unknown([cause(message)])
  defp response(:invalid_wrapper), do: {:error, %Ash.Error.Invalid{errors: [cause(@drop)]}}
  defp response(:bare), do: {:error, %DBConnection.ConnectionError{message: @drop}}
  defp response(:two_drops), do: unknown([cause(@drop), cause(@drop)])

  defp response(:mixed),
    do: unknown([cause(@drop), cause("** (Postgrex.Error) ERROR 57014 (query_canceled)")])

  defp response(:non_binary), do: unknown([%UnknownError{error: :boom}])
end
