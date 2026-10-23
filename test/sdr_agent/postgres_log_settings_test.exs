defmodule SdrAgent.PostgresLogSettingsTest do
  @moduledoc """
  5b (D-178; #156 section 4.3), live invariant on the validated test
  connection: every approved server-log setting is in effect with its pinned
  `pg_settings` value and unit, comes from the configuration file (not a
  session, role, database or command-line override) and has no pending
  restart; and the extension and loaded-module audit
  (`SdrAgent.Test.PostgresLogAudit`) passes for this backend and database.
  It only reads metadata and never SETs anything.

  Against a cluster started without the 5b settings (the shared 5520 cluster
  before the owner's activation) this test fails, and that run is reported as
  failing, never excluded (Codex 5b plan r1 review). The configured-cluster
  pass before activation is exact-head CI (`hermetic-verify.sh`). It proves
  configured values only, not folder modes, containment or collector-only
  behaviour; those belong to the sink test and the owner's activation receipt.
  """
  use SdrAgent.DataCase, async: true

  alias SdrAgent.Test.PostgresLogContract, as: Contract

  @audit SdrAgent.Test.PostgresLogAudit

  defp settings_rows do
    names = Contract.names()

    %{rows: rows} =
      Repo.query!(
        "SELECT name, setting, coalesce(unit, ''), source, pending_restart " <>
          "FROM pg_settings WHERE name = ANY($1) ORDER BY name",
        [names]
      )

    Map.new(rows, fn [name, setting, unit, source, pending] ->
      {name, %{effective: {setting, unit}, source: source, pending_restart: pending}}
    end)
  end

  test "the database is the validated test partition" do
    %{rows: [[db]]} = Repo.query!("SELECT current_database()")
    assert String.starts_with?(db, "sdr_agent_test")
  end

  test "every approved setting is in effect, from the configuration file, with no pending restart" do
    rows = settings_rows()
    assert Map.keys(rows) |> Enum.sort() == Contract.names()

    mismatches =
      Contract.effective()
      |> Enum.map(fn {name, expected} -> {name, expected, Map.fetch!(rows, name)} end)
      |> Enum.reject(fn {_name, expected, row} ->
        row.effective == expected and row.source == "configuration file" and
          not row.pending_restart
      end)
      |> Enum.map(fn {name, _expected, row} -> {name, row} end)

    assert mismatches == [],
           "5b: server-log settings not in effect as approved: #{inspect(mismatches)}"
  end

  test "the extension and loaded-module audit passes for this backend and database" do
    assert Code.ensure_loaded?(@audit), "5b: #{inspect(@audit)} must exist"
    result = @audit.classify(@audit.inventory(Repo))
    assert result.verdict == :pass, "5b: audit failed: #{inspect(result.sources)}"
  end
end
