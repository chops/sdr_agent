defmodule SdrAgent.AI.ModelProvider.ClaudeCLI do
  @moduledoc """
  Serialized, tool-free structured-output adapter for the local Claude CLI.

  Every call launches through `llm-proxy-shim`, requires an init attestation
  with no tools, MCP servers, or slash commands, and pins the `opus` alias to a
  reviewed resolved model ID. Protocol failures never return process output.
  Timeouts terminate the complete observed process tree.
  """

  use GenServer
  @behaviour SdrAgent.AI.ModelProvider

  @default_timeout 120_000
  @model_alias "opus"
  @resolved_model "claude-opus-5-5"
  @reviewed_version "2.1.291"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the reviewed provider provenance recorded before a call."
  def provenance do
    %{
      provider: :claude_cli,
      provider_version: @reviewed_version,
      model_id: @resolved_model,
      model_catalog_entry: %{
        "alias" => @model_alias,
        "resolved_id" => @resolved_model,
        "reviewed_launch_config" => %{
          "tools" => [],
          "mcp_servers" => [],
          "slash_commands" => [],
          "permission_mode" => "dontAsk",
          "session_persistence" => false
        }
      },
      account_mode_ref: "claude:cached-local-login",
      data_control_setting: "personal-local-subscription"
    }
  end

  @impl true
  def prepare(_request, _opts), do: {:ok, provenance()}

  @impl true
  def complete(request, opts) do
    server = Keyword.fetch!(opts, :server)
    GenServer.call(server, {:complete, request}, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       command: Keyword.get(opts, :command, System.find_executable("llm-proxy-shim")),
       command_args: Keyword.get(opts, :command_args, ["claude"]),
       cli_args: Keyword.get(opts, :cli_args, []),
       timeout: Keyword.get(opts, :timeout, @default_timeout),
       expected_model: Keyword.get(opts, :expected_model, @resolved_model)
     }}
  end

  @impl true
  def handle_call({:complete, request}, _from, state), do: {:reply, run(request, state), state}

  @impl true
  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}
  def handle_info({_port, {:exit_status, _status}}, state), do: {:noreply, state}

  defp run(_request, %{command: nil}), do: {:error, :llm_proxy_shim_not_found}

  defp run(request, state) do
    workspace = private_workspace!()
    prompt_path = Path.join(workspace, "prompt")

    prompt =
      request.prompt <>
        "\nReturn only one JSON object matching this schema:\n" <>
        Jason.encode!(Zoi.to_json_schema(request.schema))

    File.write!(prompt_path, prompt, [:binary])
    File.chmod!(prompt_path, 0o600)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, shell_args(state, prompt_path)},
        {:cd, workspace},
        {:line, 1_048_576}
      ])

    os_pid = port |> Port.info(:os_pid) |> elem(1)
    result = collect(port, os_pid, state.expected_model, deadline(state.timeout), nil, [])
    File.rm_rf!(workspace)
    result
  end

  defp shell_args(state, prompt_path) do
    fixed =
      state.command_args ++
        [
          "-p",
          "--output-format",
          "stream-json",
          "--verbose",
          "--safe-mode",
          "--restricted",
          "--model",
          @model_alias,
          "--tools",
          "",
          "--disable-slash-commands",
          "--strict-mcp-config",
          "--mcp-config",
          ~s({"mcpServers":{}}),
          "--permission-mode",
          "dontAsk",
          "--permission-prompts",
          "none",
          "--no-session-persistence"
        ] ++ state.cli_args

    script = ~s(prompt="$1"; shift; exec "$@" < "$prompt" 2>/dev/null)
    ["-c", script, "sdr-agent-claude", prompt_path, state.command | fixed]
  end

  defp collect(port, os_pid, expected_model, deadline, init, messages) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"type" => "system", "subtype" => "init"} = event} ->
            case attest(event, expected_model) do
              :ok -> collect(port, os_pid, expected_model, deadline, event, [event | messages])
              {:error, reason} -> stop_tree(port, os_pid, {:error, reason})
            end

          {:ok, %{"type" => "result"} = event} when not is_nil(init) ->
            finish_result(event, init, Enum.reverse([event | messages]))

          {:ok, event} when is_map(event) ->
            collect(port, os_pid, expected_model, deadline, init, [event | messages])

          _ ->
            stop_tree(port, os_pid, {:error, :invalid_cli_stream})
        end

      {^port, {:data, {:noeol, fragment}}} ->
        if String.trim(fragment) == "" do
          collect(port, os_pid, expected_model, deadline, init, messages)
        else
          stop_tree(port, os_pid, {:error, :invalid_cli_stream})
        end

      {^port, {:exit_status, status}} ->
        if init,
          do: {:error, {:claude_cli_exit, status}},
          else: {:error, :missing_init_attestation}
    after
      remaining -> stop_tree(port, os_pid, {:unknown, :claude_cli_timeout})
    end
  end

  defp attest(event, expected_model) do
    cond do
      event["model"] != expected_model -> {:error, :model_attestation_drift}
      event["claude_code_version"] != @reviewed_version -> {:error, :version_attestation_drift}
      event["tools"] != [] -> {:error, :tool_attestation_drift}
      event["mcp_servers"] != [] -> {:error, :mcp_attestation_drift}
      event["slash_commands"] != [] -> {:error, :slash_command_attestation_drift}
      true -> :ok
    end
  end

  defp finish_result(%{"is_error" => true}, _init, _messages), do: {:error, :claude_cli_error}

  defp finish_result(event, init, messages) do
    with result when is_binary(result) <- event["result"],
         {:ok, output} when is_map(output) <- Jason.decode(result) do
      {:ok,
       %{
         output: output,
         provider: :claude_cli,
         model: init["model"],
         provenance: provenance(),
         raw_response: Jason.encode!(messages),
         usage: usage(event["usage"])
       }}
    else
      _ -> {:error, :missing_structured_output}
    end
  end

  defp usage(usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      plan_calls: 1
    }
  end

  defp usage(_usage), do: %{input_tokens: 0, output_tokens: 0, plan_calls: 1}

  defp stop_tree(port, os_pid, result) do
    children = descendants(os_pid) |> Enum.reverse()
    Enum.each(children, &signal(&1, "-TERM"))
    Process.sleep(20)
    Enum.filter(children, &alive?/1) |> Enum.each(&signal(&1, "-KILL"))

    if Port.info(port), do: Port.close(port)
    result
  end

  defp signal(pid, signal),
    do: System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))

  defp descendants(pid) do
    children =
      case System.cmd("pgrep", ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
        {output, 0} -> output |> String.split() |> Enum.map(&String.to_integer/1)
        _ -> []
      end

    children ++ Enum.flat_map(children, &descendants/1)
  end

  defp private_workspace! do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "sdr-agent-claude-#{suffix}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
