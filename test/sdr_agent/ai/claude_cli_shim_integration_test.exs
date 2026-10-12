defmodule SdrAgent.AI.ClaudeCLIShimIntegrationTest do
  @moduledoc """
  R0-02 wiring, end to end through the real `llm-proxy-shim`
  (ADR-0004 R0 amendment, item 1): ClaudeCLI launches the installed shim,
  which must exec exactly the pinned artifact named in
  `LLM_PROXY_SHIM_CLAUDE_BIN` — here a harmless stand-in script bound
  through the test-build identity seam — and route it to the local proxy.

  Hermetic: the "proxy" is a loopback listener in this test that answers
  only the shim's health probes; the stand-in records its argv and a few
  environment values, reads the prompt from stdin and prints a canned init
  and result. No network, no model, no real Claude CLI. Skipped where the
  shim is not installed (CI); it runs on the owner's machine.
  """
  # Sets process environment variables and the application env.
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Test.PinnedCLI

  @shim System.find_executable("llm-proxy-shim")
  if is_nil(@shim), do: @moduletag(skip: "llm-proxy-shim is not installed on this machine")

  @capability ~s({"proxy_version":"0.0.0-test","strips":["traceparent","tracestate","x-sdr-model-invocation-id"],"witness_schema":1})

  setup do
    suffix = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "sdr-shim-it-#{suffix}")
    store = Path.join(dir, "store")
    bin = Path.join([store, String.duplicate("a", 32) <> "-app-claude-cli-2.1.294", "bin"])
    File.mkdir_p!(bin)
    record = Path.join(dir, "stand-in-record")
    stand_in = stand_in!(bin, record)

    {listener, port} = proxy!(self())
    names = ~w(LLM_OTEL_PROXY_URL ANTHROPIC_BASE_URL LLM_PROXY_SHIM_CLAUDE_BIN)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    System.put_env("LLM_OTEL_PROXY_URL", "http://127.0.0.1:#{port}")
    System.delete_env("ANTHROPIC_BASE_URL")
    System.delete_env("LLM_PROXY_SHIM_CLAUDE_BIN")

    on_exit(fn ->
      :gen_tcp.close(listener)

      Enum.each(previous, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)

      File.rm_rf!(dir)
    end)

    PinnedCLI.inject_identity!(stand_in, store: store)
    %{stand_in: stand_in, record: record, port: port, store: store}
  end

  test "the real shim execs exactly the pinned artifact, routed to the loopback proxy", ctx do
    {:ok, server} =
      ClaudeCLI.start_link(
        command: @shim,
        test_launcher: true,
        executable: ctx.stand_in,
        environment: %{}
      )

    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    assert result.output == %{"answer" => "qualified", "score" => 42}

    record = ctx.record |> File.read!() |> String.split("\n", trim: true)
    assert "self=#{ctx.stand_in}" in record
    assert "bin=#{ctx.stand_in}" in record
    assert "base=http://127.0.0.1:#{ctx.port}/anthropic" in record
    assert "sdr_header=yes" in record
    [argv] = Enum.filter(record, &String.starts_with?(&1, "argv:"))
    assert argv =~ "[-p]"
    assert argv =~ "[--model] [opus]"
    assert argv =~ "[--tools] []"

    assert_received {:proxy, "/healthz/witness"}
    assert_received {:proxy, "/healthz"}
  end

  test "another artifact than the pin is refused before the shim runs", ctx do
    other_bin = Path.join([ctx.store, String.duplicate("b", 32) <> "-claude-code-2.1.294", "bin"])
    File.mkdir_p!(other_bin)
    other = stand_in!(other_bin, ctx.record)

    {:ok, server} =
      ClaudeCLI.start_link(command: @shim, test_launcher: true, executable: other)

    assert {:error, :pinned_cli_unavailable} = ClaudeCLI.complete(request(), server: server)
    refute File.exists?(ctx.record)
    refute_received {:proxy, _path}
  end

  # A harmless stand-in for the pinned CLI: records argv and a few values,
  # consumes the prompt and answers with a canned init and result.
  defp stand_in!(bin, record) do
    path = Path.join(bin, "claude-code")

    init =
      ~s({"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"#{ClaudeCLI.provenance().provider_version}","tools":[],"mcp_servers":[],"slash_commands":[]})

    result =
      ~s({"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"qualified\\",\\"score\\":42}","usage":{"input_tokens":1,"output_tokens":1}})

    File.write!(path, """
    #!/bin/sh
    {
      printf 'argv:'
      for a in "$@"; do printf ' [%s]' "$a"; done
      printf '\\n'
      printf 'self=%s\\n' "$0"
      printf 'bin=%s\\n' "$LLM_PROXY_SHIM_CLAUDE_BIN"
      printf 'base=%s\\n' "$ANTHROPIC_BASE_URL"
      case "$ANTHROPIC_CUSTOM_HEADERS" in
        *x-sdr-model-invocation-id:*) echo sdr_header=yes ;;
        *) echo sdr_header=no ;;
      esac
    } > '#{record}'
    cat > /dev/null
    printf '%s\\n' '#{init}'
    printf '%s\\n' '#{result}'
    """)

    File.chmod!(path, 0o555)
    path
  end

  # Loopback stand-in for llm-otel-proxy: answers the shim's health probes
  # only, and reports each requested path to the test.
  defp proxy!(test) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> accept(listener, test) end)
    {listener, port}
  end

  defp accept(listener, test) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket, test)
        accept(listener, test)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, test) do
    with {:ok, head} <- read_head(socket, ""),
         [_method, path | _] <- head |> String.split("\r\n") |> hd() |> String.split(" ") do
      send(test, {:proxy, path})

      {status, body} =
        case path do
          "/healthz" -> {"200 OK", "ok"}
          "/healthz/witness" -> {"200 OK", @capability}
          _other -> {"404 Not Found", ""}
        end

      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status}\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_head(socket, acc <> data)
        error -> error
      end
    end
  end

  defp request do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    %{
      id: "shim-integration",
      operation: "model.complete",
      prompt: "qualify",
      schema: Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}),
      witness: %{
        model_invocation_id: Ash.UUIDv7.generate(),
        traceparent: "00-#{trace}-#{span}-01"
      }
    }
  end
end
