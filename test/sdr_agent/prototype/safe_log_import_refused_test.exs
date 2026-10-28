defmodule SdrAgent.Prototype.SafeLogImportRefusedTest do
  @moduledoc """
  The explicit SafeLog delta for an input-level import refusal (S1b plan
  r4, I2 r2; Codex Q4 ruling: one new code with exact finite reasons,
  never a fictitious `import_row`): `:import_refused`, with exactly the ref
  `reason`, printed only through `say/2`.

  The reason family is S3's (I4 import grammar r1, sha256 27c469ab…, §3),
  adopted by S1b exactly and in its order: `@import_reasons -- [:none]`
  (18) followed by the six input-stage atoms, 24 in total. S3 owns the
  stage-to-reason table and the output contract; this file pins only the
  SafeLog enum, its line and `reasons(:import_refused)`. `@import_reasons`
  and `import_row` are unchanged. No other code, enum, level rule or filter
  behaviour changes; the new code has no `result` key, so `event/2` would
  log it at `:info` (the task uses `say/2` only).

  Pure: no attachment, logger handler, database or process is needed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SdrAgent.Prototype.SafeLog

  @row_reasons [
    :none,
    :no_named_person,
    :role_mailbox,
    :email_unavailable,
    :link_unconfirmed,
    :role_unconfirmed,
    :source_conflict,
    :insufficient_source,
    :not_selected,
    :contact_cap_exceeded,
    :dossier_conflict,
    :dossier_invalid,
    :spotcheck_invalid,
    :artifact_invalid,
    :digest_mismatch,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden,
    :import_failed
  ]

  @reasons (@row_reasons -- [:none]) ++
             [
               :invalid_arguments,
               :session_unset,
               :invalid_agent,
               :invalid_correlation,
               :delegation_not_found,
               :boot_refused
             ]

  @withheld "prototype: log content withheld\n"

  # Read dynamically: the type checker infers the current literal tables
  # and would warn that the not-yet-present key or clause is absent.
  defp shapes, do: Function.capture(SafeLog, :shapes, 0).()
  defp codes, do: Function.capture(SafeLog, :codes, 0).()
  defp reasons(kind), do: Function.capture(SafeLog, :reasons, 1).(kind)

  test "GUARD: the pinned row-level family is the current one (24 = 18 + 6)" do
    assert reasons(:import) == @row_reasons
    assert length(@reasons) == 24
  end

  test "RED: :import_refused is a code with exactly the reason ref" do
    assert :import_refused in codes()
    assert Map.get(shapes(), :import_refused) == [reason: {:enum, @reasons}]
  end

  test "RED: reasons(:import_refused) is the exact family, in order" do
    result =
      try do
        {:ok, reasons(:import_refused)}
      rescue
        FunctionClauseError -> :no_clause
      end

    assert result == {:ok, @reasons}
  end

  test "RED: say/2 prints the fixed line for every reason" do
    for reason <- @reasons do
      line = capture_io(fn -> SafeLog.say(:import_refused, reason: reason) end)
      assert line == "prototype: import_refused reason=#{reason}\n"
    end
  end

  test "GUARD: refs outside the shape print the withheld line" do
    for refs <- [
          [reason: :none],
          [reason: :bogus],
          [reason: "digest_mismatch"],
          [],
          [reason: :digest_mismatch, extra: :x],
          [row_index: 0, result: :refused, reason: :digest_mismatch]
        ] do
      assert capture_io(fn -> SafeLog.say(:import_refused, refs) end) == @withheld
    end
  end

  test "GUARD: the row-level code is unchanged" do
    assert Map.fetch!(shapes(), :import_row) == [
             row_index: {:count, 0..14},
             result: {:enum, [:imported, :replay, :skipped, :refused]},
             reason: {:enum, @row_reasons}
           ]
  end
end
