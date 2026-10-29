defmodule SdrAgent.Prototype.SafeLogSetupSeedDiffersTest do
  @moduledoc """
  The explicit SafeLog delta for setup phase 3's `:seed_differs` refusal
  (S1 handover 345b59bc §3 seed mapping; S1b step 3): one new reason,
  `:seed_differs`, appended to the setup reason family after I2's
  `:unexpected`, so setup can print
  `prototype: setup_phase phase=3 result=refused reason=seed_differs`.

  Nothing else changes: the `setup_phase` shape keys, the other setup
  reasons and their order, and the op family, which already holds
  `:seed_differs` at its own position.

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

  @op_reasons [
    :none,
    :invalid_arguments,
    :binding_mismatch,
    :not_prototype_runtime,
    :forbidden,
    :not_found,
    :stale_review,
    :digest_mismatch,
    :seed_differs,
    :seed_invalid,
    :op_failed
  ]

  @withheld "prototype: log content withheld\n"

  defp shapes, do: Function.capture(SafeLog, :shapes, 0).()
  defp reasons(kind), do: Function.capture(SafeLog, :reasons, 1).(kind)

  test "RED: the setup family is the current one with :unexpected then :seed_differs" do
    assert reasons(:setup) == @setup_reasons ++ [:unexpected, :seed_differs]
  end

  test "RED: the seed_differs line prints for phase 3" do
    line =
      capture_io(fn ->
        SafeLog.say(:setup_phase, phase: 3, result: :refused, reason: :seed_differs)
      end)

    assert line == "prototype: setup_phase phase=3 result=refused reason=seed_differs\n"
  end

  test "GUARD: the op family and the setup_phase refs are unchanged" do
    assert reasons(:op) == @op_reasons
    assert Keyword.keys(Map.fetch!(shapes(), :setup_phase)) == [:phase, :result, :reason]
    assert Keyword.fetch!(Map.fetch!(shapes(), :setup_phase), :phase) == {:count, 0..3}

    for refs <- [
          [phase: 4, result: :refused, reason: :seed_differs],
          [phase: 3, result: :refused, reason: :seed_differ],
          [phase: 3, result: :refused]
        ] do
      assert capture_io(fn -> SafeLog.say(:setup_phase, refs) end) == @withheld
    end
  end
end
