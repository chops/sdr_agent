defmodule Mix.Tasks.Sdr.AgentEnv do
  @shortdoc "The agent environment's guarded phases (bin/agent-env only)"

  @moduledoc """
  The guarded phases of the agent environment `agentenv-1` (plan
  `claude-c2star-s1-environment-plan-r2.md` sections 5.4 and 6.1; Codex
  rulings `b684dba9` Q1/Q5 and the `31b72fea` review). `bin/agent-env` is
  its only intended caller; it runs under `SDR_AGENT_ENV=agentenv-1` with
  `SDR_AGENT_ENV_STEP` (and, once leased, `SDR_AGENT_ENV_NONCE`), which
  `config/runtime.exs` turns into the leased configuration.

      mix sdr.agent_env check run|provision    P0: Launcher.check/1 (STEP=check)
      mix sdr.agent_env preflight              the bootstrap preflight (STEP=check)
      mix sdr.agent_env lease bootstrap|run    P1: prints SDR_AGENT_ENV_NONCE <nonce>
      mix sdr.agent_env step create|migrate|seed|probe
                                               one guarded bootstrap step (STEP=<step>)
      mix sdr.agent_env publish                environment.json (STEP=check, NONCE)
      mix sdr.agent_env release bootstrap|provisioning|run
                                               P5: removes that lease (STEP=check, NONCE)

  The command set is closed: anything else, including extra arguments and
  `lease provisioning` (S2's provisioning lease API stays separate), is a
  usage error, and nothing is dispatched dynamically. There is no reset,
  drop, reclaim or recovery command. `check`, `preflight`, `lease`,
  `publish` and `release` need check mode, which never starts the
  application or the Repo; `step` needs the configured bootstrap step.
  `check` gathers the VM's effective resolved configuration and Mix's real
  build and deps paths, never substituted values.

  Output is machine lines `SDR_AGENT_ENV_<KEY> <value>`; a successful lease
  prints exactly one `SDR_AGENT_ENV_NONCE <32 lowercase hex>`. A refusal
  raises `Mix.Error` whose message names only the fixed reason, never an
  input, a configuration value, the environment or argv.
  """
  use Mix.Task

  alias SdrAgent.AgentEnv
  alias SdrAgent.AgentEnv.Boot
  alias SdrAgent.AgentEnv.Bootstrap
  alias SdrAgent.AgentEnv.Launcher
  alias SdrAgent.AgentEnv.State

  @requirements ["app.config"]

  @usage """
  usage: mix sdr.agent_env check run|provision | preflight | lease bootstrap|run
         | step create|migrate|seed|probe | publish | release bootstrap|provisioning|run
  """

  @doc false
  @impl Mix.Task
  def run(args) do
    case command(args) do
      {:check, intent} -> check(intent)
      :preflight -> preflight()
      {:lease, mode} -> lease(mode)
      {:step, step} -> step(step)
      :publish -> publish()
      {:release, mode} -> release(mode)
      :usage -> Mix.raise(@usage)
    end
  end

  defp command(["check", "run"]), do: {:check, :run}
  defp command(["check", "provision"]), do: {:check, :provision}
  defp command(["preflight"]), do: :preflight
  defp command(["lease", "bootstrap"]), do: {:lease, :bootstrap}
  defp command(["lease", "run"]), do: {:lease, :run}
  defp command(["step", "create"]), do: {:step, :create}
  defp command(["step", "migrate"]), do: {:step, :migrate}
  defp command(["step", "seed"]), do: {:step, :seed}
  defp command(["step", "probe"]), do: {:step, :probe}
  defp command(["publish"]), do: :publish
  defp command(["release", "bootstrap"]), do: {:release, :bootstrap}
  defp command(["release", "provisioning"]), do: {:release, :provisioning}
  defp command(["release", "run"]), do: {:release, :run}
  defp command(_other), do: :usage

  ## Commands

  defp check(intent) do
    root = check_mode_root!()

    inputs = %{
      intent: intent,
      env: Map.take(System.get_env(), ["SDR_MODEL_PROVIDER"]),
      root: root,
      build_path: Mix.Project.build_path(),
      deps_path: Mix.Project.deps_path(),
      config: resolved_config(),
      connect: &Launcher.probe/2
    }

    case Launcher.check(inputs) do
      :ok -> line("CHECK", "ok")
      {:error, reason} -> refuse!(reason)
    end
  end

  defp preflight do
    _root = check_mode_root!()

    case Bootstrap.preflight() do
      :ok -> line("PREFLIGHT", "ok")
      {:error, reason} -> refuse!(reason)
    end
  end

  defp lease(mode) do
    root = check_mode_root!()

    case State.acquire_lease(root, mode, []) do
      {:ok, nonce} -> line("NONCE", nonce)
      {:error, reason} -> refuse!(reason)
    end
  end

  defp step(step) do
    Boot.declare_step!(step)

    case Bootstrap.step(step) do
      :ok -> line("STEP", Atom.to_string(step))
      {:error, reason} -> refuse!(reason)
    end
  end

  defp publish do
    _root = check_mode_root!()

    case Bootstrap.publish() do
      {:ok, binding_sha256} -> line("BINDING", binding_sha256)
      {:error, reason} -> refuse!(reason)
    end
  end

  defp release(mode) do
    root = check_mode_root!()

    case State.release(root, mode, Keyword.get(AgentEnv.config(), :nonce)) do
      :ok -> line("RELEASED", Atom.to_string(mode))
      {:error, reason} -> refuse!(reason)
    end
  end

  ## Helpers

  # Check mode's configured root (the selector at STEP=check).
  defp check_mode_root! do
    with :check <- AgentEnv.mode(),
         {:ok, root} <- State.root() do
      root
    else
      _other -> refuse!(:step_mode_mismatch)
    end
  end

  # The VM's effective resolved configuration for Launcher.check/1.
  defp resolved_config do
    endpoint = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])
    witness = Application.get_env(:sdr_agent, SdrAgent.Agents.Witness, [])

    %{
      repo: SdrAgent.Repo.config(),
      endpoint_http: Keyword.get(endpoint, :http, []),
      anchor_sinks: Application.get_env(:sdr_agent, :anchor_sinks, []),
      witness_store_root: Keyword.get(witness, :store_root),
      suppression_check: Application.get_env(:sdr_agent, :suppression_check),
      otel_capture_content: Application.get_env(:sdr_agent, :otel_capture_content)
    }
  end

  defp line(key, value), do: Mix.shell().info("SDR_AGENT_ENV_#{key} #{value}")

  @spec refuse!(atom()) :: no_return()
  defp refuse!(reason) when is_atom(reason),
    do: Mix.raise("agent environment refused (#{reason})")
end
