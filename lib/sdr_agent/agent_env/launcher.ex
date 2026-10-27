defmodule SdrAgent.AgentEnv.Launcher do
  @moduledoc """
  Phase P0, the agent environment's pre-lease readiness check (plan
  `claude-c2star-s1-environment-plan-r2.md` sections 5.4 and 6.1; AC2,
  AC6; ADR-0004 agent-environment amendment item 2; Codex rulings
  `b684dba9` Q1 and the `31b72fea` review).

  `check/1` is a pure function of one inputs map, which the real caller
  (`mix sdr.agent_env check`) fills with the VM's effective resolved
  configuration, Mix's real build and deps paths, and `probe/2`:

      %{
        intent: :provision | :run,
        env: %{"SDR_MODEL_PROVIDER" => ...},
        root: root,
        build_path: path,
        deps_path: path,
        config: %{
          repo: keyword,
          endpoint_http: keyword,
          anchor_sinks: list,
          witness_store_root: path | nil,
          suppression_check: module,
          otel_capture_content: boolean
        },
        connect: (ip, port -> {:ok, term} | {:error, atom})
      }

  It returns `:ok` or `{:error, reason}` with a fixed reason atom, in this
  order: malformed inputs (`:invalid_inputs`); an `SDR_MODEL_PROVIDER`
  other than unset, `fake` or `claude_cli` (`:provider_refused`; never a
  fallback to the Fake); the Repo target (`:repo_target_refused` unless
  exactly `sdr_agent_agentenv` on `localhost`/`127.0.0.1`:5520 with `url`,
  `socket`, `socket_dir` and `endpoints` absent or nil); HTTP
  (`:port_refused` unless `127.0.0.1:4130`); the port probe of
  `{127, 0, 0, 1}`:4130 (`:port_in_use` for `{:ok, _}`, `:port_probe_failed`
  for any error but `:econnrefused`); the private root and its `build`,
  `deps`, `state`, `evidence`, `anchors` and `tmp` (`:root_refused` unless
  each is a physical 0700 directory); Mix's build and deps paths
  (`:build_paths_refused` unless absolute, normalized, at or under the
  root with every component a real directory, never a symlink, and no
  `.devenv` component); the witness root (`:witness_root_missing`); the
  anchor sinks (`:anchor_sinks_refused` unless exactly one file sink in a
  physical directory at or under `<root>/anchors`); the suppression check
  (`:suppression_check_not_store`); content capture
  (`:otel_capture_refused`); the classification `State.classify(root,
  :unknown)` (`:lease_held`, `:quarantined`, `:not_fresh` for provision,
  `:environment_unbound` for run); and, only when `claude_cli` is
  requested, `SpendReady.preflight/1` (`:agent_env_not_spend_ready`).

  It takes no lease, writes no file, opens no Repo, reads no database,
  grants no authority, and never logs, inspects or returns its inputs.

  `probe/2` is the production port probe: one `:gen_tcp.connect/4` with a
  finite timeout (1000 ms), closing any socket it opened before it
  returns `{:ok, :listening}`; any error passes through unchanged, so only
  `:econnrefused` reads as free.
  """

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.SpendReady
  alias SdrAgent.AgentEnv.State
  alias SdrAgent.Audit.AnchorSinks.FileSink
  alias SdrAgent.SDR.SuppressionCheck

  @loopback {127, 0, 0, 1}
  @probe_timeout_ms 1_000
  @providers [nil, "fake", "claude_cli"]
  @subdirectories ["build", "deps", "state", "evidence", "anchors", "tmp"]
  @connection_overrides [:url, :socket, :socket_dir, :endpoints]

  @type inputs :: %{
          intent: :provision | :run,
          env: %{optional(String.t()) => String.t()},
          root: Path.t(),
          build_path: Path.t(),
          deps_path: Path.t(),
          config: map(),
          connect: (:inet.ip_address(), :inet.port_number() -> {:ok, term()} | {:error, atom()})
        }

  @doc "Phase P0 (see the moduledoc): `:ok` or the first failing item's fixed reason."
  @spec check(inputs() | term()) :: :ok | {:error, atom()}
  def check(inputs) do
    with :ok <- shape(inputs),
         :ok <- provider(inputs.env),
         :ok <- repo_target(inputs.config.repo),
         :ok <- http(inputs.config.endpoint_http),
         :ok <- port_free(inputs.connect),
         :ok <- private_root(inputs.root),
         :ok <- build_paths(inputs),
         :ok <- witness(inputs.config.witness_store_root),
         :ok <- anchor_sinks(inputs.config.anchor_sinks, inputs.root),
         :ok <- suppression(inputs.config.suppression_check),
         :ok <- capture(inputs.config.otel_capture_content),
         :ok <- classification(inputs.intent, inputs.root) do
      spend_ready(inputs)
    end
  end

  @doc "The production port probe (see the moduledoc)."
  @spec probe(:inet.ip_address(), :inet.port_number()) :: {:ok, :listening} | {:error, atom()}
  def probe(ip, port) do
    case :gen_tcp.connect(ip, port, [:binary, active: false], @probe_timeout_ms) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        {:ok, :listening}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _other ->
        {:error, :probe_failed}
    end
  end

  ## Shape and provider

  defp shape(%{
         intent: intent,
         env: env,
         root: root,
         build_path: build_path,
         deps_path: deps_path,
         config: config,
         connect: connect
       })
       when intent in [:provision, :run] and is_map(env) and is_binary(root) and
              is_binary(build_path) and is_binary(deps_path) and is_function(connect, 2) do
    if config_shape?(config), do: :ok, else: {:error, :invalid_inputs}
  end

  defp shape(_malformed), do: {:error, :invalid_inputs}

  defp config_shape?(%{
         repo: repo,
         endpoint_http: http,
         anchor_sinks: sinks,
         witness_store_root: witness,
         suppression_check: suppression,
         otel_capture_content: capture
       }) do
    keyword?(repo) and keyword?(http) and is_list(sinks) and optional_path?(witness) and
      is_atom(suppression) and is_boolean(capture)
  end

  defp config_shape?(_malformed), do: false

  defp keyword?(value), do: is_list(value) and Keyword.keyword?(value)
  defp optional_path?(value), do: is_nil(value) or is_binary(value)

  defp provider(env) do
    if Map.get(env, "SDR_MODEL_PROVIDER") in @providers,
      do: :ok,
      else: {:error, :provider_refused}
  end

  ## The Repo target, HTTP and the port

  defp repo_target(repo) do
    target? =
      Keyword.get(repo, :database) == AgentEnv.database() and
        Keyword.get(repo, :hostname) in ["localhost", "127.0.0.1"] and
        Keyword.get(repo, :port) == 5520 and
        Enum.all?(@connection_overrides, &is_nil(Keyword.get(repo, &1)))

    if target?, do: :ok, else: {:error, :repo_target_refused}
  end

  defp http(http) do
    if Keyword.get(http, :ip) == @loopback and Keyword.get(http, :port) == AgentEnv.http_port(),
      do: :ok,
      else: {:error, :port_refused}
  end

  defp port_free(connect) do
    case connect.(@loopback, AgentEnv.http_port()) do
      {:error, :econnrefused} -> :ok
      {:ok, _socket} -> {:error, :port_in_use}
      _unclear -> {:error, :port_probe_failed}
    end
  rescue
    _error -> {:error, :port_probe_failed}
  catch
    :exit, _reason -> {:error, :port_probe_failed}
  end

  ## The private root and the physical paths

  defp private_root(root) do
    dirs = [root | Enum.map(@subdirectories, &Path.join(root, &1))]

    if normalized?(root) and Enum.all?(dirs, &private_directory?/1),
      do: :ok,
      else: {:error, :root_refused}
  end

  defp private_directory?(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory, mode: mode}} -> Bitwise.band(mode, 0o777) == 0o700
      _other -> false
    end
  end

  defp build_paths(%{root: root, build_path: build_path, deps_path: deps_path}) do
    if Enum.all?([build_path, deps_path], &(physical_under?(&1, root) and not devenv?(&1))),
      do: :ok,
      else: {:error, :build_paths_refused}
  end

  defp devenv?(path), do: ".devenv" in Path.split(path)

  # `path` is absolute and normalized (no `.`/`..`), at or under `base`, and
  # every component from `base` down is a real directory, never a symlink:
  # a symlink component is refused even when it resolves inside `base`.
  defp physical_under?(path, base) do
    relative =
      cond do
        not normalized?(path) -> nil
        path == base -> []
        String.starts_with?(path, base <> "/") -> path |> Path.relative_to(base) |> Path.split()
        true -> nil
      end

    is_list(relative) and
      Enum.all?([base | Enum.scan(relative, base, &Path.join(&2, &1))], &directory?/1)
  end

  defp normalized?(path), do: Path.type(path) == :absolute and Path.expand(path) == path

  defp directory?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  ## Runtime configuration

  defp witness(root) when is_binary(root) and root != "", do: :ok
  defp witness(_missing), do: {:error, :witness_root_missing}

  defp anchor_sinks([{:file, FileSink, options}], root) when is_list(options) do
    directory = Keyword.get(options, :directory)

    if is_binary(directory) and physical_under?(directory, Path.join(root, "anchors")),
      do: :ok,
      else: {:error, :anchor_sinks_refused}
  end

  defp anchor_sinks(_other, _root), do: {:error, :anchor_sinks_refused}

  defp suppression(SuppressionCheck.Store), do: :ok
  defp suppression(_other), do: {:error, :suppression_check_not_store}

  defp capture(false), do: :ok
  defp capture(_on), do: {:error, :otel_capture_refused}

  ## Classification and the requested real provider

  defp classification(intent, root) do
    case {intent, State.classify(root, :unknown)} do
      {_intent, {:leased, _mode}} -> {:error, :lease_held}
      {_intent, {:quarantine, _reason}} -> {:error, :quarantined}
      {:provision, :fresh} -> :ok
      {:provision, {:bound, _binding}} -> {:error, :not_fresh}
      {:run, {:bound, _binding}} -> :ok
      {:run, :fresh} -> {:error, :environment_unbound}
    end
  end

  defp spend_ready(%{env: env, root: root}) do
    if Map.get(env, "SDR_MODEL_PROVIDER") == "claude_cli" do
      views = %{
        environment: State.read(root, :environment),
        authorization: State.read(root, :authorization),
        claim: State.read(root, :claim)
      }

      # A dynamic call: S1's fail-closed body returns one fixed refusal, and
      # the type checker would otherwise reject the :ok branch S2 needs.
      case apply(SpendReady, :preflight, [views]) do
        :ok -> :ok
        _refused -> {:error, :agent_env_not_spend_ready}
      end
    else
      :ok
    end
  end
end
