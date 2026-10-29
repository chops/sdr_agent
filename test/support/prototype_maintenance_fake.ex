defmodule SdrAgent.PrototypeMaintenanceFake do
  @moduledoc """
  A scripted stand-in for setup phase 0's maintenance connector (S1 I4 r2
  §2.4), for tests only. It opens no socket, reads no cluster and touches
  no path: `SdrAgent.Prototype.Authority.TestSeam.put_maintenance/1` puts
  `{SdrAgent.PrototypeMaintenanceFake, script}` in place of the real
  connector before `maintenance_identity/0` starts anything.

  The callbacks mirror the real connector's three calls, each made by the
  helper process:

  - `start_link(opts, script)` starts a fake pool linked to the helper and,
    when the script names `notify: pid`, sends
    `{:maintenance_fake, :started, helper, pool}` to that pid; with
    `mode: :start_error` it starts nothing and returns
    `{:error, :econnrefused}`;
  - `query(pool, sql, script)` asks the pool and waits for its answer;
  - `stop(pool, stop_ms, script)` asks the pool to stop and waits up to
    `stop_ms` for its death, else exits `:stop_timeout`.

  Modes: `:ok` (one typed row), `:query_error` (a `Postgrex.Error`),
  `:hang_query` (never answers), `:slow_query` (answers after 100 ms),
  `:stop_hang` (answers, then ignores `:stop`), `:pool_survives` (traps
  exits, never answers, outlives its helper). The row's values are
  synthetic constants.
  """

  @row [
    "postgres",
    7_400_000_000_000_000_001,
    "/Users/charles/.local/state/sdr-agent/prototype/d237/pgdata"
  ]

  @doc "Starts the fake pool for `script`; see the moduledoc."
  @spec start_link(keyword(), map()) :: {:ok, pid()} | {:error, :econnrefused}
  def start_link(_opts, %{mode: :start_error}), do: {:error, :econnrefused}

  def start_link(_opts, %{mode: mode} = script) do
    helper = self()
    pool = spawn_link(fn -> pool(mode) end)

    case Map.get(script, :notify) do
      pid when is_pid(pid) -> send(pid, {:maintenance_fake, :started, helper, pool})
      nil -> :ok
    end

    {:ok, pool}
  end

  @doc "Asks the fake pool for the statement's result and waits for it."
  @spec query(pid(), String.t(), map()) :: term()
  def query(pool, _sql, _script) do
    ref = make_ref()
    send(pool, {:query, self(), ref})

    receive do
      {^ref, reply} -> reply
    end
  end

  @doc "Asks the fake pool to stop and waits up to `stop_ms` for its death."
  @spec stop(pid(), non_neg_integer(), map()) :: :ok
  def stop(pool, stop_ms, _script) do
    ref = Process.monitor(pool)
    send(pool, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pool, _reason} -> :ok
    after
      stop_ms ->
        Process.demonitor(ref, [:flush])
        exit(:stop_timeout)
    end
  end

  @doc """
  Test-build-only post-reply gate for the absolute-deadline regression.
  The helper calls this only after sending its reply. The exact owned
  notification records that send before the success deadline; no sleep
  or generic process inspection establishes ordering. The gate waits
  until the protocol kills the helper at its deadline.
  """
  @spec after_reply(map(), integer()) :: :ok
  def after_reply(%{mode: :hold_after_reply, notify: notify}, deadline) do
    send(
      notify,
      {:maintenance_fake, :replied, self(), System.monotonic_time(:millisecond), deadline}
    )

    receive do
      :release_after_reply -> :ok
    end
  end

  def after_reply(_script, _deadline), do: :ok

  defp pool(:pool_survives) do
    Process.flag(:trap_exit, true)
    loop(:pool_survives)
  end

  defp pool(mode), do: loop(mode)

  defp loop(mode) do
    receive do
      {:query, from, ref} ->
        answer(mode, from, ref)
        loop(mode)

      :stop when mode == :stop_hang ->
        loop(mode)

      :stop ->
        :ok

      {:EXIT, _from, _reason} ->
        loop(mode)
    end
  end

  defp answer(mode, _from, _ref) when mode in [:hang_query, :pool_survives], do: :ok

  defp answer(:query_error, from, ref),
    do: send(from, {ref, {:error, %Postgrex.Error{message: "synthetic"}}})

  defp answer(:slow_query, from, ref) do
    Process.sleep(100)
    send(from, {ref, {:ok, result()}})
  end

  defp answer(_ok, from, ref), do: send(from, {ref, {:ok, result()}})

  defp result, do: %Postgrex.Result{command: :select, rows: [@row], num_rows: 1}
end
