defmodule Mix.Tasks.Sdr.Demo.RehearseResolver do
  @shortdoc "Synthetic R0-05 resolver browser rehearsal over a fake-CLI blocked switch (test only)"

  @moduledoc """
  Serves the console from a disposable `sdr_agent_test<partition>_rehearsal`
  database with one real stored `:blocked` profile switch, so the owner can
  rehearse the R0-05 blocked-switch resolver in a real browser. A
  **synthetic** rehearsal on the harness's fake CLI: no model call, no real
  CLI, no credentials; not runtime cleanup proof and not the R0-06 trial.

      MIX_ENV=test MIX_TEST_PARTITION=_r1 mix sdr.demo.rehearse_resolver [--port 4123]
        [--email rehearsal-admin@example.test]

  `MIX_ENV=test` only (the fixture driver, `SdrAgent.Test.ResolverRehearsal`,
  exists only in test builds; see its moduledoc for every guard and the
  phase order). The target database must not exist: it is created
  exclusively and migrated; an existing one is refused and left untouched,
  and nothing is ever dropped or reset. It asks for a fresh synthetic
  password for the fixture admin without echo, prints the report (code SHA,
  database, fixture identities, counters before and after), serves until
  `STOP` is typed (or terminal input ends), then stops and joins every
  fixture-owned process. It exits non-zero unless that stop is confirmed
  clean with unchanged counters and no launch. Ctrl-C or SIGTERM end the VM
  without the stop: such a run is interrupted, not clean-stop evidence.
  """
  use Mix.Task

  # Exists only in test builds; referenced through apply/3 so that other
  # builds compile this task (which refuses outside MIX_ENV=test).
  @driver SdrAgent.Test.ResolverRehearsal

  @doc false
  @impl Mix.Task
  def run(argv) do
    Mix.env() == :test ||
      Mix.raise("mix sdr.demo.rehearse_resolver runs only with MIX_ENV=test")

    Mix.Task.run("app.config")

    Code.ensure_loaded?(@driver) ||
      Mix.raise("mix sdr.demo.rehearse_resolver refuses: not a test build")

    apply(@driver, :run, [argv])
  end
end
