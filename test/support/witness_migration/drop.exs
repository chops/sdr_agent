# Projection v4 lineage migration campaign: a normal drop (no FORCE, no
# connection termination) of the database this run claimed, after
# validating the resolved target again. Every other child has exited.
#
# The decision is `SdrAgent.WitnessMigration.Harness.drop_flow/1` (protocol
# v2, Codex db034af6 Q6: the standing lane runner's r7b drain), with the
# real effects injected here. Through one maintenance-database connection
# (never the target itself), each observation is one bounded read of
# `Harness.backends_sql/0` in its own transaction, with its statement and
# lock timeouts set for that transaction only; the clock is this VM's
# monotonic clock. Only an accepted observation (no backend other than an
# exact `autovacuum worker`, the final clock check still inside the fixed
# budget, every line written) leads to the one plain `storage_down`; the
# absence proof follows, with the drop's own declared waits. Types and
# counts only are printed: never query text, users, addresses or PIDs. A
# refusal prints `DROP-REFUSED <label>` and exits with
# `Harness.drop_refused/0`.
# Usage: mix run --no-start drop.exs DATABASE
Code.require_file("common.exs", __DIR__)

alias SdrAgent.WitnessMigration.Harness

[database] = System.argv()
config = SdrAgent.WitnessMigration.validate_target!(database)

{:ok, _} = Application.ensure_all_started(:postgrex)
bounds = Harness.drop_bounds()

maintenance =
  config
  |> Keyword.take([:hostname, :port, :username, :password, :socket_dir, :ssl, :parameters])
  |> Keyword.put(:database, Keyword.get(config, :maintenance_database, "postgres"))

{:ok, catalog} =
  Postgrex.start_link(maintenance ++ [connect_timeout: bounds.connect_timeout_ms, pool_size: 1])

# One bounded read: its own transaction, statement and lock timeouts set for
# that transaction only, a client-side bound as well; every failure is a
# value, never an exception.
read = fn sql, params, statement_ms, lock_ms ->
  try do
    Postgrex.transaction(
      catalog,
      fn conn ->
        with {:ok, _} <-
               Postgrex.query(conn, "SELECT set_config('statement_timeout', $1, true)", [
                 Integer.to_string(statement_ms)
               ]),
             {:ok, _} <-
               Postgrex.query(conn, "SELECT set_config('lock_timeout', $1, true)", [
                 Integer.to_string(lock_ms)
               ]),
             {:ok, %Postgrex.Result{rows: rows}} <- Postgrex.query(conn, sql, params) do
          rows
        else
          {:error, reason} -> Postgrex.rollback(conn, reason)
        end
      end,
      timeout: statement_ms + bounds.slack_ms
    )
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  catch
    kind, _reason -> {:error, {kind, :caught}}
  end
end

drop_config =
  Keyword.merge(config,
    connect_timeout: bounds.drop_connect_timeout_ms,
    timeout: bounds.drop_statement_timeout_ms,
    parameters: [
      statement_timeout: Integer.to_string(bounds.drop_statement_timeout_ms),
      lock_timeout: Integer.to_string(bounds.drop_lock_timeout_ms)
    ]
  )

effects = %{
  clock: fn -> {:ok, System.monotonic_time(:millisecond)} end,
  observe: fn ms ->
    case read.(Harness.backends_sql(), [database], ms, ms) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn
           [line] -> line
           _other -> nil
         end)}

      {:error, _reason} = error ->
        error
    end
  end,
  pause: fn -> Process.sleep(bounds.pause_ms) end,
  storage_down: fn -> Ecto.Adapters.Postgres.storage_down(drop_config) end,
  count_present: fn ->
    case read.(
           "SELECT count(*) FROM pg_database WHERE datname = $1",
           [database],
           bounds.drop_statement_timeout_ms,
           bounds.drop_lock_timeout_ms
         ) do
      {:ok, [[present]]} when is_integer(present) -> {:ok, present}
      {:ok, _other} -> {:error, :unexpected_rows}
      {:error, _reason} = error -> error
    end
  end,
  emit: &IO.puts/1
}

decision = Harness.drop_flow(effects)
GenServer.stop(catalog)

case decision do
  :ok ->
    System.halt(0)

  {:error, reason} ->
    :ok = IO.puts("DROP-REFUSED #{Harness.drop_refusal_label(reason)}")
    System.halt(Harness.drop_refused())
end
