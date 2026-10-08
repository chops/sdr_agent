defmodule SdrAgent.AI.ClaudeCLITest do
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.CodexAppServer

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  test "requires a tool-free init attestation and returns structured output" do
    {:ok, server} = start_server("ready")
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    assert result.output == %{"answer" => "qualified", "score" => 42}
    assert result.model == "claude-opus-5-5"

    assert %{"alias" => "opus", "resolved_id" => "claude-opus-5-5"} =
             result.provenance.model_catalog_entry
  end

  test "fails closed on missing, malformed, model-drifted, and tool-enabled init" do
    for {mode, expected} <- [
          {"missing_init", :missing_init_attestation},
          {"malformed", :invalid_cli_stream},
          {"model_drift", :model_attestation_drift},
          {"version_drift", :version_attestation_drift},
          {"tool_drift", :tool_attestation_drift}
        ] do
      {:ok, server} = start_server(mode)
      assert {:error, ^expected} = ClaudeCLI.complete(request(), server: server)
    end
  end

  test "accepts one JSON object wrapped in a Markdown code fence, nothing else" do
    {:ok, server} = start_server("fenced")
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    assert result.output == %{"answer" => "qualified", "score" => 42}

    {:ok, server} = start_server("prose")
    assert {:error, :missing_structured_output} = ClaudeCLI.complete(request(), server: server)
  end

  test "stderr cannot leak into a successful response" do
    {:ok, server} = start_server("stderr_secret")
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    refute inspect(result) =~ "SECRET_DO_NOT_EXPOSE"
  end

  test "timeout reports unknown and kills the spawned process tree" do
    pid_file =
      Path.join(System.tmp_dir!(), "sdr-claude-child-#{System.unique_integer([:positive])}")

    {:ok, server} = start_server("timeout", [pid_file], timeout: 1_000)

    assert {:unknown, :claude_cli_timeout} = ClaudeCLI.complete(request(), server: server)
    child_pid = pid_file |> File.read!() |> String.trim()

    assert eventually(fn ->
             match?({_, 1}, System.cmd("kill", ["-0", child_pid], stderr_to_stdout: true))
           end)

    File.rm(pid_file)
  end

  describe "Q0.1 the named, supervised server" do
    test "without :server the call goes to the named server; absent, it is a typed error" do
      refute GenServer.whereis(ClaudeCLI.server())
      assert {:error, :provider_not_running} = ClaudeCLI.complete(request(), [])

      start_supervised!({ClaudeCLI, named_opts("ready")})
      assert {:ok, result} = ClaudeCLI.complete(request(), [])
      assert result.model == "claude-opus-5-5"
    end

    test "a dead server pid is a typed error, not an exit" do
      {:ok, server} = start_server("ready")
      GenServer.stop(server)
      assert {:error, :provider_not_running} = ClaudeCLI.complete(request(), server: server)
    end

    test "boot records a pending attestation (no no-call probe); the first call attests" do
      start_supervised!({ClaudeCLI, named_opts("ready")})

      assert %{status: :pending, command?: true} = ClaudeCLI.attestation()

      assert {:ok, _} = ClaudeCLI.complete(request(), [])

      assert %{
               status: :attested,
               model: "claude-opus-5-5",
               version: "2.1.291",
               reason: nil,
               at: %DateTime{}
             } = ClaudeCLI.attestation()
    end

    test "drift and a missing init are recorded as the last attestation" do
      for {mode, reason} <- [
            {"model_drift", :model_attestation_drift},
            {"tool_drift", :tool_attestation_drift},
            {"missing_init", :missing_init_attestation}
          ] do
        start_supervised!({ClaudeCLI, named_opts(mode)}, id: mode)
        assert {:error, ^reason} = ClaudeCLI.complete(request(), [])
        assert %{status: :drift, reason: ^reason, at: %DateTime{}} = ClaudeCLI.attestation()
        stop_supervised!(mode)
      end
    end

    test "a missing llm-proxy-shim is surfaced at boot" do
      start_supervised!(
        {ClaudeCLI, name: ClaudeCLI.server(), command: nil, command_args: ["claude"]}
      )

      assert %{status: :pending, command?: false} = ClaudeCLI.attestation()
      assert {:error, :llm_proxy_shim_not_found} = ClaudeCLI.complete(request(), [])
    end

    test "no server, no attestation" do
      assert %{status: :not_running} = ClaudeCLI.attestation()
    end

    test "concurrent callers of the named server are serialized (concurrency 1)" do
      dump = Path.join(System.tmp_dir!(), "sdr-claude-env-#{System.unique_integer([:positive])}")
      on_exit(fn -> dump |> dumps() |> Enum.each(&File.rm/1) end)

      start_supervised!(
        {ClaudeCLI,
         name: ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         command_args: [@fake, "env_dump", dump, "300"]}
      )

      [witness(), witness(), witness()]
      |> Enum.map(fn witness ->
        Task.async(fn -> ClaudeCLI.complete(request(witness), []) end)
      end)
      |> Task.await_many(30_000)
      |> Enum.each(&assert({:ok, _} = &1))

      assert [one, two, three] = read_dumps(dump)
      assert one["finished_us"] <= two["started_us"], "CLI launches overlapped"
      assert two["finished_us"] <= three["started_us"], "CLI launches overlapped"
    end
  end

  defp named_opts(mode) do
    [
      name: ClaudeCLI.server(),
      command: System.find_executable("elixir"),
      command_args: [@fake, mode]
    ]
  end

  test "Codex app-server is retained fail-closed" do
    assert {:error, :codex_app_server_disabled} = CodexAppServer.prepare(request(), [])
    assert {:error, :codex_app_server_disabled} = CodexAppServer.complete(request(), [])
  end

  @tag :external
  @tag timeout: 180_000
  test "real Claude CLI smoke attests the resolved opus model and no capabilities" do
    {:ok, server} = ClaudeCLI.start_link([])
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    assert result.model == "claude-opus-5-5"
  end

  describe "S12b witness propagation (child environment only)" do
    setup do
      dump = Path.join(System.tmp_dir!(), "sdr-claude-env-#{System.unique_integer([:positive])}")
      on_exit(fn -> dump |> dumps() |> Enum.each(&File.rm/1) end)
      %{dump: dump}
    end

    test "passes the invocation UUID and traceparent to the child, nothing global", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      before = System.get_env()
      witness = witness()

      assert {:ok, _result} = ClaudeCLI.complete(request(witness), server: server)
      assert [child] = read_dumps(dump)
      assert child["SDR_MODEL_INVOCATION_ID"] == witness.model_invocation_id
      assert child["SDR_TRACEPARENT"] == witness.traceparent
      assert System.get_env() == before
      assert System.get_env("SDR_MODEL_INVOCATION_ID") == nil
      assert System.get_env("SDR_TRACEPARENT") == nil
    end

    test "the caller's W3C sampling flag is forwarded as given (00 or 01)", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      sampled = witness()

      unsampled = %{
        witness()
        | traceparent: String.replace_suffix(witness().traceparent, "-01", "-00")
      }

      assert {:ok, _} = ClaudeCLI.complete(request(sampled), server: server)
      assert {:ok, _} = ClaudeCLI.complete(request(unsampled), server: server)
      assert [one, two] = read_dumps(dump)
      assert one["SDR_TRACEPARENT"] == sampled.traceparent
      assert two["SDR_TRACEPARENT"] == unsampled.traceparent
      assert String.ends_with?(two["SDR_TRACEPARENT"], "-00")
    end

    test "two serial calls carry their own distinct ids and contexts", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      first = witness()
      second = witness()

      assert {:ok, _} = ClaudeCLI.complete(request(first), server: server)
      assert {:ok, _} = ClaudeCLI.complete(request(second), server: server)

      assert [one, two] = read_dumps(dump)

      assert {one["SDR_MODEL_INVOCATION_ID"], one["SDR_TRACEPARENT"]} ==
               {first.model_invocation_id, first.traceparent}

      assert {two["SDR_MODEL_INVOCATION_ID"], two["SDR_TRACEPARENT"]} ==
               {second.model_invocation_id, second.traceparent}
    end

    test "concurrent callers are serialized through one CLI at a time", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump, "300"])

      [witness(), witness()]
      |> Enum.map(fn witness ->
        Task.async(fn -> ClaudeCLI.complete(request(witness), server: server) end)
      end)
      |> Task.await_many(30_000)
      |> Enum.each(&assert({:ok, _} = &1))

      assert [one, two] = read_dumps(dump)
      assert one["finished_us"] <= two["started_us"], "CLI launches overlapped"
    end

    test "Bedrock/Vertex/Foundry routing is scrubbed from the child environment",
         %{dump: dump} do
      bypass = %{
        "CLAUDE_CODE_USE_BEDROCK" => "1",
        "CLAUDE_CODE_USE_VERTEX" => "1",
        "CLAUDE_CODE_USE_FOUNDRY" => "1",
        "ANTHROPIC_BEDROCK_BASE_URL" => "https://bedrock.example.invalid",
        "ANTHROPIC_VERTEX_BASE_URL" => "https://vertex.example.invalid",
        "ANTHROPIC_FOUNDRY_BASE_URL" => "https://foundry.example.invalid"
      }

      # The inherited OS environment carries the bypass; the refusal check is
      # given a clean view so this test isolates the child-env scrub itself.
      {:ok, server} = start_server("env_dump", [dump], environment: %{})
      Enum.each(bypass, fn {name, value} -> System.put_env(name, value) end)

      try do
        assert {:ok, _} = ClaudeCLI.complete(request(), server: server)
      after
        Enum.each(Map.keys(bypass), &System.delete_env/1)
      end

      assert [child] = read_dumps(dump)
      for name <- Map.keys(bypass), do: assert(child[name] == nil, "#{name} reached the CLI")
    end

    test "an enabled bypass route in the environment refuses before launch", %{dump: dump} do
      for {name, value} <- [
            {"CLAUDE_CODE_USE_BEDROCK", "1"},
            {"CLAUDE_CODE_USE_VERTEX", "true"},
            {"CLAUDE_CODE_USE_FOUNDRY", "1"},
            {"ANTHROPIC_BEDROCK_BASE_URL", "https://bedrock.example.invalid"},
            {"ANTHROPIC_VERTEX_BASE_URL", "https://vertex.example.invalid"},
            {"ANTHROPIC_FOUNDRY_BASE_URL", "https://foundry.example.invalid"}
          ] do
        {:ok, server} = start_server("env_dump", [dump], environment: %{name => value})

        assert match?(
                 {:error, :witness_bypass_environment},
                 ClaudeCLI.complete(request(), server: server)
               ),
               name
      end

      assert read_dumps(dump) == []
    end

    test "missing or malformed witness context refuses before launch", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      good = witness()

      for witness <- [
            nil,
            %{good | model_invocation_id: String.upcase(good.model_invocation_id)},
            %{good | model_invocation_id: "../../etc/passwd"},
            %{good | model_invocation_id: good.model_invocation_id <> "\nx-evil: 1"},
            %{good | traceparent: "00-" <> String.duplicate("0", 32) <> "-0123456789abcdef-01"},
            %{
              good
              | traceparent:
                  "00-0123456789abcdef0123456789abcdef-" <> String.duplicate("0", 16) <> "-01"
            },
            %{good | traceparent: "ff-0123456789abcdef0123456789abcdef-0123456789abcdef-01"},
            %{good | traceparent: String.upcase(good.traceparent)},
            %{good | traceparent: good.traceparent <> "\ntracestate: x"}
          ] do
        assert match?(
                 {:error, :invalid_witness_context},
                 ClaudeCLI.complete(request(witness), server: server)
               ),
               inspect(witness)
      end

      assert read_dumps(dump) == []
    end

    test "init attestation is unchanged when witness context is present" do
      for {mode, expected} <- [
            {"missing_init", :missing_init_attestation},
            {"model_drift", :model_attestation_drift},
            {"version_drift", :version_attestation_drift},
            {"tool_drift", :tool_attestation_drift}
          ] do
        {:ok, server} = start_server(mode)
        assert {:error, ^expected} = ClaudeCLI.complete(request(witness()), server: server)
      end
    end
  end

  defp dumps(dump), do: Path.wildcard(dump <> ".*")

  defp read_dumps(dump) do
    dump
    |> dumps()
    |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
    |> Enum.sort_by(& &1["started_us"])
  end

  defp witness do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    %{model_invocation_id: Ash.UUIDv7.generate(), traceparent: "00-#{trace}-#{span}-01"}
  end

  defp start_server(mode, extra_args \\ [], opts \\ []) do
    ClaudeCLI.start_link(
      Keyword.merge(
        [
          command: System.find_executable("elixir"),
          command_args: [@fake, mode | extra_args]
        ],
        opts
      )
    )
  end

  defp request(witness \\ witness()) do
    %{
      id: "claude-test",
      operation: "model.complete",
      prompt: "qualify",
      schema: @schema,
      witness: witness
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
