defmodule SdrAgent.Inbox.FaultSelectorsTest do
  @moduledoc """
  The test-build fault registry has exactly eighteen selectors. Its module
  and selector path must not compile into non-test-seam builds. The GREEN
  dev-VM proof must also show that a valid session passing `test_fault`
  receives `:invalid_input`, not a normal page from an ignored option.
  """
  use ExUnit.Case, async: true

  test "the test-build selector set is exactly the six closed sources times three modes" do
    expected =
      for source <- [
            :draft_list,
            :failure_list,
            :pending_email_drafts,
            :live_failures,
            :local_captures_this_week,
            :audit_append
          ],
          mode <- [:returned, :raised, :timeout],
          do: {source, mode}

    assert Code.ensure_loaded?(SdrAgent.Inbox.TestFaults) and
             function_exported?(SdrAgent.Inbox.TestFaults, :selectors, 0),
           "C1-02 compile-time test-only fault registry is not implemented"

    actual = apply(SdrAgent.Inbox.TestFaults, :selectors, [])
    assert is_list(actual)
    assert length(actual) == 18
    assert Enum.sort(actual) == Enum.sort(expected)
  end
end
