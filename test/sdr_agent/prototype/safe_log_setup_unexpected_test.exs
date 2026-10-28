defmodule SdrAgent.Prototype.SafeLogSetupUnexpectedTest do
  @moduledoc """
  The explicit SafeLog delta for setup's `{:unexpected, phase}` outcome
  (S1b plan r4, I2 r2; S1 ACK 6dbe2278 M1, ruled by S1b): one new reason,
  `:unexpected`, appended to the setup reason family, so setup can print
  `prototype: setup_phase phase=<0..3> result=refused reason=unexpected`
  and return `:refused` (status 2). The phase is the recovery fact.

  Nothing else changes: the `setup_phase` shape keys, the other setup
  reasons and their order, every other code and enum. `{:sink_unavailable,
  0}` is NOT presented through SafeLog (it ends as an aborted body, 70).

  Pure: no attachment, logger handler, database or process is needed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SdrAgent.Prototype.SafeLog

  @setup_reasons [
    :none,
    :wrong_env,
    :flag_unset,
    :switch_unset,
    :session_unset,
    :invalid_agent,
    :invalid_correlation,
    :invalid_arguments,
    :repo_target_mismatch,
    :cluster_identity_mismatch,
    :app_running,
    :seed_invalid,
    :credential_path_exists,
    :database_exists,
    :storage_failed,
    :migration_failed,
    :database_not_resumable,
    :database_not_fresh,
    :bootstrap_failed,
    :credential_stale,
    :boot_refused,
    :seed_failed
  ]

  @withheld "prototype: log content withheld\n"

  defp shapes, do: Function.capture(SafeLog, :shapes, 0).()
  defp reasons(kind), do: Function.capture(SafeLog, :reasons, 1).(kind)

  test "RED: the setup family is the current one with :unexpected appended" do
    assert reasons(:setup) == @setup_reasons ++ [:unexpected]
  end

  test "RED: the unexpected line prints for every phase" do
    for phase <- 0..3 do
      line =
        capture_io(fn ->
          SafeLog.say(:setup_phase, phase: phase, result: :refused, reason: :unexpected)
        end)

      expected = "prototype: setup_phase phase=#{phase} result=refused reason=unexpected\n"
      assert line == expected
    end
  end

  test "GUARD: the setup_phase keys and the other refs are unchanged" do
    assert Keyword.keys(Map.fetch!(shapes(), :setup_phase)) == [:phase, :result, :reason]
    assert Keyword.fetch!(Map.fetch!(shapes(), :setup_phase), :phase) == {:count, 0..3}

    assert Keyword.fetch!(Map.fetch!(shapes(), :setup_phase), :result) ==
             {:enum, [:ok, :refused, :rolled_back]}

    for refs <- [
          [phase: 4, result: :refused, reason: :unexpected],
          [phase: 1, result: :refused, reason: :sink_unavailable],
          [phase: 1, result: :refused]
        ] do
      assert capture_io(fn -> SafeLog.say(:setup_phase, refs) end) == @withheld
    end
  end
end
