mode = Enum.at(System.argv(), 0, "ready")

model = if(mode == "model_drift", do: "claude-opus-future", else: "claude-opus-5-5")
tools = if(mode == "tool_drift", do: ~s(["Read"]), else: "[]")
version = if(mode == "version_drift", do: "2.1.292", else: "2.1.291")

init =
  ~s({"type":"system","subtype":"init","model":"#{model}","claude_code_version":"#{version}","tools":#{tools},"mcp_servers":[],"slash_commands":[]})

result =
  ~s({"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"qualified\\",\\"score\\":42}","usage":{"input_tokens":12,"output_tokens":3}})

fenced =
  ~s({"type":"result","subtype":"success","is_error":false,"result":"```json\\n{\\"answer\\":\\"qualified\\",\\"score\\":42}\\n```","usage":{"input_tokens":12,"output_tokens":3}})

prose =
  ~s({"type":"result","subtype":"success","is_error":false,"result":"Here you go: {\\"answer\\":\\"qualified\\",\\"score\\":42}","usage":{"input_tokens":12,"output_tokens":3}})

# Child-environment names the S12b witness tests observe (never values of
# any other variable, so the dump cannot capture an operator credential).
observed = ~w(SDR_MODEL_INVOCATION_ID SDR_TRACEPARENT CLAUDE_CODE_USE_BEDROCK
              CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_BEDROCK_BASE_URL
              ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL)

case mode do
  "witness" ->
    # argv: witness <store root> <variant>. Plays shim + S12a proxy for one
    # call: records the exchange(s) under the propagated invocation id in a
    # stand-in witness store, then answers like the CLI.
    unless Code.ensure_loaded?(SdrAgent.Test.FakeWitnessProxy),
      do: Code.require_file(Path.join(__DIR__, "fake_witness_proxy.exs"))

    alias SdrAgent.Test.FakeWitnessProxy, as: Proxy
    [_mode, root, variant | _] = System.argv()
    stdin = IO.read(:stdio, :eof)
    id = System.get_env("SDR_MODEL_INVOCATION_ID")
    tp = System.get_env("SDR_TRACEPARENT")
    answer = ~s({"answer":"qualified","score":42})

    message = fn prompt, text, sse_opts ->
      [
        traceparent: tp,
        request: Proxy.messages_request(prompt),
        response: Proxy.sse_response(text, sse_opts)
      ]
    end

    if id do
      ok = message.(stdin, answer, [])

      case variant do
        "none" ->
          :ok

        "ok" ->
          Proxy.exchange!(root, id, ok)

        "mismatch" ->
          Proxy.exchange!(root, id, message.(stdin, ~s({"answer":"disqualified","score":42}), []))

        "prompt_changed" ->
          Proxy.exchange!(root, id, message.(stdin <> " (edited)", answer, []))

        "tool_use" ->
          Proxy.exchange!(
            root,
            id,
            message.(stdin, answer, blocks: [{:text, answer}, {:tool_use, nil}])
          )

        "no_stop" ->
          Proxy.exchange!(root, id, message.(stdin, answer, stop: false))

        "double" ->
          Enum.each(1..2, fn _ -> Proxy.exchange!(root, id, ok) end)

        "open" ->
          Proxy.exchange!(root, id, ok) && Proxy.exchange!(root, id, Keyword.put(ok, :open, true))

        "unknown_route" ->
          Proxy.exchange!(root, id, ok)

          Proxy.exchange!(root, id,
            route: "/anthropic/unknown",
            traceparent: tp,
            request: "{}",
            response: "{}"
          )

        "count_tokens" ->
          Proxy.exchange!(root, id, ok)

          Proxy.exchange!(root, id,
            route: "/anthropic/v1/messages/count_tokens",
            traceparent: tp,
            request: Proxy.messages_request(stdin),
            response: ~s({"input_tokens":12})
          )

        "count_tokens_content" ->
          Proxy.exchange!(root, id, ok)

          Proxy.exchange!(root, id,
            route: "/anthropic/v1/messages/count_tokens",
            traceparent: tp,
            request: Proxy.messages_request(stdin),
            response: ~s({"input_tokens":12,"content":[{"type":"text","text":"x"}]})
          )
      end
    end

    IO.puts(init)
    IO.puts(result)

  "env_dump" ->
    # argv: env_dump <dump file> [sleep ms]. Records the observed child env
    # and the wall-clock interval of this launch, then answers normally.
    dump = Enum.at(System.argv(), 1)

    pause =
      case Integer.parse(Enum.at(System.argv(), 2, "0")) do
        {ms, ""} -> ms
        _ -> 0
      end

    started = System.os_time(:microsecond)
    Process.sleep(pause)

    env =
      Map.new(observed, fn name -> {name, System.get_env(name)} end)
      |> Map.put("started_us", started)
      |> Map.put("finished_us", System.os_time(:microsecond))

    File.write!(dump <> "." <> Integer.to_string(started), JSON.encode!(env))
    IO.puts(init)
    IO.puts(result)

  "fenced" ->
    IO.puts(init)
    IO.puts(fenced)

  "prose" ->
    IO.puts(init)
    IO.puts(prose)

  "ready" ->
    IO.puts(init)
    IO.puts(result)

  "stderr_secret" ->
    IO.puts(:stderr, "SECRET_DO_NOT_EXPOSE")
    IO.puts(init)
    IO.puts(result)

  "missing_init" ->
    IO.puts(result)

  "malformed" ->
    IO.puts("not-json SECRET_DO_NOT_EXPOSE")

  "timeout" ->
    pid_file = Enum.at(System.argv(), 1)
    sleeper = Port.open({:spawn_executable, System.find_executable("sleep")}, [{:args, ["60"]}])
    {:os_pid, pid} = Port.info(sleeper, :os_pid)
    File.write!(pid_file, Integer.to_string(pid))
    IO.puts(init)
    Process.sleep(:infinity)

  _drift ->
    IO.puts(init)
    IO.puts(result)
end
