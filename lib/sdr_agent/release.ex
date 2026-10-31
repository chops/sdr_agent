defmodule SdrAgent.Release do
  @moduledoc """
  Release task for the hosted_prototype artifact (ADR-0024), run as
  `bin/migrate` (`bin/sdr_agent eval SdrAgent.Release.migrate`) in its own VM.
  The release has no Erlang distribution (`rel/env.sh.eex`).

    * `migrate/0`: runs every pending migration of every configured repo.
      It starts only the Repo and its dependency applications, never the
      Endpoint, Oban or a model call.

  Only the separately reviewed runbook calls it.
  `scripts/build-hosted-artifact.sh` never runs it. This module seeds,
  provisions and activates nothing: prototype setup, binding, delegation
  and owner steps stay reviewed runbook steps.
  """

  @app :sdr_agent

  @doc "Runs every pending migration of each configured repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app, do: Application.ensure_loaded(@app)
end
