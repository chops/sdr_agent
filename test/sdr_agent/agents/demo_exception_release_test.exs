defmodule SdrAgent.Agents.DemoExceptionReleaseTest do
  @moduledoc """
  C2* S3 RED-3, the release decision (plan r2 §8 row
  `demo_exception_release_test.exs`, §6 `ResultGate.finalize/4` and
  `ReleaseDecision`; ADR-0005 C2* amendment items 3-5 and 8; AC3, AC4,
  AC12): the result gate releases a fresh in-scope unpromoted v4 positive
  match as `:demo_exception`/`:v4_uncalibrated`, and every ineligible case
  keeps today's withheld outcome, reason, classification and cause while
  the withheld event also carries exactly one closed
  `demo_exception_refusal` code (OQ7 order: `exception_off`,
  `environment_unattested`, `outside_window`, `scope_mismatch`,
  `identity_mismatch`, `output_invalid`, `promotion_gap_not_v4`,
  `link_not_eligible`, `invocation_not_clean`).

  Harnesses (plan r2 §8): H1 is the pipeline (`GateFixtures.call_model!/3`
  with the hermetic fake CLI, then `ResultGate.await/3` and
  `ResultGate.finalize/4`); H2 is `SdrAgent.DemoExceptionFixtures`
  (`constructed!/3`: a completed invocation, a REC primary v4 link and its
  receipt, then the real `finalize/4`). Both run in
  `DemoExceptionFixtures.demo_env!/1`'s synthetic environment. Faults are
  applied after the call is charged, so later admission guards never see
  them.

  Classification (RED-3 at 2578a6f5): every positive is behavioural (today
  the same exchange is withheld `:witness_missing`/`method_not_enabled`);
  every negative first asserts today's outcome (passes) and then its code
  (fails: no code is recorded), so its intended failure is the missing
  closed code; tests named `control:` pass in RED and GREEN. The CHECK half
  of T-W3 is `demo_exception_constraints_test.exs` T-S1 ("demo decided at
  its expiry").

  RED-3 supplement (Codex facf9dcf R1, R2): T-N8 also persists each bad
  current extra (open, unknown route, contentful or incomplete count_tokens,
  ambiguous, a second primary) behind a clean receipt, so only the
  under-head re-read of the persisted link set can refuse; T-N11 covers
  every non-assignment origin and a `:proof` run through the domain path.
  The pure E1/E2/E5 fact vectors are in `demo_exception/eligibility_test.exs`.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.DemoException.Basis
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Clock
  alias SdrAgent.DemoExceptionFixtures, as: Fx
  alias SdrAgent.GateFixtures
  alias SdrAgent.Operations

  @v4 "claude-message-json/4+prompt-builder/1"
  @policy "c2star-demo-v4/1"
  @label "demo exception - v4 not independently calibrated"
  @end_at ~U[2026-11-01 06:00:00.000000Z]
  @layouts [
    "cli_shape_v4_overflow",
    "cli_shape_v4_two_text",
    "cli_shape_v4_after_text",
    "cli_shape_v4_unknown_block",
    "cli_shape_v4_unparsed_signature",
    "cli_shape_v4_v2_thinking"
  ]

  setup ctx do
    %{env: Fx.demo_env!(Map.get(ctx, :demo_env, []))}
  end

  describe "positives (AC3; T-P1a, T-P2, T-P3, T-E4-6)" do
    test "T-P1a: a fresh in-scope v4 positive match is released as a demo exception", %{env: env} do
      {invocation, outcome} = pipeline(env, "cli_shape_v4_thinking")
      assert {:ok, %{status: :inferred}} = outcome
      assert [link] = links!(env, invocation)
      # T-E4-6: the unmodified reconciler pipeline emits the two codes.
      assert link.evidence["reason_codes"] == ["method_not_enabled", "cli_injected_context"]

      release = assert_demo!(env, invocation, link, finalize(env, invocation, outcome))

      assert release.exception_basis["evidence"]["reason_codes"] ==
               ["cli_injected_context", "method_not_enabled"]

      assert_untouched!(env, invocation, [link])
    end

    test "T-P2: an ancillary count_tokens extra keeps the primary eligible", %{env: env} do
      {invocation, outcome} = pipeline(env, "cli_shape_v4_thinking_count_tokens")
      assert {:ok, %{status: :inferred, link_id: link_id}} = outcome
      links = links!(env, invocation)

      assert Enum.sort(Enum.map(links, & &1.evidence["classification"])) ==
               ["ancillary", "primary"]

      primary = Enum.find(links, &(&1.id == link_id))
      release = assert_demo!(env, invocation, primary, finalize(env, invocation, outcome))

      assert release.exception_basis["evidence"]["current_link_ids"] ==
               links |> Enum.map(& &1.id) |> Enum.sort()

      assert_untouched!(env, invocation, links)
    end

    for purpose <- [:qualification, :evidence_extraction, :outreach_proposal] do
      @tag purpose: purpose
      test "T-P3: purpose #{purpose} is released as a demo exception", %{env: env} = ctx do
        {invocation, outcome} = pipeline(env, "cli_shape_v4_thinking", purpose: ctx.purpose)
        assert invocation.purpose == ctx.purpose
        assert [link] = links!(env, invocation)
        release = assert_demo!(env, invocation, link, finalize(env, invocation, outcome))
        assert release.exception_basis["invocation"]["purpose"] == Atom.to_string(ctx.purpose)
      end
    end

    for {label, codes} <- [
          {"the one-code path", ["method_not_enabled"]},
          {"the two codes in the other persisted order",
           ["cli_injected_context", "method_not_enabled"]}
        ] do
      @tag codes: codes
      test "T-E4-6: #{label} qualifies; the persisted evidence is never rewritten",
           %{env: env} = ctx do
        parts = Fx.constructed!(env, :qualification, evidence: %{"reason_codes" => ctx.codes})
        before = Canonical.encode!(parts.link.evidence)
        result = finalize(env, parts.invocation, {:ok, parts.receipt})
        release = assert_demo!(env, parts.invocation, parts.link, result)
        assert release.exception_basis["evidence"]["reason_codes"] == Enum.sort(ctx.codes)
        assert [after_link] = links!(env, parts.invocation)
        assert Canonical.encode!(after_link.evidence) == before
        assert after_link.evidence["reason_codes"] == ctx.codes
      end
    end
  end

  describe "selector off and an inert entry (T-N1; exception_off)" do
    @tag demo_env: [selector: false]
    test "control: T-N1 selector off is today's withheld outcome, with no code", %{env: env} do
      {invocation, outcome} = pipeline(env, "cli_shape_v4_thinking")
      assert {:ok, %{status: :inferred}} = outcome
      assert {:withheld, release, run} = finalize(env, invocation, outcome)
      assert {release.disposition, release.reason} == {:withheld, :witness_missing}
      assert {run.status, run.status_reason} == {:failed, :witness_unreconciled}
      assert exception_nil?(release)
      assert [event] = events_for(env, "model.result.withheld", release)
      assert event.payload["arguments"]["gate_classification"] == "method_not_enabled"
      refute Map.has_key?(event.payload["arguments"], "demo_exception_refusal")
      assert events_for(env, "model.result.demo_exception", release) == []
      assert Fx.calls(env) == []
    end

    test "T-N1b: an inert entry (no authorization id) is withheld with exception_off",
         %{env: env} do
      parts = Fx.constructed!(env)
      Fx.put_source!(:authorization_id, nil)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "exception_off")
    end
  end

  describe "decision authority (T-N3; environment_unattested)" do
    for {label, fault} <- [
          {"no active registration (:none)", :none},
          {"a provisioning-level attestation", :provisioning},
          {"live_binding? false (lease nonce or database oid drift)", :live_binding},
          {"the authorization's entry_sha256 drifted", :entry_sha256},
          {"another tenant in the attestation", :tenant},
          {"another environment id", :environment},
          {"an authorization the registry does not know", :authorization}
        ] do
      @tag fault: fault
      test "T-N3: #{label} is withheld as today, environment_unattested", %{env: env} = ctx do
        parts = Fx.constructed!(env)
        attestation_fault!(env, ctx.fault)
        result = finalize(env, parts.invocation, {:ok, parts.receipt})
        withheld!(env, result, {:witness_missing, :method_not_enabled}, "environment_unattested")
      end
    end
  end

  describe "the window (T-W3, T-W4; outside_window)" do
    test "T-W3: one microsecond before the effective end is decided, with that end", %{env: env} do
      parts = Fx.constructed!(env)
      :ok = Clock.freeze(DateTime.add(@end_at, -1, :microsecond))
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      release = assert_demo!(env, parts.invocation, parts.link, result)
      assert release.decided_at == DateTime.add(@end_at, -1, :microsecond)
      assert release.exception_expires_at == @end_at
    end

    test "T-W3: a decision at exactly the effective end is withheld, outside_window",
         %{env: env} do
      parts = Fx.constructed!(env)
      :ok = Clock.freeze(@end_at)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "outside_window")
    end

    test "T-W4: a call completing after the end stays charged and is withheld", %{env: env} do
      after_end = DateTime.add(@end_at, 60, :second)
      parts = Fx.constructed!(env, :qualification, complete_at: after_end)
      assert parts.invocation.status == :completed

      assert {parts.invocation.grant_id, parts.invocation.allocation_id} ==
               {env.grant.id, env.allocation.id}

      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "outside_window")
    end
  end

  describe "run, funding and seed scope (T-N11, T-N12, T-N13; scope_mismatch)" do
    test "T-N11: purpose reply_classification", %{env: env} do
      parts = Fx.constructed!(env, :reply_classification)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "scope_mismatch")
    end

    # Codex facf9dcf R2 (T-N11): every non-assignment origin through the
    # domain path (`demo_env!/1` passes `usage_origin:` to the run).
    for origin <- [:referral, :reply, :followup, :discovery, :channel] do
      @tag demo_env: [usage_origin: origin]
      test "T-N11: a #{origin} run is withheld as today with scope_mismatch", %{env: env} do
        assert env.run.usage_origin != :assignment
        parts = Fx.constructed!(env)
        result = finalize(env, parts.invocation, {:ok, parts.receipt})
        withheld!(env, result, {:witness_missing, :method_not_enabled}, "scope_mismatch")
      end
    end

    # A proof invocation is never released or withheld by an ordinary
    # decide (`release_decision.ex:249-250`), so today the finalizer errors;
    # the exception branch must refuse it under the head with scope_mismatch.
    @tag demo_env: [usage_origin: :proof]
    test "T-N11: a :proof run's call is refused under the head with scope_mismatch, " <>
           "writing nothing",
         %{env: env} do
      assert env.run.usage_origin == :proof
      parts = Fx.constructed!(env, :qualification, calibration: true)
      before = length(events(env.tenant))

      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      assert result == {:error, {:demo_exception_refused, :scope_mismatch}}
      assert {:ok, nil} = Agents.get_result_release(parts.invocation.id, actor: env.agent)
      assert length(events(env.tenant)) == before
    end

    test "T-N12: an owner-form grant (no delegated provenance)", %{env: env} do
      parts = Fx.constructed!(env)
      Fx.put_source!(:delegated_grant?, false)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "scope_mismatch")
    end

    test "T-N12: an authorization that names another grant", %{env: env} do
      parts = Fx.constructed!(env)
      other = %{env.attestation.authorization | grant_id: Ecto.UUID.generate()}
      Fx.put_source!(:attestation, {:ok, %{env.attestation | authorization: other}})
      Fx.put_source!(:live_binding?, true)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "scope_mismatch")
    end

    test "T-N12: a revoked grant", %{env: env} do
      parts = Fx.constructed!(env)

      {:ok, _} =
        Agents.revoke_grant(env.grant, %{expected_revision: 1}, actor: human(:admin, env.tenant))

      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "scope_mismatch")
    end

    @tag demo_env: [lead_id: "019b8eac-1180-7fff-8fff-000000000c25"]
    test "T-N13: a lead that is not a fixture lead", %{env: env} do
      parts = Fx.constructed!(env)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "scope_mismatch")
    end

    test "T-N13: a fixture lead with a duplicate creation event", %{env: env} do
      parts = Fx.constructed!(env)
      duplicate_creation_event!(env)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "scope_mismatch")
    end
  end

  describe "identity, output and the promotion gap (T-N4, T-N10, T-N5)" do
    test "T-N4: a Sonnet invocation is withheld with identity_mismatch", %{env: env} do
      parts = Fx.constructed!(env, :qualification, profile: :claude_cli_sonnet)
      assert parts.invocation.profile_id == :claude_cli_sonnet
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "identity_mismatch")
    end

    test "T-N10: an invalid output is withheld with output_invalid", %{env: env} do
      parts = Fx.constructed!(env, :qualification, completion: %{validation_status: :invalid})
      assert parts.invocation.validation_status == :invalid
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "output_invalid")
    end

    test "T-N5: no v3 entry is withheld with promotion_gap_not_v4", %{env: env} do
      parts = Fx.constructed!(env)
      AgentsFixtures.put_allowlist!([])
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "promotion_gap_not_v4")
    end

    test "T-N5: a shipped v4 entry is withheld with promotion_gap_not_v4", %{env: env} do
      parts = Fx.constructed!(env)
      AgentsFixtures.put_allowlist!([Fx.v3_opus(), Fx.v4_opus()])
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "promotion_gap_not_v4")
    end

    test "control: T-N5 with a v4 entry the pipeline takes the ordinary release", %{env: env} do
      AgentsFixtures.put_allowlist!([Fx.v3_opus(), Fx.v4_opus()])
      {invocation, outcome} = pipeline(env, "cli_shape_v4_thinking")
      assert {:ok, %{status: :reconciled}} = outcome
      assert {:released, release, _output} = finalize(env, invocation, outcome)
      assert {release.disposition, release.reason} == {:released, :reconciled}
      assert exception_nil?(release)
      assert events_for(env, "model.result.demo_exception", release) == []
    end
  end

  describe "evidence and a clean invocation (T-N6, T-N7, T-N8, T-N9)" do
    for variant <- @layouts do
      @tag variant: variant
      test "T-N6: #{variant} is withheld as today with link_not_eligible", %{env: env} = ctx do
        {invocation, outcome} = pipeline(env, ctx.variant)
        assert {:ok, %{status: :inferred}} = outcome
        result = finalize(env, invocation, outcome)
        withheld!(env, result, {:witness_missing, nil}, "link_not_eligible")
      end
    end

    for {label, codes} <- [
          {"an unknown extra reason code", ["method_not_enabled", "unknown_extra_code"]},
          {"method_not_enabled absent", ["cli_injected_context"]}
        ] do
      @tag codes: codes
      test "T-E4-6: #{label} is refused, never repaired: link_not_eligible", %{env: env} = ctx do
        parts = Fx.constructed!(env, :qualification, evidence: %{"reason_codes" => ctx.codes})
        result = finalize(env, parts.invocation, {:ok, parts.receipt})
        withheld!(env, result, {:witness_missing, nil}, "link_not_eligible")
        assert [link] = links!(env, parts.invocation)
        assert link.evidence["reason_codes"] == ctx.codes
      end
    end

    test "T-N7: a current mismatch keeps witness_mismatch, link_not_eligible", %{env: env} do
      parts = mismatch!(env)
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      {_release, run, _event} = withheld!(env, result, {:witness_mismatch, :mismatch}, nil)
      assert {run.status, run.status_reason} == {:failed, :witness_mismatch}
      assert_code!(env, result, "link_not_eligible")
    end

    test "T-N7: a resolved critical cause is withheld with invocation_not_clean", %{env: env} do
      parts = Fx.constructed!(env)
      critical = GateFixtures.cause!(parts.invocation, severity: :critical)

      {:ok, _} =
        Operations.resolve_failure(critical, %{resolution_note: "seen"},
          actor: human(:admin, env.tenant)
        )

      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "invocation_not_clean")
    end

    test "T-N7: a live warning is withheld on it with invocation_not_clean", %{env: env} do
      parts = Fx.constructed!(env)
      warning = GateFixtures.cause!(parts.invocation, operation_id: env.run.operation_id)
      receipt = %{parts.receipt | cause_id: warning.id}
      result = finalize(env, parts.invocation, {:ok, receipt})

      {_release, run, event} =
        withheld!(env, result, {:witness_missing, :method_not_enabled}, nil)

      assert event.payload["arguments"]["gate_cause_id"] == warning.id
      assert run.attention_failure_id == warning.id
      assert_code!(env, result, "invocation_not_clean")
    end

    for {label, code, classification} <- [
          {"an unclassified exchange", "unclassified_exchange", :unclassified},
          {"two primary exchanges", "multiple_primary_exchanges", :ambiguous}
        ] do
      @tag extra: {code, classification}
      test "T-N8: #{label} is withheld as today with invocation_not_clean", %{env: env} = ctx do
        {code, classification} = ctx.extra
        parts = Fx.constructed!(env)
        receipt = %{parts.receipt | codes: parts.receipt.codes ++ [code]}
        result = finalize(env, parts.invocation, {:ok, receipt})
        withheld!(env, result, {:witness_missing, classification}, "invocation_not_clean")
      end
    end

    test "T-N9: a timeout is withheld as today with invocation_not_clean", %{env: env} do
      parts = Fx.constructed!(env)
      result = finalize(env, parts.invocation, {:timeout, parts.receipt})
      withheld!(env, result, {:witness_timeout, :capture_pending}, "invocation_not_clean")
    end

    test "T-N9: an unreadable store is withheld as today with invocation_not_clean",
         %{env: env} do
      parts = Fx.constructed!(env)
      receipt = %{parts.receipt | codes: parts.receipt.codes ++ ["store_unreadable"]}
      result = finalize(env, parts.invocation, {:ok, receipt})
      withheld!(env, result, {:store_unreadable, :store_unreadable}, "invocation_not_clean")
    end

    test "T-N9: an unconfigured store names no link: link_not_eligible", %{env: env} do
      parts = Fx.constructed!(env, :qualification, link?: false)
      receipt = %{status: :skipped, link_id: nil, cause_id: nil, codes: []}
      result = finalize(env, parts.invocation, {:ok, receipt})
      withheld!(env, result, {:store_unreadable, :store_unconfigured}, "link_not_eligible")
    end
  end

  # Codex facf9dcf R1: a clean receipt and a valid v4 primary, with a bad
  # extra persisted independently through REC. Only the under-head re-read
  # of the persisted current link set can refuse. The producer writes each
  # of these extras (`witness.ex:481-514`): an open exchange, an unknown
  # route and a contentful or incomplete count_tokens are `unclassified`;
  # several message exchanges are `ambiguous`. T-P2 keeps the ancillary
  # positive.
  describe "the persisted current link set (T-N8; Codex facf9dcf R1)" do
    for {label, extra} <- [
          {"an open exchange", :open},
          {"an unknown-route exchange", :unknown_route},
          {"a count_tokens exchange with content", :count_tokens_content},
          {"an incomplete count_tokens exchange", :count_tokens_incomplete},
          {"an ambiguous message exchange", :ambiguous}
        ] do
      @tag extra: extra
      test "T-N8: a persisted current extra (#{label}) behind a clean receipt is " <>
             "invocation_not_clean",
           %{env: env} = ctx do
        parts = Fx.constructed!(env)
        extra = extra_link!(env, parts.invocation, ctx.extra)

        assert Enum.sort(Enum.map(links!(env, parts.invocation), & &1.id)) ==
                 Enum.sort([parts.link.id, extra.id])

        assert parts.receipt.codes == Fx.emitted_codes()
        result = finalize(env, parts.invocation, {:ok, parts.receipt})
        withheld!(env, result, {:witness_missing, :method_not_enabled}, "invocation_not_clean")
      end
    end

    test "T-N8: a second persisted current primary is link_not_eligible", %{env: env} do
      parts = Fx.constructed!(env)
      second = extra_link!(env, parts.invocation, :primary)
      assert second.evidence["classification"] == "primary"
      result = finalize(env, parts.invocation, {:ok, parts.receipt})
      withheld!(env, result, {:witness_missing, :method_not_enabled}, "link_not_eligible")
    end
  end

  ## Harness

  defp pipeline(env, variant, opts \\ []) do
    invocation = GateFixtures.call_model!(env, variant, Keyword.put(opts, :clock_from, self()))
    {invocation, ResultGate.await(invocation, Fx.gate(env), store_root: env.root)}
  end

  defp finalize(env, invocation, outcome),
    do: ResultGate.finalize(invocation, Fx.gate(env), outcome)

  defp links!(env, invocation) do
    rec = system_actor(:reconciler, env.tenant)
    {:ok, links} = Agents.current_wire_witness_links(invocation.id, actor: rec)
    links
  end

  defp events_for(env, type, release),
    do: env.tenant |> events_of_type(type) |> Enum.filter(&(&1.subject_id == release.id))

  defp exception_nil?(release) do
    [
      release.exception_policy_id,
      release.exception_expires_at,
      release.exception_basis,
      release.exception_basis_sha256
    ] == [nil, nil, nil, nil]
  end

  # AC3: the one demo-exception row, its closed basis, its event and the
  # output; returns the release.
  defp assert_demo!(env, invocation, link, result) do
    assert {:released, release, output} = result
    assert {release.disposition, release.reason} == {:demo_exception, :v4_uncalibrated}
    assert release.model_invocation_id == invocation.id
    assert release.wire_witness_link_id == link.id
    assert {release.projection_version, release.method} == {@v4, :propagated_id}
    assert release.evidence_sha256 == nil
    assert release.exception_policy_id == @policy
    assert release.exception_expires_at == @end_at
    assert release.decided_at == Clock.utc_now()

    basis = release.exception_basis
    assert release.exception_basis_sha256 == Basis.sha256_hex(basis)

    assert :ok ==
             Basis.validate(basis, %{
               decided_at: release.decided_at,
               exception_expires_at: release.exception_expires_at,
               entry_sha256: env.entry_sha256,
               acceptance_ref: "D-223"
             })

    assert basis["evidence"]["link_id"] == link.id
    assert basis["invocation"]["id"] == invocation.id
    assert basis["invocation"]["lead_id"] == env.run.lead_id

    assert {basis["funding"]["grant_id"], basis["funding"]["allocation_id"]} ==
             {env.grant.id, env.allocation.id}

    assert basis["environment"]["tenant_id"] == env.tenant.id

    assert [event] = events_for(env, "model.result.demo_exception", release)
    arguments = event.payload["arguments"]
    assert arguments["demo_exception_policy_id"] == @policy
    assert arguments["demo_exception_basis_sha256"] == release.exception_basis_sha256
    assert arguments["demo_exception_label"] == @label
    assert events_for(env, "model.result.withheld", release) == []
    assert events_for(env, "model.result.released", release) == []

    assert is_map(output)
    assert {:ok, %{status: :running}} = Agents.get_run(env.run.id, actor: env.agent)
    release
  end

  # AC3: the links, the invocation and its witness status are unchanged,
  # and no attention was opened.
  defp assert_untouched!(env, invocation, links) do
    rec = system_actor(:reconciler, env.tenant)
    assert Enum.sort_by(links!(env, invocation), & &1.id) == Enum.sort_by(links, & &1.id)
    assert {:ok, :inferred} = Agents.witness_status(invocation.id, actor: rec)
    {:ok, attention} = Operations.list_attention(actor: human(:admin, env.tenant))
    assert Enum.filter(attention, &(&1.subject_id == invocation.id)) == []
  end

  # AC4: today's withheld outcome (reason, typed classification when given)
  # first, then the one closed refusal code when `code` is given.
  defp withheld!(env, result, {reason, classification}, code) do
    assert {:withheld, release, run} = result
    assert {release.disposition, release.reason} == {:withheld, reason}
    assert exception_nil?(release)
    assert [event] = events_for(env, "model.result.withheld", release)
    assert events_for(env, "model.result.demo_exception", release) == []

    if classification,
      do:
        assert(
          event.payload["arguments"]["gate_classification"] == Atom.to_string(classification)
        )

    if code, do: assert_code!(env, result, code)
    {release, run, event}
  end

  defp assert_code!(env, {:withheld, release, _run}, code) do
    assert [event] = events_for(env, "model.result.withheld", release)

    assert event.payload["arguments"]["demo_exception_refusal"] == code,
           "the withheld event carries no closed demo_exception_refusal #{code}: " <>
             inspect(event.payload["arguments"])
  end

  defp attestation_fault!(_env, :none), do: Fx.put_source!(:attestation, :none)
  defp attestation_fault!(_env, :live_binding), do: Fx.put_source!(:live_binding?, false)
  defp attestation_fault!(_env, :authorization), do: Fx.put_source!(:authorization, :error)

  defp attestation_fault!(env, fault) do
    att = env.attestation

    changed =
      case fault do
        :provisioning -> %{att | level: :provisioning}
        :entry_sha256 -> %{att | authorization: %{att.authorization | entry_sha256: Fx.hex("x")}}
        :tenant -> %{att | tenant_id: Ecto.UUID.generate()}
        :environment -> %{att | environment_id: "agentenv-2"}
      end

    Fx.put_source!(:attestation, {:ok, changed})
  end

  # A second `sales.lead.created` event for the run's fixture lead,
  # appended by the kernel (E1: exactly one, by the seeder).
  defp duplicate_creation_event!(env) do
    {:ok, _event} =
      Audit.append(
        %{
          event_type: "sales.lead.created",
          category: :domain_change,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: env.run.lead_id,
          action: "seed",
          payload: %{action: "seed", changes: %{}, arguments: %{}}
        },
        actor: system_actor(:kernel, env.tenant)
      )

    :ok
  end

  # An extra current link of `invocation` on another exchange, recorded by
  # REC with the evidence the reconciler writes for that shape
  # (`witness.ex:481-514`, `evidence/4` at :920-958).
  defp extra_link!(env, invocation, shape) do
    rec = system_actor(:reconciler, env.tenant)

    base =
      invocation
      |> Fx.v4_evidence()
      |> Map.take(~w(witness_schema proxy_version cli_version http_method http_status
                     started_at completed_at request_bytes_seen response_bytes_seen
                     request_capture_complete response_capture_complete stream_complete
                     app_request_sha256 app_response_sha256 model_id profile_id))

    evidence =
      case shape do
        :primary ->
          Fx.v4_evidence(invocation, %{"inventory_sha256" => Fx.hex("second inventory")})

        :open ->
          base
          |> Map.drop(~w(completed_at http_status))
          |> Map.merge(%{
            "route" => "/anthropic/v1/messages",
            "outcome" => "open",
            "response_capture_complete" => false,
            "stream_complete" => false,
            "classification" => "unclassified",
            "reason_codes" => ["exchange_open"]
          })

        :unknown_route ->
          Map.merge(base, %{
            "route" => "/anthropic/unknown",
            "outcome" => "complete",
            "classification" => "unclassified",
            "reason_codes" => ["unclassified_exchange"]
          })

        :count_tokens_content ->
          Map.merge(base, %{
            "route" => "/anthropic/v1/messages/count_tokens",
            "outcome" => "complete",
            "classification" => "unclassified",
            "reason_codes" => ["unclassified_exchange"]
          })

        :count_tokens_incomplete ->
          Map.merge(base, %{
            "route" => "/anthropic/v1/messages/count_tokens",
            "outcome" => "complete",
            "response_capture_complete" => false,
            "classification" => "unclassified",
            "reason_codes" => ["unclassified_exchange", "capture_incomplete"]
          })

        :ambiguous ->
          Map.merge(base, %{
            "route" => "/anthropic/v1/messages",
            "outcome" => "complete",
            "classification" => "ambiguous",
            "reason_codes" => ["multiple_primary_exchanges"]
          })
      end

    attrs = %{
      model_invocation_id: invocation.id,
      proxy_record_ref: Ash.UUIDv7.generate(),
      proxy_request_sha256: digest("extra raw request"),
      proxy_response_sha256: digest("extra raw response"),
      link_status: :inferred,
      method: :propagated_id,
      evidence: evidence
    }

    {:ok, link} = Agents.link_wire_witness(attrs, actor: rec)
    link
  end

  # A current v4 mismatch: the REC link (output differs) and its critical
  # cause, with the reconciler's receipt for them.
  defp mismatch!(env) do
    differs = %{
      "observed_response_projection_sha256" => Fx.hex("another response projection"),
      "reason_codes" => ["response_output_differs"]
    }

    parts =
      Fx.constructed!(env, :qualification, evidence: differs, link: %{link_status: :mismatch})

    critical =
      GateFixtures.cause!(parts.invocation,
        severity: :critical,
        operation_id: env.run.operation_id
      )

    receipt = %{parts.receipt | status: :mismatch, cause_id: critical.id}
    %{parts | receipt: receipt}
  end
end
