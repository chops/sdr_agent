defmodule SdrAgent.Agents.WitnessEvidenceV4Test do
  @moduledoc """
  Witness response-block plan r5, T2 (sections 6.4 and E2; ADR-0005
  response-layout amendment item 4, D-182): the v4 R group of
  `SdrAgent.Agents.WitnessEvidence`.

  R is a discriminated group: the complete 9-key v3 request group,
  `response_layout` (a closed enum), and the two counts if and only if the
  layout is `reasoning_then_text`, with thinking + redacted thinking in
  1..4. Counts are never zero-filled or saturated and never appear on a
  refusal. `projection_version` v4 requires the v3 group plus R exactly; v1
  to v3 refuse R; a downgrade (no `projection_version`) keeps the whole
  group. The 4096-byte cap is unchanged.

  "Accepted" here means `validate/1` returns `{:ok, normalized}` and
  `validate_claim/1` returns `:ok` for it; a refusal is either one failing,
  so the test does not pin which of the two enforces each rule. Every
  refusal list first asserts that its unmutated base is accepted, so a
  refusal cannot pass merely because R is not yet an allowlisted key.

  Only the public `validate/1` and `validate_claim/1` are used; no new
  production seam is added for this test (size backstop: see the size
  test's own note).

  RED report labels: tests named `control: ...` are expected to pass now
  and after GREEN; every other test is an intended failure (R is not yet
  part of the allowlist or the claim rules).
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Agents.WitnessEvidence

  @v1 "claude-message-json/1+prompt-builder/1"
  @v2 "claude-message-json/2+prompt-builder/1"
  @v3 "claude-message-json/3+prompt-builder/1"
  @v4 "claude-message-json/4+prompt-builder/1"
  @refusal_layouts ~w(reasoning_overflow text_count_invalid block_after_text
                      block_type_unsupported reasoning_unparsed)
  @thinking "response_thinking_count"
  @redacted "response_redacted_thinking_count"
  @allowlist_error "contains a key outside the allowlist"

  ## Fixtures

  defp v2_group do
    %{
      "reminder_count" => 1,
      "reminder_sha256s" => [String.duplicate("a1", 32)],
      "reminder_bytes" => [64],
      "trailing_system_count" => 1,
      "trailing_system_sha256s" => [String.duplicate("b2", 32)],
      "trailing_system_bytes" => [28],
      "request_extras_sha256" => String.duplicate("c3", 32),
      "request_fields" => ["thinking_present", "output_config_present"]
    }
  end

  defp v3_group, do: Map.put(v2_group(), "trailing_output_config", ["present"])

  # The R group: `reasoning_then_text` defaults to counts {1, 0}; any other
  # layout defaults to no counts. `layout_only/1` is a layout without counts.
  defp r(layout, counts \\ nil)
  defp r("reasoning_then_text", nil), do: r("reasoning_then_text", {1, 0})

  defp r(layout, {thinking, redacted}),
    do: %{"response_layout" => layout, @thinking => thinking, @redacted => redacted}

  defp r(layout, nil), do: layout_only(layout)

  defp layout_only(layout), do: %{"response_layout" => layout}

  defp base_evidence do
    %{
      "witness_schema" => 1,
      "proxy_version" => "0.2.0",
      "cli_version" => "2.1.294",
      "route" => "/anthropic/v1/messages",
      "classification" => "primary",
      "reason_codes" => ["cli_injected_context"],
      "projections_inapplicable" => ["v2"],
      "model_id" => "claude-opus-5-5",
      "profile_id" => "claude_cli_opus"
    }
  end

  # A full v4 claim: base evidence, the v3 group and R.
  defp v4_claim(r_group),
    do: base_evidence() |> Map.merge(v3_group()) |> Map.merge(r_group) |> claim(@v4)

  defp claim(evidence, version), do: Map.put(evidence, "projection_version", version)

  defp accepted?(evidence) do
    case WitnessEvidence.validate(evidence) do
      {:ok, normalized} -> WitnessEvidence.validate_claim(normalized) == :ok
      {:error, _} -> false
    end
  end

  defp error(evidence) do
    case WitnessEvidence.validate(evidence) do
      {:ok, normalized} ->
        case WitnessEvidence.validate_claim(normalized) do
          :ok -> nil
          {:error, message} -> message
        end

      {:error, message} ->
        message
    end
  end

  # Each case must be refused, and not merely as an unknown key, after its
  # base is accepted.
  defp assert_refused(base, cases) do
    assert accepted?(base), "the unmutated base must be accepted first: #{inspect(error(base))}"

    for {label, evidence, opts} <- cases do
      message = error(evidence)
      assert message, "#{label}: must be refused"

      unless Keyword.get(opts, :unknown_key, false),
        do: refute(message == @allowlist_error, "#{label}: refused for the intended rule")
    end
  end

  ## Valid groups

  test "valid per-layout groups pass, as v4 claims and as downgrades" do
    valid =
      [
        {"reasoning_then_text 1 + 0", r("reasoning_then_text", {1, 0})},
        {"reasoning_then_text 0 + 1", r("reasoning_then_text", {0, 1})},
        {"reasoning_then_text 2 + 2", r("reasoning_then_text", {2, 2})},
        {"reasoning_then_text 4 + 0", r("reasoning_then_text", {4, 0})},
        {"reasoning_then_text 0 + 4", r("reasoning_then_text", {0, 4})},
        {"reasoning_then_text 3 + 1", r("reasoning_then_text", {3, 1})}
      ] ++ for layout <- @refusal_layouts, do: {layout, r(layout)}

    for {label, group} <- valid do
      assert accepted?(v4_claim(group)), "v4 #{label}: #{inspect(error(v4_claim(group)))}"

      downgraded = Map.delete(v4_claim(group), "projection_version")
      assert accepted?(downgraded), "downgrade #{label}: #{inspect(error(downgraded))}"
    end
  end

  test "a downgraded v4 link (no projection, the whole group kept) passes" do
    downgraded =
      r("reasoning_then_text", {2, 1})
      |> v4_claim()
      |> Map.delete("projection_version")
      |> Map.merge(%{
        "reason_codes" => ["exchange_missing", "cli_injected_context"],
        "supersede_reason" => "exchange_missing"
      })

    assert {:ok, normalized} = WitnessEvidence.validate(downgraded)
    assert WitnessEvidence.validate_claim(normalized) == :ok
    assert normalized["response_layout"] == "reasoning_then_text"
    assert {normalized[@thinking], normalized[@redacted]} == {2, 1}
  end

  ## Refusals

  test "totals outside 1..4 are refused (0, 5 and 3 + 2), never saturated" do
    assert_refused(v4_claim(r("reasoning_then_text", {2, 2})), [
      {"0 + 0", v4_claim(r("reasoning_then_text", {0, 0})), []},
      {"3 + 2", v4_claim(r("reasoning_then_text", {3, 2})), []},
      {"4 + 1", v4_claim(r("reasoning_then_text", {4, 1})), []},
      {"1 + 4", v4_claim(r("reasoning_then_text", {1, 4})), []},
      {"4 + 4", v4_claim(r("reasoning_then_text", {4, 4})), []},
      {"5 + 0 (typed range)", v4_claim(r("reasoning_then_text", {5, 0})), []},
      {"negative", v4_claim(r("reasoning_then_text", {-1, 2})), []},
      {"non-integer", v4_claim(r("reasoning_then_text", {"1", 0})), []}
    ])
  end

  test "counts with a refusal layout, and an ok layout without counts, are refused" do
    with_counts =
      for layout <- @refusal_layouts do
        {"#{layout} with counts", v4_claim(r(layout, {1, 0})), []}
      end

    zero_filled =
      for layout <- @refusal_layouts do
        {"#{layout} with zero counts", v4_claim(r(layout, {0, 0})), []}
      end

    assert_refused(
      v4_claim(r("reasoning_then_text")),
      with_counts ++
        zero_filled ++
        [
          {"reasoning_then_text without counts", v4_claim(layout_only("reasoning_then_text")),
           []},
          {"reasoning_then_text, thinking count only",
           v4_claim(Map.delete(r("reasoning_then_text"), @redacted)), []},
          {"reasoning_then_text, redacted count only",
           v4_claim(Map.delete(r("reasoning_then_text"), @thinking)), []},
          {"a refusal layout, thinking count only",
           v4_claim(Map.put(r("reasoning_overflow"), @thinking, 1)), []},
          {"a refusal layout, redacted count only",
           v4_claim(Map.put(r("reasoning_unparsed"), @redacted, 1)), []},
          {"an unknown layout", v4_claim(r("reasoning_maybe")), []},
          {"a non-string layout", v4_claim(%{"response_layout" => 1}), []},
          {"counts without a layout",
           v4_claim(Map.delete(r("reasoning_then_text"), "response_layout")), []}
        ]
    )
  end

  test "R with a v1, v2 or v3 projection is refused" do
    full = v4_claim(r("reasoning_then_text"))

    assert_refused(full, [
      {"v1 with R", claim(full, @v1), []},
      {"v2 with R", claim(full, @v2), []},
      {"v3 with R", claim(full, @v3), []},
      {"v3 with a refusal R", claim(v4_claim(r("reasoning_unparsed")), @v3), []}
    ])
  end

  test "R without the complete v3 group, and v4 without R, are refused" do
    without_group = base_evidence() |> Map.merge(r("reasoning_then_text"))

    assert_refused(v4_claim(r("reasoning_then_text")), [
      {"R alone, no projection", without_group, []},
      {"R alone, v4", claim(without_group, @v4), []},
      {"R with the 8-key v2 group, no projection", Map.merge(without_group, v2_group()), []},
      {"R with the 8-key v2 group, v4", claim(Map.merge(without_group, v2_group()), @v4), []},
      {"v4 with the v3 group and no R", base_evidence() |> Map.merge(v3_group()) |> claim(@v4),
       []},
      {"v4 with no group at all", claim(base_evidence(), @v4), []}
    ])
  end

  test "a partial or extra group is refused" do
    full = v4_claim(r("reasoning_then_text"))

    partial =
      for key <- Map.keys(v3_group()) do
        {"v3 group without #{key}", Map.delete(full, key), []}
      end

    assert_refused(
      full,
      partial ++
        [
          {"an extra, unknown R-like key", Map.put(full, "response_text_count", 1),
           [unknown_key: true]},
          {"an extra block-type list", Map.put(full, "response_block_types", ["thinking"]),
           [unknown_key: true]}
        ]
    )
  end

  ## Unchanged v1-v3 group helpers

  test "control: context_group and exact_context_group? are unchanged for v1 to v3" do
    group = Map.keys(v2_group())
    assert Enum.sort(WitnessEvidence.context_group()) == Enum.sort(group)
    assert WitnessEvidence.context_group(@v1) == nil
    assert Enum.sort(WitnessEvidence.context_group(@v2)) == Enum.sort(group)

    assert Enum.sort(WitnessEvidence.context_group(@v3)) ==
             Enum.sort(group ++ ["trailing_output_config"])

    assert WitnessEvidence.exact_context_group?(v2_group(), @v2)
    assert WitnessEvidence.exact_context_group?(v3_group(), @v3)
    refute WitnessEvidence.exact_context_group?(v3_group(), @v2)
    refute WitnessEvidence.exact_context_group?(v2_group(), @v3)
    refute WitnessEvidence.exact_context_group?(v3_group(), @v1)

    for layout <- ["reasoning_then_text" | @refusal_layouts] do
      with_r = Map.merge(v3_group(), r(layout))
      refute WitnessEvidence.exact_context_group?(with_r, @v3), layout
      refute WitnessEvidence.exact_context_group?(with_r, @v2), layout
    end
  end

  test "control: v1 to v3 claims without R are unchanged" do
    assert WitnessEvidence.validate_claim(claim(base_evidence(), @v1)) == :ok

    assert WitnessEvidence.validate_claim(base_evidence() |> Map.merge(v2_group()) |> claim(@v2)) ==
             :ok

    assert WitnessEvidence.validate_claim(base_evidence() |> Map.merge(v3_group()) |> claim(@v3)) ==
             :ok

    refute WitnessEvidence.validate_claim(base_evidence() |> Map.merge(v2_group()) |> claim(@v3)) ==
             :ok
  end

  ## Size (section 6.4; Codex r5 PASS size clarification)

  @hex String.duplicate("f", 64)

  # Every allowlisted key at its typed maximum (longest string, largest
  # number, longest list), with the v4 projection and the full R group.
  defp maximal(r_group) do
    %{
      "witness_schema" => 99,
      "proxy_version" => String.duplicate("v", 32),
      "cli_version" => "9999.9999.999999",
      "route" => "/anthropic/v1/messages/count_tokens",
      "http_method" => "OPTIONS",
      "http_status" => 599,
      "outcome" => String.duplicate("o", 39),
      "started_at" => "2026-10-07T12:00:00.123456789Z",
      "completed_at" => "2026-10-07T12:00:02.123456789Z",
      "request_bytes_seen" => 1_000_000_000_000,
      "response_bytes_seen" => 1_000_000_000_000,
      "request_capture_complete" => false,
      "response_capture_complete" => false,
      "stream_complete" => false,
      "traceparent_match" => false,
      "response_content_encoding" => String.duplicate("g", 16),
      "classification" => "unclassified",
      "projection_version" => @v4,
      "app_request_sha256" => @hex,
      "app_response_sha256" => @hex,
      "projected_request_sha256" => @hex,
      "projected_response_sha256" => @hex,
      "observed_request_projection_sha256" => @hex,
      "observed_response_projection_sha256" => @hex,
      "inventory_sha256" => @hex,
      "reason_codes" =>
        Enum.map(1..16, &(String.duplicate("r", 36) <> "_#{rem(&1, 10)}#{div(&1, 10)}")),
      "supersede_reason" => String.duplicate("s", 39),
      "reminder_count" => 4,
      "reminder_sha256s" => List.duplicate(@hex, 4),
      "reminder_bytes" => List.duplicate(8192, 4),
      "trailing_system_count" => 2,
      "trailing_system_sha256s" => List.duplicate(@hex, 2),
      "trailing_system_bytes" => List.duplicate(32_768, 2),
      "request_extras_sha256" => @hex,
      "request_fields" =>
        Enum.flat_map(
          ~w(system thinking output_config context_management),
          &["#{&1}_present", "#{&1}_null"]
        ),
      "trailing_output_config" => ["present", "present"],
      "projections_inapplicable" => ["v2", "v3"],
      "model_id" => String.duplicate("m", 39),
      "profile_id" => "claude_cli_sonnet"
    }
    |> Map.merge(r_group)
  end

  test "size: the largest valid v4 map is measured, accepted and within 4096 bytes" do
    candidates =
      [r("reasoning_then_text", {4, 0}), r("reasoning_then_text", {2, 2})] ++
        for(layout <- @refusal_layouts, do: r(layout))

    for group <- candidates do
      map = maximal(group)

      # Every bounded field of the allowlist is populated.
      assert Enum.sort(Map.keys(map)) == Enum.sort(Map.keys(WitnessEvidence.allowed())),
             inspect(Map.keys(WitnessEvidence.allowed()) -- Map.keys(map))

      size = byte_size(Jason.encode!(map))
      assert accepted?(map), "#{group["response_layout"]} (#{size} bytes): #{inspect(error(map))}"
      assert size <= WitnessEvidence.max_bytes(), "measured #{size} bytes"
    end
  end

  # Disclosure (Codex r5 PASS clarification): the fully typed maximum above
  # is below 4096 bytes, so no fully typed, valid map reaches the size
  # check through `validate/1`; every larger map is refused earlier by a
  # typed validator. The backstop branch is kept but is NOT directly
  # covered here, and the refusal below is asserted as a typed refusal, not
  # as backstop coverage.
  test "size: a directly oversized map is refused by a typed validator, not the backstop" do
    map = maximal(r("reasoning_then_text", {2, 2}))
    assert accepted?(map), inspect(error(map))

    oversized = Map.put(map, "outcome", String.duplicate("o", WitnessEvidence.max_bytes()))
    assert byte_size(Jason.encode!(oversized)) > WitnessEvidence.max_bytes()
    assert {:error, message} = WitnessEvidence.validate(oversized)
    assert message == "outcome is invalid"
    refute message =~ "exceeds", "a typed refusal is not presented as backstop coverage"
  end
end
