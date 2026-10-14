defmodule Mix.Tasks.Sdr.Calibration.Console do
  @shortdoc "Serves the R0-07 calibration console from sdr_agent_calibration (test-seam build only)"

  @moduledoc """
  The R0-07 calibration console (readiness packet §3). Run it through
  `bin/calibration-console`, which checks the environment and this task's
  plan first:

      bin/calibration-console check            # print the plan; no server, no database
      read -rs PW; printf '%s\\n' "$PW" | \\
        bin/calibration-console bootstrap-admin --email … --display-name … --password-stdin
      bin/calibration-console serve            # http://127.0.0.1:4124

  `MIX_ENV=test` only (the test-seam build). The database is always the
  fixed, persistent `sdr_agent_calibration` (`SdrAgent.CalibrationConsole`);
  it is created if absent and migrated, and never dropped, reset or seeded.
  The endpoint listens only on 127.0.0.1:4124 and, active, serves only the
  sign-in and `/admin` pages (`SdrAgentWeb.CalibrationConsole`). The model
  provider must be the Fake, so no model server starts, and Oban never
  executes jobs. The endpoint `secret_key_base` and the token signing
  secret are per-machine values from
  `~/.local/state/sdr-agent/calibration/secrets`, generated on first use
  (`SdrAgent.CalibrationConsole.Secrets`) and never printed; the checked-in
  test secrets are never used.

    * `check` — prints the plan line and exits. It starts no server and
      touches no database, but like every command it creates the secrets
      file on first use.
    * `bootstrap-admin ARGS` — the first-admin bootstrap
      (`mix sdr.bootstrap_admin ARGS`) in `sdr_agent_calibration`; the
      endpoint does not listen.
    * `serve` — serves the console until stopped; refuses unless the
      LiveView assets are built (`mix assets.build`).
    * `calibrate PROFILE` — one attended calibration call of a real profile
      (R0-07 d3c, packet 8.14.1 and 8.14.9): exactly
      `{:run, p, o} = Calibrate.command(argv)`, then the first-run
      `Calibrate.prepare/1` of the two canonical paths, then
      `Calibrate.run(p, o)`, with the console's fixed `console_opts/1` (no
      hook, no override). The
      endpoint does not listen; the command starts the authority registry
      and its own private ClaudeCLI server, and asks the owner to type
      `CALIBRATE PROFILE`. It prints only the stop or outcome, the record
      state and the evidence file's path and hash.
  """
  use Mix.Task

  alias SdrAgent.CalibrationConsole
  alias SdrAgent.CalibrationConsole.Secrets

  # Both exist only in test-seam builds; referenced through apply/3 so that
  # other builds compile this task (which refuses outside MIX_ENV=test).
  @calibrate SdrAgent.CalibrationConsole.Calibrate
  @authority SdrAgent.CalibrationConsole.Authority

  @doc false
  @impl Mix.Task
  def run(["check"]) do
    plan = plan!()
    Mix.shell().info(CalibrationConsole.plan_line(plan))

    Mix.shell().info(
      "calibration console secrets: #{Secrets.default_path()} " <>
        "(created on first use, by check too; values never printed)"
    )
  end

  def run(["bootstrap-admin" | args]) do
    plan = plan!()
    CalibrationConsole.apply!(plan, serve: false)
    CalibrationConsole.ensure_storage!()
    Mix.Task.run("sdr.bootstrap_admin", args)
  end

  def run(["serve"]) do
    plan = plan!()

    with {:error, reason} <- CalibrationConsole.check_assets(),
         do: Mix.raise("mix sdr.calibration.console refuses: #{reason}")

    CalibrationConsole.apply!(plan, serve: true)
    CalibrationConsole.ensure_storage!()
    Mix.Task.run("app.start")
    CalibrationConsole.verify_started!()
    {ip, port} = CalibrationConsole.bind()

    Mix.shell().info(
      "calibration console on http://#{:inet.ntoa(ip)}:#{port} " <>
        "(database #{CalibrationConsole.database()}; sign-in and /admin only; no model server)"
    )

    Process.sleep(:infinity)
  end

  def run(["calibrate" | argv]) do
    plan = plan!()

    Code.ensure_loaded?(@calibrate) ||
      Mix.raise("mix sdr.calibration.console calibrate refuses: not a test-seam build")

    case apply(@calibrate, :command, [argv]) do
      {:run, profile_id, opts} ->
        prepare!(opts)
        CalibrationConsole.apply!(plan, serve: false)
        CalibrationConsole.ensure_storage!()
        Mix.Task.run("app.start")
        CalibrationConsole.verify_started!()
        {:ok, _registry} = apply(@authority, :start_link, [[]])
        report(apply(@calibrate, :run, [profile_id, opts]))

      {:error, :usage} ->
        Mix.raise(
          "usage: mix sdr.calibration.console calibrate claude_cli_opus | claude_cli_sonnet"
        )
    end
  end

  def run(_args) do
    Mix.raise(
      "usage: mix sdr.calibration.console check | serve | bootstrap-admin ARGS | calibrate PROFILE " <>
        "(run it through bin/calibration-console)"
    )
  end

  # First-run setup of the two canonical paths (packet 8.14.9 round 4),
  # before the app starts; any refusal stops the command.
  defp prepare!(opts) do
    case apply(@calibrate, :prepare, [Keyword.take(opts, [:root, :evidence_dir])]) do
      {:ok, _created_or_existing} -> :ok
      {:error, reason} -> Mix.raise("mix sdr.calibration.console calibrate refuses: #{reason}")
    end
  end

  defp report({:ok, summary}),
    do: Mix.shell().info("calibrate: finished, outcome #{summary.outcome}; " <> details(summary))

  defp report({:stop, reason, summary}),
    do: Mix.raise("calibrate stopped: #{reason}; " <> details(summary))

  defp details(summary) do
    evidence =
      case summary.evidence do
        %{path: path, sha256: sha256} -> "evidence #{path} (sha256 #{sha256})"
        nil -> "no evidence"
      end

    "record #{inspect(summary.record)}, invocation #{summary.invocation_id || "none"}, #{evidence}"
  end

  defp plan! do
    Mix.env() == :test ||
      Mix.raise("mix sdr.calibration.console runs only the test-seam build (MIX_ENV=test)")

    Mix.Task.run("app.config")

    secrets =
      case Secrets.load_or_create() do
        {:ok, secrets} -> secrets
        {:error, reason} -> Mix.raise("mix sdr.calibration.console refuses: #{reason}")
      end

    config = Map.put(CalibrationConsole.current(Mix.env()), :secrets, secrets)

    case CalibrationConsole.plan(config) do
      {:ok, plan} -> plan
      {:error, reason} -> Mix.raise("mix sdr.calibration.console refuses: #{reason}")
    end
  end
end
