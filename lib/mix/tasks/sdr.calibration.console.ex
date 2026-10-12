defmodule Mix.Tasks.Sdr.Calibration.Console do
  @shortdoc "Serves the R0-07 calibration console from sdr_agent_calibration (test-seam build only)"

  @moduledoc """
  The R0-07 calibration console (readiness packet §3). Run it through
  `bin/calibration-console`, which checks the environment and this task's
  plan first:

      bin/calibration-console check            # print the plan; start nothing
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

    * `check` — prints the plan line and exits; reads configuration only.
    * `bootstrap-admin ARGS` — the first-admin bootstrap
      (`mix sdr.bootstrap_admin ARGS`) in `sdr_agent_calibration`; the
      endpoint does not listen.
    * `serve` — serves the console until stopped; refuses unless the
      LiveView assets are built (`mix assets.build`).
  """
  use Mix.Task

  alias SdrAgent.CalibrationConsole
  alias SdrAgent.CalibrationConsole.Secrets

  @doc false
  @impl Mix.Task
  def run(["check"]) do
    plan = plan!()
    Mix.shell().info(CalibrationConsole.plan_line(plan))
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

  def run(_args) do
    Mix.raise(
      "usage: mix sdr.calibration.console check | serve | bootstrap-admin ARGS " <>
        "(run it through bin/calibration-console)"
    )
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
