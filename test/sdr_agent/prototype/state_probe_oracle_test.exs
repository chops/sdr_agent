defmodule SdrAgent.Prototype.StateProbeOracleTest do
  @moduledoc """
  RED-b2c (Codex ab4320ae R2), D-237 slice S2: positive and negative
  controls for the aborted-caller SQL oracle
  (`PrototypeGateFixtures.probe_then_owner_rollback?/2`) that
  `ReleaseReadersTest` applies to `ReleasedScope.run/3`. Each control runs
  real statements inside an owning `SdrAgent.Audit.transaction/1` (a user
  transaction in the sandbox, so a failing statement really aborts it, with
  no per-query savepoint) and captures them (`GateFixtures.capture/1`).

  - Positive: after `SELECT 1/0`, exactly the state probe (`SELECT 1`, which
    gets the typed `in_failed_sql_transaction`) and then the owner's
    rollback.
  - Negative: a business SELECT, a savepoint statement, a second statement
    after the probe, or no probe at all, each in place of the exact
    sequence, fails the oracle.

  No release and no prototype runtime are needed. Synthetic statements only.
  """
  use SdrAgent.DataCase, async: false

  alias SdrAgent.GateFixtures
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.Repo

  # The statements after the abort run inside the owning transaction, which
  # then rolls back; the captured SQL and each statement's result return.
  defp captured(statements) do
    {result, sql} =
      GateFixtures.capture(fn ->
        SdrAgent.Audit.transaction(fn ->
          aborted = Repo.query("SELECT 1/0")
          results = Enum.map(statements, &Repo.query/1)
          Repo.rollback({aborted, results})
        end)
      end)

    {:error, {aborted, results}} = result
    {sql, aborted, results}
  end

  test "positive: the exact probe after the abort, then only the owner's rollback" do
    {sql, aborted, [probe]} = captured([G.state_probe()])

    assert match?({:error, %Postgrex.Error{postgres: %{code: :division_by_zero}}}, aborted)

    assert match?(
             {:error, %Postgrex.Error{postgres: %{code: :in_failed_sql_transaction}}},
             probe
           ),
           "the probe did not see the aborted transaction"

    assert G.probe_then_owner_rollback?(sql),
           "after the abort: #{inspect(G.after_abort_shape(sql))}"
  end

  for {label, statements} <- [
        business_select: ["SELECT count(*) FROM agent_runs"],
        savepoint: ["SAVEPOINT s2_probe_oracle"],
        second_statement: ["SELECT 1", "SELECT 1"],
        no_probe: []
      ] do
    test "negative: #{label} instead of the exact sequence fails the oracle" do
      {sql, _aborted, _results} = captured(unquote(statements))

      refute G.probe_then_owner_rollback?(sql),
             "accepted: #{inspect(G.after_abort_shape(sql))}"
    end
  end
end
