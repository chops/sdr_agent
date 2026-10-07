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
