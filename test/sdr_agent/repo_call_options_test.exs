defmodule SdrAgent.RepoCallOptionsTest do
  @moduledoc """
  C3-02 G3-2b (Codex d47c9d0 review, item 4): `SdrAgent.Repo.with_call_options/2`
  and `default_options/1`, the per-process option scope the definition
  bootstrap uses for its bounded calls.

  What the scope adds is observed twice: directly through
  `Repo.default_options/1`, and end to end through Ecto, by scoping
  `telemetry_options:` (which Ecto SQL copies into the `options` of the
  `[:sdr_agent, :repo, :query]` telemetry event) and reading the event of a
  real query in this process. Covered: nothing is added outside a scope,
  in another process, or after the scope ends (return, raise, throw,
  exit); a nested scope merges over the enclosing one and restores it; an
  operation's explicit option wins over the scope.
  """
  use SdrAgent.DataCase, async: true

  import Ecto.Query

  alias SdrAgent.Repo

  @event [:sdr_agent, :repo, :query]

  setup do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, @event, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  @doc false
  # Runs in the process that made the query; reports only this test's.
  def handle_event(_event, _measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:c302_query_options, metadata.options})
  end

  describe "outside a scope" do
    test "an ordinary repo call gets no injected options" do
      assert Repo.default_options(:all) == []
      assert Repo.default_options(:transaction) == []
      assert query_options() == []
    end

    test "another process does not see the caller's scope" do
      Repo.with_call_options([deadline: 1, checkout_retries: 0], fn ->
        assert Repo.default_options(:all) == [deadline: 1, checkout_retries: 0]
        assert Task.await(Task.async(fn -> Repo.default_options(:all) end)) == []
      end)
    end
  end

  describe "inside a scope" do
    test "a repo operation receives the scoped options" do
      result =
        Repo.with_call_options([telemetry_options: [c302: :scope]], fn ->
          query_options()
        end)

      assert result == [c302: :scope]
      assert query_options() == [], "C3-02: the scope outlived its call"
    end

    test "an operation's explicit option wins over the scope" do
      Repo.with_call_options([telemetry_options: [c302: :scope]], fn ->
        assert query_options(telemetry_options: [c302: :explicit]) == [c302: :explicit]
        assert query_options() == [c302: :scope]
      end)
    end

    test "a nested scope merges over the enclosing one and restores it" do
      Repo.with_call_options([deadline: 1, checkout_retries: 0], fn ->
        Repo.with_call_options([deadline: 2, prepare: :unnamed], fn ->
          assert Repo.default_options(:all) ==
                   [checkout_retries: 0, deadline: 2, prepare: :unnamed]
        end)

        assert Repo.default_options(:all) == [deadline: 1, checkout_retries: 0]
      end)

      assert Repo.default_options(:all) == []
    end

    test "with_call_options/2 returns the function's value" do
      assert Repo.with_call_options([deadline: 1], fn -> :value end) == :value
    end
  end

  describe "restoration on every exit path" do
    test "a raise restores the enclosing set" do
      Repo.with_call_options([deadline: 1], fn ->
        assert_raise RuntimeError, fn ->
          Repo.with_call_options([deadline: 2], fn -> raise "c302" end)
        end

        assert Repo.default_options(:all) == [deadline: 1]
      end)

      assert_raise RuntimeError, fn ->
        Repo.with_call_options([deadline: 2], fn -> raise "c302" end)
      end

      assert Repo.default_options(:all) == []
    end

    test "a throw restores the enclosing set" do
      Repo.with_call_options([deadline: 1], fn ->
        assert catch_throw(Repo.with_call_options([deadline: 2], fn -> throw(:c302) end)) ==
                 :c302

        assert Repo.default_options(:all) == [deadline: 1]
      end)

      assert catch_throw(Repo.with_call_options([deadline: 2], fn -> throw(:c302) end)) == :c302
      assert Repo.default_options(:all) == []
    end

    test "an exit restores the enclosing set" do
      Repo.with_call_options([deadline: 1], fn ->
        assert catch_exit(Repo.with_call_options([deadline: 2], fn -> exit(:c302) end)) == :c302
        assert Repo.default_options(:all) == [deadline: 1]
      end)

      assert catch_exit(Repo.with_call_options([deadline: 2], fn -> exit(:c302) end)) == :c302
      assert Repo.default_options(:all) == []
    end
  end

  # One real query in this process; returns the `options` of its telemetry
  # event (Ecto SQL: the operation's `telemetry_options:`, default []).
  defp query_options(opts \\ []) do
    assert [_count] = Repo.all(from(t in "tenants", select: count()), opts)
    assert_received {:c302_query_options, options}
    refute_received {:c302_query_options, _more}
    options
  end
end
