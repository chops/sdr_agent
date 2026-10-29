defmodule SdrAgent.Prototype.RepoStateTest do
  @moduledoc """
  Setup contract r6 A1/A2 (Codex m_1793194297723131417_77c441d5,
  m_1793194953010412292_25f4fb18): the `repo_state/0` adapter
  `SdrAgent.Prototype.RepoState`, in the shared test VM. Never stops
  `:ecto`, touches the registry or re-registers the Repo name here; the
  isolated child-VM controls (AC4-AC7) are
  `repo_state_child_vm_test.exs` (`:external`).

  - AC1 (prerequisite): `SdrAgent.Repo` is configured without `:name`, and
    its default dynamic selection is `SdrAgent.Repo` (only the presence of
    `:name` is read; no configuration value is printed).
  - AC2 (real): the shared VM's bounded observation is S3 and decides
    `:observe_transaction`; `repo_state/0` is `{:started, false}` outside a
    transaction and `{:started, true}` inside `SdrAgent.Repo.transaction/1`
    (the sandbox's `in_transaction?/0` behaviour is measured here, not
    assumed).
  - AC3 (real): a non-default dynamic selection is `:unavailable`, decided
    before any transaction read; the selection is restored.
  - AC8 (pure): `decide/1` over every supported, unsupported (U1-U7) and
    malformed observation, and `transaction_result/1`. U2 and U5 are
    pure-only: they are not constructed without private registry API.
  - AC9 (prerequisite): `repo_state.ex` compiled with the prototype flags
    false defines nothing and emits nothing.

  RED at the declarations (every `RepoState` function
  `{:error, :not_implemented}`): AC2, AC3 and AC8 fail on the declaration;
  AC1 and AC9 are prerequisites that hold without it.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.RepoState

  @source Path.expand("../../../lib/sdr_agent/prototype/repo_state.ex", __DIR__)
  @flags [:prototype_authority_compiled, :prototype_test_seams]

  # {id, expected decide/1 result}; each observation is built at run time
  # (pids cannot be literals) by observation/1.
  @decide_rows [
    {:s1_free_without_ecto, :not_started},
    {:s2_free_with_ecto_empty, :not_started},
    {:s2_free_with_other_repo, :not_started},
    {:s3_listed_once, :observe_transaction},
    {:s3_listed_once_among_others, :observe_transaction},
    {:u1_dynamic_other_atom, :unavailable},
    {:u1_dynamic_pid, :unavailable},
    {:u1_dynamic_string, :unavailable},
    {:u2_pid_entry_name_free, :unavailable},
    {:u2_pid_entry_listed, :unavailable},
    {:u3_named_without_ecto, :unavailable},
    {:u4_named_not_listed, :unavailable},
    {:u5_listed_name_free, :unavailable},
    {:u6_name_appeared, :unavailable},
    {:u6_name_vanished, :unavailable},
    {:u6_name_changed, :unavailable},
    {:u7_listed_twice, :unavailable},
    {:malformed_not_a_map, :unavailable},
    {:malformed_keyword_list, :unavailable},
    {:malformed_missing_key, :unavailable},
    {:malformed_extra_key, :unavailable},
    {:malformed_ecto_not_boolean, :unavailable},
    {:malformed_unobserved_with_ecto, :unavailable},
    {:malformed_list_without_ecto, :unavailable},
    {:malformed_improper_list, :unavailable},
    {:malformed_nil_entry, :unavailable},
    {:malformed_string_entry, :unavailable},
    {:malformed_named_not_pid, :unavailable},
    {:malformed_red_sentinel, :unavailable}
  ]

  @transaction_rows [
    {:flag_true, {:started, true}},
    {:flag_false, {:started, false}},
    {:flag_nil, :unavailable},
    {:flag_atom, :unavailable},
    {:flag_tuple, :unavailable},
    {:flag_string, :unavailable},
    {:flag_integer, :unavailable}
  ]

  describe "AC1: the pinned default identity (prerequisite)" do
    test "SdrAgent.Repo is configured without :name and is its own default selection" do
      named? = Keyword.has_key?(Application.get_env(:sdr_agent, Repo, []), :name)
      refute named?, "SdrAgent.Repo configuration sets :name"
      assert Repo.get_dynamic_repo() == Repo
    end
  end

  describe "AC2: the real adapter in the shared test VM (S3)" do
    test "the shared VM's bounded observation is S3 and decides :observe_transaction" do
      assert %{
               dynamic: dynamic,
               named_before: before,
               ecto_started: ecto,
               running: running,
               named_after: after_
             } = observation = RepoState.observe()

      assert map_size(observation) == 5
      assert dynamic == Repo
      assert is_pid(before) and before == after_
      assert ecto == true
      assert Enum.count(running, &(&1 == Repo)) == 1
      refute Enum.any?(running, &is_pid/1)
      assert RepoState.decide(observation) == :observe_transaction
    end

    test "outside a transaction: {:started, false}" do
      assert RepoState.repo_state() == {:started, false}
    end

    test "inside SdrAgent.Repo.transaction/1: {:started, true}" do
      assert Repo.transaction(fn -> RepoState.repo_state() end) == {:ok, {:started, true}}
    end
  end

  describe "AC3: a non-default dynamic selection (U1, real)" do
    test "is :unavailable, decided before any transaction read, and is restored" do
      previous = Repo.put_dynamic_repo(:sdr_agent_other)

      {observation, decided, state} =
        try do
          observation = RepoState.observe()
          {observation, RepoState.decide(observation), RepoState.repo_state()}
        after
          Repo.put_dynamic_repo(previous)
        end

      assert Repo.get_dynamic_repo() == Repo
      assert %{dynamic: :sdr_agent_other} = observation
      assert decided == :unavailable
      assert state == :unavailable
    end
  end

  describe "AC8: decide/1 (pure, one test per observation)" do
    for {id, expected} <- @decide_rows do
      test "#{id}" do
        result = RepoState.decide(observation(unquote(id)))
        assert result == unquote(Macro.escape(expected)), "#{unquote(id)}: #{inspect(result)}"
      end
    end
  end

  describe "AC8: transaction_result/1 (pure, one test per flag)" do
    for {id, expected} <- @transaction_rows do
      test "#{id}" do
        result = RepoState.transaction_result(flag(unquote(id)))
        assert result == unquote(Macro.escape(expected)), "#{unquote(id)}: #{inspect(result)}"
      end
    end
  end

  describe "AC9: no adapter code under false flags (prerequisite)" do
    test "repo_state.ex compiled with the prototype flags false defines nothing and emits nothing" do
      source = File.read!(@source)
      previous = Map.new(@flags, &{&1, Application.fetch_env(:sdr_agent, &1)})

      {modules, diagnostics} =
        try do
          Enum.each(@flags, &Application.put_env(:sdr_agent, &1, false))

          Code.with_diagnostics(fn ->
            Code.compile_string(source, "repo_state_production_twin.ex")
          end)
        after
          Enum.each(previous, fn
            {flag, {:ok, value}} -> Application.put_env(:sdr_agent, flag, value)
            {flag, :error} -> Application.delete_env(:sdr_agent, flag)
          end)
        end

      assert modules == []
      assert diagnostics == []
    end
  end

  ## Helpers

  # S3: a stable named pid, :ecto started, SdrAgent.Repo listed once.
  defp base do
    named = self()

    %{
      dynamic: SdrAgent.Repo,
      named_before: named,
      ecto_started: true,
      running: [SdrAgent.Repo],
      named_after: named
    }
  end

  defp free(changes),
    do: Map.merge(base(), Map.merge(%{named_before: nil, named_after: nil}, changes))

  defp other_pid, do: spawn(fn -> :ok end)

  defp observation(:s1_free_without_ecto),
    do: free(%{ecto_started: false, running: :not_observed})

  defp observation(:s2_free_with_ecto_empty), do: free(%{running: []})
  defp observation(:s2_free_with_other_repo), do: free(%{running: [SdrAgent.OtherRepo]})
  defp observation(:s3_listed_once), do: base()

  defp observation(:s3_listed_once_among_others),
    do: %{base() | running: [SdrAgent.OtherRepo, SdrAgent.Repo]}

  defp observation(:u1_dynamic_other_atom), do: %{base() | dynamic: :sdr_agent_other}
  defp observation(:u1_dynamic_pid), do: %{base() | dynamic: other_pid()}
  defp observation(:u1_dynamic_string), do: %{base() | dynamic: "Elixir.SdrAgent.Repo"}
  defp observation(:u2_pid_entry_name_free), do: free(%{running: [other_pid()]})
  defp observation(:u2_pid_entry_listed), do: %{base() | running: [SdrAgent.Repo, other_pid()]}

  defp observation(:u3_named_without_ecto),
    do: %{base() | ecto_started: false, running: :not_observed}

  defp observation(:u4_named_not_listed), do: %{base() | running: []}
  defp observation(:u5_listed_name_free), do: free(%{running: [SdrAgent.Repo]})
  defp observation(:u6_name_appeared), do: %{base() | named_before: nil}
  defp observation(:u6_name_vanished), do: %{base() | named_after: nil}
  defp observation(:u6_name_changed), do: %{base() | named_after: other_pid()}
  defp observation(:u7_listed_twice), do: %{base() | running: [SdrAgent.Repo, SdrAgent.Repo]}
  defp observation(:malformed_not_a_map), do: :maybe
  defp observation(:malformed_keyword_list), do: Map.to_list(base())
  defp observation(:malformed_missing_key), do: Map.delete(base(), :named_after)
  defp observation(:malformed_extra_key), do: Map.put(base(), :in_transaction, false)
  defp observation(:malformed_ecto_not_boolean), do: %{base() | ecto_started: :yes}
  defp observation(:malformed_unobserved_with_ecto), do: %{base() | running: :not_observed}

  defp observation(:malformed_list_without_ecto),
    do: free(%{ecto_started: false, running: []})

  defp observation(:malformed_improper_list), do: %{base() | running: [SdrAgent.Repo | :tail]}
  defp observation(:malformed_nil_entry), do: free(%{running: [nil]})
  defp observation(:malformed_string_entry), do: free(%{running: ["Elixir.SdrAgent.Repo"]})

  defp observation(:malformed_named_not_pid),
    do: %{base() | named_before: SdrAgent.Repo, named_after: SdrAgent.Repo}

  defp observation(:malformed_red_sentinel), do: {:error, :not_implemented}

  defp flag(:flag_true), do: true
  defp flag(:flag_false), do: false
  defp flag(:flag_nil), do: nil
  defp flag(:flag_atom), do: :yes
  defp flag(:flag_tuple), do: {:ok, true}
  defp flag(:flag_string), do: "true"
  defp flag(:flag_integer), do: 1
end
