defmodule SdrAgent.CalibrationConsole.OutcomeTest do
  @moduledoc """
  R0-07 slice E, row R11-4 (harness round 13, entity PASS at 094caa86): the
  closed calibration outcome, mapped from the typed results of one call.

  `Outcome.classify/1` takes the committed invocation, the server's init
  attestation after this call, the gate receipt of the one bounded
  reconciliation (`{:ok | :timeout, receipt}`), the primary link that
  receipt names (or nil) and the candidate entry. Precedence: no launch →
  `launch_failed`; a drifted, missing or non-candidate init → `init_drift`;
  a timed-out observation → `timeout`; an unreadable or unconfigured store
  → `unreadable`; then the receipt and its link.

    * "No launch" is proven only by a nil `sent_at` or a known
      deterministic no-spawn failure recorded after `sent` (C9-03:
      `launch_failed`, `provider_queue_timeout`); an `unknown` call or any
      other failure is never called unlaunched. The attempt stays charged.
    * `match` needs the whole invocation reconciled (receipt status
      `:reconciled`, no ambiguity) and the receipt's own primary link of
      this invocation under the candidate's exact projection and method. A
      link the receipt does not name, or of another invocation, is ignored.
    * The evaluated projection and method come from that link and are
      recorded even when they differ. Attested values are recorded only for
      a valid init of the candidate's identity; expected values are never
      copied into observed fields. Nothing here promotes anything.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.CalibrationConsole.Outcome

  @v3 "claude-message-json/3+prompt-builder/1"
  @invocation_id "01a133dd-0000-7000-8000-000000000001"
  @link_id "01a133dd-0000-7000-8000-0000000000aa"

  @opus %{
    provider: :claude_cli,
    cli_version: "2.1.294",
    profile_id: :claude_cli_opus,
    model_id: "claude-opus-5-5",
    projection_version: @v3,
    method: :propagated_id
  }

  @sonnet %{@opus | profile_id: :claude_cli_sonnet, model_id: "claude-sonnet-5-5"}

  # A missing module fails as an assertion, never as a crash.
  setup do
    assert Code.ensure_loaded?(Outcome), "SdrAgent.CalibrationConsole.Outcome is not defined"
    :ok
  end

  test "the outcome set is closed" do
    assert Outcome.values() ==
             ~w(match mismatch projection_differs not_enabled unsupported ambiguous missing
                timeout unreadable init_drift launch_failed)
  end

  describe "the receipt and its link decide when the call ran and was observed" do
    test "match: the whole invocation reconciled under the candidate" do
      result = classify(link: link(:reconciled), gate: ok(:reconciled))
      assert result.outcome == "match"
      assert result.evaluated_projection_version == @v3
      assert result.evaluated_method == "propagated_id"
    end

    test "match for the Sonnet profile with its own candidate and init" do
      result =
        classify(
          candidate: @sonnet,
          link: link(:reconciled),
          gate: ok(:reconciled),
          attestation: attested("claude-sonnet-5-5")
        )

      assert result.outcome == "match"
      assert result.attested_model_id == "claude-sonnet-5-5"
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

    test "another evaluated method is never a match, and is recorded" do
      result = classify(link: link(:reconciled, method: :time_window), gate: ok(:reconciled))
      refute result.outcome == "match"
      assert result.evaluated_method == "time_window"
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
        result = classify(link: nil, gate: {:ok, receipt(:unwitnessed, codes, nil)})
        assert result.outcome == outcome, inspect(codes)
      end
    end

    test "no link and no codes is missing, never a match" do
      result = classify(link: nil, gate: {:ok, receipt(:unwitnessed, [], nil)})
      assert result.outcome == "missing"
      assert {result.evaluated_projection_version, result.evaluated_method} == {nil, nil}
    end
  end

  describe "a reconciled primary link alone is never a match" do
    test "when the invocation is not reconciled as a whole" do
      for {status, codes, outcome} <- [
            {:inferred, [], nil},
            {:mismatch, [], "mismatch"},
            {:reconciled, ["multiple_primary_exchanges"], "ambiguous"},
            {:reconciled, ["unclassified_exchange"], "ambiguous"},
            {:inferred, ["multiple_primary_exchanges"], "ambiguous"}
          ] do
        result = classify(link: link(:reconciled), gate: ok(status, codes))
        refute result.outcome == "match", inspect({status, codes})
        if outcome, do: assert(result.outcome == outcome, inspect({status, codes}))
      end
    end

    test "when the receipt names another link, or none" do
      for gate <- [
            {:ok, receipt(:reconciled, [], "01a133dd-0000-7000-8000-0000000000bb")},
            {:ok, receipt(:reconciled, [], nil)}
          ] do
        result = classify(link: link(:reconciled), gate: gate)
        refute result.outcome == "match"
        assert {result.evaluated_projection_version, result.evaluated_method} == {nil, nil}
      end
    end

    test "when the link belongs to another invocation" do
      foreign = %{link(:reconciled) | model_invocation_id: "01a133dd-0000-7000-8000-0000000000ff"}
      result = classify(link: foreign, gate: ok(:reconciled))
      refute result.outcome == "match"
      assert {result.evaluated_projection_version, result.evaluated_method} == {nil, nil}
    end
  end

  describe "precedence before the receipt" do
    test "timeout: the bounded observation timed out" do
      gate = {:timeout, receipt(:inferred, [], @link_id)}
      assert classify(link: link(:reconciled), gate: gate).outcome == "timeout"
    end

    test "unreadable: a skipped or unreadable store" do
      assert classify(link: nil, gate: {:ok, %{status: :skipped}}).outcome == "unreadable"

      gate = {:ok, receipt(:unwitnessed, ["store_unreadable"], nil)}
      assert classify(link: nil, gate: gate).outcome == "unreadable"
    end

    # Packet 8.14.8 E3 delta: a failed read of the store is unreadable,
    # never "missing" or "projection_differs"; no capture stays missing.
    test "unreadable: an unreadable primary blob (inferred link, no projection)" do
      for reason <- ~w(blob_missing blob_too_large blob_corrupt) do
        blob = link(:inferred, projection: nil)
        gate = {:ok, receipt(:inferred, [reason], @link_id)}
        result = classify(link: blob, gate: gate)

        # Only the projection is unknown: the link's own method and the
        # independently valid init are recorded as before.
        assert result == %{
                 outcome: "unreadable",
                 evaluated_projection_version: nil,
                 evaluated_method: "propagated_id",
                 attested_cli_version: "2.1.294",
                 attested_model_id: "claude-opus-5-5"
               },
               reason
      end
    end

    test "unreadable: a failed inventory read" do
      for code <- ~w(unsafe_path record_invalid record_too_large too_many_entries
                     invalid_invocation_id store_root_missing) do
        gate = {:ok, receipt(:unwitnessed, [code], nil)}
        assert classify(link: nil, gate: gate).outcome == "unreadable", code
      end
    end

    test "missing: no capture (witness_missing) is not unreadable" do
      gate = {:ok, receipt(:unwitnessed, ["witness_missing"], nil)}
      assert classify(link: nil, gate: gate).outcome == "missing"
    end

    test "init_drift: a drifted init, whatever the receipt says" do
      for reason <- [:model_attestation_drift, :version_attestation_drift] do
        attestation = %{status: :drift, reason: reason, model: nil, version: nil}

        result =
          classify(link: link(:reconciled), gate: ok(:reconciled), attestation: attestation)

        assert result.outcome == "init_drift"
        assert {result.attested_cli_version, result.attested_model_id} == {nil, nil}
      end
    end

    test "init_drift: no observed init after a sent call" do
      for attestation <- [
            %{status: :drift, reason: :missing_init_attestation, model: nil, version: nil},
            %{status: :pending},
            %{status: :not_running},
            nil
          ] do
        result =
          classify(link: link(:reconciled), gate: ok(:reconciled), attestation: attestation)

        assert result.outcome == "init_drift", inspect(attestation)
        assert {result.attested_cli_version, result.attested_model_id} == {nil, nil}
      end
    end

    test "init_drift: an init of another version or another profile's model" do
      for {candidate, attestation} <- [
            {@opus, attested("claude-opus-5-5", "2.1.291")},
            {@opus, attested("claude-sonnet-5-5")},
            {@sonnet, attested("claude-opus-5-5")},
            {@sonnet, attested("claude-sonnet-5-5", "2.1.291")}
          ] do
        result =
          classify(
            candidate: candidate,
            link: link(:reconciled),
            gate: ok(:reconciled),
            attestation: attestation
          )

        assert result.outcome == "init_drift", inspect({candidate.profile_id, attestation})
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

    test "launch_failed: a known no-spawn failure recorded after sent" do
      for reason <- ["launch_failed", "provider_queue_timeout"] do
        result =
          classify(
            invocation: failed(reason),
            link: nil,
            gate: {:ok, receipt(:unwitnessed, ["no_primary_exchange"], nil)},
            attestation: %{status: :pending}
          )

        assert result.outcome == "launch_failed", reason
      end
    end

    test "an unknown call, or a failure after spawn, is never called unlaunched" do
      unknown = %{invocation() | status: :unknown, completed_at: nil}

      for invocation <- [unknown, failed("claude_cli_exit"), failed("claude_cli_timeout")] do
        result =
          classify(
            invocation: invocation,
            link: nil,
            gate: {:ok, receipt(:unwitnessed, ["no_primary_exchange"], nil)},
            attestation: %{status: :pending}
          )

        refute result.outcome == "launch_failed", inspect(invocation.error)
      end
    end
  end

  describe "observed fields" do
    test "a valid init records the attested version and model" do
      result =
        classify(
          link: link(:reconciled),
          gate: ok(:reconciled),
          attestation: attested("claude-opus-5-5")
        )

      assert {result.attested_cli_version, result.attested_model_id} ==
               {"2.1.294", "claude-opus-5-5"}
    end
  end

  defp classify(overrides) do
    overrides = Map.new(overrides)

    Outcome.classify(%{
      invocation: Map.get(overrides, :invocation, invocation()),
      attestation: Map.get(overrides, :attestation, attested("claude-opus-5-5")),
      gate: Map.fetch!(overrides, :gate),
      link: Map.fetch!(overrides, :link),
      candidate: Map.get(overrides, :candidate, @opus)
    })
  end

  defp attested(model, version \\ "2.1.294"),
    do: %{status: :attested, reason: nil, model: model, version: version}

  defp invocation do
    %{
      id: @invocation_id,
      status: :completed,
      error: nil,
      sent_at: ~U[2026-10-13 06:00:00.000000Z],
      completed_at: ~U[2026-10-13 06:00:05.000000Z]
    }
  end

  defp failed(reason),
    do: %{
      invocation()
      | status: :failed,
        error: %{"kind" => "provider_error", "reason" => reason}
    }

  # The receipt's primary link of this invocation, with its evidence
  # identity.
  defp link(status, opts \\ []) do
    %{
      id: @link_id,
      model_invocation_id: @invocation_id,
      link_status: status,
      method: Keyword.get(opts, :method, :propagated_id),
      evidence: %{
        "classification" => "primary",
        "cli_version" => "2.1.294",
        "projection_version" => Keyword.get(opts, :projection, @v3)
      }
    }
  end

  defp ok(status, codes \\ []), do: {:ok, receipt(status, codes, @link_id)}

  defp receipt(status, codes, link_id),
    do: %{status: status, link_id: link_id, cause_id: nil, codes: codes}
end
