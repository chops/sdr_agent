defmodule SdrAgent.AI.CodexAppServerTest do
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.CodexAppServer

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})
  @fake_server Path.expand("../../support/fake_codex_app_server.exs", __DIR__)

  setup do
    assert Code.ensure_loaded?(CodexAppServer), "S6a must define the Codex app-server adapter"
    :ok
  end

  test "preflights cached login and catalog, then validates structured output" do
    {:ok, server} = start_server("ready")

    assert {:ok, preflight} = CodexAppServer.preflight(server)
    assert preflight.model == "fake-codex"
    assert preflight.account_mode == :cached_chatgpt
    assert preflight.client_name == "sdr_agent"
    assert preflight.app_server_version

    assert preflight.config == %{
             "approval_policy" => "never",
             "model" => "fake-codex",
             "model_reasoning_effort" => "medium",
             "sandbox_mode" => "read-only"
           }

    refute inspect(preflight) =~ "token-canary"
    refute inspect(preflight) =~ "owner@example.test"

    request = %{id: "codex-1", prompt: "fixture", schema: @schema}
    assert {:ok, result} = CodexAppServer.complete(server, request)
    assert result.output == %{answer: "qualified", score: 42}
    assert result.model == "fake-codex"
    assert result.raw_request
    assert result.raw_response

    thread_start = result.raw_request.thread_start["params"]
    assert thread_start["config"]["mcp_servers"] == %{}
    assert thread_start["config"]["web_search"] == "disabled"
    assert Enum.all?(thread_start["config"]["features"], fn {_name, enabled?} -> !enabled? end)
    assert File.ls!(thread_start["cwd"]) == []
    GenServer.stop(server)
    refute File.exists?(thread_start["cwd"])
  end

  test "calls are serialized through one app-server process" do
    {:ok, server} = start_server("ready")

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          CodexAppServer.complete(server, %{
            id: "serial-#{index}",
            prompt: "fixture #{index}",
            schema: @schema
          })
        end)
      end

    assert [first, second] = Enum.map(tasks, &Task.await(&1, 2_000))
    assert {:ok, first} = first
    assert {:ok, second} = second
    assert get_in(first.raw_response, [:thread_start, "thread", "id"]) == "thread-1"
    assert get_in(second.raw_response, [:thread_start, "thread", "id"]) == "thread-2"
  end

  test "structured output that violates the Zoi schema is rejected" do
    {:ok, server} = start_server("invalid_output")

    assert {:error, {:validation_failed, errors}} =
             CodexAppServer.complete(server, %{
               id: "invalid-codex",
               prompt: "fixture",
               schema: @schema
             })

    assert errors != []
  end

  test "JSON-RPC errors are returned without crashing the serialized adapter" do
    {:ok, server} = start_server("thread_error")

    assert {:error, {:json_rpc, %{"code" => -32_000, "message" => "fixture failure"}}} =
             CodexAppServer.complete(server, %{
               id: "rpc-error",
               prompt: "fixture",
               schema: @schema
             })

    assert Process.alive?(server)
  end

  test "built-in and unknown item types fail closed without committing output" do
    for {mode, type} <- [
          {"command_item", "commandExecution"},
          {"file_item", "fileChange"},
          {"unknown_item", "futureSecretReader"}
        ] do
      {:ok, server} = start_server(mode)

      assert {:error, {:forbidden_item, ^type}} =
               CodexAppServer.complete(server, %{
                 id: "forbidden-#{mode}",
                 prompt: "untrusted fixture",
                 schema: @schema
               })

      assert Process.alive?(server)
    end
  end

  test "turn deadline interrupts and drains before returning" do
    {:ok, server} = start_server("timeout", turn_timeout: 25)

    assert {:error, :turn_timeout} =
             CodexAppServer.complete(server, %{
               id: "timeout",
               prompt: "fixture",
               schema: @schema
             })

    assert Process.alive?(server)
  end

  test "missing cached ChatGPT login fails before starting a turn" do
    {:ok, server} = start_server("logged_out")
    assert {:error, :cached_chatgpt_login_required} = CodexAppServer.preflight(server)
  end

  test "an unavailable configured model fails closed" do
    {:ok, server} = start_server("ready", model: "missing-model")
    assert {:error, {:model_unavailable, "missing-model"}} = CodexAppServer.preflight(server)
  end

  @tag :external
  test "real app-server cached-login preflight smoke" do
    assert {:ok, server} =
             CodexAppServer.start_link(
               command: System.find_executable("llm-proxy-shim"),
               args: ["codex", "app-server"],
               codex_home: System.fetch_env!("CODEX_HOME")
             )

    assert {:ok, %{account_mode: :cached_chatgpt, model: model}} =
             CodexAppServer.preflight(server)

    assert is_binary(model)
  end

  defp start_server(mode, extra \\ []) do
    codex_home = Path.join(System.tmp_dir!(), "sdr-agent-fake-codex-home")

    CodexAppServer.start_link(
      Keyword.merge(
        [
          command: System.find_executable("mix"),
          args: ["run", "--no-start", @fake_server, mode, codex_home],
          codex_home: codex_home
        ],
        extra
      )
    )
  end
end
