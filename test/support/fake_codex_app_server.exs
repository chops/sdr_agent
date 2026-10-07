mode = Enum.at(System.argv(), 0, "ready")
expected_codex_home = Enum.at(System.argv(), 1)

respond = fn payload -> IO.puts(Jason.encode!(payload)) end

Stream.transform(IO.stream(:stdio, :line), %{threads: 0}, fn line, state ->
  message = Jason.decode!(line)
  id = message["id"]

  next_state =
    case message["method"] do
      "initialize" ->
        name = get_in(message, ["params", "clientInfo", "name"])

        if name == "sdr_agent" and System.get_env("CODEX_HOME") == expected_codex_home do
          respond.(%{"id" => id, "result" => %{"userAgent" => "codex-cli/0.test"}})
        else
          respond.(%{"id" => id, "error" => %{"code" => -1, "message" => "wrong client"}})
        end

        state

      "initialized" ->
        state

      "account/read" ->
        account =
          if mode == "logged_out" do
            nil
          else
            %{
              "type" => "chatgpt",
              "email" => "owner@example.test",
              "planType" => "plus",
              "accessToken" => "token-canary"
            }
          end

        respond.(%{"id" => id, "result" => %{"account" => account, "requiresOpenaiAuth" => true}})
        state

      "config/read" ->
        config = %{
          "approval_policy" => "never",
          "model" => "fake-codex",
          "model_reasoning_effort" => "medium",
          "openai_api_key" => "token-canary",
          "sandbox_mode" => "read-only"
        }

        respond.(%{"id" => id, "result" => %{"config" => config, "origins" => %{}}})
        state

      "model/list" ->
        model = %{
          "id" => "fake-codex",
          "model" => "fake-codex",
          "displayName" => "Fake Codex",
          "isDefault" => true,
          "hidden" => false,
          "defaultReasoningEffort" => "medium",
          "supportedReasoningEfforts" => []
        }

        respond.(%{"id" => id, "result" => %{"data" => [model], "nextCursor" => nil}})
        state

      "thread/start" ->
        params = message["params"]
        features = get_in(params, ["config", "features"]) || %{}

        secure? =
          get_in(params, ["config", "mcp_servers"]) == %{} and
            get_in(params, ["config", "web_search"]) == "disabled" and
            features != %{} and Enum.all?(features, fn {_key, value} -> value == false end) and
            File.ls!(params["cwd"]) == []

        if mode == "thread_error" or not secure? do
          respond.(%{"id" => id, "error" => %{"code" => -32_000, "message" => "fixture failure"}})
          state
        else
          sequence = state.threads + 1
          respond.(%{"id" => id, "result" => %{"thread" => %{"id" => "thread-#{sequence}"}}})
          %{state | threads: sequence}
        end

      "turn/start" ->
        thread_id = get_in(message, ["params", "threadId"])
        sequence = thread_id |> String.split("-") |> List.last() |> String.to_integer()
        respond.(%{"id" => id, "result" => %{"turn" => %{"id" => "turn-#{sequence}"}}})

        forbidden_type =
          case mode do
            "command_item" -> "commandExecution"
            "file_item" -> "fileChange"
            "unknown_item" -> "futureSecretReader"
            _ -> nil
          end

        if forbidden_type do
          respond.(%{
            "method" => "item/completed",
            "params" => %{
              "threadId" => thread_id,
              "turnId" => "turn-#{sequence}",
              "item" => %{"type" => forbidden_type, "secret" => "must-not-commit"}
            }
          })
        end

        output =
          if mode == "invalid_output" do
            %{answer: "qualified", score: "not-an-integer"}
          else
            %{answer: "qualified", score: 42}
          end

        unless mode == "timeout" do
          respond.(%{
            "method" => "item/completed",
            "params" => %{
              "threadId" => thread_id,
              "turnId" => "turn-#{sequence}",
              "item" => %{
                "type" => "agentMessage",
                "text" => Jason.encode!(output)
              }
            }
          })

          respond.(%{
            "method" => "turn/completed",
            "params" => %{
              "threadId" => thread_id,
              "turn" => %{"id" => "turn-#{sequence}", "status" => "completed"}
            }
          })
        end

        state

      "turn/interrupt" ->
        respond.(%{"id" => id, "result" => %{}})

        respond.(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => get_in(message, ["params", "threadId"]),
            "turn" => %{
              "id" => get_in(message, ["params", "turnId"]),
              "status" => "interrupted"
            }
          }
        })

        state
    end

  {[], next_state}
end)
|> Stream.run()
