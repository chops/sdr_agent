defmodule SdrAgent.Agents.Witness.ProjectionV3Test do
  @moduledoc """
  S12d projection v3 (`claude-message-json/3+prompt-builder/1`, entity PASS
  9343defb). v3 is v2 with exactly three bounded relaxations, taken from the
  structure of real proofs 1 and 2. The fixtures are synthetic: no real CLI
  context or account metadata.

    1. A reminder may end with its close tag plus exactly one LF. Its digest
       and byte count cover the original bytes.
    2. `cache_control` may be `{type: ephemeral, ttl: "1h"}` on system and
       trailing blocks, and only that ttl.
    3. A trailing system message may carry a message-level `output_config`
       of the top-level shape. It is tagged in manifest v3 and in
       `trailing_output_config`.

  Everything else is v2's: the stdin is byte-exact, the response rules are
  unchanged, and thinking is unsupported.
  """
  use ExUnit.Case, async: true

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @v3 "claude-message-json/3+prompt-builder/1"
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @prompt "Qualify the v3 fixture lead"
  @answer ~s({"answer":"qualified","score":42})
  @close "</system-reminder>"
  @reminder "<system-reminder>\nSynthetic date.\n" <> @close
  @reminder_lf @reminder <> "\n"
  @effort %{"output_config" => %{"effort" => "high"}}

  setup do
    json_schema = Zoi.to_json_schema(@schema)

    app = %{
      request: Jason.encode!(%{prompt: @prompt, schema: json_schema}),
      response: Jason.encode!([%{"type" => "result", "result" => @answer}])
    }

    invocation = %{
      model_id: "claude-opus-5-5",
      model_catalog_entry: ClaudeCLI.provenance().model_catalog_entry
    }

    %{app: app, invocation: invocation, stdin: ClaudeCLI.render_prompt(@prompt, json_schema)}
  end

  # The proof-shaped synthetic request: all three relaxations at once.
  defp proof_shaped(ctx, overrides \\ []) do
    Proxy.cli_request(
      ctx.stdin,
      Keyword.merge(
        [reminders: [@reminder_lf], cache_ttl: "1h", trailing_message_extra: @effort],
        overrides
      )
    )
  end

  defp v3(ctx, request, response \\ nil),
    do: call(:compare_v3, [ctx.invocation, ctx.app, request, response || sse()])

  defp v2(ctx, request, response \\ nil),
    do: Projection.compare_v2(ctx.invocation, ctx.app, request, response || sse())

  defp sse, do: Proxy.sse_response(@answer)

  # A missing S12d v3 interface fails the scenario's own assertion (RED).
  defp call(function, args) do
    Code.ensure_loaded(Projection)

    if function_exported?(Projection, function, length(args)),
      do: apply(Projection, function, args),
      else: {:error, {:not_implemented, function}}
  end

  test "the v3 version fits the S12b evidence bound" do
    assert call(:version_v3, []) == @v3
    assert {:ok, _} = WitnessEvidence.validate(%{"projection_version" => @v3})
  end

  test "the proof-shaped request matches under v3, is outside v2, and records context", ctx do
    request = proof_shaped(ctx)
    assert match?({:unsupported, %{extras: nil}}, v2(ctx, request))

    assert {:match, proof} = v3(ctx, request)
    assert "cli_injected_context" in proof.reasons
    extras = proof.extras

    # Original complete bytes, the admitted LF included (no stripping).
    assert extras["reminder_sha256s"] == [sha(@reminder_lf)]
    assert extras["reminder_bytes"] == [byte_size(@reminder_lf)]
    assert extras["trailing_output_config"] == ["present"]

    # Block hashes bind the ttl; no normalisation.
    blocks =
      ~s([{"cache_control":{"ttl":"1h","type":"ephemeral"},) <>
        ~s("text":"Synthetic trailing context 1","type":"text"}])

    assert extras["trailing_system_sha256s"] == [sha(blocks)]

    observed = JSON.decode!(request)

    manifest = %{
      "version" => 3,
      "request_fields" => extras["request_fields"],
      "fields" =>
        Map.new(~w(system thinking output_config context_management), fn f ->
          {f, %{"present" => true, "value" => observed[f]}}
        end),
      "reminders" => [
        %{"block_index" => 0, "sha256" => sha(@reminder_lf), "bytes" => byte_size(@reminder_lf)}
      ],
      "trailing_system" => [
        %{
          "message_index" => 1,
          "sha256" => sha(blocks),
          "bytes" => byte_size("Synthetic trailing context 1"),
          "output_config" => %{"present" => true, "value" => %{"effort" => "high"}}
        }
      ]
    }

    assert extras["request_extras_sha256"] == sha(canon(manifest))
    assert {:ok, _} = WitnessEvidence.validate(extras)
    assert WitnessEvidence.validate_claim(Map.put(extras, "projection_version", @v3)) == :ok
  end

  test "each relaxation alone is admitted by v3 and refused by v2", ctx do
    for {label, opts} <- [
          {"reminder close tag + one LF", [reminders: [@reminder_lf]]},
          {"cache_control ttl 1h", [cache_ttl: "1h"]},
          {"message-level output_config", [trailing_message_extra: @effort]}
        ] do
      request = Proxy.cli_request(ctx.stdin, opts)
      assert match?({:unsupported, %{extras: nil}}, v2(ctx, request)), label
      assert match?({:match, _}, v3(ctx, request)), label
    end
  end

  test "a different sole stdin under v3 is a mismatch with recorded context", ctx do
    result = v3(ctx, Proxy.cli_request(ctx.stdin <> " ", reminders: [@reminder_lf]))
    assert match?({:mismatch, %{extras: %{}}}, result), inspect(result)
  end

  test "reminder endings: exactly one LF after the close tag, inner LFs unchanged", ctx do
    # An LF inside the wrapper before its close tag is valid v2 content.
    assert match?({:match, _}, v3(ctx, Proxy.cli_request(ctx.stdin, reminders: [@reminder])))

    for {label, reminder} <- [
          {"CRLF", @reminder <> "\r\n"},
          {"two LFs", @reminder <> "\n\n"},
          {"space then LF", @reminder <> " \n"},
          {"trailing space", @reminder <> " "},
          {"trailing tab", @reminder <> "\t"},
          {"LF then space", @reminder <> "\n "},
          {"missing close tag", "<system-reminder>\nSynthetic date.\n"},
          {"incorrect close tag", "<system-reminder>\nSynthetic date.\n</system-reminde>\n"}
        ] do
      result = v3(ctx, Proxy.cli_request(ctx.stdin, reminders: [reminder]))
      assert match?({:unsupported, _}, result), "#{label}: #{inspect(result)}"
    end
  end

  test "cache_control: only {type: ephemeral[, ttl: 1h]}, system and trailing only", ctx do
    for {label, cache_control} <- [
          {"ttl 5m", %{"type" => "ephemeral", "ttl" => "5m"}},
          {"numeric ttl", %{"type" => "ephemeral", "ttl" => 3600}},
          {"upper-case ttl", %{"type" => "ephemeral", "ttl" => "1H"}},
          {"null ttl", %{"type" => "ephemeral", "ttl" => nil}},
          {"extra key", %{"type" => "ephemeral", "ttl" => "1h", "scope" => "global"}},
          {"ttl without ephemeral", %{"type" => "persistent", "ttl" => "1h"}},
          {"ttl alone", %{"ttl" => "1h"}}
        ] do
      result = v3(ctx, Proxy.cli_request(ctx.stdin, cache_control: cache_control))
      assert match?({:unsupported, _}, result), "#{label}: #{inspect(result)}"
    end

    user_ttl =
      mutate(Proxy.cli_request(ctx.stdin), fn request ->
        update_in(request, ["messages", Access.at(0), "content", Access.at(0)], fn block ->
          Map.put(block, "cache_control", %{"type" => "ephemeral", "ttl" => "1h"})
        end)
      end)

    assert match?({:unsupported, _}, v3(ctx, user_ttl))
  end

  test "the ttl is bound by the trailing digest and the root hash", ctx do
    assert {:match, plain} =
             v3(ctx, Proxy.cli_request(ctx.stdin, trailing_message_extra: @effort))

    assert {:match, ttl} = v3(ctx, proof_shaped(ctx, reminders: []))
    refute plain.extras["trailing_system_sha256s"] == ttl.extras["trailing_system_sha256s"]
    refute plain.extras["request_extras_sha256"] == ttl.extras["request_extras_sha256"]
  end

  test "message-level controls: only output_config of the top-level shape", ctx do
    for {label, opts} <- [
          {"unknown message key", [trailing_message_extra: %{"name" => "n"}]},
          {"message-level cache_control",
           [trailing_message_extra: %{"cache_control" => %{"type" => "ephemeral"}}]},
          {"unknown output_config field",
           [trailing_message_extra: %{"output_config" => %{"verbosity" => "x"}}]},
          {"17-byte effort",
           [
             trailing_message_extra: %{
               "output_config" => %{"effort" => String.duplicate("e", 17)}
             }
           ]},
          {"output_config not a map", [trailing_message_extra: %{"output_config" => "high"}]},
          {"output_config plus another key",
           [trailing_message_extra: Map.put(@effort, "name", "n")]},
          {"output_config on the user message", [user_message_extra: @effort]}
        ] do
      result = v3(ctx, Proxy.cli_request(ctx.stdin, opts))
      assert match?({:unsupported, _}, result), "#{label}: #{inspect(result)}"
    end

    # A 16-byte effort is the accepted maximum.
    max = %{"output_config" => %{"effort" => String.duplicate("e", 16)}}
    assert match?({:match, _}, v3(ctx, Proxy.cli_request(ctx.stdin, trailing_message_extra: max)))
  end

  test "absent, null and present message-level output_config are distinguished", ctx do
    results =
      for {code, extra} <- [
            {"absent", %{}},
            {"null", %{"output_config" => nil}},
            {"present", @effort},
            {"present", %{"output_config" => %{"effort" => "low"}}},
            {"present", %{"output_config" => %{}}}
          ] do
        assert {:match, proof} =
                 v3(ctx, Proxy.cli_request(ctx.stdin, trailing_message_extra: extra))

        assert proof.extras["trailing_output_config"] == [code]
        proof.extras
      end

    roots = Enum.map(results, & &1["request_extras_sha256"])
    assert length(Enum.uniq(roots)) == length(roots)

    # The block list did not change, so its digest is the same throughout.
    assert results |> Enum.map(& &1["trailing_system_sha256s"]) |> Enum.uniq() |> length() == 1

    assert {:match, two} =
             v3(ctx, Proxy.cli_request(ctx.stdin, trailing: 2, trailing_message_extra: @effort))

    assert two.extras["trailing_output_config"] == ["present", "present"]

    assert {:match, zero} = v3(ctx, Proxy.cli_request(ctx.stdin, trailing: 0))
    assert zero.extras["trailing_output_config"] == []
    assert zero.extras["trailing_system_count"] == 0
  end

  test "request-inapplicable is distinct from an unsupported response", ctx do
    thinking = Proxy.sse_response(@answer, blocks: [{:thinking, nil}, {:text, @answer}])

    # Admitted request, unsupported response: evaluated, context recorded.
    for result <- [
          v2(ctx, Proxy.cli_request(ctx.stdin), thinking),
          v3(ctx, proof_shaped(ctx), thinking)
        ] do
      assert match?({:unsupported, %{extras: %{"reminder_count" => _}}}, result), inspect(result)
    end

    # A request outside the grammar: not evaluated, no context.
    result = v3(ctx, proof_shaped(ctx, cache_ttl: "5m"))
    assert match?({:unsupported, %{extras: nil}}, result), inspect(result)
  end

  describe "evidence contract" do
    test "the v3 group is the v2 group plus trailing_output_config, cardinality-checked" do
      good = Map.put(v2_group(), "trailing_output_config", ["present"])
      assert {:ok, _} = WitnessEvidence.validate(good)

      for {label, bad} <- [
            {"length below count", %{good | "trailing_output_config" => []}},
            {"length above count", %{good | "trailing_output_config" => ["present", "null"]}},
            {"unknown code", %{good | "trailing_output_config" => ["maybe"]}},
            {"not a list", %{good | "trailing_output_config" => "present"}},
            {"without the v2 group", %{"trailing_output_config" => ["present"]}}
          ] do
        assert match?({:error, _}, WitnessEvidence.validate(bad)), label
      end
    end

    test "claims are exact per version" do
      v3_group = Map.put(v2_group(), "trailing_output_config", ["absent"])

      assert WitnessEvidence.validate_claim(Map.put(v3_group, "projection_version", @v3)) == :ok

      for {label, evidence} <- [
            {"v3 with only the v2 group", Map.put(v2_group(), "projection_version", @v3)},
            {"v3 without any group", %{"projection_version" => @v3}},
            {"v2 carrying the v3-only key",
             Map.put(v3_group, "projection_version", Projection.version_v2())}
          ] do
        assert match?({:error, _}, WitnessEvidence.validate_claim(evidence)), label
      end

      assert WitnessEvidence.validate_claim(
               Map.put(v2_group(), "projection_version", Projection.version_v2())
             ) == :ok
    end

    test "projections_inapplicable accepts only the legal prefixes" do
      for value <- [[], ["v2"], ["v2", "v3"]] do
        assert match?({:ok, _}, WitnessEvidence.validate(%{"projections_inapplicable" => value})),
               inspect(value)
      end

      for value <- [["v3"], ["v3", "v2"], ["v2", "v2"], ["v1"], ["v2", "v3", "v1"], "v2", [2]] do
        assert match?(
                 {:error, _},
                 WitnessEvidence.validate(%{"projections_inapplicable" => value})
               ),
               inspect(value)
      end
    end
  end

  ## Helpers

  defp v2_group do
    %{
      "reminder_count" => 0,
      "reminder_sha256s" => [],
      "reminder_bytes" => [],
      "trailing_system_count" => 1,
      "trailing_system_sha256s" => [String.duplicate("a1", 32)],
      "trailing_system_bytes" => [10],
      "request_extras_sha256" => String.duplicate("b2", 32),
      "request_fields" => ["thinking_present"]
    }
  end

  defp mutate(json, fun), do: json |> JSON.decode!() |> fun.() |> JSON.encode!()

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Independent canonical JSON (sorted keys, compact) for the ASCII fixtures.
  defp canon(map) when is_map(map) do
    "{" <>
      (map
       |> Enum.sort_by(fn {k, _} -> k end)
       |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canon(v) end)) <> "}"
  end

  defp canon(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &canon/1) <> "]"
  defp canon(value), do: Jason.encode!(value)
end
