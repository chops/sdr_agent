defmodule SdrAgent.Prototype.SafeLogTaskAbortedTest do
  @moduledoc """
  The explicit SafeLog delta of the D-237 task presentation boundary (S1b
  proposal r2 section 2.7): one new code, `:task_aborted`, with exactly the
  refs `task` (the boundary's closed task atoms) and `stage` (`:attach`,
  `:entry` or `:body`), printed only through `say/2`. No other code, enum,
  level rule or filter behaviour changes.

  Pure: no attachment, logger handler, database or process is needed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SdrAgent.Prototype.SafeLog

  @tasks [:setup, :provision, :import, :op, :serve, :export]
  @stages [:attach, :entry, :body]
  @withheld "prototype: log content withheld\n"

  # Read dynamically: the type checker infers the current literal table and
  # would warn that the not-yet-present key is always absent.
  defp shapes, do: Function.capture(SafeLog, :shapes, 0).()
  defp codes, do: Function.capture(SafeLog, :codes, 0).()

  test ":task_aborted is a code with exactly the task and stage refs" do
    assert :task_aborted in codes()
    assert Map.get(shapes(), :task_aborted) == [task: {:enum, @tasks}, stage: {:enum, @stages}]
  end

  test "say/2 prints the fixed line for every task and stage" do
    for task <- @tasks, stage <- @stages do
      line = capture_io(fn -> SafeLog.say(:task_aborted, task: task, stage: stage) end)
      assert line == "prototype: task_aborted task=#{task} stage=#{stage}\n"
    end
  end

  test "refs outside the shape print the withheld line" do
    for refs <- [
          [task: :bogus, stage: :body],
          [task: :import, stage: :bogus],
          [task: :import],
          [task: :import, stage: :body, extra: :x],
          [task: "import", stage: :body]
        ] do
      assert capture_io(fn -> SafeLog.say(:task_aborted, refs) end) == @withheld
    end
  end

  test "no other code changes" do
    assert codes() -- [:task_aborted] ==
             Enum.sort([
               :boot,
               :setup_phase,
               :seed_result,
               :import_row,
               :import_summary,
               :provisioned,
               :op_result,
               :bundle_written,
               :status_counts
             ])
  end
end
