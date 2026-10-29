# DRAFT r4 (outside the repository; review only; NOT formatted, compiled or
# run). PURE scope: no engine callback is ever invoked (a callback would
# reach Oban.Engines.Basic and the database at GREEN). Oban.Job.format_attempt/1
# is a pure function of its argument (oban job.ex:582-590).
defmodule SdrAgent.Prototype.ClosedErrorEngineShapeTest do
  @moduledoc """
  Containment r4 PS-E: the closed replacement, the fixed exception text,
  the stored error line, the delegation table and the callback shape.

  RED (deny-only declarations):
  - `closed_unsaved`, `JobFailedError message` and `delegation` FAIL at their
    first assertion with their fixed messages (intended RED);
  - `stored error line` FAILS at its guard assertion (closed_unsaved did
    not return a map) before format_attempt is called, so no MatchError
    can occur; its format assertion is unexecuted;
  - `callback shape` PASSES (a structural control, no TDD credit): every
    Oban.Engine callback that Basic implements is exported at its arity.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.ClosedErrorEngine
  alias SdrAgent.Prototype.JobFailedError

  @closed %{kind: :error, reason: %JobFailedError{}, stacktrace: []}
  # Basic's public callbacks (oban 2.24.0 basic.ex:29-377).
  @callbacks [
    {:init, 2, :delegate},
    {:put_meta, 4, :delegate},
    {:check_meta, 3, :delegate},
    {:refresh, 2, :delegate},
    {:shutdown, 2, :delegate},
    {:insert_job, 3, :delegate},
    {:insert_all_jobs, 3, :delegate},
    {:fetch_jobs, 3, :delegate},
    {:stage_jobs, 3, :delegate},
    {:prune_jobs, 3, :delegate},
    {:rescue_jobs, 3, :delegate},
    {:check_available, 1, :delegate},
    {:complete_job, 2, :delegate},
    {:discard_job, 2, :close_then_delegate},
    {:error_job, 3, :close_then_delegate},
    {:snooze_job, 3, :delegate},
    {:cancel_job, 2, :close_then_delegate},
    {:cancel_all_jobs, 2, :delegate},
    {:delete_job, 2, :delegate},
    {:delete_all_jobs, 2, :delegate},
    {:retry_job, 2, :delegate},
    {:retry_all_jobs, 2, :delegate},
    {:update_job, 3, :delegate}
  ]

  test "closed_unsaved: any unsaved error map becomes the closed value, nil stays nil" do
    raw = %{
      kind: {:EXIT, self()},
      reason: %RuntimeError{message: "canary x.test"},
      stacktrace: [{__MODULE__, :canary, 1, [file: ~c"canary.ex", line: 1]}]
    }

    assert ClosedErrorEngine.closed_unsaved(raw) == @closed,
           "an unsaved error was not replaced by the closed value"

    rows = [
      {%{kind: :error, reason: %ArgumentError{message: "canary"}, stacktrace: []}, @closed},
      {%{kind: :throw, reason: "canary", stacktrace: []}, @closed},
      {%{kind: :exit, reason: {:shutdown, "canary"}, stacktrace: []}, @closed},
      {nil, nil},
      {:not_a_map, @closed}
    ]

    for {{unsaved, expected}, index} <- Enum.with_index(rows) do
      assert ClosedErrorEngine.closed_unsaved(unsaved) == expected,
             "closed_unsaved row #{index} is not #{inspect(expected)}"
    end
  end

  test "JobFailedError: the fixed, value-free message" do
    assert JobFailedError.message(%JobFailedError{}) == "prototype_job_failed",
           "JobFailedError's message is not the fixed text"
  end

  test "stored error line: Oban formats the closed value to the fixed text" do
    closed =
      ClosedErrorEngine.closed_unsaved(%{
        kind: :error,
        reason: %RuntimeError{message: "canary x.test"},
        stacktrace: []
      })

    assert is_map(closed), "closed_unsaved did not return a map"

    %{error: error} = Oban.Job.format_attempt(%Oban.Job{attempt: 1, unsaved_error: closed})

    assert error == "** (SdrAgent.Prototype.JobFailedError) prototype_job_failed",
           "the stored error is not the fixed closed text"
  end

  test "delegation: the reviewed table" do
    assert ClosedErrorEngine.delegation() == @callbacks,
           "the delegation table is not the reviewed one"
  end

  test "callback shape: every Basic callback is exported at its arity (structural control)" do
    Code.ensure_loaded!(ClosedErrorEngine)
    Code.ensure_loaded!(Oban.Engines.Basic)

    for {name, arity, _mode} <- @callbacks do
      assert function_exported?(ClosedErrorEngine, name, arity),
             "#{name}/#{arity} is not exported"

      assert function_exported?(Oban.Engines.Basic, name, arity),
             "#{name}/#{arity} is not a Basic callback at this Oban version"
    end
  end
end
