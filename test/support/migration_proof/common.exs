# Shared by the C3-02 additive migration proof scripts
# (`SdrAgent.Sales.AdditiveMigrationProofTest`). Each script runs in its own
# fresh BEAM under `MIX_ENV=test`, without the application, against the one
# synthetic database the parent test owns.
defmodule SdrAgent.MigrationProof do
  @moduledoc false

  alias SdrAgent.Repo

  # Refuses anything but the owned synthetic database on the devenv port and
  # the test build.
  def validate_target!(database) do
    config = Application.fetch_env!(:sdr_agent, Repo)
    true = Regex.match?(SdrAgent.MigrationProof.Harness.database_pattern(), database)
    ^database = config[:database]
    "localhost" = config[:hostname]
    5520 = config[:port]
    :test = Mix.env()
    config
  end
end
