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
end
