defmodule SdrAgent.AI.ModelProvider.ClaudeCLI do
  @moduledoc """
  Serialized, tool-free structured-output adapter for the local Claude CLI.

  Every call launches through `llm-proxy-shim`, requires an init attestation
  with no tools, MCP servers, or slash commands, and pins the `opus` alias to a
  reviewed resolved model ID. The result must be exactly one JSON object,
  optionally wrapped in a single Markdown code fence (as the model sometimes
  formats longer answers). Protocol failures never return process output.
  Timeouts terminate the complete observed process tree.

  ## Wire-witness correlation (ADR-0005 S12, C6)

  Each request must carry the facade's `:witness` — the reserved invocation
  UUID (lowercase, RFC 9562 version/variant) and a W3C version-00
  `traceparent` with non-zero ids and its own `00`/`01` flags. They are
  validated and passed **only** in this call's child environment as
  `SDR_MODEL_INVOCATION_ID` / `SDR_TRACEPARENT`, which `llm-proxy-shim`
  turns into loopback-only correlation headers; the BEAM environment is
  never modified. Missing or malformed context refuses the call
  (`:invalid_witness_context`) before any process starts.

  The child environment is an explicit allowlist (`SdrAgent.ChildEnv`,
  `@child_env_allow`): every other parent variable — the audit-anchor
  signing key and any `*_KEY`/`*_TOKEN`/`*_SECRET` included — is removed.
  It always unsets the Bedrock/Vertex/Foundry routing
  variables (`@route_flags`, `@route_urls`), so an SDR-stamped CLI cannot
  bypass the local proxy. If the operator environment enables one of those
  routes the call is refused (`:witness_bypass_environment`) instead of
  silently re-routed. The `:environment` option (a map) replaces the
  operator environment for that check in hermetic tests.

  One GenServer serialises every call (ADR-0004, C8: concurrency 1).
  """

  use GenServer
  @behaviour SdrAgent.AI.ModelProvider

  alias SdrAgent.ChildEnv

  @default_timeout 120_000
  @route_flags ~w(CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY)
  @route_urls ~w(ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL)
  # The only parent variables the shim and Claude Code receive (besides
  # `SdrAgent.ChildEnv`'s base): proxy routing the shim validates, the
  # Claude Code config/binary location, XDG dirs and TLS roots. Everything
  # else — the anchor signing key included — is removed (security fix).
  @child_env_allow ChildEnv.xdg() ++
                     ~w(TERM LLM_OTEL_PROXY_URL LLM_PROXY_SHIM_CLAUDE_BIN
                        ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR SSL_CERT_FILE
                        NIX_SSL_CERT_FILE NODE_EXTRA_CA_CERTS)
  @invocation_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @traceparent ~r/\A00-([0-9a-f]{32})-([0-9a-f]{16})-(?:00|01)\z/
  @model_alias "opus"
  @resolved_model "claude-opus-5-5"
  @reviewed_version "2.1.291"
  # Versioned stdin prompt builder (S12 P1): any change to `render_prompt/2`
  # must bump this, so the wire-witness projection never re-derives a
  # historical invocation's prompt with different code.
  @prompt_builder "prompt-builder/1"

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
        "prompt_builder" => @prompt_builder,
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

  @doc "The prompt-builder version recorded in the provenance of every call."
  def prompt_builder, do: @prompt_builder

  @doc """
  The exact stdin text of a call (builder `prompt-builder/1`): the prompt,
  the fixed instruction and the JSON schema in `sdr-canonical-json/1`
  (sorted keys), so a schema decoded from the stored request re-renders
  byte-identically.
  """
  def render_prompt(prompt, json_schema) when is_binary(prompt) and is_map(json_schema) do
    prompt <>
      "\nReturn only one JSON object matching this schema:\n" <>
      SdrAgent.Audit.Canonical.encode!(json_schema)
  end

  @doc """
  Unwraps a result consisting of exactly one Markdown code fence (optionally
  `json`); any other text is returned unchanged.
  """
  def unfence(result) when is_binary(result) do
    case Regex.run(~r/\A\s*```(?:json)?\s*\n(.*)\n\s*```\s*\z/s, result, capture: :all_but_first) do
      [inner] -> inner
      nil -> result
    end
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
       expected_model: Keyword.get(opts, :expected_model, @resolved_model),
       environment: Keyword.get(opts, :environment)
     }}
  end

  @impl true
  def handle_call({:complete, request}, _from, state), do: {:reply, run(request, state), state}

  @impl true
  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}
  def handle_info({_port, {:exit_status, _status}}, state), do: {:noreply, state}

  defp run(_request, %{command: nil}), do: {:error, :llm_proxy_shim_not_found}

  defp run(request, state) do
    with {:ok, witness_env} <- witness_env(Map.get(request, :witness)),
         :ok <- refuse_bypass(state.environment || System.get_env()) do
      launch(request, state, witness_env)
    end
  end

  defp witness_env(%{model_invocation_id: id, traceparent: traceparent})
       when is_binary(id) and is_binary(traceparent) do
    with true <- Regex.match?(@invocation_id, id),
         [_, trace_id, span_id] <- Regex.run(@traceparent, traceparent),
         false <- trace_id == String.duplicate("0", 32) or span_id == String.duplicate("0", 16) do
      {:ok, [{"SDR_MODEL_INVOCATION_ID", id}, {"SDR_TRACEPARENT", traceparent}]}
    else
      _ -> {:error, :invalid_witness_context}
    end
  end

  defp witness_env(_witness), do: {:error, :invalid_witness_context}

  defp refuse_bypass(environment) do
    enabled? = fn name ->
      value = environment |> Map.get(name, "") |> String.trim() |> String.downcase()
      if name in @route_flags, do: value not in ["", "0", "false"], else: value != ""
    end

    if Enum.any?(@route_flags ++ @route_urls, enabled?),
      do: {:error, :witness_bypass_environment},
      else: :ok
  end

  defp launch(request, state, witness_env) do
    workspace = private_workspace!()
    prompt_path = Path.join(workspace, "prompt")

    prompt = render_prompt(request.prompt, Zoi.to_json_schema(request.schema))

    File.write!(prompt_path, prompt, [:binary])
    File.chmod!(prompt_path, 0o600)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, shell_args(state, prompt_path)},
        {:cd, workspace},
        {:env,
         ChildEnv.port(@child_env_allow, witness_env) ++
           Enum.map(@route_flags ++ @route_urls, &{~c"#{&1}", false})},
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
         {:ok, output} when is_map(output) <- result |> unfence() |> Jason.decode() do
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
    do:
      System.cmd("kill", [signal, Integer.to_string(pid)],
        stderr_to_stdout: true,
        env: ChildEnv.cmd([])
      )

  defp alive?(pid),
    do:
      match?(
        {_, 0},
        System.cmd("kill", ["-0", Integer.to_string(pid)],
          stderr_to_stdout: true,
          env: ChildEnv.cmd([])
        )
      )

  defp descendants(pid) do
    children =
      case System.cmd("pgrep", ["-P", Integer.to_string(pid)],
             stderr_to_stdout: true,
             env: ChildEnv.cmd([])
           ) do
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
