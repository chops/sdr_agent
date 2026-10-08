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

  ## Process lifecycle (Q0.1 review)

    * **End-to-end deadline.** `:timeout` counts from `complete/2`, queue
      wait included. A request reaching the front with less than
      `min(1 s, timeout / 2)` left is refused unlaunched with
      `{:error, :provider_queue_timeout}`; a launched one gets only the time
      left before its tree is killed (`{:unknown, :claude_cli_timeout}`).
    * **Abandoned callers.** A request whose caller died while it was
      queued is dropped unlaunched; a caller that dies during its call
      stops that CLI tree (`{:unknown, :caller_down}`, nobody receives it).
    * **Quiescent on return.** A call returns only after its process tree is
      gone and its workspace removed (a CLI still running briefly after its
      result is given 2 s to exit, then killed).
    * **Crash safety and admission.** Every launch is opened by the
      server's `SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper`, which owns the
      OS pid before the process runs and kills tracked trees (and removes
      workspaces) if the server dies, even by `:kill`. A named server is
      admitted only while it holds the reaper lease; a lease still held by
      a predecessor's reaper (cleanup running, or never confirmed) or a
      tree of its own it could not confirm stopped makes every call
      `{:error, :provider_not_quiescent}` until that clears (`admission/1`
      reports it). A launch whose receipt never arrived (reaper died, or
      the handshake outlived the deadline) is an unknown outcome
      (`{:unknown, :reaper_down}` / `{:unknown, :launch_handshake_timeout}`)
      and also closes admission: until a late receipt makes it known and
      it is confirmed stopped, or an operator `Reaper.release/1` attests it
      is gone. A reaper lost while the server is idle is replaced only when
      no launch is unknown or unconfirmed.
    * `:timeout` must be at least 1000 ms (`{:error, {:invalid_timeout, t}}`
      otherwise); the deadline is absolute from enqueue, so it is checked
      again before launch and bounds the run.
  """

  use GenServer
  @behaviour SdrAgent.AI.ModelProvider

  require Logger

  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.ChildEnv
  alias SdrAgent.Clock

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
  @server __MODULE__
  @min_launch_ms 1_000
  @min_timeout 1_000
  @exit_grace_ms 2_000
  @predecessor_wait_ms 3_000

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
  Whether the named `server` admits calls: `%{admission: :open}`,
  `%{admission: :blocked, reason: reason}` (`:previous_cli_not_quiescent`,
  `:previous_cleanup_unconfirmed`, `:cli_not_quiescent`), or
  `%{admission: :not_running}`. Never blocks on a running call.
  """
  def admission(server \\ @server) when is_atom(server) do
    case :ets.lookup(server, :admission) do
      [{:admission, :open}] -> %{admission: :open}
      [{:admission, {:blocked, reason}}] -> %{admission: :blocked, reason: reason}
      [] -> %{admission: :not_running}
    end
  rescue
    ArgumentError -> %{admission: :not_running}
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
      do:
        GenServer.call(
          server,
          {:complete, request, System.monotonic_time(:millisecond)},
          :infinity
        ),
      else: {:error, :provider_not_running}
  end

  @impl true
  def init(opts) do
    case Keyword.get(opts, :timeout, @default_timeout) do
      timeout when is_integer(timeout) and timeout >= @min_timeout -> start(opts, timeout)
      timeout -> {:stop, {:invalid_timeout, timeout}}
    end
  end

  defp start(opts, timeout) do
    name = Keyword.get(opts, :name)

    state = %{
      name: name,
      reaper: nil,
      reaper_opts: Keyword.get(opts, :reaper, []),
      blocked: nil,
      lost_reaper: nil,
      predecessor: nil,
      stuck: [],
      unconfirmed: %{},
      command:
        Keyword.get_lazy(opts, :command, fn -> System.find_executable("llm-proxy-shim") end),
      command_args: Keyword.get(opts, :command_args, ["claude"]),
      cli_args: Keyword.get(opts, :cli_args, []),
      timeout: timeout,
      expected_model: Keyword.get(opts, :expected_model, @resolved_model),
      environment: Keyword.get(opts, :environment),
      table: status_table(name)
    }

    state = state |> await_predecessor() |> admit()
    preflight(state)
    {:ok, state}
  end

  # A predecessor's reaper still cleaning up gets a bounded wait; past it
  # this server starts closed and opens when that reaper exits.
  defp await_predecessor(state) do
    with {:held, holder} <- Reaper.lease(state.name),
         true <- Process.alive?(holder) do
      ref = Process.monitor(holder)

      receive do
        {:DOWN, ^ref, :process, ^holder, _reason} -> state
      after
        @predecessor_wait_ms -> %{state | predecessor: {holder, ref}}
      end
    else
      _ -> state
    end
  end

  # Takes the reaper lease only when nothing of this server is unknown or
  # unconfirmed.
  defp admit(%{reaper: nil, stuck: [], unconfirmed: unconfirmed} = state)
       when map_size(unconfirmed) == 0 do
    opts =
      if state.lost_reaper,
        do: Keyword.put(state.reaper_opts, :takeover, state.lost_reaper),
        else: state.reaper_opts

    case Reaper.start(state.name, opts) do
      {:ok, reaper} ->
        sync_admission(%{state | reaper: reaper, blocked: nil, lost_reaper: nil})

      {:blocked, reason} ->
        if state.blocked != reason,
          do: Logger.error("ClaudeCLI calls refused: #{reason} (see ClaudeCLI.Reaper)")

        sync_admission(%{state | blocked: reason})
    end
  end

  defp admit(state), do: sync_admission(state)

  # A tree this server could not confirm stopped is retried before a call.
  defp prune_stuck(%{stuck: []} = state), do: state

  defp prune_stuck(state) do
    stuck = Enum.reject(state.stuck, &stopped?(state, &1))
    sync_admission(%{state | stuck: stuck})
  end

  defp stopped?(state, {workspace, os_pid}) do
    case Reaper.kill_tree(os_pid, state.reaper_opts) do
      :ok ->
        File.rm_rf(workspace)
        if state.reaper, do: Reaper.done(state.reaper, workspace)
        true

      :timeout ->
        false
    end
  end

  defp admitted?(state),
    do: not is_nil(state.reaper) and state.stuck == [] and map_size(state.unconfirmed) == 0

  defp sync_admission(%{table: nil} = state), do: state

  defp sync_admission(state) do
    admission =
      cond do
        is_nil(state.reaper) -> {:blocked, state.blocked || :previous_cleanup_unconfirmed}
        state.stuck != [] or map_size(state.unconfirmed) > 0 -> {:blocked, :cli_not_quiescent}
        true -> :open
      end

    :ets.insert(state.table, {:admission, admission})
    state
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
  def handle_call({:complete, request, enqueued_at}, {caller, _tag}, state) do
    state = state |> prune_stuck() |> admit()
    deadline = enqueued_at + state.timeout

    cond do
      # Abandoned while queued: nobody waits for this call, so none starts.
      not Process.alive?(caller) ->
        {:reply, {:error, :caller_down}, state}

      not admitted?(state) ->
        {:reply, {:error, :provider_not_quiescent}, state}

      not launchable?(deadline, state.timeout) ->
        {:reply, {:error, :provider_queue_timeout}, state}

      true ->
        {result, state} = run(request, state, caller, deadline)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info({port, {:data, _data}}, state) when is_port(port), do: {:noreply, state}

  def handle_info({port, {:exit_status, _status}}, state) when is_port(port),
    do: {:noreply, state}

  # Lost while idle: every launch of this server is confirmed gone or still
  # in `stuck`, so a new reaper may take over the dead one's lease.
  def handle_info({:DOWN, _ref, :process, reaper, _reason}, %{reaper: reaper} = state) do
    Logger.warning("ClaudeCLI reaper exited; taking over its lease")
    {:noreply, admit(%{state | reaper: nil, lost_reaper: reaper})}
  end

  def handle_info({:DOWN, ref, :process, holder, _reason}, %{predecessor: {holder, ref}} = state),
    do: {:noreply, admit(%{state | predecessor: nil})}

  # A late launch receipt: the launch is now known, so it can be confirmed
  # stopped (or, if it failed, it never ran).
  def handle_info({ref, reply}, state) when is_map_key(state.unconfirmed, ref) do
    {workspace, unconfirmed} = Map.pop(state.unconfirmed, ref)
    state = %{state | unconfirmed: unconfirmed}

    state =
      case reply do
        {:ok, _port, os_pid} ->
          prune_stuck(%{state | stuck: [{workspace, os_pid} | state.stuck]})

        {:error, _reason} ->
          File.rm_rf(workspace)
          if state.reaper, do: Reaper.done(state.reaper, workspace)
          state
      end

    {:noreply, admit(state)}
  end

  # After an operator `Reaper.release/1`: the operator attests that no CLI
  # of this server is left, including launches whose outcome is unknown.
  def handle_info(:admission_check, state) do
    Enum.each(state.unconfirmed, fn {_key, workspace} -> File.rm_rf(workspace) end)
    {:noreply, admit(%{state | unconfirmed: %{}})}
  end

  # Expired, or too little time left to be worth launching.
  defp launchable?(deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)
    remaining > 0 and remaining >= min(@min_launch_ms, div(timeout, 2))
  end

  defp run(_request, %{command: nil} = state, _caller, _deadline),
    do: {{:error, :llm_proxy_shim_not_found}, state}

  defp run(request, state, caller, deadline) do
    with {:ok, witness_env} <- witness_env(Map.get(request, :witness)),
         :ok <- refuse_bypass(state.environment || System.get_env()) do
      launch(request, state, caller, deadline, witness_env)
    else
      error -> {error, state}
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

  defp launch(request, state, caller, deadline, witness_env) do
    workspace = workspace_path()
    Reaper.track(state.reaper, workspace)
    create_workspace!(workspace)
    prompt_path = Path.join(workspace, "prompt")

    prompt = render_prompt(request.prompt, Zoi.to_json_schema(request.schema))

    File.write!(prompt_path, prompt, [:binary])
    File.chmod!(prompt_path, 0o600)

    # The reaper opens the port with the child environment it builds from
    # this allowlist and these values (SdrAgent.ChildEnv): no parent secret
    # reaches the CLI; the Bedrock/Vertex/Foundry routes are removed.
    child_env =
      {@child_env_allow, witness_env ++ Enum.map(@route_flags ++ @route_urls, &{&1, nil})}

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, shell_args(state, prompt_path)},
      {:cd, workspace},
      {:line, 1_048_576}
    ]

    # The absolute deadline is checked again after preparation and bounds
    # the launch handshake.
    with true <- launchable?(deadline, state.timeout) || {:error, :provider_queue_timeout},
         {:ok, port, os_pid} <-
           Reaper.open(
             state.reaper,
             workspace,
             {:spawn_executable, "/bin/sh"},
             {port_opts, child_env},
             deadline
           ) do
      watch = Process.monitor(caller)
      result = collect(port, os_pid, Map.put(state, :caller, watch), deadline, nil, [])
      Process.demonitor(watch, [:flush])
      {result, settle(state, port, os_pid, workspace)}
    else
      {:pending, ref} ->
        unknown(state, ref, workspace, :launch_handshake_timeout)

      {:unknown, :reaper_down} ->
        unknown(state, make_ref(), workspace, :reaper_down)

      error ->
        File.rm_rf(workspace)
        Reaper.done(state.reaper, workspace)
        {error, state}
    end
  end

  # No launch receipt: the CLI may be running (and may have sent its
  # request), so the outcome is unknown and admission closes on it.
  defp unknown(state, key, workspace, reason) do
    Logger.error("ClaudeCLI launch outcome unknown (#{reason}); calls refused until confirmed")
    state = sync_admission(%{state | unconfirmed: Map.put(state.unconfirmed, key, workspace)})
    {{:unknown, reason}, state}
  end

  # The call returns only once its process tree is confirmed gone; one that
  # cannot be confirmed stays tracked and closes admission.
  defp settle(state, port, os_pid, workspace) do
    case quiesce(port, os_pid, state.reaper_opts) do
      :ok ->
        File.rm_rf!(workspace)
        Reaper.done(state.reaper, workspace)
        state

      :timeout ->
        Logger.error("ClaudeCLI could not confirm a CLI process tree stopped; calls refused")
        sync_admission(%{state | stuck: [{workspace, os_pid} | state.stuck]})
    end
  end

  # A CLI still running after its result gets a short grace to exit, then
  # its tree is killed.
  defp quiesce(port, os_pid, opts) do
    if Reaper.alive?(os_pid) do
      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        @exit_grace_ms -> :ok
      end

      if Reaper.alive?(os_pid), do: Reaper.kill_tree(os_pid, opts), else: :ok
    else
      :ok
    end
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
                stop_tree(os_pid, state, {:error, reason})
            end

          {:ok, %{"type" => "result"} = event} when not is_nil(init) ->
            finish_result(event, init, Enum.reverse([event | messages]))

          {:ok, event} when is_map(event) ->
            collect(port, os_pid, state, deadline, init, [event | messages])

          _ ->
            stop_tree(os_pid, state, {:error, :invalid_cli_stream})
        end

      {^port, {:data, {:noeol, fragment}}} ->
        if String.trim(fragment) == "" do
          collect(port, os_pid, state, deadline, init, messages)
        else
          stop_tree(os_pid, state, {:error, :invalid_cli_stream})
        end

      {^port, {:exit_status, status}} ->
        if init do
          {:error, {:claude_cli_exit, status}}
        else
          drifted(state, :missing_init_attestation)
          {:error, :missing_init_attestation}
        end

      {:DOWN, ref, :process, _caller, _reason} when ref == state.caller ->
        stop_tree(os_pid, state, {:unknown, :caller_down})

      # The reaper (port owner) is gone: stop the tree; the server handles
      # the loss once this call has settled.
      {:DOWN, _ref, :process, reaper, _reason} = down when reaper == state.reaper ->
        send(self(), down)
        stop_tree(os_pid, state, {:unknown, :reaper_down})
    after
      remaining -> stop_tree(os_pid, state, {:unknown, :claude_cli_timeout})
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

  # Kills the whole tree (root included); `settle/4` confirms it is gone.
  defp stop_tree(os_pid, state, result) do
    Reaper.kill_tree(os_pid, state.reaper_opts)
    result
  end

  defp workspace_path do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "sdr-agent-claude-#{suffix}")
  end

  defp create_workspace!(path) do
    File.mkdir!(path)
    File.chmod!(path, 0o700)
  end
end
