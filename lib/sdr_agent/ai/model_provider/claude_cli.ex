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

  The child environment always unsets the Bedrock/Vertex/Foundry routing
  variables (`@route_flags`, `@route_urls`), so an SDR-stamped CLI cannot
  bypass the local proxy. If the operator environment enables one of those
  routes the call is refused (`:witness_bypass_environment`) instead of
  silently re-routed. The `:environment` option (a map) replaces the
  operator environment for that check in hermetic tests.

  One GenServer serialises every call (ADR-0004, C8: concurrency 1).

  ## The supervised server (Q0.1)

  When `SDR_MODEL_PROVIDER=claude_cli` selects this provider
  (`SdrAgent.AI.ModelProvider.Runtime`), the application starts exactly one
  instance registered as `server/0`. `complete/2` without `:server` calls
  that instance; a server that is not running is `{:error,
  :provider_not_running}`, never an exit. Claude CLI has no no-call probe
  for the init attestation (model, version, tools, MCP servers and slash
  commands are reported only by a session that also sends a model
  request), so boot records the attestation as `:pending` — checked at
  the first call — together with whether `llm-proxy-shim` was found. Every
  call then records its init outcome (`:attested`, or `:drift` with the
  reason) in a protected ETS table named after the server, which
  `attestation/1` reads without waiting behind a running call. It holds no
  prompt, output or credential.
  """

  use GenServer
  @behaviour SdrAgent.AI.ModelProvider

  require Logger

  alias SdrAgent.Clock

  @default_timeout 120_000
  @route_flags ~w(CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY)
  @route_urls ~w(ANTHROPIC_BEDROCK_BASE_URL ANTHROPIC_VERTEX_BASE_URL ANTHROPIC_FOUNDRY_BASE_URL)
  @invocation_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @traceparent ~r/\A00-([0-9a-f]{32})-([0-9a-f]{16})-(?:00|01)\z/
  @model_alias "opus"
  @resolved_model "claude-opus-5-5"
  @reviewed_version "2.1.291"
  # Versioned stdin prompt builder (S12 P1): any change to `render_prompt/2`
  # must bump this, so the wire-witness projection never re-derives a
  # historical invocation's prompt with different code.
  @prompt_builder "prompt-builder/1"
  @server __MODULE__

  @doc """
  Starts a server. Options: `:name` (registers it and keeps its attestation
  status readable by name), `:command`, `:command_args`, `:cli_args`,
  `:timeout` (ms), `:expected_model`, `:environment`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "The registered name of the application's one supervised server."
  def server, do: @server

  @doc "Whether `server` (a name or pid) is a live process on this node."
  def running?(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  The last init attestation of the named `server`: `%{status: :pending |
  :attested | :drift, reason, model, version, at, command?}`, or
  `%{status: :not_running}`. Never blocks on a running call.
  """
  def attestation(server \\ @server) when is_atom(server) do
    case :ets.lookup(server, :attestation) do
      [{:attestation, attestation}] -> attestation
      [] -> %{status: :not_running}
    end
  rescue
    ArgumentError -> %{status: :not_running}
  end

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
    server = Keyword.get(opts, :server, @server)

    if running?(server),
      do: GenServer.call(server, {:complete, request}, :infinity),
      else: {:error, :provider_not_running}
  end

  @impl true
  def init(opts) do
    state = %{
      command:
        Keyword.get_lazy(opts, :command, fn -> System.find_executable("llm-proxy-shim") end),
      command_args: Keyword.get(opts, :command_args, ["claude"]),
      cli_args: Keyword.get(opts, :cli_args, []),
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      expected_model: Keyword.get(opts, :expected_model, @resolved_model),
      environment: Keyword.get(opts, :environment),
      table: status_table(Keyword.get(opts, :name))
    }

    preflight(state)
    {:ok, state}
  end

  # Boot preflight: no model call is spent. The attestation is checked at
  # the first call; only the launcher's presence is known now.
  defp preflight(%{table: nil}), do: :ok

  defp preflight(state) do
    if is_nil(state.command),
      do: Logger.warning("ClaudeCLI selected but llm-proxy-shim was not found on PATH")

    note(state, %{status: :pending, reason: nil, model: nil, version: nil})
  end

  defp status_table(name) when is_atom(name) and not is_nil(name),
    do: :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])

  defp status_table(_name), do: nil

  defp note(%{table: nil}, _attestation), do: :ok

  defp note(state, attestation) do
    attestation =
      Map.merge(attestation, %{at: Clock.utc_now(), command?: not is_nil(state.command)})

    :ets.insert(state.table, {:attestation, attestation})
    :ok
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
      launch(
        request,
        state,
        witness_env ++ Enum.map(@route_flags ++ @route_urls, &{~c"#{&1}", false})
      )
    end
  end

  defp witness_env(%{model_invocation_id: id, traceparent: traceparent})
       when is_binary(id) and is_binary(traceparent) do
    with true <- Regex.match?(@invocation_id, id),
         [_, trace_id, span_id] <- Regex.run(@traceparent, traceparent),
         false <- trace_id == String.duplicate("0", 32) or span_id == String.duplicate("0", 16) do
      {:ok,
       [
         {~c"SDR_MODEL_INVOCATION_ID", String.to_charlist(id)},
         {~c"SDR_TRACEPARENT", String.to_charlist(traceparent)}
       ]}
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

  defp launch(request, state, child_env) do
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
        {:env, child_env},
        {:line, 1_048_576}
      ])

    os_pid = port |> Port.info(:os_pid) |> elem(1)
    result = collect(port, os_pid, state, deadline(state.timeout), nil, [])
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

  defp collect(port, os_pid, state, deadline, init, messages) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"type" => "system", "subtype" => "init"} = event} ->
            case attest(event, state.expected_model) do
              :ok ->
                attested(state, event)
                collect(port, os_pid, state, deadline, event, [event | messages])

              {:error, reason} ->
                drifted(state, reason)
                stop_tree(port, os_pid, {:error, reason})
            end

          {:ok, %{"type" => "result"} = event} when not is_nil(init) ->
            finish_result(event, init, Enum.reverse([event | messages]))

          {:ok, event} when is_map(event) ->
            collect(port, os_pid, state, deadline, init, [event | messages])

          _ ->
            stop_tree(port, os_pid, {:error, :invalid_cli_stream})
        end

      {^port, {:data, {:noeol, fragment}}} ->
        if String.trim(fragment) == "" do
          collect(port, os_pid, state, deadline, init, messages)
        else
          stop_tree(port, os_pid, {:error, :invalid_cli_stream})
        end

      {^port, {:exit_status, status}} ->
        if init do
          {:error, {:claude_cli_exit, status}}
        else
          drifted(state, :missing_init_attestation)
          {:error, :missing_init_attestation}
        end
    after
      remaining -> stop_tree(port, os_pid, {:unknown, :claude_cli_timeout})
    end
  end

  defp attested(state, event) do
    note(state, %{
      status: :attested,
      reason: nil,
      model: event["model"],
      version: event["claude_code_version"]
    })
  end

  defp drifted(state, reason),
    do: note(state, %{status: :drift, reason: reason, model: nil, version: nil})

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
