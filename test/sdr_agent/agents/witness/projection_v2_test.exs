defmodule SdrAgent.Agents.Witness.ProjectionV2Test do
  @moduledoc """
  S12d projection v2 (`claude-message-json/2+prompt-builder/1`, Codex ruling
  540b562a, entity delta PASS <id>): the real Claude Code request shape —
  one user message holding exactly one non-reminder text block byte-equal
  to the versioned stdin plus at most four exactly wrapped
  `<system-reminder>` blocks, then at most two text-only system-role
  messages; tools present and empty; a top-level key allowlist. Additional
  context is recorded (typed evidence), never claimed equal or benign.
  Response rules are unchanged; thinking stays unsupported.
  """
  use ExUnit.Case, async: true

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.Agents.WitnessEvidence
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @prompt "Qualify the fixture lead"
  @answer ~s({"answer":"qualified","score":42})
  @reminder "<system-reminder>\nToday is a synthetic date.\n</system-reminder>"

  setup do
    json_schema = Zoi.to_json_schema(@schema)

    app = %{
      request:
        Jason.encode!(%{
          id: "p2",
          operation: "model.complete",
          prompt: @prompt,
          schema: json_schema
        }),
      response: Jason.encode!([%{"type" => "result", "result" => @answer}])
    }

    invocation = %{
      model_id: "claude-opus-5-5",
      model_catalog_entry: ClaudeCLI.provenance().model_catalog_entry
    }

    %{app: app, invocation: invocation, stdin: ClaudeCLI.render_prompt(@prompt, json_schema)}
  end

  defp request(ctx, overrides \\ []) do
    Proxy.cli_request(ctx.stdin, Keyword.merge([reminders: [@reminder]], overrides))
  end

  defp compare(ctx, request, response \\ nil),
    do:
      call(:compare_v2, [
        ctx.invocation,
        ctx.app,
        request,
        response || Proxy.sse_response(@answer)
      ])

  # A missing S12d interface fails the scenario's own assertion (RED).
  defp call(function, args) do
    if function_exported?(Projection, function, length(args)),
      do: apply(Projection, function, args),
      else: {:error, {:not_implemented, function}}
  end

  test "the v2 version fits the S12b evidence bound" do
    assert call(:version_v2, []) == "claude-message-json/2+prompt-builder/1"

    assert {:ok, _} =
             WitnessEvidence.validate(%{
               "projection_version" => "claude-message-json/2+prompt-builder/1"
             })
  end

  test "the observed CLI shape matches and records its additional context", ctx do
    assert {:match, proof} = compare(ctx, request(ctx))
    assert "cli_injected_context" in proof.reasons

    assert proof.digests["projected_request_sha256"] ==
             proof.digests["observed_request_projection_sha256"]

    extras = proof.extras

    assert Enum.sort(Map.keys(extras)) ==
             Enum.sort(~w(reminder_count reminder_sha256s reminder_bytes
             trailing_system_count trailing_system_sha256s trailing_system_bytes request_extras_sha256
             request_fields))

    assert extras["reminder_count"] == 1
    assert extras["reminder_bytes"] == [byte_size(@reminder)]
    assert [_] = extras["reminder_sha256s"]
    assert extras["trailing_system_count"] == 1
    assert extras["request_extras_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert "thinking_present" in extras["request_fields"]
    assert {:ok, _} = WitnessEvidence.validate(extras)
  end

  test "zero counts, duplicate positions and present/null fields are recorded exactly", ctx do
    assert {:match, zero} = compare(ctx, request(ctx, reminders: [], trailing: 0))
    assert zero.extras["reminder_count"] == 0 and zero.extras["reminder_sha256s"] == []

    assert zero.extras["trailing_system_count"] == 0 and
             zero.extras["trailing_system_bytes"] == []

    assert {:match, dup} = compare(ctx, request(ctx, reminders: [@reminder, @reminder]))
    assert [same, same] = dup.extras["reminder_sha256s"]

    assert {:match, nulls} =
             compare(
               ctx,
               Proxy.cli_request(ctx.stdin, top: %{"thinking" => nil})
               |> drop_key("output_config")
             )

    assert nulls.extras["request_fields"] == [
             "system_present",
             "thinking_present",
             "thinking_null",
             "context_management_present"
           ]

    refute nulls.extras["request_extras_sha256"] == dup.extras["request_extras_sha256"]
  end

  test "a different sole application text is a mismatch", ctx do
    assert {:mismatch, proof} =
             compare(ctx, Proxy.cli_request(ctx.stdin <> " ", reminders: [@reminder]))

    assert "request_text_differs" in proof.reasons
  end

  test "shapes outside the grammar are unsupported, never a match", ctx do
    big = "<system-reminder>" <> String.duplicate("x", 8192) <> "</system-reminder>"

    for {label, req} <- [
          {"stdin only inside a reminder",
           Proxy.cli_request("<system-reminder>" <> ctx.stdin <> "</system-reminder>",
             reminders: []
           )},
          {"two non-reminder blocks", request(ctx, extra_user_texts: ["hello"])},
          {"five reminders", request(ctx, reminders: List.duplicate(@reminder, 5))},
          {"oversized reminder", request(ctx, reminders: [big])},
          {"reminder without closing tag", request(ctx, reminders: ["<system-reminder> open"])},
          {"tools present", request(ctx, tools: [%{"name" => "Read"}])},
          {"tools absent", request(ctx, tools: :absent)},
          {"unknown top-level key", request(ctx, top: %{"temperature" => 1})},
          {"assistant turn",
           request(ctx, extra_messages: [%{"role" => "assistant", "content" => "x"}])},
          {"three trailing system messages", request(ctx, trailing: 3)},
          {"cache_control on user block", request(ctx, user_cache_control: true)},
          {"image block", request(ctx, user_blocks_extra: [%{"type" => "image"}])},
          {"stream false", request(ctx, top: %{"stream" => false})}
        ] do
      result = compare(ctx, req)

      assert match?({:unsupported, _}, result) or match?({:mismatch, _}, result),
             "#{label}: #{inspect(result)}"

      refute match?({:match, _}, result), label
    end
  end

  test "thinking in the response stays unsupported under v2", ctx do
    for blocks <- [
          [{:thinking, nil}, {:text, @answer}],
          [{:redacted_thinking, nil}, {:text, @answer}]
        ] do
      assert {:unsupported, _} =
               compare(ctx, request(ctx), Proxy.sse_response(@answer, blocks: blocks))
    end
  end

  test "evidence contract: counts must equal list lengths and keys come together" do
    good = %{
      "reminder_count" => 1,
      "reminder_sha256s" => [String.duplicate("a1", 32)],
      "reminder_bytes" => [10],
      "trailing_system_count" => 0,
      "trailing_system_sha256s" => [],
      "trailing_system_bytes" => [],
      "request_extras_sha256" => String.duplicate("b2", 32),
      "request_fields" => ["thinking_present"]
    }

    assert {:ok, _} = WitnessEvidence.validate(good)

    zero = %{good | "reminder_count" => 0, "reminder_sha256s" => [], "reminder_bytes" => []}
    assert {:ok, _} = WitnessEvidence.validate(zero)

    max = %{
      good
      | "reminder_count" => 4,
        "reminder_sha256s" => List.duplicate(String.duplicate("c3", 32), 4),
        "reminder_bytes" => [0, 8192, 8192, 1],
        "trailing_system_count" => 2,
        "trailing_system_sha256s" => List.duplicate(String.duplicate("d4", 32), 2),
        "trailing_system_bytes" => [32_768, 0]
    }

    assert {:ok, _} = WitnessEvidence.validate(max)

    for {label, bad} <- [
          {"count mismatch", %{good | "reminder_count" => 2}},
          {"bytes length mismatch", %{good | "reminder_bytes" => [1, 2]}},
          {"partial set", Map.delete(good, "request_extras_sha256")},
          {"bad digest", %{good | "reminder_sha256s" => ["XYZ"]}},
          {"too many reminders", %{good | "reminder_count" => 5}},
          {"oversized bytes", %{good | "reminder_bytes" => [9000]}},
          {"unknown field code", %{good | "request_fields" => ["temperature_present"]}},
          {"field codes out of order",
           %{good | "request_fields" => ["thinking_present", "system_present"]}},
          {"duplicate field code",
           %{good | "request_fields" => ["system_present", "system_present"]}},
          {"null without present", %{good | "request_fields" => ["thinking_null"]}},
          {"negative bytes", %{good | "reminder_bytes" => [-1]}},
          {"secret-shaped digest slot",
           %{good | "request_extras_sha256" => "sk-" <> String.duplicate("a", 40)}}
        ] do
      assert match?({:error, _}, WitnessEvidence.validate(bad)), label
    end
  end

  defp drop_key(json, key), do: json |> JSON.decode!() |> Map.delete(key) |> JSON.encode!()
end
