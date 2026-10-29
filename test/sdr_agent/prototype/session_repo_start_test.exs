defmodule SdrAgent.Prototype.SessionRepoStartTest do
  @moduledoc """
  Minimal source/API RED for the approved prototype Session startup adapter.
  The shared VM's real Repo is never stopped or replaced. Source wiring is
  structural evidence only; missing-Repo startup, deterministic TOCTOU and
  asynchronous failure privacy require the separately issued fresh-VM proof.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Prototype.Session

  @starter SdrAgent.Prototype.SessionRepoStart
  @error SdrAgent.Prototype.SessionRepoStart.RepoStartError
  @message "prototype: repo_start_failed"

  defp starter! do
    assert Code.ensure_loaded?(@starter), "SessionRepoStart is absent"
    assert function_exported?(@starter, :start!, 0), "SessionRepoStart.start!/0 is absent"
  end

  # Return closed booleans only. A raw exception, message or PID is never
  # included in an assertion or printed by this helper.
  defp refused_start do
    Function.capture(@starter, :start!, 0).()
    :returned
  rescue
    error ->
      %{
        fixed_class?: error.__struct__ == @error,
        fixed_message?: Exception.message(error) == @message,
        fixed_fields?: Enum.sort(Map.keys(error)) == [:__exception__, :__struct__, :message]
      }
  catch
    _kind, _reason -> :other_failure
  end

  test "structural: prototype Session wires the real RepoState decision and no-argument starter" do
    source = File.read!("lib/sdr_agent/prototype/session.ex")
    assert source =~ "SdrAgent.Prototype.RepoState.repo_state()", "RepoState entry is not wired"
    assert source =~ "SdrAgent.Prototype.SessionRepoStart.start!()", "real startup is not wired"
  end

  test "structural: the internal real starter exports start!/0" do
    starter!()
  end

  test "a direct start when the real Repo already exists refuses without adopting or stopping it" do
    starter!()
    winner = Process.whereis(Repo)
    assert is_pid(winner), "prerequisite: the shared real Repo is absent"

    assert refused_start() == %{
             fixed_class?: true,
             fixed_message?: true,
             fixed_fields?: true
           }

    assert Process.whereis(Repo) == winner, "the existing Repo identity changed"
    assert Process.alive?(winner), "the existing Repo was stopped"
  end

  test "control: entry outside prototype runtime leaves the shared Repo unchanged" do
    winner = Process.whereis(Repo)
    assert is_pid(winner), "prerequisite: the shared real Repo is absent"

    assert Session.enter(agent: "codex_cli", session_correlation: "startup-reuse-control-0001") ==
             {:error, :not_prototype_runtime}

    assert Process.whereis(Repo) == winner, "Session changed the shared Repo identity"
    assert Process.alive?(winner), "Session stopped the shared Repo on return"
  end
end
