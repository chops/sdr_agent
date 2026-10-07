defmodule SdrAgent.Agents.Witness.ProjectionTest do
  @moduledoc """
  S12c step 6 / P1: the versioned `claude-message-json/1` projection. It
  re-derives the exact stdin prompt from the stored application request
  with the adapter's own versioned prompt builder, requires exactly that
  final user text (no substring matching) and exactly one parsed JSON
  completion (the adapter's single-fence rule) in a complete SSE stream,
  and never normalises a difference away: changed content is a mismatch,
  unknown shapes are unsupported. An invocation recorded under another or
  no prompt-builder version is unsupported, never re-derived with new code.
  """
  use ExUnit.Case, async: true

  unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
    do: Code.require_file("../../../support/fake_witness_proxy.exs", __DIR__)

  alias SdrAgent.Agents.Witness.Projection
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @prompt "Qualify the fixture lead"
  @answer ~s({"answer":"qualified","score":42})

  setup do
    json_schema = Zoi.to_json_schema(@schema)

    app = %{
      request:
        Jason.encode!(%{
          id: "proj-1",
          operation: "model.complete",
          prompt: @prompt,
          schema: json_schema
        }),
      response: app_response(@answer)
    }

    invocation = %{
      model_id: "claude-opus-5-5",
      model_catalog_entry: ClaudeCLI.provenance().model_catalog_entry
    }

    %{app: app, invocation: invocation, stdin: render(@prompt, json_schema)}
  end

  test "the version names the projection and the prompt builder within S12b bounds" do
    assert version() == "claude-message-json/1+prompt-builder/1"
    assert ClaudeCLI.provenance().model_catalog_entry["prompt_builder"] == "prompt-builder/1"

    # The exact string the reconciler records must pass the accepted S12b
    # evidence validator unchanged (no truncation, no redactor weakening).
    assert {:ok, %{"projection_version" => version}} =
             SdrAgent.Agents.WitnessEvidence.validate(%{"projection_version" => version()})

    assert version == version()
  end

  test "the exact rendered prompt and the same JSON completion match", ctx do
    assert {:match, proof} = compare(ctx, Proxy.messages_request(ctx.stdin), sse(@answer))
    assert proof.reasons == []

    assert proof.digests["projected_request_sha256"] ==
             proof.digests["observed_request_projection_sha256"]

    assert proof.digests["projected_response_sha256"] ==
             proof.digests["observed_response_projection_sha256"]

    assert proof.digests["projected_request_sha256"] == sha(ctx.stdin)

    fenced = "```json\n" <> @answer <> "\n```"
    assert {:match, _} = compare(ctx, Proxy.messages_request(ctx.stdin), sse(fenced))
  end

  test "changed content is a mismatch, never normalised away", ctx do
    for {label, request, response, reason} <- [
          {"edited prompt", Proxy.messages_request(ctx.stdin <> " "), sse(@answer),
           "request_text_differs"},
          {"prompt substring", Proxy.messages_request("x" <> ctx.stdin), sse(@answer),
           "request_text_differs"},
          {"other completion", Proxy.messages_request(ctx.stdin),
           sse(~s({"answer":"disqualified","score":42})), "response_output_differs"},
          {"tool use", Proxy.messages_request(ctx.stdin),
           Proxy.sse_response(@answer, blocks: [{:text, @answer}, {:tool_use, nil}]),
           "response_tool_use"},
          {"prose around JSON", Proxy.messages_request(ctx.stdin), sse("Sure: " <> @answer),
           "response_output_differs"}
        ] do
      result = compare(ctx, request, response)
      assert match?({:mismatch, _}, result), "#{label}: #{inspect(result)}"
      {:mismatch, proof} = result
      assert reason in proof.reasons, "#{label}: #{inspect(proof.reasons)}"
    end
  end

  test "unknown or incomplete shapes are unsupported, not matched", ctx do
    request = Proxy.messages_request(ctx.stdin)

    for {label, request, response, reason} <- [
          {"no message_stop", request, Proxy.sse_response(@answer, stop: false),
           "response_stream_incomplete"},
          {"thinking block", request,
           Proxy.sse_response(@answer, blocks: [{:thinking, nil}, {:text, @answer}]),
           "response_block_unsupported"},
          {"two text blocks", request,
           Proxy.sse_response(@answer, blocks: [{:text, @answer}, {:text, @answer}]),
           "response_block_unsupported"},
          {"not SSE", request, @answer, "response_not_sse"},
          {"extra user block",
           Proxy.messages_request(ctx.stdin,
             blocks: [
               %{"type" => "text", "text" => "<system-reminder>x</system-reminder>"},
               %{"type" => "text", "text" => ctx.stdin}
             ]
           ), sse(@answer), "request_extra_blocks"},
          {"other model", Proxy.messages_request(ctx.stdin, model: "claude-other"), sse(@answer),
           "request_model_differs"},
          {"request not JSON", "not json", sse(@answer), "request_not_json"}
        ] do
      result = compare(ctx, request, response)
      assert match?({:unsupported, _}, result), "#{label}: #{inspect(result)}"
      {:unsupported, proof} = result
      assert reason in proof.reasons, "#{label}: #{inspect(proof.reasons)}"
    end
  end

  test "an invocation under another or no prompt builder is unsupported (P1)", ctx do
    for entry <- [
          Map.delete(ctx.invocation.model_catalog_entry, "prompt_builder"),
          Map.put(ctx.invocation.model_catalog_entry, "prompt_builder", "prompt-builder/0")
        ] do
      historical = %{ctx | invocation: %{ctx.invocation | model_catalog_entry: entry}}

      # Even a differing text is not called a mismatch under an unknown builder.
      assert {:unsupported, proof} =
               compare(historical, Proxy.messages_request("anything"), sse(@answer))

      assert "prompt_builder_unsupported" in proof.reasons
    end
  end

  defp sse(text), do: Proxy.sse_response(text)
  defp sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp app_response(answer) do
    Jason.encode!([
      %{"type" => "system", "subtype" => "init", "model" => "claude-opus-5-5"},
      %{"type" => "result", "subtype" => "success", "is_error" => false, "result" => answer}
    ])
  end

  defp compare(ctx, request, response),
    do: Projection.compare(ctx.invocation, ctx.app, request, response)

  defp version, do: Projection.version()
  defp render(prompt, schema), do: ClaudeCLI.render_prompt(prompt, schema)
end
