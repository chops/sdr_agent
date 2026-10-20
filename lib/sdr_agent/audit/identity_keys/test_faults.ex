if Application.compile_env(:sdr_agent, :claude_cli_test_seams, false) do
  defmodule SdrAgent.Audit.IdentityKeys.TestFaults do
    @moduledoc """
    Test-seam builds only (`:claude_cli_test_seams`, config/test.exs): the
    identity-key test seams. Each is process-local (it acts only on
    `IdentityKeys` calls made by the calling process while `fun` runs),
    nested-safe, and restores the caller's previous state on return, raise,
    throw and exit. None changes a decision. This module does not exist in
    dev or prod builds.

      * `with_fault(point, fun)`: the acquisition fault points of plan r8
        section 2.5. The identity pass raises at `point`:
        `:before_first_lock`, `{:after_locks, k}` (after the k-th lock of
        the pass) or `:at_publication` (before the record is published).
      * `record_preimages(fun)` (C3-02 G4, T-D4): returns `{result,
        records}`, `records` being every `H` computation made in this
        process during `fun`, in order, as `{op, kind, tenant_id, bytes}`:
        `op` the entry that computed it (`:pass`, `:require_held` or
        `:id`), `kind` the key kind and `bytes` the exact preimage `H`
        hashed. The records stay in the test process: nothing is logged
        or emitted. A nested call's records are also kept by the enclosing
        call.
      * `park_after_pass(owner, fun)` (C3-02 G4, the RED-3 races): the first
        identity pass made during `fun` that publishes its record parks
        right after the publication and its passed state (its keys held,
        inside its transaction): it sends `{:c302_parked, self(), ids}` to
        `owner` (`ids` the pass's requested ids, ascending) and waits for
        `{:c302_resume}`; meanwhile it answers `{:c302_probe, from, ref,
        probe}` by running `probe.()` in-process and sending `{ref, result}`
        to `from`. It monitors `owner`: on the owner's `:DOWN`, or after
        60 s without a resume, it raises, so its transaction rolls
        back with no further database work. Later passes during `fun` do
        not park.
    """

    @fault {__MODULE__, :point}
    @records {__MODULE__, :records}
    @park {__MODULE__, :park}
    @park_ms 60_000

    @doc "Runs `fun` with the fault `point` armed in the calling process."
    def with_fault(point, fun) when is_function(fun, 0) do
      previous = Process.put(@fault, point)

      try do
        fun.()
      after
        restore(@fault, previous)
      end
    end

    @doc "Runs `fun`, returning `{result, records}` (see the moduledoc)."
    def record_preimages(fun) when is_function(fun, 0) do
      previous = Process.put(@records, [])

      try do
        result = fun.()
        {result, Enum.reverse(Process.get(@records))}
      after
        keep_for_enclosing(Process.get(@records, []), previous)
      end
    end

    @doc "Runs `fun` with its first publishing pass parked for `owner` (see the moduledoc)."
    def park_after_pass(owner, fun) when is_pid(owner) and is_function(fun, 0) do
      previous = Process.put(@park, {:armed, owner})

      try do
        fun.()
      after
        restore(@park, previous)
      end
    end

    @doc false
    # Called by IdentityKeys at each fault point.
    def trip!(point) do
      if Process.get(@fault) == point, do: raise("C3-02 identity key test fault"), else: :ok
    end

    @doc false
    # Called by IdentityKeys for every `H` computation.
    def record!(op, kind, tenant_id, bytes) do
      case Process.get(@records) do
        records when is_list(records) ->
          Process.put(@records, [{op, kind, tenant_id, bytes} | records])
          :ok

        _off ->
          :ok
      end
    end

    @doc false
    # Called by IdentityKeys right after a pass published its record.
    def parked!(ids) do
      case Process.get(@park) do
        {:armed, owner} ->
          Process.put(@park, {:spent, owner})
          park(owner, ids)

        _off ->
          :ok
      end
    end

    defp park(owner, ids) do
      ref = Process.monitor(owner)
      send(owner, {:c302_parked, self(), ids})
      await_resume(owner, ref, System.monotonic_time(:millisecond) + @park_ms)
    end

    defp await_resume(owner, ref, deadline) do
      receive do
        {:c302_resume} ->
          Process.demonitor(ref, [:flush])
          :ok

        {:c302_probe, from, probe_ref, probe} when is_function(probe, 0) ->
          send(from, {probe_ref, probe.()})
          await_resume(owner, ref, deadline)

        {:DOWN, ^ref, :process, ^owner, _reason} ->
          raise "C3-02 parked identity pass: its owner exited"
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          Process.demonitor(ref, [:flush])
          raise "C3-02 parked identity pass: not resumed in time"
      end
    end

    # A nested call's records stay visible to the enclosing call.
    defp keep_for_enclosing(inner, previous) when is_list(previous),
      do: Process.put(@records, inner ++ previous)

    defp keep_for_enclosing(_inner, previous), do: restore(@records, previous)

    defp restore(key, nil), do: Process.delete(key)
    defp restore(key, previous), do: Process.put(key, previous)
  end
end
