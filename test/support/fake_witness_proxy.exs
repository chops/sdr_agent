defmodule SdrAgent.Test.FakeWitnessProxy do
  @moduledoc """
  Hermetic stand-in for the S12a `llm-otel-proxy` witness store (nix-darwin
  PR #6, protocol v1): writes the header-free per-invocation inventory

      <root>/witnesses/<invocation>/<record>.started.json
      <root>/witnesses/<invocation>/<record>.json
      <root>/witness/sha256/<aa>/<digest>.json

  with 0700 directories and 0600 files, exactly as the proxy lays them out.
  Used by tests and by `fake_claude_cli.exs` (mode `witness`), which plays
  shim + proxy for one call. Never contacts any network.
  """

  @proxy_version "0.2.0"

  @doc "Writes one exchange; returns the record id. See `record/3` for options."
  def exchange!(root, invocation_id, opts \\ []) do
    record_id = Keyword.get(opts, :record_id, uuid7())
    dir = Path.join([root, "witnesses", invocation_id])
    mkdir!(dir)
    request = Keyword.get(opts, :request, "{}")
    response = Keyword.get(opts, :response, "")
    started = record(record_id, invocation_id, Keyword.put(opts, :phase, :started))
    write!(Path.join(dir, record_id <> ".started.json"), JSON.encode!(started))

    unless Keyword.get(opts, :open, false) do
      request_sha = blob!(root, request)
      response_sha = if response == "", do: nil, else: blob!(root, response)

      terminal =
        record(
          record_id,
          invocation_id,
          Keyword.merge(opts,
            phase: :terminal,
            request_sha256: request_sha,
            response_sha256: response_sha,
            request_bytes: byte_size(request),
            response_bytes: byte_size(response)
          )
        )

      write!(Path.join(dir, record_id <> ".json"), JSON.encode!(terminal))
    end

    record_id
  end

  @doc "Stores `body` in the raw witness namespace; returns its hex digest."
  def blob!(root, body) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    dir = Path.join([root, "witness", "sha256", binary_part(digest, 0, 2)])
    mkdir!(dir)
    path = Path.join(dir, digest <> ".json")
    unless File.exists?(path), do: write!(path, body)
    digest
  end

  @doc "An Anthropic Messages request as Claude Code sends it (synthetic)."
  def messages_request(prompt, opts \\ []) do
    JSON.encode!(%{
      "model" => Keyword.get(opts, :model, "claude-opus-5-5"),
      "max_tokens" => 32_000,
      "stream" => true,
      "system" => [%{"type" => "text", "text" => "Synthetic CLI system text"}],
      "metadata" => %{"user_id" => account_id()},
      "messages" => [
        %{
          "role" => "user",
          "content" => Keyword.get(opts, :blocks, [%{"type" => "text", "text" => prompt}])
        }
      ]
    })
  end

  @doc """
  A request shaped like Claude Code 2.1.291's (S12d proof 1, structure
  only, synthetic text): one user message holding reminder-shaped blocks and
  the stdin, a trailing system-role message, empty tools and the control
  fields. Options adjust it for negative cases: `:reminders`,
  `:extra_user_texts`, `:user_blocks_extra`, `:user_cache_control`,
  `:trailing` (count), `:extra_messages`, `:tools` (`:absent` to drop),
  `:top` (merged top-level keys). S12d v3 shapes: `:cache_ttl` (adds a
  `ttl` to every default `cache_control`), `:cache_control` (replaces every
  default `cache_control` value), `:trailing_message_extra` and
  `:user_message_extra` (keys merged into those messages).
  """
  def cli_request(stdin, opts \\ []) do
    reminders = Keyword.get(opts, :reminders, [])

    user_blocks =
      Enum.map(reminders, &%{"type" => "text", "text" => &1}) ++
        [%{"type" => "text", "text" => stdin}] ++
        Enum.map(Keyword.get(opts, :reminders_after, []), &%{"type" => "text", "text" => &1}) ++
        Enum.map(Keyword.get(opts, :extra_user_texts, []), &%{"type" => "text", "text" => &1}) ++
        Keyword.get(opts, :user_blocks_extra, [])

    user_blocks =
      if Keyword.get(opts, :user_cache_control, false),
        do: Enum.map(user_blocks, &Map.put(&1, "cache_control", %{"type" => "ephemeral"})),
        else: user_blocks

    cache_control =
      case {Keyword.fetch(opts, :cache_control), Keyword.fetch(opts, :cache_ttl)} do
        {{:ok, value}, _} -> value
        {:error, {:ok, ttl}} -> %{"type" => "ephemeral", "ttl" => ttl}
        {:error, :error} -> %{"type" => "ephemeral"}
      end

    trailing =
      for n <- 1..Keyword.get(opts, :trailing, 1)//1 do
        Map.merge(
          %{
            "role" => "system",
            "content" =>
              Keyword.get(opts, :trailing_content, [
                %{
                  "type" => "text",
                  "text" => "Synthetic trailing context #{n}",
                  "cache_control" => cache_control
                }
              ])
          },
          Keyword.get(opts, :trailing_message_extra, %{})
        )
      end

    request = %{
      "model" => "claude-opus-5-5",
      "max_tokens" => 32_000,
      "stream" => true,
      "metadata" => %{"user_id" => account_id()},
      "system" => [
        %{"type" => "text", "text" => "Synthetic CLI system text"},
        %{
          "type" => "text",
          "text" => "More synthetic system text",
          "cache_control" => cache_control
        }
      ],
      "thinking" => %{"type" => "adaptive", "display" => "summarized"},
      "output_config" => %{"effort" => "high"},
      "context_management" => %{"edits" => [%{"type" => "clear_thinking"}]},
      "tools" => Keyword.get(opts, :tools, []),
      "messages" =>
        Keyword.get(opts, :leading_messages, []) ++
          [
            Map.merge(
              %{"role" => "user", "content" => user_blocks},
              Keyword.get(opts, :user_message_extra, %{})
            )
          ] ++
          trailing ++ Keyword.get(opts, :extra_messages, [])
    }

    request =
      if Keyword.get(opts, :tools) == :absent, do: Map.delete(request, "tools"), else: request

    request
    |> Map.merge(Keyword.get(opts, :top, %{}))
    |> Map.drop(Keyword.get(opts, :drop, []))
    |> JSON.encode!()
  end

  @doc "An Anthropic SSE response whose single text block is `text`."
  def sse_response(text, opts \\ []) do
    blocks = Keyword.get(opts, :blocks, [{:text, text}])

    events =
      [{"message_start", %{"type" => "message_start", "message" => %{"id" => "msg_synthetic"}}}] ++
        Enum.flat_map(Enum.with_index(blocks), &block_events/1) ++
        [
          {"message_delta",
           %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}}
        ] ++
        if(Keyword.get(opts, :stop, true),
          do: [{"message_stop", %{"type" => "message_stop"}}],
          else: []
        )

    Enum.map_join(events, fn {name, data} -> "event: #{name}\ndata: #{JSON.encode!(data)}\n\n" end)
  end

  defp block_events({{:text, text}, index}) do
    {first, rest} = String.split_at(text, div(String.length(text), 2))

    [
      {"content_block_start",
       %{
         "type" => "content_block_start",
         "index" => index,
         "content_block" => %{"type" => "text", "text" => ""}
       }}
    ] ++
      for part <- [first, rest] do
        {"content_block_delta",
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "text_delta", "text" => part}
         }}
      end ++ [{"content_block_stop", %{"type" => "content_block_stop", "index" => index}}]
  end

  # A block with an exact start `content_block` and exact delta maps (the v4
  # reasoning fixtures, `thinking_block/2` and `redacted_block/1`).
  defp block_events({{:raw, start, deltas}, index}) do
    [
      {"content_block_start",
       %{"type" => "content_block_start", "index" => index, "content_block" => start}}
    ] ++
      for delta <- deltas do
        {"content_block_delta",
         %{"type" => "content_block_delta", "index" => index, "delta" => delta}}
      end ++ [{"content_block_stop", %{"type" => "content_block_stop", "index" => index}}]
  end

  defp block_events({{type, _}, index}) do
    [
      {"content_block_start",
       %{
         "type" => "content_block_start",
         "index" => index,
         "content_block" => %{"type" => Atom.to_string(type)}
       }},
      {"content_block_stop", %{"type" => "content_block_stop", "index" => index}}
    ]
  end

  ## Projection v4 reasoning fixtures (witness response-block plan r5, T1/T3)

  @v3_only [
    cache_ttl: "1h",
    trailing_message_extra: %{"output_config" => %{"effort" => "high"}}
  ]

  @doc """
  A `thinking` block in the conservative v4 candidate shape (synthetic
  text only): the start `{type, thinking: "", signature: ""}`, one string
  `thinking_delta` per `thinking` part, then one string `signature_delta`
  per `signature` part. For `sse_response/2`'s `:blocks`.
  """
  def thinking_block(thinking \\ ["Synthetic reasoning."], signature \\ ["synthetic-signature"]) do
    {:raw, %{"type" => "thinking", "thinking" => "", "signature" => ""},
     Enum.map(thinking, &%{"type" => "thinking_delta", "thinking" => &1}) ++
       Enum.map(signature, &%{"type" => "signature_delta", "signature" => &1})}
  end

  @doc "A `redacted_thinking` block `{type, data}` with no deltas (synthetic data)."
  def redacted_block(data \\ "synthetic-redacted-data"),
    do: {:raw, %{"type" => "redacted_thinking", "data" => data}, []}

  @doc "A block with an exact start `content_block` and exact delta maps."
  def raw_block(start, deltas \\ []), do: {:raw, start, deltas}

  @doc """
  The `{request, response}` of a v4 fixture variant (`cli_shape_v4_*`,
  played by `fake_claude_cli.exs` in `witness` mode) for `stdin` and the
  application's `answer`. The request is v3-only (`cache_control` ttl 1h
  and a message-level `output_config`, so v2 does not apply) unless the
  variant says otherwise:

    * `cli_shape_v4_thinking` / `_redacted`: one reasoning block, then the text;
    * `cli_shape_v4_thinking_mismatch`: one thinking block, then other output;
    * `cli_shape_v4_overflow`: 3 thinking + 2 redacted blocks, then the text;
    * `cli_shape_v4_two_text`: one thinking block, then two text blocks;
    * `cli_shape_v4_after_text`: thinking, text, thinking;
    * `cli_shape_v4_unknown_block`: thinking, a zero-delta unknown type, text;
    * `cli_shape_v4_unparsed_signature`: a thinking block with no signature;
    * `cli_shape_v4_redacted_delta`: a redacted block with a delta (refused
      by the shared stream parser);
    * `cli_shape_v4_request_mismatch`: a different stdin, then thinking + text;
    * `cli_shape_v4_v2_thinking`: a v2-applicable request, thinking + text.
  """
  def v4_variant!(variant, stdin, answer) do
    {edit, opts, blocks} = Map.fetch!(v4_variants(answer), variant)
    {cli_request(stdin <> edit, opts), sse_response(answer, blocks: blocks)}
  end

  # variant => {stdin suffix, request options, response blocks}
  defp v4_variants(answer) do
    other = ~s({"answer":"disqualified","score":42})
    thinking = thinking_block()
    text = {:text, answer}
    redacted_delta = %{"type" => "text_delta", "text" => "x"}

    %{
      "cli_shape_v4_thinking" => {"", @v3_only, [thinking, text]},
      "cli_shape_v4_redacted" => {"", @v3_only, [redacted_block(), text]},
      "cli_shape_v4_thinking_mismatch" => {"", @v3_only, [thinking, {:text, other}]},
      "cli_shape_v4_overflow" =>
        {"", @v3_only, [thinking, thinking, thinking, redacted_block(), redacted_block(), text]},
      "cli_shape_v4_two_text" => {"", @v3_only, [thinking, text, text]},
      "cli_shape_v4_after_text" => {"", @v3_only, [thinking, text, thinking]},
      "cli_shape_v4_unknown_block" => {"", @v3_only, [thinking, {:mystery, nil}, text]},
      "cli_shape_v4_unparsed_signature" =>
        {"", @v3_only, [thinking_block(["Synthetic reasoning."], []), text]},
      "cli_shape_v4_redacted_delta" =>
        {"", @v3_only,
         [raw_block(%{"type" => "redacted_thinking", "data" => "d"}, [redacted_delta]), text]},
      "cli_shape_v4_request_mismatch" => {" (edited)", @v3_only, [thinking, text]},
      "cli_shape_v4_v2_thinking" => {"", [], [thinking, text]}
    }
  end

  @doc "Claude Code's account-derived `metadata.user_id` shape (synthetic)."
  def account_id, do: "user_" <> String.duplicate("ab", 32) <> "_account__session_synthetic"

  @doc """
  A proxy record map. Options: `:route` (default messages), `:outcome`,
  `:http_status`, `:stream_complete`, `:capture_complete`,
  `:content_encoding`, `:traceparent`, `:extra` (merged raw keys).
  """
  def record(record_id, invocation_id, opts) do
    started = %{
      "schema_version" => 1,
      "record_id" => record_id,
      "invocation_id" => invocation_id,
      "proxy_version" => @proxy_version,
      "route" => Keyword.get(opts, :route, "/anthropic/v1/messages"),
      "method" => "POST",
      "traceparent" => Keyword.get(opts, :traceparent, traceparent()),
      "started_at" => "2026-10-07T12:00:00.000001Z",
      "outcome" => "started",
      "request_bytes_seen" => Keyword.get(opts, :request_bytes, 0),
      "response_bytes_seen" => 0,
      "request_capture_complete" => false,
      "response_capture_complete" => false,
      "stream_complete" => false
    }

    record =
      case Keyword.fetch!(opts, :phase) do
        :started ->
          started

        :terminal ->
          complete = Keyword.get(opts, :capture_complete, true)

          started
          |> Map.merge(%{
            "completed_at" => "2026-10-07T12:00:02.5Z",
            "outcome" => Keyword.get(opts, :outcome, "complete"),
            "http_status" => Keyword.get(opts, :http_status, 200),
            "response_bytes_seen" => Keyword.get(opts, :response_bytes, 0),
            "request_capture_complete" => complete,
            "response_capture_complete" => complete,
            "stream_complete" => Keyword.get(opts, :stream_complete, complete),
            "request_capture_sha256" => Keyword.get(opts, :request_sha256),
            "response_capture_sha256" => Keyword.get(opts, :response_sha256)
          })
          |> put_if(complete, "request_sha256", Keyword.get(opts, :request_sha256))
          |> put_if(complete, "response_sha256", Keyword.get(opts, :response_sha256))
          |> put_if(true, "response_content_encoding", Keyword.get(opts, :content_encoding))
      end

    record |> Map.merge(Keyword.get(opts, :extra, %{})) |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp put_if(map, true, key, value) when not is_nil(value), do: Map.put(map, key, value)
  defp put_if(map, _cond, _key, _value), do: map

  @doc "A valid W3C v00 traceparent."
  def traceparent do
    "00-" <> hex(16) <> "-" <> hex(8) <> "-01"
  end

  @doc "A lowercase UUIDv7-shaped id, as the proxy's `uuidv7Like`."
  def uuid7 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    ms = System.os_time(:millisecond)
    <<x::128>> = <<ms::48, 7::4, b::12, 2::2, c::62>>
    _ = a

    hex = x |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  defp hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp mkdir!(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
  end

  defp write!(path, data) do
    File.write!(path, data, [:binary])
    File.chmod!(path, 0o600)
  end
end
