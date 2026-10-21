defmodule SdrAgent.Agents.Witness.Projection do
  @moduledoc """
  The versioned `claude-message-json/1` projection of one ClaudeCLI model
  call onto one observed Anthropic Messages exchange (S12 step 6, P1;
  ADR-0005 S12 amendment). Version: `version/0`, which also names the
  ClaudeCLI prompt builder it re-derives the request with.

  Request: the stored application request (`id`, `operation`, `prompt`,
  `schema`) is re-rendered with `ClaudeCLI.render_prompt/2` — only when the
  invocation recorded exactly that builder version; otherwise the result is
  `:unsupported` (`prompt_builder_unsupported`), never a mismatch and never
  a re-derivation with new code. The observed request's final message must
  be a `user` message whose content holds exactly that text as its only
  text block (no substring matching).

  Response: a complete SSE stream (`message_stop`) with exactly one text
  content block; its text, through the adapter's single-fence rule, must
  decode to the same JSON object as the application's recorded result.

  Never normalises a difference away: different text or output, or a
  `tool_use` block, is `:mismatch`; any other unexpected shape (extra
  blocks, thinking, a different model, non-SSE) is `:unsupported`. The
  digests compare the expected and observed projections (sha256 of the
  prompt text and of the canonical output); whole-wire equality is never
  claimed.

  Versions 2 and 3 (`compare_v2/4`, `compare_v3/4`; ADR-0005 S12d) read the
  real Claude Code request shape. They record the additional CLI context
  as a typed evidence group, which is never claimed equal or benign. v3 is
  v2 plus a reminder that ends with its close tag and one LF,
  `cache_control` ttl `"1h"`, and a message-level `output_config`. For both
  versions, `extras: nil` means that the request is outside the grammar, so
  the version does not apply.

  Version 4 (`compare_v4/4`; ADR-0005 response-layout amendment, D-182) is
  v3's request contract and prompt-builder guard, unchanged, plus a
  response of 1 to 4 leading `thinking` / `redacted_thinking` blocks in
  total, then exactly one `text` block, with nothing after it. It is
  evaluated only where v3's response-layout refusal applies (a v3 request
  `:match`, the current builder, a decodable application output, a stream
  the shared parser accepts, no `tool_use`, a block list other than one
  text block); otherwise it is `:ineligible` and v3's result stands. The
  stream first passes the unchanged shared parser; a v4-only walk over the
  decoded events then checks each reasoning block syntactically (no local
  authentication, decryption or benignity claim). Its evidence adds only a
  closed layout label and, for an admitted layout, block counts: no
  reasoning text, signature, encrypted data or per-block digest.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit.Canonical

  @version "claude-message-json/1+prompt-builder/1"

  @type verdict :: :match | :mismatch | :unsupported
  @type proof :: %{reasons: [String.t()], digests: %{String.t() => String.t()}}

  @doc "The projection version recorded as link evidence."
  def version, do: @version

  @doc """
  Compares one invocation (`model_id`, `model_catalog_entry`) and its stored
  application payloads (`%{request:, response:}`) with the observed raw
  request and response bodies. Returns `{verdict, proof}`.
  """
  @spec compare(map(), map(), binary(), binary()) :: {verdict(), proof()}
  def compare(invocation, app, raw_request, raw_response) do
    builder = Map.get(invocation.model_catalog_entry || %{}, "prompt_builder")

    if builder == ClaudeCLI.prompt_builder() do
      request = compare_request(invocation, app.request, raw_request)
      response = compare_response(app.response, raw_response)
      combine(request, response)
    else
      {:unsupported, %{reasons: ["prompt_builder_unsupported"], digests: %{}}}
    end
  end

  defp combine(
         {request_verdict, request_reasons, request_digests},
         {response_verdict, response_reasons, response_digests}
       ) do
    reasons = Enum.uniq(request_reasons ++ response_reasons)
    digests = Map.merge(request_digests, response_digests)

    verdict =
      cond do
        :mismatch in [request_verdict, response_verdict] -> :mismatch
        :unsupported in [request_verdict, response_verdict] -> :unsupported
        true -> :match
      end

    {verdict, %{reasons: reasons, digests: digests}}
  end

  ## Request

  defp compare_request(invocation, app_request, raw_request) do
    with {:ok, %{"prompt" => prompt, "schema" => schema}}
         when is_binary(prompt) and is_map(schema) <-
           Jason.decode(app_request),
         expected = ClaudeCLI.render_prompt(prompt, schema),
         {:ok, %{} = observed} <- decode_request(raw_request) do
      expected_digest = %{"projected_request_sha256" => sha(expected)}
      request_shape(invocation, observed, expected, expected_digest)
    else
      {:error, :request_not_json} -> {:unsupported, ["request_not_json"], %{}}
      _ -> {:unsupported, ["app_request_unreadable"], %{}}
    end
  end

  defp decode_request(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = request} -> {:ok, request}
      _ -> {:error, :request_not_json}
    end
  end

  defp request_shape(invocation, observed, expected, digests) do
    texts = final_user_texts(observed)

    cond do
      texts == :unsupported ->
        {:unsupported, ["request_shape_unsupported"], digests}

      observed["model"] != invocation.model_id ->
        {:unsupported, ["request_model_differs"], digests}

      texts == [expected] ->
        {:match, [], Map.put(digests, "observed_request_projection_sha256", sha(expected))}

      expected in texts ->
        {:unsupported, ["request_extra_blocks"], digests}

      match?([_], texts) ->
        [text] = texts

        {:mismatch, ["request_text_differs"],
         Map.put(digests, "observed_request_projection_sha256", sha(text))}

      true ->
        {:mismatch, ["request_text_differs"], digests}
    end
  end

  # Text blocks of the final message when it is a user message; :unsupported
  # for any non-text block or another shape.
  defp final_user_texts(%{"messages" => messages}) when is_list(messages) and messages != [] do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) ->
        [content]

      %{"role" => "user", "content" => blocks} when is_list(blocks) ->
        if Enum.all?(
             blocks,
             &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)
           ),
           do: Enum.map(blocks, & &1["text"]),
           else: :unsupported

      _ ->
        :unsupported
    end
  end

  defp final_user_texts(_request), do: :unsupported

  ## Response

  defp compare_response(app_response, raw_response) do
    case app_output(app_response) do
      {:ok, expected} ->
        expected_digest = %{"projected_response_sha256" => sha(Canonical.encode!(expected))}
        compare_output(expected, expected_digest, sse_text(raw_response))

      :error ->
        {:unsupported, ["app_response_unreadable"], %{}}
    end
  end

  defp compare_output(expected, expected_digest, {:ok, text}) do
    observed = decode_output(text)
    observed_digest = sha(Canonical.encode!(observed || %{"unparsable" => text}))
    digests = Map.put(expected_digest, "observed_response_projection_sha256", observed_digest)

    if observed == expected,
      do: {:match, [], digests},
      else: {:mismatch, ["response_output_differs"], digests}
  end

  defp compare_output(_expected, expected_digest, {verdict, reason}),
    do: {verdict, [reason], expected_digest}

  # The application's recorded result: the CLI stream's `result` event,
  # through the same single-fence rule as the adapter.
  defp app_output(app_response) when is_binary(app_response) do
    with {:ok, events} when is_list(events) <- Jason.decode(app_response),
         %{"result" => result} when is_binary(result) <-
           Enum.find(events, &match?(%{"type" => "result"}, &1)),
         output when is_map(output) <- decode_output(result) do
      {:ok, output}
    else
      _ -> :error
    end
  end

  defp app_output(_response), do: :error

  defp decode_output(text) do
    case text |> ClaudeCLI.unfence() |> Jason.decode() do
      {:ok, output} when is_map(output) -> output
      _ -> nil
    end
  end

  # Validates the complete Anthropic event sequence before any text is
  # trusted: message_start first; content blocks strictly in index order,
  # each start → deltas of its own index and type → stop; one message_delta;
  # message_stop last and once. `ping` is allowed between events; any other
  # (including `error`) or malformed event refuses the stream.
  defp sse_text(raw) do
    with {:ok, events} <- sse_events(raw) do
      events = Enum.reject(events, &(&1["type"] == "ping"))

      case sequence(events) do
        {:ok, blocks} -> stream_blocks(blocks)
        {:error, reason} -> {:unsupported, reason}
      end
    end
  end

  defp stream_blocks(blocks) do
    types = Enum.map(blocks, & &1.type)

    cond do
      "tool_use" in types -> {:mismatch, "response_tool_use"}
      types == ["text"] -> {:ok, hd(blocks).text}
      true -> {:unsupported, "response_block_unsupported"}
    end
  end

  defp sequence([%{"type" => "message_start", "message" => %{}} | rest]), do: blocks(rest, [])
  defp sequence(_events), do: {:error, "response_stream_invalid"}

  defp blocks(
         [
           %{
             "type" => "content_block_start",
             "index" => index,
             "content_block" => %{"type" => type}
           }
           | rest
         ],
         acc
       )
       when index == length(acc) and is_binary(type) do
    with {:ok, text, rest} <- block_body(rest, index, type, []) do
      blocks(rest, acc ++ [%{type: type, text: text}])
    end
  end

  defp blocks([%{"type" => "message_delta", "delta" => %{}} | rest], acc), do: finish(rest, acc)
  defp blocks([], _acc), do: {:error, "response_stream_incomplete"}
  defp blocks(_events, _acc), do: {:error, "response_stream_invalid"}

  defp block_body(
         [%{"type" => "content_block_stop", "index" => index} | rest],
         index,
         _type,
         parts
       ),
       do: {:ok, parts |> Enum.reverse() |> Enum.join(), rest}

  defp block_body(
         [%{"type" => "content_block_delta", "index" => index, "delta" => delta} | rest],
         index,
         type,
         parts
       ) do
    case {type, delta} do
      {"text", %{"type" => "text_delta", "text" => text}} when is_binary(text) ->
        block_body(rest, index, type, [text | parts])

      {"tool_use", %{"type" => "input_json_delta", "partial_json" => json}}
      when is_binary(json) ->
        block_body(rest, index, type, parts)

      {"thinking", %{"type" => kind}} when kind in ["thinking_delta", "signature_delta"] ->
        block_body(rest, index, type, parts)

      _ ->
        {:error, "response_stream_invalid"}
    end
  end

  defp block_body([], _index, _type, _parts), do: {:error, "response_stream_incomplete"}
  defp block_body(_events, _index, _type, _parts), do: {:error, "response_stream_invalid"}

  defp finish([%{"type" => "message_stop"}], acc), do: {:ok, acc}
  defp finish([], _acc), do: {:error, "response_stream_incomplete"}
  defp finish(_events, _acc), do: {:error, "response_stream_invalid"}

  defp sse_events(raw) when is_binary(raw) do
    frames = raw |> String.split(~r/\r?\n\r?\n/, trim: true)

    events =
      Enum.map(frames, fn frame ->
        data =
          frame
          |> String.split(~r/\r?\n/)
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map_join(
            "\n",
            &(&1 |> String.replace_prefix("data:", "") |> String.trim_leading())
          )

        case Jason.decode(data) do
          {:ok, %{"type" => _} = event} -> event
          _ -> nil
        end
      end)

    if events != [] and Enum.all?(events, &is_map/1),
      do: {:ok, events},
      else: {:unsupported, "response_not_sse"}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  ## Projection v2 (S12d; entity PASS f04a7e44)

  @version_v2 "claude-message-json/2+prompt-builder/1"
  @top_keys ~w(model max_tokens messages metadata stream system thinking tools context_management output_config)
  @control_fields ~w(system thinking output_config context_management)
  @reminder_open "<system-reminder>"
  @reminder_close "</system-reminder>"
  @max_reminders 4
  @max_reminder_bytes 8192
  @max_trailing 2
  @max_trailing_blocks 4
  @max_trailing_bytes 32_768

  # v3 (entity PASS 9343defb): v2 plus exactly three bounded relaxations.
  @version_v3 "claude-message-json/3+prompt-builder/1"
  # v4 (D-182, plan r5 section 6): v3's request plus the bounded reasoning layout.
  @version_v4 "claude-message-json/4+prompt-builder/1"
  @max_reasoning 4
  @cache_ttls ["1h"]

  @doc "The v2 projection version (CLI request shape with recorded context)."
  def version_v2, do: @version_v2

  @doc """
  The v3 projection version: v2, plus a reminder that ends with its close tag
  and one LF, `cache_control` ttl `"1h"`, and a message-level `output_config`
  on trailing system messages.
  """
  def version_v3, do: @version_v3

  @doc """
  The v4 projection version: v3's request contract plus 1 to 4 leading
  reasoning blocks, then exactly one text block (D-182).
  """
  def version_v4, do: @version_v4

  @doc """
  The supported projection ids of the current ClaudeCLI prompt builder
  (R0-07 slice B, row B2): the literal registry ids `version/0`,
  `version_v2/0`, `version_v3/0` and `version_v4/0` whose builder is
  `ClaudeCLI.prompt_builder/0`. Admission compares an allowlist entry's
  `projection_version` with these ids exactly, never by substring.
  """
  def current_versions do
    builder = "+" <> ClaudeCLI.prompt_builder()

    for version <- [@version, @version_v2, @version_v3, @version_v4],
        String.ends_with?(version, builder),
        do: version
  end

  @doc """
  v2 comparison. Like `compare/4`, plus `proof.extras` — the typed
  WitnessEvidence context group (present on every evaluated v2 result).
  """
  def compare_v2(invocation, app, raw_request, raw_response),
    do: compare_cli(:v2, invocation, app, raw_request, raw_response)

  @doc """
  v3 comparison, with the same result shape as `compare_v2/4`. `proof.extras`
  is the 9-key v3 group, which adds `trailing_output_config`. `extras: nil`
  means that the request is outside the grammar, so v3 does not apply.
  """
  def compare_v3(invocation, app, raw_request, raw_response),
    do: compare_cli(:v3, invocation, app, raw_request, raw_response)

  @doc """
  v4 comparison (D-182; plan r5 sections 6.1 and 6.2). `:ineligible` unless
  every one of these holds, re-derived structurally: (a) the recorded
  prompt builder is the current one; (b) the v3 request verdict is
  `:match`; (c) the application output decodes; (d) the shared parser
  accepts the raw stream; (e) its block types are not `["text"]`; (f) it
  has no `tool_use`. These are exactly the conditions of v3's
  `response_block_unsupported`.

  Otherwise `{verdict, %{reasons:, digests:, extras:}}`: `extras` is the
  complete v3 request group plus `response_layout` and, only for
  `reasoning_then_text`, `response_thinking_count` and
  `response_redacted_thinking_count`. `reasoning_then_text` compares its
  one text block like v3 (`:match` or `:mismatch`,
  `response_output_differs`); every other layout is `:unsupported` with
  exactly one code, `"response_" <> layout`. Layout precedence:
  `block_type_unsupported`, `reasoning_unparsed`, `text_count_invalid`,
  `block_after_text`, `reasoning_overflow`, then `reasoning_then_text`.
  """
  def compare_v4(invocation, app, raw_request, raw_response) do
    builder = Map.get(invocation.model_catalog_entry || %{}, "prompt_builder")

    with true <- builder == ClaudeCLI.prompt_builder(),
         {:match, [], request_digests, %{} = extras} <-
           compare_request_v2(:v3, invocation, app.request, raw_request),
         {:ok, expected} <- app_output(app.response),
         {:ok, events} <- v4_events(raw_response) do
      expected_digest = %{"projected_response_sha256" => sha(Canonical.encode!(expected))}
      {layout, response} = v4_response(v4_blocks(events), expected, expected_digest)
      {verdict, proof} = combine({:match, [], request_digests}, response)
      extras = Map.merge(extras, layout)
      {verdict, proof |> Map.put(:extras, extras) |> add_reason(extras)}
    else
      _ineligible -> :ineligible
    end
  end

  # (d)-(f): the shared parser accepts the stream, which is not exactly one
  # text block and has no tool_use. Returns the decoded events (pings out).
  defp v4_events(raw) do
    with {:ok, events} <- sse_events(raw),
         events = Enum.reject(events, &(&1["type"] == "ping")),
         {:ok, blocks} <- sequence(events),
         types = Enum.map(blocks, & &1.type),
         true <- types != ["text"] and "tool_use" not in types do
      {:ok, events}
    else
      _ -> :ineligible
    end
  end

  # The v4-only walk over the decoded (already sequence-validated) events:
  # each block's exact start `content_block` and its delta maps.
  defp v4_blocks([%{"type" => "message_start"} | rest]), do: v4_blocks(rest, [])

  defp v4_blocks([%{"type" => "content_block_start", "content_block" => start} | rest], acc) do
    {deltas, [_stop | rest]} = Enum.split_while(rest, &(&1["type"] == "content_block_delta"))
    v4_blocks(rest, [{start["type"], start, Enum.map(deltas, & &1["delta"])} | acc])
  end

  defp v4_blocks(_rest, acc), do: Enum.reverse(acc)

  defp v4_response(blocks, expected, expected_digest) do
    case v4_layout(blocks) do
      {:ok, text, thinking, redacted} ->
        {verdict, reasons, digests} = compare_output(expected, expected_digest, {:ok, text})

        {%{
           "response_layout" => "reasoning_then_text",
           "response_thinking_count" => thinking,
           "response_redacted_thinking_count" => redacted
         }, {verdict, reasons, digests}}

      layout ->
        {%{"response_layout" => layout}, {:unsupported, ["response_" <> layout], expected_digest}}
    end
  end

  defp v4_layout(blocks) do
    types = Enum.map(blocks, &elem(&1, 0))
    texts = Enum.count(types, &(&1 == "text"))
    reasoning = Enum.count(types, &(&1 in ["thinking", "redacted_thinking"]))

    cond do
      Enum.any?(types, &(&1 not in ["thinking", "redacted_thinking", "text"])) ->
        "block_type_unsupported"

      not Enum.all?(blocks, &reasoning_valid?/1) ->
        "reasoning_unparsed"

      texts != 1 ->
        "text_count_invalid"

      List.last(types) != "text" ->
        "block_after_text"

      reasoning > @max_reasoning ->
        "reasoning_overflow"

      true ->
        {"text", _start, deltas} = List.last(blocks)
        text = Enum.map_join(deltas, & &1["text"])

        {:ok, text, Enum.count(types, &(&1 == "thinking")),
         Enum.count(types, &(&1 == "redacted_thinking"))}
    end
  end

  # Syntactic checks only. thinking: the exact empty start, zero or more
  # string thinking deltas, then one or more string signature deltas with a
  # non-empty combined value. redacted_thinking: exactly {type, data} with a
  # string `data` and no deltas.
  defp reasoning_valid?({"thinking", start, deltas}),
    do:
      start == %{"type" => "thinking", "thinking" => "", "signature" => ""} and
        thinking_phase(deltas)

  defp reasoning_valid?({"redacted_thinking", start, deltas}),
    do:
      deltas == [] and Enum.sort(Map.keys(start)) == ["data", "type"] and
        is_binary(start["data"])

  defp reasoning_valid?(_text), do: true

  defp thinking_phase([%{"type" => "thinking_delta", "thinking" => text} = delta | rest])
       when is_binary(text) and map_size(delta) == 2,
       do: thinking_phase(rest)

  defp thinking_phase(deltas), do: signature_phase(deltas, [])

  defp signature_phase([%{"type" => "signature_delta", "signature" => part} = delta | rest], acc)
       when is_binary(part) and map_size(delta) == 2,
       do: signature_phase(rest, [part | acc])

  defp signature_phase([], [_ | _] = parts), do: Enum.join(parts) != ""
  defp signature_phase(_deltas, _parts), do: false

  defp compare_cli(grammar, invocation, app, raw_request, raw_response) do
    builder = Map.get(invocation.model_catalog_entry || %{}, "prompt_builder")

    if builder == ClaudeCLI.prompt_builder() do
      case compare_request_v2(grammar, invocation, app.request, raw_request) do
        # Outside the v2 grammar, v2 does not apply at all (whatever the response).
        {:unsupported, reasons, digests, _extras} ->
          {:unsupported, %{reasons: reasons, digests: digests, extras: nil}}

        {verdict, reasons, digests, extras} ->
          response = compare_response(app.response, raw_response)
          {verdict, proof} = combine({verdict, reasons, digests}, response)
          {verdict, proof |> Map.put(:extras, extras) |> add_reason(extras)}
      end
    else
      {:unsupported, %{reasons: ["prompt_builder_unsupported"], digests: %{}, extras: nil}}
    end
  end

  defp add_reason(proof, %{
         "reminder_count" => r,
         "trailing_system_count" => t,
         "request_fields" => f
       })
       when r > 0 or t > 0 or f != [],
       do: %{proof | reasons: Enum.uniq(proof.reasons ++ ["cli_injected_context"])}

  defp add_reason(proof, _extras), do: proof

  # {verdict, reasons, digests, extras | nil}
  defp compare_request_v2(grammar, invocation, app_request, raw_request) do
    with {:ok, %{"prompt" => prompt, "schema" => schema}}
         when is_binary(prompt) and is_map(schema) <-
           Jason.decode(app_request),
         expected = ClaudeCLI.render_prompt(prompt, schema),
         {:ok, %{} = observed} <- decode_request(raw_request) do
      digests = %{"projected_request_sha256" => sha(expected)}
      v2_verdict(v2_grammar(grammar, invocation, observed), expected, digests)
    else
      {:error, :request_not_json} -> {:unsupported, ["request_not_json"], %{}, nil}
      _ -> {:unsupported, ["app_request_unreadable"], %{}, nil}
    end
  end

  defp v2_verdict({:ok, text, extras}, expected, digests) do
    digests = Map.put(digests, "observed_request_projection_sha256", sha(text))

    if text == expected,
      do: {:match, [], digests, extras},
      else: {:mismatch, ["request_text_differs"], digests, extras}
  end

  defp v2_verdict({:unsupported, reason}, _expected, digests),
    do: {:unsupported, [reason], digests, nil}

  defp v2_grammar(grammar, invocation, request) do
    with :ok <- check(Enum.all?(Map.keys(request), &(&1 in @top_keys)), "request_key_unsupported"),
         :ok <- check(request["model"] == invocation.model_id, "request_model_differs"),
         :ok <- check(request["stream"] == true, "request_shape_unsupported"),
         :ok <- check(Map.get(request, "tools", :absent) == [], "request_tools_present"),
         :ok <- check(controls_valid?(request, grammar), "request_control_unsupported"),
         {:ok, user, trailing} <- split_messages(request["messages"], grammar),
         {:ok, text, reminders} <- user_blocks(user, grammar),
         {:ok, trailing} <- trailing_messages(trailing, grammar) do
      {:ok, text, extras(request, reminders, trailing, grammar)}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(_false, reason), do: {:unsupported, reason}

  defp split_messages([%{"role" => "user", "content" => content} = first | rest], grammar)
       when is_list(content) and length(rest) <= @max_trailing do
    if map_size(first) == 2 and Enum.all?(rest, &trailing_message?(&1, grammar)),
      do: {:ok, content, rest},
      else: {:unsupported, "request_shape_unsupported"}
  end

  defp split_messages(_messages, _grammar), do: {:unsupported, "request_shape_unsupported"}

  # Message keys: exactly {role, content}; v3 also admits a message-level
  # output_config of the top-level shape (absent, null or {effort}).
  defp trailing_message?(%{"role" => "system", "content" => c} = message, grammar)
       when is_list(c) do
    case {map_size(message), grammar} do
      {2, _} ->
        true

      {3, :v3} ->
        Map.has_key?(message, "output_config") and valid_output_config?(message["output_config"])

      _ ->
        false
    end
  end

  defp trailing_message?(_message, _grammar), do: false

  # Exactly one non-reminder text block; reminders exactly wrapped and capped.
  defp user_blocks(blocks, grammar) do
    if Enum.all?(
         blocks,
         &(match?(%{"type" => "text", "text" => t} when is_binary(t), &1) and map_size(&1) == 2)
       ) do
      indexed = Enum.with_index(blocks, fn %{"text" => text}, i -> {i, text} end)
      {reminders, others} = Enum.split_with(indexed, fn {_i, t} -> reminder?(t, grammar) end)

      cond do
        length(others) != 1 ->
          {:unsupported, "request_extra_blocks"}

        length(reminders) > @max_reminders ->
          {:unsupported, "request_reminders_unsupported"}

        Enum.any?(reminders, fn {_i, t} -> byte_size(t) > @max_reminder_bytes end) ->
          {:unsupported, "request_reminders_unsupported"}

        true ->
          {:ok, others |> hd() |> elem(1), reminders}
      end
    else
      {:unsupported, "request_shape_unsupported"}
    end
  end

  # v2: ends exactly with the close tag. v3 also admits the close tag plus
  # exactly one LF (no CRLF, no other whitespace). The recorded digest and
  # byte count always cover the original complete text.
  defp reminder?(text, grammar) do
    minimum = byte_size(@reminder_open) + byte_size(@reminder_close)

    String.starts_with?(text, @reminder_open) and
      ((String.ends_with?(text, @reminder_close) and byte_size(text) >= minimum) or
         (grammar == :v3 and String.ends_with?(text, @reminder_close <> "\n") and
            byte_size(text) >= minimum + 1))
  end

  defp trailing_messages(messages, grammar) do
    # Shape and cardinality are checked before any sizing, so malformed wire
    # data is unsupported rather than an exception.
    Enum.reduce_while(Enum.with_index(messages, 1), {:ok, []}, fn {%{"content" => blocks} =
                                                                     message, index},
                                                                  {:ok, acc} ->
      with true <- length(blocks) in 1..@max_trailing_blocks,
           true <- Enum.all?(blocks, &system_block?(&1, grammar)),
           bytes = blocks |> Enum.map(&byte_size(&1["text"])) |> Enum.sum(),
           true <- bytes <= @max_trailing_bytes do
        {:cont, {:ok, acc ++ [{index, blocks, bytes, Map.fetch(message, "output_config")}]}}
      else
        _ -> {:halt, {:unsupported, "request_trailing_unsupported"}}
      end
    end)
  end

  defp system_block?(%{"type" => "text", "text" => text} = block, grammar)
       when is_binary(text) do
    case Map.drop(block, ["type", "text"]) do
      empty when map_size(empty) == 0 -> true
      %{"cache_control" => cc} when map_size(block) == 3 -> cache_control?(cc, grammar)
      _ -> false
    end
  end

  defp system_block?(_block, _grammar), do: false

  # Exactly {type: ephemeral}; v3 also {type: ephemeral, ttl} with a reviewed ttl.
  defp cache_control?(%{"type" => "ephemeral"} = cc, _grammar) when map_size(cc) == 1, do: true

  defp cache_control?(%{"type" => "ephemeral", "ttl" => ttl} = cc, :v3) when map_size(cc) == 2,
    do: ttl in @cache_ttls

  defp cache_control?(_cc, _grammar), do: false

  defp controls_valid?(request, grammar) do
    valid_max_tokens?(Map.get(request, "max_tokens", 1)) and
      valid_metadata?(Map.get(request, "metadata", %{})) and
      valid_system?(Map.get(request, "system", []), grammar) and
      valid_thinking?(Map.get(request, "thinking")) and
      valid_output_config?(Map.get(request, "output_config", %{})) and
      valid_context_management?(Map.get(request, "context_management", %{}))
  end

  defp valid_max_tokens?(n), do: is_integer(n) and n > 0
  defp valid_metadata?(nil), do: true
  defp valid_metadata?(m), do: is_map(m) and Enum.all?(Map.keys(m), &(&1 == "user_id"))
  defp valid_system?(nil, _grammar), do: true

  defp valid_system?(blocks, grammar) when is_list(blocks) do
    length(blocks) <= 8 and Enum.all?(blocks, &system_block?(&1, grammar)) and
      blocks |> Enum.map(&byte_size(&1["text"])) |> Enum.sum() <= 262_144
  end

  defp valid_system?(_blocks, _grammar), do: false
  defp valid_thinking?(nil), do: true

  defp valid_thinking?(%{} = t),
    do:
      Enum.all?(Map.keys(t), &(&1 in ~w(type budget_tokens display))) and
        Map.get(t, "type") in ["adaptive", "enabled", "disabled"]

  defp valid_thinking?(_), do: false
  defp valid_output_config?(nil), do: true

  defp valid_output_config?(%{} = o),
    do:
      Enum.all?(Map.keys(o), &(&1 == "effort")) and
        (not Map.has_key?(o, "effort") or
           (is_binary(o["effort"]) and byte_size(o["effort"]) <= 16))

  defp valid_output_config?(_), do: false
  defp valid_context_management?(nil), do: true

  defp valid_context_management?(%{} = c) do
    Enum.all?(Map.keys(c), &(&1 == "edits")) and
      (not Map.has_key?(c, "edits") or
         (is_list(c["edits"]) and length(c["edits"]) <= 16 and Enum.all?(c["edits"], &is_map/1))) and
      byte_size(Canonical.encode!(c)) <= 16_384
  end

  defp valid_context_management?(_), do: false

  defp extras(request, reminders, trailing, grammar) do
    fields = request_fields(request)

    reminder_entries =
      Enum.map(reminders, fn {i, t} ->
        %{"block_index" => i, "sha256" => sha(t), "bytes" => byte_size(t)}
      end)

    trailing_entries =
      Enum.map(trailing, fn {i, blocks, bytes, control} ->
        entry = %{
          "message_index" => i,
          "sha256" => sha(Canonical.encode!(blocks)),
          "bytes" => bytes
        }

        if grammar == :v3, do: Map.put(entry, "output_config", tagged(control)), else: entry
      end)

    manifest = %{
      "version" => if(grammar == :v3, do: 3, else: 2),
      "request_fields" => fields,
      "fields" =>
        Map.new(@control_fields, fn f ->
          {f,
           if(Map.has_key?(request, f),
             do: %{"present" => true, "value" => request[f]},
             else: %{"present" => false}
           )}
        end),
      "reminders" => reminder_entries,
      "trailing_system" => trailing_entries
    }

    %{
      "reminder_count" => length(reminder_entries),
      "reminder_sha256s" => Enum.map(reminder_entries, & &1["sha256"]),
      "reminder_bytes" => Enum.map(reminder_entries, & &1["bytes"]),
      "trailing_system_count" => length(trailing_entries),
      "trailing_system_sha256s" => Enum.map(trailing_entries, & &1["sha256"]),
      "trailing_system_bytes" => Enum.map(trailing_entries, & &1["bytes"]),
      "request_extras_sha256" => sha(Canonical.encode!(manifest)),
      "request_fields" => fields
    }
    |> put_v3_controls(trailing, grammar)
  end

  defp put_v3_controls(extras, trailing, :v3) do
    codes =
      Enum.map(trailing, fn
        {_i, _blocks, _bytes, :error} -> "absent"
        {_i, _blocks, _bytes, {:ok, nil}} -> "null"
        {_i, _blocks, _bytes, {:ok, _value}} -> "present"
      end)

    Map.put(extras, "trailing_output_config", codes)
  end

  defp put_v3_controls(extras, _trailing, _grammar), do: extras

  # Tagged presence (manifest v3): absent is distinct from JSON null.
  defp tagged(:error), do: %{"present" => false}
  defp tagged({:ok, value}), do: %{"present" => true, "value" => value}

  defp request_fields(request) do
    Enum.flat_map(@control_fields, fn f ->
      cond do
        not Map.has_key?(request, f) -> []
        is_nil(request[f]) -> ["#{f}_present", "#{f}_null"]
        true -> ["#{f}_present"]
      end
    end)
  end
end
