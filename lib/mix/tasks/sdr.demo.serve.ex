defmodule Mix.Tasks.Sdr.Demo.Serve do
  @shortdoc "Serves the console from the throw-away test database for a browser smoke (test only)"

  @moduledoc """
  Starts the console on `PORT` (default 4122) against the throw-away
  `bin/demo --test` database, for a real-browser smoke of the golden path
  that never touches the dev database or the dev server:

      bin/demo --test reset --yes && bin/demo --test seed && bin/demo --test serve

  `MIX_ENV=test` only, and only when the Repo's database is a `_demo`
  partition (`sdr_agent_test<partition>_demo`, as `bin/demo --test` sets
  it). The test configuration is changed for this VM only: the endpoint
  listens on loopback (origin-checked for it), the Repo uses an ordinary
  pool of 5 connections instead of the SQL sandbox, and Oban runs its queues (research, delivery, …) so
  the agent and the capture adapter work as in dev; cron plugins stay off.
  The model is the fake one, delivery is capture-only. Runs until stopped.

  Refuses the dev port 4120. At start it writes a fresh nonce to
  `tmp/smoke/attestation-<port>.json` (mode 0600) and serves it at
  `GET /__smoke/attestation` (`SdrAgentWeb.SmokeAttestation`): the browser
  smoke script attaches only to a server that proves it is this one.
  """
  use Mix.Task

  @doc false
  @impl Mix.Task
  def run(_args) do
    Mix.env() == :test || Mix.raise("mix sdr.demo.serve runs only with MIX_ENV=test")
    Mix.Task.run("app.config")

    database = Keyword.fetch!(SdrAgent.Repo.config(), :database)

    (String.starts_with?(database, "sdr_agent_test") and String.ends_with?(database, "_demo")) ||
      Mix.raise("mix sdr.demo.serve needs the throw-away _demo database (is #{database})")

    port = String.to_integer(System.get_env("PORT", "4122"))
    port != 4120 || Mix.raise("mix sdr.demo.serve refuses the dev port 4120")
    endpoint = Application.get_env(:sdr_agent, SdrAgentWeb.Endpoint, [])

    Application.put_env(
      :sdr_agent,
      SdrAgentWeb.Endpoint,
      Keyword.merge(endpoint,
        server: true,
        http: [ip: {127, 0, 0, 1}, port: port],
        url: [host: "127.0.0.1", port: port],
        check_origin: ["//127.0.0.1:#{port}", "//localhost:#{port}"]
      )
    )

    # A long-running server, not a test: an ordinary small connection pool
    # instead of the SQL sandbox (whose ownership times out after 120 s).
    repo = Application.get_env(:sdr_agent, SdrAgent.Repo, [])

    Application.put_env(
      :sdr_agent,
      SdrAgent.Repo,
      Keyword.merge(repo, pool: DBConnection.ConnectionPool, pool_size: 5)
    )

    oban = Application.get_env(:sdr_agent, Oban, [])
    queues = Keyword.get(oban, :queues, [])

    Application.put_env(
      :sdr_agent,
      Oban,
      Keyword.merge(oban, testing: :disabled, queues: queues, plugins: false)
    )

    Application.put_env(:sdr_agent, SdrAgentWeb.LiveRefresh, debounce_ms: 250)
    attest!(port, database)
    Mix.Task.run("app.start")
    Mix.shell().info("smoke console on http://127.0.0.1:#{port} (database #{database})")
    Process.sleep(:infinity)
  end

  # The launcher-owned handshake the browser smoke checks (see the moduledoc).
  defp attest!(port, database) do
    nonce = 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    Application.put_env(:sdr_agent, SdrAgentWeb.SmokeAttestation, %{nonce: nonce})

    dir = Path.join(File.cwd!(), "tmp/smoke")
    File.mkdir_p!(dir)
    path = Path.join(dir, "attestation-#{port}.json")
    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.write!(path, Jason.encode!(%{nonce: nonce, port: port, database: database}))
  end
end
