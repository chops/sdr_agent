defmodule SdrAgent.MacAgent.Launch do
  @moduledoc """
  Closed, pinned subscription-CLI launcher for a claimed remote call.

  The server supplies data, never argv or an executable. Prompt files are
  private and transient. Stdout is bounded to 2 MiB; stderr is discarded.
  Deadlines and failures never cause a second launch. A timed-out child may
  outlive the worker cutoff (owner waiver); this is not proof of quiescence.
  Transcript attestation and settlement remain the hosted application's job.
  """

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.ChildEnv
  alias SdrAgent.MacAgent.Config
  alias SdrAgent.MacAgent.Journal

  @keys ~w(call_id profile_id model_id request_digest prompt schema result_deadline)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @limit 2_097_152
  @child_env ChildEnv.xdg() ++
               ~w(TERM CLAUDE_CONFIG_DIR SSL_CERT_FILE NIX_SSL_CERT_FILE NODE_EXTRA_CA_CERTS)

  @doc "Validate the launch input and construct only the reviewed CLI flags."
  def argv(call) when is_map(call) do
    with true <- Enum.sort(Map.keys(call)) == Enum.sort(@keys),
         true <- text?(call["call_id"], @uuid),
         true <- text?(call["request_digest"], @digest),
         true <- is_binary(call["prompt"]) and String.valid?(call["prompt"]),
         true <- byte_size(call["prompt"]) <= 262_144,
         true <- is_map(call["schema"]) and not is_struct(call["schema"]),
         {:ok, schema} <- Jason.encode(call["schema"]),
         true <- byte_size(schema) <= 262_144,
         {:ok, profile} <- Config.profile(call["profile_id"]),
         true <- profile.resolved_model == call["model_id"],
         {:ok, deadline, _} <- DateTime.from_iso8601(call["result_deadline"]),
         true <- DateTime.compare(deadline, DateTime.utc_now()) == :gt do
      {:ok,
       [
         "-p",
         "--output-format",
         "stream-json",
         "--verbose",
         "--safe-mode",
         "--restricted",
         "--model",
         profile.cli_alias,
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
       ]}
    else
      _ -> {:error, :invalid_call}
    end
  rescue
    _ -> {:error, :invalid_call}
  end

  def argv(_), do: {:error, :invalid_call}

  @doc "Use a rendered private prompt for one callback, then remove its workspace."
  def with_prompt(root, call, callback) do
    with {:ok, _} <- argv(call), :ok <- Journal.prepare(root) do
      dir =
        Path.join(root, "prompt-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))

      case File.mkdir(dir) do
        :ok ->
          try do
            File.chmod!(dir, 0o700)
            path = Path.join(dir, "stdin")
            File.write!(path, "", [:exclusive])
            File.chmod!(path, 0o600)
            File.write!(path, ClaudeCLI.render_prompt(call["prompt"], call["schema"]))
            {:ok, callback.(path)}
          rescue
            _ -> {:error, :launch_failed}
          after
            File.rm_rf(dir)
          end

        _ ->
          {:error, :launch_failed}
      end
    end
  end

  @doc "Run the pinned local child once and return bounded raw stdout. Never retries."
  def run(config, call, options \\ []) do
    with {:ok, argv} <- argv(call),
         true <- call["profile_id"] == config.pins["profile_id"],
         true <- call["model_id"] == config.pins["model_id"],
         :ok <- Config.verify(config),
         {:ok, result} <-
           with_prompt(config.journal_dir, call, &spawn_child(config, call, argv, &1, options)) do
      result
    else
      _ -> {:error, :launch_failed}
    end
  end

  defp spawn_child(config, call, argv, prompt_path, options) do
    script = ~s(prompt="$1"; shift; exec "$@" < "$prompt" 2>/dev/null)
    args = ["-c", script, "sdr-mac-agent", prompt_path, config.executable | argv]
    {:ok, deadline, _} = DateTime.from_iso8601(call["result_deadline"])
    # Cap a hostile/faulty server's deadline; the protocol allows at most 600 s.
    remaining = min(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0), 600_000)
    until = System.monotonic_time(:millisecond) + remaining
    interval = Keyword.get(options, :heartbeat_interval, 15_000)
    heartbeat = Keyword.get(options, :heartbeat, fn -> :ok end)
    pulse = {heartbeat, interval, System.monotonic_time(:millisecond) + interval}

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        {:args, args},
        {:env, ChildEnv.port(@child_env)}
      ])

    try do
      collect(port, until, [], 0, pulse)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect(port, deadline, chunks, size, {heartbeat, interval, next} = pulse) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= deadline ->
        {:error, :child_timeout}

      now >= next ->
        case heartbeat.() do
          {:error, :unauthorized} = error ->
            error

          _transient_or_healthy ->
            collect(
              port,
              deadline,
              chunks,
              size,
              {heartbeat, interval, System.monotonic_time(:millisecond) + interval}
            )
        end

      true ->
        wait_for_child(port, deadline, chunks, size, pulse, min(deadline, next) - now)
    end
  end

  defp wait_for_child(port, deadline, chunks, size, pulse, remaining) do
    receive do
      {^port, {:data, bytes}} ->
        if size + byte_size(bytes) <= @limit,
          do: collect(port, deadline, [bytes | chunks], size + byte_size(bytes), pulse),
          else: {:error, :transcript_too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :child_failed}
    after
      remaining ->
        collect(port, deadline, chunks, size, pulse)
    end
  end

  defp text?(value, regex), do: is_binary(value) and Regex.match?(regex, value)
end
