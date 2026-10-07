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
    assert {:ok, %{sequence: 1}} = first
    assert {:ok, %{sequence: 2}} = second
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
    assert {:ok, server} = CodexAppServer.start_link(command: System.find_executable("codex"))

    assert {:ok, %{account_mode: :cached_chatgpt, model: model}} =
             CodexAppServer.preflight(server)

    assert is_binary(model)
  end

  defp start_server(mode, extra \\ []) do
    CodexAppServer.start_link(
      Keyword.merge(
        [command: System.find_executable("mix"), args: ["run", "--no-start", @fake_server, mode]],
        extra
      )
    )
  end
end
