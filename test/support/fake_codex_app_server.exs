mode = Enum.at(System.argv(), 0, "ready")

respond = fn payload -> IO.puts(Jason.encode!(payload)) end

Stream.transform(IO.stream(:stdio, :line), %{threads: 0}, fn line, state ->
  message = Jason.decode!(line)
  id = message["id"]

  next_state =
    case message["method"] do
      "initialize" ->
        name = get_in(message, ["params", "clientInfo", "name"])

        if name == "sdr_agent" do
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
        if mode == "thread_error" do
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

        output =
          if mode == "invalid_output" do
            %{answer: "qualified", score: "not-an-integer"}
          else
            %{answer: "qualified", score: 42}
          end

        respond.(%{
          "method" => "item/completed",
          "params" => %{
            "threadId" => thread_id,
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

        state
    end

  {[], next_state}
end)
|> Stream.run()
