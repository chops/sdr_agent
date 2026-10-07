defmodule SdrAgent.AI.ModelProvider.CodexAppServer do
  @moduledoc """
  Serialized JSONL client for a local `codex app-server` process.

  The adapter uses only an existing cached ChatGPT login, exposes no tools,
  and returns allowlisted provenance. Raw account and configuration responses
  are deliberately discarded because they may contain credentials or PII.
  """

  use GenServer

  @behaviour SdrAgent.AI.ModelProvider

  @timeout 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Checks cached-login state and chooses an available catalog model."
  def preflight(server), do: GenServer.call(server, :preflight, @timeout)

  @doc "Runs one structured-output turn. Calls are serialized by the adapter process."
  def complete(server, request) when is_pid(server) and is_map(request) do
    GenServer.call(server, {:complete, request}, @timeout)
  end

  @impl SdrAgent.AI.ModelProvider
  def complete(request, opts) when is_map(request) and is_list(opts) do
    server = Keyword.fetch!(opts, :server)
    complete(server, request)
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, ["app-server"])

    port =
      Port.open({:spawn_executable, command}, [
        :binary,
        :exit_status,
        {:args, args},
        {:line, 1_048_576}
      ])

    {:ok,
     %{
       port: port,
       next_id: 1,
       model: Keyword.get(opts, :model),
       preflight: nil,
       buffered: ""
     }}
  end

  @impl true
  def handle_call(:preflight, _from, state) do
    {reply, next_state} = ensure_preflight(state)
    {:reply, reply, next_state}
  end

  def handle_call({:complete, request}, _from, state) do
    with {{:ok, preflight}, state} <- ensure_preflight(state),
         {thread_request, {:ok, thread_result}, state} <- start_thread(state, preflight.model),
         thread_id <- get_in(thread_result, ["thread", "id"]),
         {turn_request, {:ok, turn_result}, state} <- start_turn(state, thread_id, request),
         {:ok, output} <- decode_output(turn_result.text),
         {:ok, validated} <- validate(request.schema, output) do
      result = %{
        output: validated,
        provider: :codex_app_server,
        model: preflight.model,
        sequence: sequence(thread_id),
        provenance: preflight,
        raw_request: %{thread_start: thread_request, turn_start: turn_request},
        raw_response: %{thread_start: thread_result, turn: turn_result.raw}
      }

      {:reply, {:ok, result}, state}
    else
      {{:error, reason}, state} -> {:reply, {:error, reason}, state}
      {_request, {:error, reason}, state} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ensure_preflight(%{preflight: preflight} = state) when not is_nil(preflight) do
    {{:ok, preflight}, state}
  end

  defp ensure_preflight(state) do
    with {_request, {:ok, initialize}, state} <-
           rpc(state, "initialize", %{
             "clientInfo" => %{
               "name" => "sdr_agent",
               "title" => "SDR Agent",
               "version" => "0.1.0"
             },
             "capabilities" => %{}
           }),
         :ok <- notify(state.port, "initialized", %{}),
         {_request, {:ok, account}, state} <- rpc(state, "account/read", %{}),
         :ok <- cached_login(account),
         {_request, {:ok, config}, state} <-
           rpc(state, "config/read", %{"cwd" => File.cwd!(), "includeLayers" => false}),
         {_request, {:ok, catalog}, state} <- rpc(state, "model/list", %{}),
         {:ok, model} <- select_model(catalog, state.model) do
      preflight = %{
        account_mode: :cached_chatgpt,
        app_server_version: initialize["userAgent"],
        catalog: sanitize_model(model),
        client_name: "sdr_agent",
        config: sanitize_config(config),
        data_controls: %{improve_model_for_everyone: false, recorded_on: "2026-10-06"},
        model: model["model"] || model["id"]
      }

      {{:ok, preflight}, %{state | preflight: preflight}}
    else
      {:error, reason} -> {{:error, reason}, state}
      {_request, {:error, reason}, state} -> {{:error, reason}, state}
    end
  end

  defp start_thread(state, model) do
    rpc(state, "thread/start", %{
      "approvalPolicy" => "never",
      "cwd" => File.cwd!(),
      "model" => model,
      "sandbox" => "read-only"
    })
  end

  defp start_turn(state, thread_id, request) do
    params = %{
      "input" => [%{"type" => "text", "text" => request.prompt}],
      "outputSchema" => Zoi.to_json_schema(request.schema),
      "threadId" => thread_id
    }

    {raw_request, reply, state} = rpc(state, "turn/start", params)

    case reply do
      {:ok, started} ->
        case await_turn(state, thread_id, nil, []) do
          {:ok, text, messages, state} ->
            {raw_request, {:ok, %{started: started, text: text, raw: messages}}, state}

          {:error, reason, state} ->
            {raw_request, {:error, reason}, state}
        end

      {:error, reason} ->
        {raw_request, {:error, reason}, state}
    end
  end

  defp rpc(state, method, params) do
    id = state.next_id
    request = %{"id" => id, "method" => method, "params" => params}
    :ok = send_json(state.port, request)
    next_state = %{state | next_id: id + 1}

    case await_response(next_state, id, []) do
      {:ok, result, messages, final_state} ->
        {request, {:ok, Map.put(result, "_messages", messages)}, final_state}

      {:error, reason, final_state} ->
        {request, {:error, reason}, final_state}
    end
  end

  defp await_response(state, id, messages) do
    case receive_message(state) do
      {:ok, %{"id" => ^id, "result" => result} = message, state} ->
        {:ok, result, Enum.reverse([message | messages]), state}

      {:ok, %{"id" => ^id, "error" => error}, state} ->
        {:error, {:json_rpc, error}, state}

      {:ok, message, state} ->
        await_response(state, id, [message | messages])

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp await_turn(state, thread_id, text, messages) do
    case receive_message(state) do
      {:ok, %{"method" => "item/completed", "params" => params} = message, state} ->
        item = params["item"] || %{}

        next_text =
          if params["threadId"] == thread_id and item["type"] == "agentMessage",
            do: item["text"],
            else: text

        await_turn(state, thread_id, next_text, [message | messages])

      {:ok, %{"method" => "turn/completed", "params" => %{"threadId" => ^thread_id}} = message,
       state}
      when is_binary(text) ->
        {:ok, text, Enum.reverse([message | messages]), state}

      {:ok, %{"method" => method}, state}
      when method in ["item/tool/call", "item/tool/request", "approval/request"] ->
        {:error, {:forbidden_app_server_request, method}, state}

      {:ok, message, state} ->
        await_turn(state, thread_id, text, [message | messages])

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp receive_message(state) do
    receive do
      {port, {:data, {:eol, line}}} when port == state.port ->
        decode_line(state.buffered <> line, %{state | buffered: ""})

      {port, {:data, {:noeol, fragment}}} when port == state.port ->
        receive_message(%{state | buffered: state.buffered <> fragment})

      {port, {:exit_status, status}} when port == state.port ->
        {:error, {:app_server_exit, status}, state}
    after
      @timeout -> {:error, :app_server_timeout, state}
    end
  end

  defp decode_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} -> {:ok, message, state}
      {:error, _reason} -> {:error, :invalid_app_server_json, state}
    end
  end

  defp send_json(port, value) do
    true = Port.command(port, [Jason.encode!(value), "\n"])
    :ok
  end

  defp notify(port, method, params) do
    send_json(port, %{"method" => method, "params" => params})
  end

  defp cached_login(%{"account" => %{"type" => "chatgpt"}}), do: :ok
  defp cached_login(_account), do: {:error, :cached_chatgpt_login_required}

  defp select_model(%{"data" => models}, configured) when is_list(models) do
    available = Enum.reject(models, &(&1["hidden"] == true))

    selected =
      if configured do
        Enum.find(available, &((&1["model"] || &1["id"]) == configured))
      else
        Enum.find(available, &(&1["isDefault"] == true)) || List.first(available)
      end

    case selected do
      nil when is_binary(configured) -> {:error, {:model_unavailable, configured}}
      nil -> {:error, :no_model_available}
      model -> {:ok, model}
    end
  end

  defp sanitize_model(model) do
    Map.take(model, [
      "id",
      "model",
      "displayName",
      "isDefault",
      "defaultReasoningEffort",
      "supportedReasoningEfforts"
    ])
  end

  defp sanitize_config(%{"config" => config}) when is_map(config) do
    Map.take(config, ["approval_policy", "model", "model_reasoning_effort", "sandbox_mode"])
  end

  defp sanitize_config(_config), do: %{}

  defp decode_output(text) when is_binary(text) do
    case Jason.decode(text, keys: :atoms!) do
      {:ok, output} -> {:ok, output}
      {:error, _reason} -> {:error, :invalid_structured_output_json}
    end
  end

  defp validate(schema, output) do
    case Zoi.parse(schema, output) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, {:validation_failed, errors}}
    end
  end

  defp sequence("thread-" <> sequence), do: String.to_integer(sequence)
  defp sequence(_thread_id), do: nil
end
