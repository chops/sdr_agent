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
end
