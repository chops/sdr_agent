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

  defp request do
    %{id: "claude-test", operation: "model.complete", prompt: "qualify", schema: @schema}
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
