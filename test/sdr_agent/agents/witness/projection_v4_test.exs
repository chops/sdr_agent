defmodule SdrAgent.Agents.Witness.ProjectionV4Test do
  @moduledoc """
  Witness response-block plan r5, T1 (ADR-0005 response-layout amendment,
  D-182): projection v4, `claude-message-json/4+prompt-builder/1`.

  v4 is v3's request contract and prompt-builder guard, unchanged, plus a
  response of 1 to 4 leading `thinking` / `redacted_thinking` blocks in
  total, then exactly one `text` block, with nothing after it. The stream
  first passes the unchanged shared v1-v3 parser; its refusals stay v3
  refusals. A v4-only validator over the decoded events then checks each
  reasoning block syntactically (section 6.1).

  The contract pinned here for `Projection.compare_v4/4`:

    * `:ineligible` unless all of section 6.2 (a)-(f) hold: the current
      prompt builder, a v3 request `:match`, a decodable application
      output, a stream the shared parser accepts, a block list other than
      `["text"]`, and no `tool_use`;
    * otherwise `{verdict, %{reasons:, digests:, extras:}}`, whose `extras`
      is the complete 9-key v3 request group plus the R keys:
      `response_layout`, and `response_thinking_count` /
      `response_redacted_thinking_count` only for `reasoning_then_text`.
      Every other layout is `:unsupported` with exactly one `response_*`
      code.

  Fixtures are synthetic (`SdrAgent.Test.FakeWitnessProxy`); no real CLI
  context, reasoning text, signature or account metadata.

  RED report labels:

    * tests named `control: ...` are expected to pass now (unchanged v1-v3
      behaviour) and after GREEN;
    * every other test is an intended failure. Where it fails only because
      `version_v4/0` or `compare_v4/4` is absent, that is a structural
      (presence) failure, not proof of the guarded behaviour.
  """
  use ExUnit.Case, async: true

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @v4 "claude-message-json/4+prompt-builder/1"
  @v3 "claude-message-json/3+prompt-builder/1"
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @prompt "Qualify the v4 fixture lead"
  @answer ~s({"answer":"qualified","score":42})
  @other ~s({"answer":"disqualified","score":42})
  @reminder_lf "<system-reminder>\nSynthetic date.\n</system-reminder>\n"
  @effort %{"output_config" => %{"effort" => "high"}}
  @r_keys ~w(response_layout response_thinking_count response_redacted_thinking_count)
  @counts ~w(response_thinking_count response_redacted_thinking_count)
  @request_digests ~w(projected_request_sha256 observed_request_projection_sha256)

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

  ## Fixtures

  # The proof-shaped v3-only request (v2 does not apply to it).
  defp v3_only(ctx, stdin \\ nil) do
    Proxy.cli_request(stdin || ctx.stdin,
      reminders: [@reminder_lf],
      cache_ttl: "1h",
      trailing_message_extra: @effort
    )
  end

  defp stream(blocks, opts \\ []), do: Proxy.sse_response(@answer, [blocks: blocks] ++ opts)

  defp thinking, do: Proxy.thinking_block()
  defp redacted, do: Proxy.redacted_block()
  defp text(body \\ @answer), do: {:text, body}
  defp unknown, do: {:mystery, nil}

  defp thinking_with(start \\ %{}, deltas) do
    Proxy.raw_block(
      Map.merge(%{"type" => "thinking", "thinking" => "", "signature" => ""}, start),
      deltas
    )
  end

  defp td(value), do: %{"type" => "thinking_delta", "thinking" => value}
  defp sd(value), do: %{"type" => "signature_delta", "signature" => value}

  # An unparsed (bad-signature) thinking block that still passes the shared parser.
  defp unparsed, do: Proxy.thinking_block(["Synthetic reasoning."], [])

  ## Calls

  defp v4(ctx, request, response, app \\ nil, invocation \\ nil),
    do: call(:compare_v4, [invocation || ctx.invocation, app || ctx.app, request, response])

  defp v3(ctx, request, response, app \\ nil, invocation \\ nil),
    do: Projection.compare_v3(invocation || ctx.invocation, app || ctx.app, request, response)

  # A missing v4 interface fails the scenario's own assertion (structural RED).
  defp call(function, args) do
    Code.ensure_loaded(Projection)

    if function_exported?(Projection, function, length(args)),
      do: apply(Projection, function, args),
      else: {:error, {:not_implemented, function, length(args)}}
  end

  defp response_codes(%{reasons: reasons}),
    do: Enum.filter(reasons, &String.starts_with?(&1, "response_"))

  # The R group of an evaluated v4 result, and its v3 request group.
  defp r_group(%{extras: extras}), do: Map.take(extras, @r_keys)
  defp request_group(%{extras: extras}), do: Map.drop(extras, @r_keys)

  defp assert_refusal(result, layout, code, label) do
    assert match?({:unsupported, _}, result), "#{label}: #{inspect(result)}"
    {:unsupported, proof} = result
    assert r_group(proof) == %{"response_layout" => layout}, "#{label}: #{inspect(proof.extras)}"
    assert response_codes(proof) == [code], "#{label}: #{inspect(proof.reasons)}"

    for key <- @counts,
        do: refute(Map.has_key?(proof.extras, key), "#{label}: no #{key} on a refusal")
  end

  ## Version

  test "the v4 version is the 38-byte literal and a current version of the builder" do
    assert call(:version_v4, []) == @v4
    assert byte_size(@v4) == 38
    assert @v4 in Projection.current_versions()

    for version <- [Projection.version(), Projection.version_v2(), Projection.version_v3()],
        do: assert(version in Projection.current_versions(), version)
  end

  test "control: the v4 version string fits the existing evidence pattern" do
    assert {:ok, _} = WitnessEvidence.validate(%{"projection_version" => @v4})
  end

  ## Matches (reasoning_then_text)

  test "matches: 1 thinking, 1 redacted, 2 + 2, and a zero-thinking-delta block", ctx do
    for {label, blocks, {thinking, redacted}} <- [
          {"1 thinking + text", [thinking(), text()], {1, 0}},
          {"1 redacted + text", [redacted(), text()], {0, 1}},
          {"2 thinking + 2 redacted + text",
           [thinking(), thinking(), redacted(), redacted(), text()], {2, 2}},
          {"zero thinking deltas, one signature delta", [thinking_with([sd("sig")]), text()],
           {1, 0}},
          {"several thinking pieces, several signature pieces",
           [thinking_with([td("a"), td("b"), sd("sig-"), sd("part")]), text()], {1, 0}},
          {"an empty signature piece, then a non-empty one",
           [thinking_with([td("x"), sd(""), sd("sig")]), text()], {1, 0}},
          {"a non-empty signature piece, then an empty one",
           [thinking_with([sd("sig"), sd("")]), text()], {1, 0}},
          {"empty thinking pieces, then a signature",
           [thinking_with([td(""), td(""), sd("s")]), text()], {1, 0}}
        ] do
      result = v4(ctx, v3_only(ctx), stream(blocks))
      assert match?({:match, _}, result), "#{label}: #{inspect(result)}"
      {:match, proof} = result

      assert r_group(proof) == %{
               "response_layout" => "reasoning_then_text",
               "response_thinking_count" => thinking,
               "response_redacted_thinking_count" => redacted
             },
             label

      assert response_codes(proof) == [], label
      assert "cli_injected_context" in proof.reasons, label

      assert proof.digests["projected_response_sha256"] ==
               proof.digests["observed_response_projection_sha256"],
             label

      assert {:ok, _} = WitnessEvidence.validate(proof.extras)
    end
  end

  test "a reasoning response with different output is a v4 mismatch with counts", ctx do
    result = v4(ctx, v3_only(ctx), stream([thinking(), text(@other)]))
    assert match?({:mismatch, _}, result), inspect(result)
    {:mismatch, proof} = result
    assert response_codes(proof) == ["response_output_differs"]

    assert r_group(proof) == %{
             "response_layout" => "reasoning_then_text",
             "response_thinking_count" => 1,
             "response_redacted_thinking_count" => 0
           }

    refute proof.digests["projected_response_sha256"] ==
             proof.digests["observed_response_projection_sha256"]
  end

  test "request digests and the request group are identical to v3's", ctx do
    request = v3_only(ctx)
    response = stream([thinking(), text()])
    assert {:unsupported, v3_proof} = v3(ctx, request, response)
    assert {:match, v4_proof} = v4(ctx, request, response)

    assert request_group(v4_proof) == v3_proof.extras

    assert Map.keys(request_group(v4_proof)) |> Enum.sort() ==
             Enum.sort(WitnessEvidence.context_group(@v3))

    assert Map.take(v4_proof.digests, @request_digests) ==
             Map.take(v3_proof.digests, @request_digests)

    assert v4_proof.digests["projected_request_sha256"] ==
             v4_proof.digests["observed_request_projection_sha256"]
  end

  ## Layout refusals

  test "layout refusals: overflow, text count, block after text, unknown type", ctx do
    for {label, blocks, layout, code} <- [
          {"total of 5 (3 + 2)",
           [thinking(), thinking(), thinking(), redacted(), redacted(), text()],
           "reasoning_overflow", "response_reasoning_overflow"},
          {"total of 5 (5 thinking)", List.duplicate(thinking(), 5) ++ [text()],
           "reasoning_overflow", "response_reasoning_overflow"},
          {"0 text", [thinking()], "text_count_invalid", "response_text_count_invalid"},
          {"2 text", [thinking(), text(), text()], "text_count_invalid",
           "response_text_count_invalid"},
          {"2 text, no reasoning", [text(), text()], "text_count_invalid",
           "response_text_count_invalid"},
          {"thinking after text", [thinking(), text(), thinking()], "block_after_text",
           "response_block_after_text"},
          {"redacted after text", [redacted(), text(), redacted()], "block_after_text",
           "response_block_after_text"},
          {"unknown zero-delta type", [thinking(), unknown(), text()], "block_type_unsupported",
           "response_block_type_unsupported"},
          {"unknown zero-delta type, no reasoning", [unknown(), text()], "block_type_unsupported",
           "response_block_type_unsupported"}
        ] do
      assert_refusal(v4(ctx, v3_only(ctx), stream(blocks)), layout, code, label)
    end
  end

  test "control: every v4 refusal code is snake_case, at most 39 bytes and a valid code" do
    for code <- ~w(response_reasoning_overflow response_text_count_invalid
                   response_block_after_text response_block_type_unsupported
                   response_reasoning_unparsed) do
      assert code =~ ~r/\A[a-z][a-z0-9_]{0,38}\z/, code
      assert {:ok, _} = WitnessEvidence.validate(%{"reason_codes" => [code]}), code
    end
  end

  ## Signature rule (reasoning_unparsed)

  test "the thinking signature rule: every violation is reasoning_unparsed", ctx do
    for {label, block} <- [
          {"no signature_delta", thinking_with([td("x")])},
          {"no delta at all", thinking_with([])},
          {"an empty combined signature", thinking_with([td("x"), sd("")])},
          {"two empty signature deltas", thinking_with([sd(""), sd("")])},
          {"a thinking_delta after a signature_delta",
           thinking_with([td("x"), sd("s"), td("y")])},
          {"an extra key in the start block", thinking_with(%{"extra" => ""}, [sd("s")])},
          {"an extra key in a thinking delta",
           thinking_with([Map.put(td("x"), "extra", "y"), sd("s")])},
          {"an extra key in a signature delta", thinking_with([Map.put(sd("s"), "extra", "y")])},
          {"a non-string thinking delta", thinking_with([td(1), sd("s")])},
          {"a null thinking delta", thinking_with([td(nil), sd("s")])},
          {"a non-string signature delta", thinking_with([sd(7)])},
          {"a null signature delta", thinking_with([sd(nil)])},
          {"a thinking delta without its field",
           thinking_with([%{"type" => "thinking_delta"}, sd("s")])},
          {"a non-empty thinking in the start block",
           thinking_with(%{"thinking" => "pre"}, [sd("s")])},
          {"a non-empty signature in the start block",
           thinking_with(%{"signature" => "pre"}, [sd("s")])},
          {"a non-string thinking in the start block",
           thinking_with(%{"thinking" => nil}, [sd("s")])},
          {"a start block without thinking and signature",
           Proxy.raw_block(%{"type" => "thinking"}, [sd("s")])},
          {"the bare thinking start of the v3 fixtures", {:thinking, nil}}
        ] do
      assert_refusal(
        v4(ctx, v3_only(ctx), stream([block, text()])),
        "reasoning_unparsed",
        "response_reasoning_unparsed",
        label
      )
    end
  end

  ## Redacted rule, split by the parser-first rule (R4-1)

  test "a zero-delta redacted block with a bad start shape is v4 reasoning_unparsed", ctx do
    for {label, start} <- [
          {"data missing", %{"type" => "redacted_thinking"}},
          {"data non-string", %{"type" => "redacted_thinking", "data" => 5}},
          {"data null", %{"type" => "redacted_thinking", "data" => nil}},
          {"an extra start key", %{"type" => "redacted_thinking", "data" => "d", "extra" => ""}}
        ] do
      assert_refusal(
        v4(ctx, v3_only(ctx), stream([Proxy.raw_block(start), text()])),
        "reasoning_unparsed",
        "response_reasoning_unparsed",
        label
      )
    end
  end

  defp redacted_with_deltas do
    start = %{"type" => "redacted_thinking", "data" => "d"}

    for {label, delta} <- [
          {"text_delta", %{"type" => "text_delta", "text" => "x"}},
          {"thinking_delta", td("x")},
          {"signature_delta", sd("s")},
          {"an unknown delta kind", %{"type" => "mystery_delta", "value" => "x"}}
        ],
        do: {label, Proxy.raw_block(start, [delta])}
  end

  test "a redacted block with any delta is ineligible for v4", ctx do
    for {label, block} <- redacted_with_deltas() do
      result = v4(ctx, v3_only(ctx), stream([block, text()]))
      assert result == :ineligible, "#{label}: #{inspect(result)}"
    end
  end

  test "control: a redacted block with any delta stays v3 response_stream_invalid", ctx do
    for {label, block} <- redacted_with_deltas() do
      result = v3(ctx, v3_only(ctx), stream([block, text()]))
      assert {:unsupported, proof} = result, "#{label}: #{inspect(result)}"
      assert "response_stream_invalid" in proof.reasons, label
      assert Map.take(proof.extras, @r_keys) == %{}, label
    end
  end

  ## Competing faults: the layout precedence

  test "competing faults resolve by the declared precedence", ctx do
    five = [thinking(), thinking(), thinking(), redacted(), redacted()]

    for {label, blocks, layout, code} <- [
          {"unknown type + unparsed thinking", [unparsed(), unknown(), text()],
           "block_type_unsupported", "response_block_type_unsupported"},
          {"unknown type + overflow + two text", five ++ [unknown(), text(), text()],
           "block_type_unsupported", "response_block_type_unsupported"},
          {"unparsed + two text", [unparsed(), text(), text()], "reasoning_unparsed",
           "response_reasoning_unparsed"},
          {"unparsed + after text + overflow", five ++ [text(), unparsed()], "reasoning_unparsed",
           "response_reasoning_unparsed"},
          {"two text + overflow", five ++ [text(), text()], "text_count_invalid",
           "response_text_count_invalid"},
          {"zero text + overflow", five, "text_count_invalid", "response_text_count_invalid"},
          {"after text + overflow", five ++ [text(), thinking()], "block_after_text",
           "response_block_after_text"}
        ] do
      assert_refusal(v4(ctx, v3_only(ctx), stream(blocks)), layout, code, label)
    end
  end

  ## Shared-parser refusals stay old v3 refusals

  defp shared_parser_refusals do
    reasoning = stream([thinking(), text()])
    [_message_start, without_start] = String.split(reasoning, "\n\n", parts: 2)

    [
      {"an unknown type with deltas",
       stream([Proxy.raw_block(%{"type" => "mystery"}, [%{"type" => "mystery_delta"}]), text()]),
       "response_stream_invalid"},
      {"a text delta inside a thinking block",
       stream([thinking_with([%{"type" => "text_delta", "text" => "x"}]), text()]),
       "response_stream_invalid"},
      {"no message_start (malformed)", without_start, "response_stream_invalid"},
      {"no message_stop (incomplete)", stream([thinking(), text()], stop: false),
       "response_stream_incomplete"},
      {"not SSE", "not an event stream", "response_not_sse"}
    ]
  end

  test "shared-parser refusals are ineligible for v4", ctx do
    for {label, response, _code} <- shared_parser_refusals() do
      result = v4(ctx, v3_only(ctx), response)
      assert result == :ineligible, "#{label}: #{inspect(result)}"
    end
  end

  test "control: shared-parser refusals keep their v3 codes and no R keys", ctx do
    for {label, response, code} <- shared_parser_refusals() do
      assert {:unsupported, proof} = v3(ctx, v3_only(ctx), response), label
      assert code in proof.reasons, "#{label}: #{inspect(proof.reasons)}"
      assert Map.take(proof.extras, @r_keys) == %{}, label
    end
  end

  ## Ineligible

  defp unreadable_apps(ctx) do
    [
      {"a result that is not a JSON object",
       %{ctx.app | response: Jason.encode!([%{"type" => "result", "result" => "plain prose"}])}},
      {"a JSON array result",
       %{ctx.app | response: Jason.encode!([%{"type" => "result", "result" => "[1]"}])}},
      {"no result event", %{ctx.app | response: Jason.encode!([%{"type" => "system"}])}},
      {"a missing response", %{ctx.app | response: nil}}
    ]
  end

  defp other_builder(ctx),
    do: %{
      ctx.invocation
      | model_catalog_entry:
          Map.put(ctx.invocation.model_catalog_entry, "prompt_builder", "prompt-builder/0")
    }

  test "ineligible: single text, tool_use, request mismatch, outside v3, unreadable app, builder",
       ctx do
    reasoning = stream([thinking(), text()])

    cases =
      [
        {"single text", v3_only(ctx), stream([text()]), ctx.app, ctx.invocation},
        {"tool_use", v3_only(ctx), stream([thinking(), text(), {:tool_use, nil}]), ctx.app,
         ctx.invocation},
        {"request mismatch", v3_only(ctx, ctx.stdin <> " "), reasoning, ctx.app, ctx.invocation},
        {"request outside the v3 grammar", Proxy.cli_request(ctx.stdin, cache_ttl: "5m"),
         reasoning, ctx.app, ctx.invocation},
        {"unsupported builder", v3_only(ctx), reasoning, ctx.app, other_builder(ctx)}
      ] ++
        for {label, app} <- unreadable_apps(ctx),
            do: {"unreadable app output: #{label}", v3_only(ctx), reasoning, app, ctx.invocation}

    for {label, request, response, app, invocation} <- cases do
      result = v4(ctx, request, response, app, invocation)
      assert result == :ineligible, "#{label}: #{inspect(result)}"
    end
  end

  test "control: the ineligible cases keep their v3 results", ctx do
    reasoning = stream([thinking(), text()])

    assert {:match, single} = v3(ctx, v3_only(ctx), stream([text()]))
    assert Map.take(single.extras, @r_keys) == %{}

    assert {:mismatch, tool} =
             v3(ctx, v3_only(ctx), stream([thinking(), text(), {:tool_use, nil}]))

    assert "response_tool_use" in tool.reasons

    assert {:mismatch, request} = v3(ctx, v3_only(ctx, ctx.stdin <> " "), reasoning)
    assert "request_text_differs" in request.reasons

    assert {:unsupported, %{extras: nil}} =
             v3(ctx, Proxy.cli_request(ctx.stdin, cache_ttl: "5m"), reasoning)

    # A valid v3-only request and a valid reasoning stream with an unreadable
    # application result stay v3 app_response_unreadable (MF1).
    for {label, app} <- unreadable_apps(ctx) do
      assert {:unsupported, proof} = v3(ctx, v3_only(ctx), reasoning, app), label
      assert "app_response_unreadable" in proof.reasons, label
      refute "response_block_unsupported" in proof.reasons, label
      assert Map.take(proof.extras, @r_keys) == %{}, label
    end

    assert {:unsupported, %{reasons: ["prompt_builder_unsupported"], extras: nil}} =
             v3(ctx, v3_only(ctx), reasoning, ctx.app, other_builder(ctx))
  end

  ## v1 to v3 unchanged on every new fixture

  defp eligible_fixtures do
    five = [thinking(), thinking(), thinking(), redacted(), redacted()]

    [
      {"1 thinking", [thinking(), text()]},
      {"1 redacted", [redacted(), text()]},
      {"2 + 2", [thinking(), thinking(), redacted(), redacted(), text()]},
      {"zero thinking deltas", [thinking_with([sd("sig")]), text()]},
      {"output mismatch", [thinking(), text(@other)]},
      {"overflow", five ++ [text()]},
      {"0 text", [thinking()]},
      {"2 text", [thinking(), text(), text()]},
      {"after text", [thinking(), text(), thinking()]},
      {"unknown type", [thinking(), unknown(), text()]},
      {"unparsed signature", [unparsed(), text()]},
      {"redacted without data", [Proxy.raw_block(%{"type" => "redacted_thinking"}), text()]}
    ]
  end

  test "control: v1, v2 and v3 are unchanged on every new reasoning fixture", ctx do
    for {label, blocks} <- eligible_fixtures() do
      response = stream(blocks)

      assert {:unsupported, %{reasons: ["response_block_unsupported"]}} =
               Projection.compare(
                 ctx.invocation,
                 ctx.app,
                 Proxy.messages_request(ctx.stdin),
                 response
               ),
             "v1: #{label}"

      assert {:unsupported, v2_proof} =
               Projection.compare_v2(
                 ctx.invocation,
                 ctx.app,
                 Proxy.cli_request(ctx.stdin),
                 response
               ),
             "v2: #{label}"

      assert {:unsupported, v3_proof} = v3(ctx, v3_only(ctx), response), "v3: #{label}"

      for {version, proof, group} <- [
            {"v2", v2_proof, WitnessEvidence.context_group()},
            {"v3", v3_proof, WitnessEvidence.context_group(@v3)}
          ] do
        assert "response_block_unsupported" in proof.reasons, "#{version}: #{label}"
        assert Enum.sort(Map.keys(proof.extras)) == Enum.sort(group), "#{version}: #{label}"
      end
    end
  end
end
