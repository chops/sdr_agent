defmodule Mix.Tasks.Sdr.Demo.Status do
  @shortdoc "Reports the local demo's health (dev/test only)"

  @moduledoc """
  Prints `SdrAgent.Demo.Status` — database, migrations, seed state, Oban
  queues, pipeline counts and the audit chain — for `bin/demo status`:

      mix sdr.demo.status [--check]

  `--check` exits non-zero unless the demo can run (database reachable,
  migrations current, tenant seeded); `bin/demo run` uses it before starting
  the server. Refuses outside `MIX_ENV=dev` or `test`. The application is
  started with Oban's queues and plugins off, so asking for the status never
  executes a job; verifying the chain records a `chain_verify` AuditAccess.
  """
  use Mix.Task

  alias SdrAgent.Demo.Status

  @doc false
  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [check: :boolean])
    invalid == [] || Mix.raise("usage: mix sdr.demo.status [--check]")

    unless Mix.Tasks.Sdr.Demo.Seed.allowed_env?(Mix.env()) do
      Mix.raise("mix sdr.demo.status runs only in dev and test (MIX_ENV=#{Mix.env()})")
    end

    Mix.Task.run("app.config")
    queues = Status.configured_queues()
    oban = Application.get_env(:sdr_agent, Oban, [])
    Application.put_env(:sdr_agent, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Mix.Task.run("app.start")

    report = Status.report(queues: queues)
    Enum.each(Status.format(report), fn line -> Mix.shell().info(line) end)

    if opts[:check] && not Status.ready?(report) do
      Mix.raise("the demo is not ready (see above)")
    end
  end
end
