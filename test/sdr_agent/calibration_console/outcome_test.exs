defmodule SdrAgent.CalibrationConsole.OutcomeTest do
  @moduledoc """
  R0-07 slice E, row R11-4 (harness round 13, entity PASS at 094caa86): the
  closed calibration outcome, mapped from the typed results of one call.

  `Outcome.classify/1` takes the committed invocation, the server's init
  attestation after the call, the gate receipt of the one bounded
  reconciliation (`{:ok | :timeout, receipt}`), its primary link (or nil)
  and the candidate entry. Precedence: no launch → `launch_failed`; a
  drifted or missing init → `init_drift`; a timed-out observation →
  `timeout`; an unreadable or unconfigured store → `unreadable`; then the
  link and its codes. The evaluated projection and method come from the
  link and are recorded even when they differ. Attested values are present
  only for a valid init; expected candidate values are never copied into
  observed fields. Nothing here promotes anything.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.CalibrationConsole.Outcome

  @candidate %{
    provider: :claude_cli,
    cli_version: "2.1.294",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: "claude-message-json/3+prompt-builder/1",
    method: :propagated_id
  }

  test "the outcome set is closed" do
    assert Outcome.values() ==
             ~w(match mismatch projection_differs not_enabled unsupported ambiguous missing
                timeout unreadable init_drift launch_failed)
  end

  describe "the link decides when the call ran and was observed" do
    test "match: a reconciled primary link under the candidate" do
      result = classify(link: link(:reconciled), gate: ok(:reconciled))
      assert result.outcome == "match"
      assert result.evaluated_projection_version == @candidate.projection_version
      assert result.evaluated_method == "propagated_id"
    end

    test "mismatch: the same projection and method, different hashes" do
      assert classify(link: link(:mismatch), gate: ok(:mismatch)).outcome == "mismatch"
    end

    test "projection_differs: another evaluated projection, recorded as evaluated" do
      other = link(:reconciled, projection: "claude-message-json/2+prompt-builder/1")
      result = classify(link: other, gate: ok(:reconciled))
      assert result.outcome == "projection_differs"
      assert result.evaluated_projection_version == "claude-message-json/2+prompt-builder/1"
    end

    test "not_enabled: the candidate tuple, inferred with method_not_enabled" do
      gate = ok(:inferred, ["method_not_enabled"])
      assert classify(link: link(:inferred), gate: gate).outcome == "not_enabled"
    end

    test "unsupported, ambiguous and missing from the reconcile codes" do
      for {codes, outcome} <- [
            {["proxy_version_unsupported"], "unsupported"},
            {["content_encoding_unsupported"], "unsupported"},
            {["multiple_primary_exchanges"], "ambiguous"},
            {["unclassified_exchange"], "ambiguous"},
            {["no_primary_exchange"], "missing"},
            {["witness_missing"], "missing"}
          ] do
        assert classify(link: nil, gate: ok(:unwitnessed, codes)).outcome == outcome,
               inspect(codes)
      end
    end

    test "no link and no codes is missing, never a match" do
      result = classify(link: nil, gate: ok(:unwitnessed, []))
      assert result.outcome == "missing"
      assert {result.evaluated_projection_version, result.evaluated_method} == {nil, nil}
    end
  end

  describe "precedence before the link" do
    test "timeout: the bounded observation timed out" do
      assert classify(link: link(:reconciled), gate: {:timeout, receipt(:inferred, [])}).outcome ==
               "timeout"
    end

    test "unreadable: a skipped or unreadable store" do
      assert classify(link: nil, gate: {:ok, %{status: :skipped}}).outcome == "unreadable"

      assert classify(link: nil, gate: ok(:unwitnessed, ["store_unreadable"])).outcome ==
               "unreadable"
    end

    test "init_drift: a drifted or missing init, whatever the link says" do
      for attestation <- [
            %{status: :drift, reason: :model_attestation_drift, model: nil, version: nil},
            %{status: :drift, reason: :missing_init_attestation, model: nil, version: nil}
          ] do
        result =
          classify(link: link(:reconciled), gate: ok(:reconciled), attestation: attestation)

        assert result.outcome == "init_drift"
        assert {result.attested_cli_version, result.attested_model_id} == {nil, nil}
      end
    end

    test "launch_failed: never sent, whatever else is observed" do
      invocation = %{invocation() | status: :failed, sent_at: nil, completed_at: nil}

      result =
        classify(
          invocation: invocation,
          link: nil,
          gate: {:ok, %{status: :skipped}},
          attestation: %{status: :pending}
        )

      assert result.outcome == "launch_failed"
    end
  end

  describe "observed fields" do
    test "a valid init records the attested version and model" do
      result =
        classify(
          link: link(:reconciled),
          gate: ok(:reconciled),
          attestation: %{status: :attested, model: "claude-opus-5-5", version: "2.1.294"}
        )

      assert {result.attested_cli_version, result.attested_model_id} ==
               {"2.1.294", "claude-opus-5-5"}
    end

    test "no observed init leaves them null; candidate values are not copied" do
      for attestation <- [%{status: :pending}, %{status: :not_running}, nil] do
        result =
          classify(link: link(:reconciled), gate: ok(:reconciled), attestation: attestation)

        assert {result.attested_cli_version, result.attested_model_id} == {nil, nil}
      end
    end

    test "a valid init that names another model is drift, not a recorded value" do
      result =
        classify(
          link: link(:reconciled),
          gate: ok(:reconciled),
          attestation: %{status: :attested, model: "other-model", version: "2.1.294"}
        )

      assert result.outcome == "init_drift"
      assert {result.attested_cli_version, result.attested_model_id} == {nil, nil}
    end
  end

  defp classify(overrides) do
    overrides = Map.new(overrides)

    Outcome.classify(%{
      invocation: Map.get(overrides, :invocation, invocation()),
      attestation:
        Map.get(overrides, :attestation, %{
          status: :attested,
          model: "claude-opus-5-5",
          version: "2.1.294"
        }),
      gate: Map.fetch!(overrides, :gate),
      link: Map.fetch!(overrides, :link),
      candidate: @candidate
    })
  end

  defp invocation do
    %{
      id: "01a133dd-0000-7000-8000-000000000001",
      status: :completed,
      sent_at: ~U[2026-10-13 06:00:00.000000Z],
      completed_at: ~U[2026-10-13 06:00:05.000000Z]
    }
  end

  defp link(status, opts \\ []) do
    %{
      id: "01a133dd-0000-7000-8000-0000000000aa",
      link_status: status,
      method: Keyword.get(opts, :method, :propagated_id),
      evidence: %{
        "projection_version" => Keyword.get(opts, :projection, @candidate.projection_version)
      }
    }
  end

  defp ok(status, codes \\ []), do: {:ok, receipt(status, codes)}

  defp receipt(status, codes),
    do: %{status: status, link_id: nil, cause_id: nil, codes: codes}
end
