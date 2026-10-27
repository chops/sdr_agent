defmodule SdrAgent.Release do
  @moduledoc """
  Release tasks, run with `bin/sdr_agent eval` (the release has no Erlang
  distribution, `rel/env.sh.eex`). Each runs in its own VM and starts only
  the Repo and the dependency applications, never the Endpoint, Oban or a
  model call. `scripts/deploy.sh` runs both from the staged release, before
  the switch.

    * `migrate/0` (`bin/migrate`): every pending migration of every repo.
    * `seed_hosted/0`: seeds the hosted test copy for the owner named by
      `SDR_OWNER_EMAIL` (`SdrAgent.Demo.HostedSeed`): exactly one operator,
      the owner, with no usable password (magic-link sign-in only), and the
      synthetic demo content; never the fixture operators. Idempotent;
      raises without `SDR_OWNER_EMAIL` before touching anything.
  """

  alias SdrAgent.Demo.HostedSeed

  @app :sdr_agent

  @doc "Runs every pending migration of each configured repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Seeds the hosted copy for `SDR_OWNER_EMAIL` (see the moduledoc). Returns
  `{:ok, %{created: n, existing: m}}`; prints nothing secret.
  """
  def seed_hosted do
    owner_email =
      case System.get_env("SDR_OWNER_EMAIL") do
        value when is_binary(value) ->
          if String.trim(value) == "", do: missing_owner!(), else: value

        nil ->
          missing_owner!()
      end

    load_app()
    start_dependencies()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(SdrAgent.Repo, fn _repo -> HostedSeed.run(owner_email) end)

    result
  end

  defp missing_owner! do
    raise "SDR_OWNER_EMAIL is not set: seed_hosted creates the owner it names and nothing else"
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  # The application's dependencies (Ash, AshPostgres, bcrypt, …), without
  # the application itself: its supervision tree (Endpoint, Oban) never
  # starts here.
  defp start_dependencies do
    for app <- Application.spec(@app, :applications) do
      {:ok, _started} = Application.ensure_all_started(app)
    end
  end
end
