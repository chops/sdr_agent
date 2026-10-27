defmodule SdrAgent.Agents.DemoException.EligibilityTest do
  @moduledoc """
  C2* slice S3 RED-1, the pure parts of eligibility (plan r2 §6
  `eligibility.ex` and `demo_exception.ex`, §8; binding correction 1;
  accepted design r4, ADR-0005 C2* amendment items 2 and 4, draft §9
  T-E4-1..5, the T-E4-6 negatives, and T-W1).

  Interface pinned here. The plan names `Eligibility.evaluate(facts, t)`
  (pure E1-E6 in the OQ7 code order) but not the shape of `facts`, which
  `load/3` builds from rows under the head; this file pins only the E4 step
  and the window:

    * `Eligibility.e4(link, invocation) :: :ok | {:refused, :link_not_eligible}`
      evaluates ADR item 4 E4 for the receipt's primary link of a
      `%ModelInvocation{}`. `WitnessEvidence.validate/1` and
      `validate_claim/1` run on the full evidence, unchanged;
      `exact_v4_group?/1` runs only on the extracted group (the evidence
      restricted to the v3 context-group keys plus the R keys present); the
      four projection digests are present, lowercase hex-64 and equal in
      pairs; the reason codes are compared as a set on a copy (no duplicate;
      exactly {method_not_enabled} or {method_not_enabled,
      cli_injected_context}; persisted order irrelevant); the link is
      `:inferred`, `:propagated_id`, primary, v4, `["v2"]`,
      `reasoning_then_text`, complete, from a reviewed proxy version; and
      the ordinary release's identity check passes. Its refusal code is
      `link_not_eligible` (OQ7). It returns `:ok`, never repaired evidence.
    * `DemoException.effective_window(grant, allocation, authorization) ::
      {effective_starts_at, effective_expires_at}` (ADR item 2): the latest
      start of policy, authorization, grant and allocation `available_from`;
      the earliest end of policy, environment (2026-11-01T06:00:00Z),
      authorization, grant and allocation `available_until`; a nil
      allocation bound is ignored. Instants are compared, not their
      precision.

  The link must also be the invocation's single current primary link with
  no successor; that needs the current links, so it is `evaluate/2`'s and
  is not covered here. All values are synthetic test values; no production
  authorization or cap value is used.

  Each refusal first asserts that the unmutated base passes E4, so a
  refusal cannot pass because the base is ineligible. Before the guard,
  each mutation's premise is checked with the existing public
  `WitnessEvidence` helpers (for example, that an absent digest pair is
  still accepted by `validate/1` and `validate_claim/1`, so only E4's own
  rule can refuse it).

  RED report labels: `control: ...` passes now and after GREEN; every other
  test fails on its guard (structural: `Eligibility`, `DemoException` and
  `DemoException.Authorization` are absent at this head).

  GREEN-1 coverage correction (Codex S3-G1, review ff583bd7): GREEN-1
  (6839ac61) implemented the whole E4 predicate, beyond the comparison
  subset RED-1 covered. The describe "E4 implemented guards" was added
  AFTER that GREEN, so it is not a RED of it: it gives each implemented
  guard (link, claim, identity, capture) a passing control and refusal
  cases, and documents the cases the WitnessEvidence contract already
  refuses (`:contract` premise). Its intended-reason evidence is a separate,
  disclosed transient diagnostic in which the four guards' results are
  ignored.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelCallGrant
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.WireWitnessLink
  alias SdrAgent.Agents.WitnessEvidence

  @eligibility SdrAgent.Agents.DemoException.Eligibility
  @demo_exception SdrAgent.Agents.DemoException
  @authorization SdrAgent.Agents.DemoException.Authorization

  @v3 "claude-message-json/3+prompt-builder/1"
  @v4 "claude-message-json/4+prompt-builder/1"
  @r_keys ~w(response_layout response_thinking_count response_redacted_thinking_count)
  @emitted ["method_not_enabled", "cli_injected_context"]
  @digest_pairs [
    {"projected_request_sha256", "observed_request_projection_sha256"},
    {"observed_request_projection_sha256", "projected_request_sha256"},
    {"projected_response_sha256", "observed_response_projection_sha256"},
    {"observed_response_projection_sha256", "projected_response_sha256"}
  ]

  @tenant_id "019b8eac-0aaa-7bbb-8ccc-0000000000e1"
  @invocation_id "019b8eac-0aaa-7bbb-8ccc-0000000000e2"
  @run_id "019b8eac-0aaa-7bbb-8ccc-0000000000e3"
  @link_id "019b8eac-0aaa-7bbb-8ccc-0000000000e4"
  @grant_id "019b8eac-0aaa-7bbb-8ccc-0000000000e5"
  @allocation_id "019b8eac-0aaa-7bbb-8ccc-0000000000e6"
  # The first `:qualify` fixture lead (Demo.Fixtures.leads/0).
  @fixture_lead "019b8eac-1180-74d8-9f38-54127081d946"
  @request_sha256 :crypto.hash(:sha256, "c2star test request")
  @response_sha256 :crypto.hash(:sha256, "c2star test response")

  # Policy start; policy expiry, which is also the environment end.
  @policy_start ~U[2026-10-27 06:00:00.000000Z]
  @policy_end ~U[2026-11-01 06:00:00.000000Z]
  @early ~U[2026-10-20 00:00:00.000000Z]
  @late ~U[2026-11-30 00:00:00.000000Z]

  ## Fixtures

  defp invocation do
    %ModelInvocation{
      id: @invocation_id,
      tenant_id: @tenant_id,
      agent_run_id: @run_id,
      purpose: :qualification,
      provider: :claude_cli,
      provider_version: "2.1.294",
      model_id: "claude-opus-5-5",
      profile_id: :claude_cli_opus,
      ledger_generation: 2,
      status: :completed,
      validation_status: :valid,
      request_sha256: @request_sha256,
      response_sha256: @response_sha256
    }
  end

  defp link(evidence) do
    %WireWitnessLink{
      id: @link_id,
      tenant_id: @tenant_id,
      model_invocation_id: @invocation_id,
      proxy_record_ref: "019b8eac-4000-7000-8000-000000000001",
      link_status: :inferred,
      method: :propagated_id,
      evidence: evidence,
      supersedes_id: nil
    }
  end

  # The full evidence of a fresh positive v4 primary link, as the reconciler
  # writes it (`witness.ex` `evidence/4`): base keys, identity, the four
  # projection digests, the complete v3 group and the R group.
  defp evidence(overrides \\ %{}) do
    %{
      "witness_schema" => 1,
      "proxy_version" => "0.2.0",
      "cli_version" => "2.1.294",
      "route" => "/anthropic/v1/messages",
      "http_method" => "POST",
      "http_status" => 200,
      "outcome" => "complete",
      "started_at" => "2026-10-28T11:59:50.000000Z",
      "completed_at" => "2026-10-28T11:59:58.000000Z",
      "request_bytes_seen" => 18_432,
      "response_bytes_seen" => 4_096,
      "request_capture_complete" => true,
      "response_capture_complete" => true,
      "stream_complete" => true,
      "classification" => "primary",
      "projection_version" => @v4,
      "projections_inapplicable" => ["v2"],
      "app_request_sha256" => Base.encode16(@request_sha256, case: :lower),
      "app_response_sha256" => Base.encode16(@response_sha256, case: :lower),
      "projected_request_sha256" => hex("request projection"),
      "observed_request_projection_sha256" => hex("request projection"),
      "projected_response_sha256" => hex("response projection"),
      "observed_response_projection_sha256" => hex("response projection"),
      "inventory_sha256" => hex("inventory"),
      "reason_codes" => @emitted,
      "model_id" => "claude-opus-5-5",
      "profile_id" => "claude_cli_opus",
      "reminder_count" => 1,
      "reminder_sha256s" => [hex("reminder")],
      "reminder_bytes" => [64],
      "trailing_system_count" => 1,
      "trailing_system_sha256s" => [hex("trailing system")],
      "trailing_system_bytes" => [28],
      "request_extras_sha256" => hex("request extras"),
      "request_fields" => ["thinking_present", "output_config_present"],
      "trailing_output_config" => ["present"],
      "response_layout" => "reasoning_then_text",
      "response_thinking_count" => 1,
      "response_redacted_thinking_count" => 0
    }
    |> Map.merge(overrides)
  end

  # The extracted group (ADR item 4 E4): the v3 context-group keys plus the
  # R keys present.
  defp extracted(evidence) do
    Map.take(
      evidence,
      WitnessEvidence.context_group(@v3) ++ Enum.filter(@r_keys, &Map.has_key?(evidence, &1))
    )
  end

  defp accepted?(evidence) do
    case WitnessEvidence.validate(evidence) do
      {:ok, normalized} -> WitnessEvidence.validate_claim(normalized) == :ok
      {:error, _} -> false
    end
  end

  defp hex(label), do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)

  defp grant(starts_at, expires_at) do
    %ModelCallGrant{
      id: @grant_id,
      tenant_id: @tenant_id,
      status: :active,
      starts_at: starts_at,
      expires_at: expires_at
    }
  end

  defp allocation(available_from, available_until) do
    %ModelCallAllocation{
      id: @allocation_id,
      tenant_id: @tenant_id,
      grant_id: @grant_id,
      available_from: available_from,
      available_until: available_until
    }
  end

  # Built only after the guard: the struct module is absent at this head.
  defp authorization(starts_at, expires_at) do
    struct!(@authorization,
      id: "test-only-authorization-1",
      entry_sha256: hex("authorization registry entry"),
      starts_at: starts_at,
      expires_at: expires_at
    )
  end

  ## Assertions

  defp implemented!(module, function, arity) do
    assert Code.ensure_loaded?(module) and function_exported?(module, function, arity),
           "C2* S3: #{inspect(module)}.#{function}/#{arity} is not implemented"
  end

  defp e4(evidence), do: call(@eligibility, :e4, [link(evidence), invocation()])

  # Called dynamically: the modules are absent at the RED head.
  defp call(module, function, args), do: apply(module, function, args)

  defp assert_refused(cases) do
    implemented!(@eligibility, :e4, 2)
    base = e4(evidence())
    assert base == :ok, "the unmutated base link must pass E4 first; got #{inspect(base)}"

    for {label, evidence} <- cases do
      result = e4(evidence)

      assert result == {:refused, :link_not_eligible},
             "#{label}: must be refused as link_not_eligible; got #{inspect(result)}"
    end
  end

  defp window!(grant, allocation, starts_at, expires_at) do
    window =
      call(@demo_exception, :effective_window, [
        grant,
        allocation,
        authorization(starts_at, expires_at)
      ])

    assert match?({%DateTime{}, %DateTime{}}, window),
           "effective_window/3 must return {starts_at, expires_at}; got #{inspect(window)}"

    window
  end

  defp assert_instant(%DateTime{} = actual, %DateTime{} = expected, label) do
    assert DateTime.compare(actual, expected) == :eq,
           "#{label}: expected #{inspect(expected)}, got #{inspect(actual)}"
  end

  ## E4

  describe "E4 positive v4 comparison (pure)" do
    test "control: the base link evidence is valid, identity-bound v4 evidence" do
      evidence = evidence()

      assert accepted?(evidence)
      assert WitnessEvidence.check_identity(invocation(), evidence) == :ok
      refute WitnessEvidence.exact_v4_group?(evidence)
      assert WitnessEvidence.exact_v4_group?(extracted(evidence))
    end

    test "T-E4-1: E4 passes on the extracted group, which the full evidence is not" do
      cases =
        for(
          codes <- [@emitted, Enum.sort(@emitted), ["method_not_enabled"]],
          do: {"reason_codes #{inspect(codes)}", evidence(%{"reason_codes" => codes})}
        ) ++
          for {thinking, redacted} <- [{1, 0}, {0, 1}, {2, 2}, {4, 0}] do
            {"counts #{thinking}+#{redacted}",
             evidence(%{
               "response_thinking_count" => thinking,
               "response_redacted_thinking_count" => redacted
             })}
          end

      for {label, evidence} <- cases do
        assert accepted?(evidence), label
        refute WitnessEvidence.exact_v4_group?(evidence), "#{label}: the full map is not exact"
        assert WitnessEvidence.exact_v4_group?(extracted(evidence)), label
      end

      implemented!(@eligibility, :e4, 2)

      for {label, evidence} <- cases do
        result = e4(evidence)
        assert result == :ok, "#{label}: must pass E4; got #{inspect(result)}"
      end
    end

    test "T-E4-2: each digest absent (alone or with its partner), uppercase or of the wrong length is refused" do
      base = evidence()

      absent =
        for {key, partner} <- @digest_pairs do
          [
            {"#{key} absent", Map.delete(base, key)},
            {"#{key} and #{partner} absent", Map.drop(base, [key, partner])}
          ]
        end

      malformed =
        for {key, partner} <- @digest_pairs,
            {form, value} <- [
              {"uppercase", String.upcase(base[key])},
              {"short", String.slice(base[key], 0, 63)},
              {"long", base[key] <> "0"}
            ] do
          # Both members changed alike, so the pair stays equal.
          {"#{key} #{form}", base |> Map.put(key, value) |> Map.put(partner, value)}
        end

      # Absent digests are optional evidence keys: only E4 can refuse them.
      for {label, evidence} <- List.flatten(absent), do: assert(accepted?(evidence), label)

      assert_refused(List.flatten(absent) ++ malformed)
    end

    test "T-E4-3: an unequal request or response pair is refused, even with codes [method_not_enabled]" do
      base = evidence(%{"reason_codes" => ["method_not_enabled"]})

      cases = [
        {"request pair",
         Map.put(base, "observed_request_projection_sha256", hex("another request"))},
        {"response pair",
         Map.put(base, "observed_response_projection_sha256", hex("another response"))}
      ]

      for {label, evidence} <- cases, do: assert(accepted?(evidence), label)
      assert_refused(cases)
    end

    test "T-E4-4: refused when validate/1 or validate_claim/1 fails, with an extra key in the extracted group, or a missing R count" do
      base = evidence()
      unknown_key = Map.put(base, "unexpected_key", 1)
      bad_value = Map.put(base, "http_status", "200")
      no_r_group = Map.drop(base, @r_keys)
      extra_r_key = Map.put(base, "response_layout", "reasoning_overflow")
      missing_count = Map.delete(base, "response_redacted_thinking_count")

      assert match?({:error, _}, WitnessEvidence.validate(unknown_key))
      assert match?({:error, _}, WitnessEvidence.validate(bad_value))
      assert match?({:ok, _}, WitnessEvidence.validate(no_r_group))
      assert match?({:error, _}, WitnessEvidence.validate_claim(no_r_group))
      refute WitnessEvidence.exact_v4_group?(extracted(extra_r_key))
      refute WitnessEvidence.exact_v4_group?(extracted(missing_count))

      assert_refused([
        {"validate/1 fails: a key outside the allowlist", unknown_key},
        {"validate/1 fails: a mistyped value", bad_value},
        {"validate_claim/1 fails although validate/1 passes", no_r_group},
        {"an extra key in the extracted group (counts on a refusal layout)", extra_r_key},
        {"a missing R count", missing_count}
      ])
    end

    test "T-E4-5: an unknown reason code, or method_not_enabled absent, is refused" do
      cases = [
        {"unknown code in place of cli_injected_context",
         evidence(%{"reason_codes" => ["method_not_enabled", "stale_observation"]})},
        {"method_not_enabled absent", evidence(%{"reason_codes" => ["cli_injected_context"]})},
        {"no reason codes", evidence(%{"reason_codes" => []})}
      ]

      for {label, evidence} <- cases, do: assert(accepted?(evidence), label)
      assert_refused(cases)
    end

    test "T-E4-6 negatives: a duplicate, an unknown extra code or method_not_enabled absent is refused, never repaired" do
      cases =
        for codes <- [
              ["method_not_enabled", "cli_injected_context", "method_not_enabled"],
              ["method_not_enabled", "method_not_enabled"],
              ["cli_injected_context", "method_not_enabled", "cli_injected_context"],
              ["method_not_enabled", "cli_injected_context", "response_block_unsupported"],
              ["cli_injected_context"]
            ],
            do: {"reason_codes #{inspect(codes)}", evidence(%{"reason_codes" => codes})}

      assert_refused(cases)
    end
  end

  ## E4 implemented guards (GREEN-1 coverage correction, Codex S3-G1)

  # Each case is {label, link, invocation, premise}. `:guard`: the WitnessEvidence
  # contract accepts the evidence (validate/1 unchanged, validate_claim/1 and the
  # exact extracted group), so only one of e4/2's own guards can refuse it.
  # `:contract`: the contract already refuses it (documented premise; not a
  # distinct guard).

  defp e4_for(link, invocation), do: call(@eligibility, :e4, [link, invocation])

  defp contract_accepts?(evidence) do
    is_map(evidence) and WitnessEvidence.validate(evidence) == {:ok, evidence} and
      WitnessEvidence.validate_claim(evidence) == :ok and
      WitnessEvidence.exact_v4_group?(extracted(evidence))
  end

  defp premise?(evidence, :guard), do: contract_accepts?(evidence)
  defp premise?(evidence, :contract), do: not contract_accepts?(evidence)

  defp evidence_case(label, evidence, premise), do: {label, link(evidence), invocation(), premise}

  defp link_cases do
    base = link(evidence())

    [
      {"another invocation's link",
       %{base | model_invocation_id: "019b8eac-0aaa-7bbb-8ccc-0000000000ef"}, invocation(),
       :guard},
      {"link_status :reconciled", %{base | link_status: :reconciled}, invocation(), :guard},
      {"link_status :mismatch", %{base | link_status: :mismatch}, invocation(), :guard},
      {"method :time_window", %{base | method: :time_window}, invocation(), :guard}
    ]
  end

  defp claim_cases do
    base = evidence()
    no_counts = Map.drop(base, ~w(response_thinking_count response_redacted_thinking_count))

    guard =
      for(
        classification <- ~w(ancillary unclassified ambiguous),
        do: {"classification #{classification}", %{base | "classification" => classification}}
      ) ++
        [
          {"projection_version absent (a downgrade keeps the group)",
           Map.delete(base, "projection_version")},
          {"projections_inapplicable []", %{base | "projections_inapplicable" => []}},
          {"projections_inapplicable [v2, v3]",
           %{base | "projections_inapplicable" => ["v2", "v3"]}},
          {"projections_inapplicable absent", Map.delete(base, "projections_inapplicable")}
        ] ++
        for layout <- ~w(reasoning_overflow text_count_invalid block_after_text
                         block_type_unsupported reasoning_unparsed) do
          {"layout #{layout}", Map.put(no_counts, "response_layout", layout)}
        end

    contract =
      [
        {"projection v3", %{base | "projection_version" => @v3}},
        {"projection v3 without the R group",
         base |> Map.drop(@r_keys) |> Map.put("projection_version", @v3)},
        {"projection v1",
         %{base | "projection_version" => "claude-message-json/1+prompt-builder/1"}}
      ] ++
        for {thinking, redacted} <- [{0, 0}, {4, 1}, {5, 0}, {"1", 0}] do
          {"block counts #{inspect({thinking, redacted})}",
           %{
             base
             | "response_thinking_count" => thinking,
               "response_redacted_thinking_count" => redacted
           }}
        end

    Enum.map(guard, fn {label, e} -> evidence_case(label, e, :guard) end) ++
      Enum.map(contract, fn {label, e} -> evidence_case(label, e, :contract) end)
  end

  defp identity_cases do
    base = evidence()

    evidence_side =
      [
        {"evidence cli_version differs", %{base | "cli_version" => "2.1.295"}},
        {"evidence profile_id differs", %{base | "profile_id" => "claude_cli_sonnet"}},
        {"evidence model_id differs", %{base | "model_id" => "claude-sonnet-5-5"}},
        {"app_request_sha256 differs", %{base | "app_request_sha256" => hex("another request")}},
        {"app_response_sha256 differs",
         %{base | "app_response_sha256" => hex("another response")}}
      ] ++
        for key <- ~w(model_id profile_id app_request_sha256 app_response_sha256),
            do: {"evidence #{key} absent", Map.delete(base, key)}

    invocation_side = [
      {"invocation CLI version differs", %{invocation() | provider_version: "2.1.295"}},
      {"invocation profile differs", %{invocation() | profile_id: :claude_cli_sonnet}},
      {"invocation model differs", %{invocation() | model_id: "claude-sonnet-5-5"}},
      {"invocation without a response commitment", %{invocation() | response_sha256: nil}},
      {"generation-1 invocation (empty identity map)", %{invocation() | ledger_generation: 1}}
    ]

    Enum.map(evidence_side, fn {label, e} -> evidence_case(label, e, :guard) end) ++
      Enum.map(invocation_side, fn {label, inv} -> {label, link(base), inv, :guard} end)
  end

  defp capture_cases do
    base = evidence()

    flags =
      for key <- ~w(request_capture_complete response_capture_complete stream_complete) do
        [{"#{key} false", %{base | key => false}}, {"#{key} absent", Map.delete(base, key)}]
      end

    cases =
      List.flatten(flags) ++
        [
          {"outcome incomplete", %{base | "outcome" => "incomplete"}},
          {"outcome timed_out", %{base | "outcome" => "timed_out"}},
          {"http_status 500", %{base | "http_status" => 500}},
          {"http_status 206", %{base | "http_status" => 206}},
          {"unreviewed proxy_version 0.1.9", %{base | "proxy_version" => "0.1.9"}},
          {"proxy_version absent", Map.delete(base, "proxy_version")}
        ]

    Enum.map(cases, fn {label, e} -> evidence_case(label, e, :guard) end)
  end

  defp malformed_cases do
    base = evidence()

    [
      {"nil evidence", nil},
      {"list evidence", []},
      {"string evidence", "evidence"},
      {"an atom key (validate/1 would normalize it, so it is not unchanged)",
       base |> Map.delete("outcome") |> Map.put(:outcome, "complete")}
    ]
    |> Enum.map(fn {label, e} -> evidence_case(label, e, :contract) end)
  end

  # Premises first, then the guard, then the matched base, then every case.
  # All cases are evaluated and the not-refused ones reported together.
  defp assert_cases_refused(cases) do
    for {label, link, _invocation, premise} <- cases do
      assert premise?(link.evidence, premise), "#{label}: premise #{premise} must hold"
    end

    implemented!(@eligibility, :e4, 2)
    base = e4_for(link(evidence()), invocation())
    assert base == :ok, "the matched base must pass E4 first; got #{inspect(base)}"

    not_refused =
      cases
      |> Enum.map(fn {label, link, invocation, _premise} ->
        {label, e4_for(link, invocation)}
      end)
      |> Enum.reject(fn {_label, result} -> result == {:refused, :link_not_eligible} end)

    assert not_refused == [],
           "must be refused as link_not_eligible: #{inspect(not_refused, pretty: true)}"
  end

  describe "E4 implemented guards (GREEN-1 coverage correction, Codex S3-G1)" do
    test "control: the matched link of the invocation passes E4" do
      assert contract_accepts?(evidence())
      implemented!(@eligibility, :e4, 2)
      assert e4_for(link(evidence()), invocation()) == :ok
    end

    test "link: another invocation, another link_status or another method is refused" do
      assert_cases_refused(link_cases())
    end

    test "claim: non-primary, not v4, another inapplicable list, another layout or bad counts is refused" do
      assert_cases_refused(claim_cases())
    end

    test "identity: CLI, profile, model, request or response commitment, or identity map differs" do
      assert_cases_refused(identity_cases())
    end

    test "capture: an incomplete flag, outcome or status, or an unreviewed proxy version is refused" do
      assert_cases_refused(capture_cases())
    end

    test "malformed or non-map evidence fails closed (contract-covered)" do
      assert_cases_refused(malformed_cases())
    end
  end

  ## T-W1

  describe "T-W1 effective window (pure)" do
    test "the effective end is the minimum of policy, environment, authorization, grant and allocation" do
      cases = [
        {"policy expiry and environment end", grant(@early, @late), allocation(nil, @late),
         {@early, @late}, @policy_end},
        {"authorization", grant(@early, @late), allocation(nil, ~U[2026-10-31 00:00:00Z]),
         {@early, ~U[2026-10-30 00:00:00Z]}, ~U[2026-10-30 00:00:00Z]},
        {"grant", grant(@early, ~U[2026-10-29 00:00:00Z]),
         allocation(nil, ~U[2026-10-31 00:00:00Z]), {@early, ~U[2026-10-30 00:00:00Z]},
         ~U[2026-10-29 00:00:00Z]},
        {"allocation", grant(@early, ~U[2026-10-29 00:00:00Z]),
         allocation(nil, ~U[2026-10-28 18:00:00Z]), {@early, ~U[2026-10-30 00:00:00Z]},
         ~U[2026-10-28 18:00:00Z]},
        {"allocation bound unset (ignored)", grant(@early, ~U[2026-10-29 00:00:00Z]),
         allocation(nil, nil), {@early, ~U[2026-10-30 00:00:00Z]}, ~U[2026-10-29 00:00:00Z]},
        {"both allocation bounds unset, policy minimum", grant(@early, @late),
         allocation(nil, nil), {@early, @late}, @policy_end}
      ]

      implemented!(@demo_exception, :effective_window, 3)
      assert Code.ensure_loaded?(@authorization), "C2* S3: #{inspect(@authorization)} is absent"

      for {label, grant, allocation, {auth_start, auth_end}, expected_end} <- cases do
        {_starts_at, expires_at} = window!(grant, allocation, auth_start, auth_end)
        assert_instant(expires_at, expected_end, label)
      end
    end

    test "the effective start is the maximum of policy, authorization, grant and allocation" do
      cases = [
        {"policy start", grant(@early, @late), allocation(@early, nil), {@early, @late},
         @policy_start},
        {"authorization", grant(@early, @late), allocation(~U[2026-10-27 12:00:00Z], nil),
         {~U[2026-10-28 00:00:00Z], @late}, ~U[2026-10-28 00:00:00Z]},
        {"grant", grant(~U[2026-10-28 01:00:00Z], @late),
         allocation(~U[2026-10-27 12:00:00Z], nil), {~U[2026-10-28 00:00:00Z], @late},
         ~U[2026-10-28 01:00:00Z]},
        {"allocation", grant(~U[2026-10-28 01:00:00Z], @late),
         allocation(~U[2026-10-28 02:00:00Z], nil), {~U[2026-10-28 00:00:00Z], @late},
         ~U[2026-10-28 02:00:00Z]},
        {"allocation bound unset (ignored)", grant(~U[2026-10-28 01:00:00Z], @late),
         allocation(nil, nil), {~U[2026-10-28 00:00:00Z], @late}, ~U[2026-10-28 01:00:00Z]}
      ]

      implemented!(@demo_exception, :effective_window, 3)
      assert Code.ensure_loaded?(@authorization), "C2* S3: #{inspect(@authorization)} is absent"

      for {label, grant, allocation, {auth_start, auth_end}, expected_start} <- cases do
        {starts_at, _expires_at} = window!(grant, allocation, auth_start, auth_end)
        assert_instant(starts_at, expected_start, label)
      end
    end
  end

  # Codex facf9dcf R2 (RED-3 supplement): pure facts for the E1, E2 and E5
  # predicates whose violating rows the domain writers cannot persist, each
  # with all other premises valid. The step functions are GREEN-3's
  # (`e2/1`, `e1_seed/1`, `e5/3`, beside `e4/2`); each test is structural
  # until they exist, and every E4 premise asserted before a guard is
  # reached now.

  # T-N4/T-N10. Reservation fixes the identity from the reviewed profile
  # (`ClaudeCLI.provenance/1`, claude_cli.ex:427-437, the builder at :436),
  # and only completed, valid outputs reach the gate (sdr/model.ex:145-165;
  # release_decision.ex:239-247), so these invocations are facts here.
  describe "E2 absolute entry identity and output (Codex facf9dcf R2)" do
    test "control: the entry's identity, completed and valid, is :ok" do
      implemented!(@eligibility, :e2, 1)
      assert e2(gated()) == :ok
    end

    for {label, field, value, overrides} <- [
          {"CLI version", :provider_version, "2.1.300", %{"cli_version" => "2.1.300"}},
          {"model", :model_id, "claude-opus-5-6", %{"model_id" => "claude-opus-5-6"}},
          {"profile", :profile_id, :claude_cli_sonnet, %{"profile_id" => "claude_cli_sonnet"}}
        ] do
      @tag drift: {field, value, overrides}
      test "common-mode #{label} drift passes E4 but E2 refuses it", ctx do
        {field, value, overrides} = ctx.drift
        drifted = Map.put(gated(), field, value)
        assert call(@eligibility, :e4, [link(evidence(overrides)), drifted]) == :ok
        implemented!(@eligibility, :e2, 1)
        assert e2(drifted) == {:refused, :identity_mismatch}
      end
    end

    test "a prompt-builder drift (invisible to E4) is identity_mismatch" do
      drifted = %{gated() | model_catalog_entry: %{"prompt_builder" => "prompt-builder/2"}}
      assert call(@eligibility, :e4, [link(evidence()), drifted]) == :ok
      implemented!(@eligibility, :e2, 1)
      assert e2(drifted) == {:refused, :identity_mismatch}
    end

    for {label, changes} <- [
          {"generation 1", [ledger_generation: 1]},
          {"the Fake provider", [provider: :fake]}
        ] do
      @tag changes: changes
      test "#{label} is identity_mismatch", ctx do
        implemented!(@eligibility, :e2, 1)
        assert e2(struct!(gated(), ctx.changes)) == {:refused, :identity_mismatch}
      end
    end

    for {label, changes} <- [
          {"a failed invocation", [status: :failed]},
          {"an unknown invocation", [status: :unknown]},
          {"an invalid output", [validation_status: :invalid]}
        ] do
      @tag changes: changes
      test "#{label} is output_invalid", ctx do
        implemented!(@eligibility, :e2, 1)
        assert e2(struct!(gated(), ctx.changes)) == {:refused, :output_invalid}
      end
    end

    test "identity is checked before the output" do
      implemented!(@eligibility, :e2, 1)
      drifted = struct!(gated(), model_id: "claude-opus-5-6", validation_status: :invalid)
      assert e2(drifted) == {:refused, :identity_mismatch}
    end
  end

  # T-N13. A fixture-id lead is written only by `:seed` (lead.ex:133; `:create`
  # takes no id, :124), every lead write appends its creation event
  # (lead.ex:128,137), and every account and contact writer validates the
  # reserved names (account.ex:69,79,92; contact.ex:60,70,94; regressions
  # sales/catalog_test.exs:125,180,408). `e1_seed/1` facts: the tenant, the
  # run's lead id, the lead row, its `sales.lead.created` events in the
  # tenant, and the account domain and contact email at the instant.
  describe "E1 seed provenance and reserved names (Codex facf9dcf R2)" do
    test "control: a fixture lead seeded once, with reserved names, is :ok" do
      implemented!(@eligibility, :e1_seed, 1)
      assert e1_seed(seed_facts()) == :ok
    end

    for {label, overrides} <- [
          {"no creation event", %{creation_events: []}},
          {"a creation event by a human admin", %{creation_events: [:user]}},
          {"a creation event by the kernel", %{creation_events: [:kernel]}},
          {"two seeder creation events", %{creation_events: [:seeder, :seeder]}},
          {"no lead row", %{lead: nil}},
          {"a lead of another tenant", %{lead: :other_tenant}},
          {"a lead id outside the entry", %{lead_id: "019b8eac-1180-7fff-8fff-000000000c25"}},
          {"a non-reserved contact email", %{contact_email: "avery@gmail.com"}},
          {"a non-reserved account domain", %{account_domain: "brightpath.com"}},
          {"no contact email", %{contact_email: nil}}
        ] do
      @tag overrides: overrides
      test "#{label} is scope_mismatch", ctx do
        implemented!(@eligibility, :e1_seed, 1)
        assert e1_seed(seed_facts(ctx.overrides)) == {:refused, :scope_mismatch}
      end
    end
  end

  # T-N7. Lineage forbids a v4 successor of a mismatch (witness_lineage.ex:
  # 126-131; regressions wire_witness_link_test.exs:347,446), and a v4
  # observation keeps a mismatch head (witness.ex:868-876; regression
  # reconciler_test.exs:1224), so a v4 primary behind a historical mismatch
  # is a fact vector here. `e5/3`: the receipt's primary link, every link of
  # the invocation (current and superseded), and its reconciliation_required
  # Failures (any status).
  describe "E5 history and the current link set (Codex facf9dcf R2)" do
    test "control: the primary alone, no Failure, is :ok" do
      implemented!(@eligibility, :e5, 3)
      assert e5([], []) == :ok
    end

    test "control: a current ancillary extra and a resolved warning are :ok" do
      implemented!(@eligibility, :e5, 3)
      links = [other("ancillary", :inferred)]
      assert e5(links, [failure(:warning, :resolved)]) == :ok
    end

    for {label, links, failures} <- [
          {"a superseded historical mismatch", :superseded_mismatch, []},
          {"a retained current mismatch (mismatch_kept)", :kept_mismatch, []},
          {"a current unclassified extra", :unclassified, []},
          {"a current ambiguous extra", :ambiguous, []},
          {"a resolved critical cause", [], [{:critical, :resolved}]},
          {"a live critical cause", [], [{:critical, :open}]},
          {"a live warning", [], [{:warning, :open}]},
          {"an acknowledged warning", [], [{:warning, :acknowledged}]}
        ] do
      @tag vector: {links, failures}
      test "#{label} is invocation_not_clean", ctx do
        {links, failures} = ctx.vector
        implemented!(@eligibility, :e5, 3)
        failures = Enum.map(failures, fn {severity, status} -> failure(severity, status) end)
        assert e5(history(links), failures) == {:refused, :invocation_not_clean}
      end
    end
  end

  defp gated, do: %{invocation() | model_catalog_entry: %{"prompt_builder" => "prompt-builder/1"}}

  defp e2(invocation), do: call(@eligibility, :e2, [invocation])

  defp e1_seed(facts), do: call(@eligibility, :e1_seed, [facts])

  defp seed_facts(overrides \\ %{}) do
    lead = %{id: @fixture_lead, tenant_id: @tenant_id}

    facts = %{
      tenant_id: @tenant_id,
      lead_id: @fixture_lead,
      lead: lead,
      creation_events: [:seeder],
      account_domain: "brightpath-freight.test",
      contact_email: "avery.lindqvist@brightpath-freight.test"
    }

    facts = Map.merge(facts, overrides)

    lead =
      case facts.lead do
        :other_tenant -> %{lead | tenant_id: "019b8eac-0aaa-7bbb-8ccc-0000000000f9"}
        other -> other
      end

    events =
      Enum.map(facts.creation_events, fn actor_type ->
        %{
          event_type: "sales.lead.created",
          actor_type: actor_type,
          tenant_id: @tenant_id,
          subject_id: facts.lead_id
        }
      end)

    %{facts | lead: lead && %{lead | id: facts.lead_id}, creation_events: events}
  end

  defp e5(others, failures) do
    primary = link(evidence())
    call(@eligibility, :e5, [primary, [primary | others], failures])
  end

  defp other(classification, status, overrides \\ []) do
    struct!(
      WireWitnessLink,
      [
        id: Ecto.UUID.generate(),
        tenant_id: @tenant_id,
        model_invocation_id: @invocation_id,
        proxy_record_ref: Ecto.UUID.generate(),
        link_status: status,
        method: :propagated_id,
        evidence: %{"classification" => classification, "projection_version" => @v3},
        supersedes_id: nil
      ] ++ overrides
    )
  end

  defp history(:superseded_mismatch) do
    mismatch = other("primary", :mismatch)
    [mismatch, other("ancillary", :inferred, supersedes_id: mismatch.id)]
  end

  defp history(:kept_mismatch), do: [other("primary", :mismatch)]
  defp history(:unclassified), do: [other("unclassified", :inferred)]
  defp history(:ambiguous), do: [other("ambiguous", :inferred)]
  defp history(links) when is_list(links), do: links

  defp failure(severity, status) do
    %{
      tenant_id: @tenant_id,
      class: :reconciliation_required,
      subject_resource: "SdrAgent.Agents.ModelInvocation",
      subject_id: @invocation_id,
      severity: severity,
      status: status
    }
  end
end
