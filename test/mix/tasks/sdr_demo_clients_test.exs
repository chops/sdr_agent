defmodule Mix.Tasks.Sdr.Demo.ClientsTest do
  @moduledoc """
  #201: the shared counting boundary of `mix sdr.demo.clients`, which
  `bin/demo reset` and the demo test's `await_clients/3` both use. Every
  input has the shape Postgrex returns for the task's query: a
  `%Postgrex.Result{}` whose rows are `[[backend_type], …]`, with
  `backend_type` a binary or nil.

  Exactly `"autovacuum worker"` is excluded, the one backend type a
  non-forced DROP DATABASE itself asks to exit (PostgreSQL 18.6
  `CountOtherDBBackends`). Every other type blocks, including nil and
  unknown ones, and a row of any other shape raises without its content.
  No database: no test here produces a real autovacuum worker.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Sdr.Demo.Clients

  # The subject assertion before any call: a missing function fails here,
  # not as an UndefinedFunctionError.
  defp exported!(fun, arity) do
    assert Code.ensure_loaded?(Clients) and function_exported?(Clients, fun, arity),
           "#201: Mix.Tasks.Sdr.Demo.Clients.#{fun}/#{arity} is the shared counting boundary"
  end

  defp blocking_count(rows) do
    exported!(:blocking_count, 1)
    apply(Clients, :blocking_count, [rows])
  end

  defp count_with(result_fun) do
    exported!(:count_with, 1)
    apply(Clients, :count_with, [result_fun])
  end

  defp result(rows), do: %Postgrex.Result{rows: rows, num_rows: length(rows)}

  describe "blocking_count/1 over driver-shaped rows" do
    test "an autovacuum worker is not counted; a client is" do
      assert blocking_count([["client backend"], ["autovacuum worker"]]) == 1
    end

    test "only autovacuum workers, or no rows, count zero" do
      assert blocking_count([["autovacuum worker"], ["autovacuum worker"]]) == 0
      assert blocking_count([]) == 0
    end

    test "every other backend type blocks, including nil and unknown ones" do
      for type <- [
            "walsender",
            "background worker",
            "parallel worker",
            "dead-end client backend",
            nil,
            "unknown process type"
          ] do
        assert blocking_count([[type]]) == 1, "#201: #{inspect(type)} must block"
      end
    end

    test "the exclusion is the exact type, nothing like it" do
      for type <- ["Autovacuum Worker", "autovacuum worker ", "autovacuum launcher"] do
        assert blocking_count([[type]]) == 1, "#201: #{inspect(type)} must block"
      end
    end

    test "a row of any other shape raises, without its content" do
      for {rows, secret} <- [
            {["sentinel-flat"], "sentinel-flat"},
            {[["autovacuum worker", "sentinel-extra"]], "sentinel-extra"},
            {[[424_242]], "424242"},
            {[:sentinel_atom], "sentinel_atom"}
          ] do
        exported!(:blocking_count, 1)

        error =
          assert_raise ArgumentError, fn -> apply(Clients, :blocking_count, [rows]) end

        refute error.message =~ secret, "#201: the error must not carry the row's content"
      end
    end
  end

  describe "count_with/1, the whole count path" do
    test "a driver-shaped result is decoded by the same rule" do
      rows = [["client backend"], ["autovacuum worker"], [nil]]
      assert count_with(fn -> result(rows) end) == 2
      assert count_with(fn -> result([]) end) == 0
    end

    test "anything but a Postgrex result, or a malformed row in one, raises" do
      exported!(:count_with, 1)

      assert_raise ArgumentError, fn ->
        apply(Clients, :count_with, [fn -> %{rows: []} end])
      end

      assert_raise ArgumentError, fn ->
        apply(Clients, :count_with, [fn -> result([["client backend", "x"]]) end])
      end
    end
  end
end
