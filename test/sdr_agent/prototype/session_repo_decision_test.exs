defmodule SdrAgent.Prototype.SessionRepoDecisionTest do
  @moduledoc """
  The pure Repo decision of a task entry (S1 I4b r2 §7; Codex c18f8134):
  `SdrAgent.Prototype.Session.repo_decision/1` maps a RepoState result to
  start, reuse or the nesting refusal. Pure: no Repo is started, stopped
  or read here, and the fresh-VM start itself is separately owed.

  GREEN: all decision states are exercised without starting a Repo.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.Session

  test "a Repo that is not started is started by the entry" do
    assert Session.repo_decision(:not_started) == :start
  end

  test "a started Repo outside a transaction is reused, never owned" do
    assert Session.repo_decision({:started, false}) == :reuse
  end

  test "a nested or unknown state is the nesting refusal" do
    for state <- [{:started, true}, :unavailable, {:started, nil}, :started, nil] do
      assert Session.repo_decision(state) == {:error, :binding_mismatch}, inspect(state)
    end
  end
end
