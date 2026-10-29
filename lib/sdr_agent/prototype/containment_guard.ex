# The D-237 task-body containment guard (S4 K0/guard GREEN r1). Compiled
# only with the prototype authority (config/dev.exs and config/test.exs);
# the production build has neither module below. The test seam exists only
# in builds that also set `prototype_test_seams: true` (config/test.exs).
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ContainmentGuard do
    @moduledoc """
    The containment guard a task body calls before protected work
    (D-237 S4 reduced-containment plan r5 section 4.3; K0/guard RED packet
    r1-r5). `guard(kind)` returns `:ok` or `{:error, code}` with `code` in
    the closed `codes/0`. It prints and logs nothing, never writes or
    alters a token, and its refusal is a value the body returns unchanged
    (TaskBoundary item 7 then aborts at stage `:body`, exit 70, with only
    its fixed line).

    Order, each stage ending the call at its first refusal:

      1. Stage A, the token: `Containment.entry/0` must be `{:ok, kind}`,
         else `entry_unadopted`. Nothing else is read first.
      2. Row 1e, rule G: one wall sample (`System.os_time(:millisecond)`);
         `relaxation_expired` unless `wall < W_kind`, with
         `W_kind = W_serve` for `:serve` and `W_task` for every other kind
         (exclusive; `W_task - 1` passes).
      3. Stage B, the environment: `Containment.config_check/2` over
         `System.get_env/0` and `kind` (`otel_env`, `crash_dump_env`,
         `phx_server_env`, in that order).
      4. Stage C, the view (rows 3a-12): HELD in this stage. The view is
         not read; every call that reaches it refuses `descriptor_unknown`
         (row 3a, an unreadable view). The guard therefore never returns
         `:ok` until the reviewed view stage replaces this row. No form
         falls through to `:ok`.

    In test-seam builds only, the guard consults its test seam (this file)
    after row 1e and before stage B for a one-shot injected refusal, takes
    row 1e's sample as `max(real, injected floor)` and counts stage B and
    stage C entries. Any other build has no reference to the seam.
    """

    alias SdrAgent.Prototype.Containment

    @test_seams Application.compile_env(:sdr_agent, :prototype_test_seams, false)
    # The closed family (RED packet r1 section 4.2; order r5 section 4.3).
    @codes [
      :entry_unadopted,
      :relaxation_expired,
      :descriptor_unknown,
      :otel_env,
      :crash_dump_env,
      :phx_server_env,
      :descriptor_unbounded,
      :exporter_destination,
      :tracer_provider,
      :tracer_noop,
      :tracer_sampler,
      :tracer_processor,
      :logger_filters,
      :logger_handlers,
      :endpoint_present,
      :listener_present,
      :listener_unknown,
      :distributed,
      :anchor_sinks
    ]
    # Plan r5 section 5.2: E (2026-11-07T07:00:00Z, exclusive), then the
    # serve and task cutoffs, Unix ms.
    @e_ms 1_794_034_800_000
    @w_serve @e_ms - 60_000
    @w_task @e_ms - 10_000

    @typedoc "A guard refusal code (`codes/0`)."
    @type code :: atom()

    @doc "The closed refusal family of `guard/1`."
    @spec codes() :: [code()]
    def codes, do: @codes

    @doc "The guard verdict for `kind`; see the moduledoc."
    @spec guard(term()) :: :ok | {:error, code()}
    def guard(kind) do
      with :ok <- token(kind),
           :ok <- expiry(kind) do
        admitted(kind)
      end
    end

    # Stage A: the calling process's own token only.
    defp token(kind) do
      if Containment.entry() == {:ok, kind}, do: :ok, else: {:error, :entry_unadopted}
    end

    # Row 1e, rule G: one wall sample per call.
    defp expiry(kind) do
      if wall_ms() < cutoff(kind), do: :ok, else: {:error, :relaxation_expired}
    end

    defp cutoff(:serve), do: @w_serve
    defp cutoff(_task_kind), do: @w_task

    # Stage B, then stage C.
    defp protected(kind) do
      note_read(:env)

      with :ok <- Containment.config_check(System.get_env(), kind) do
        view()
      end
    end

    # Stage C (rows 3a-12) is HELD: an unread view is unreadable (row 3a).
    defp view do
      note_read(:view)
      {:error, :descriptor_unknown}
    end

    if @test_seams do
      # The seam's one-shot claim, after stage A and row 1e and before any
      # env or view read: a won claim returns its closed code.
      defp admitted(kind) do
        case SdrAgent.Prototype.ContainmentGuard.TestSeam.claim_refusal() do
          nil -> protected(kind)
          code -> {:error, code}
        end
      end

      defp wall_ms,
        do: SdrAgent.Prototype.ContainmentGuard.TestSeam.floor_wall(System.os_time(:millisecond))

      defp note_read(stage), do: SdrAgent.Prototype.ContainmentGuard.TestSeam.note_read(stage)
    else
      defp admitted(kind), do: protected(kind)
      defp wall_ms, do: System.os_time(:millisecond)
      defp note_read(_stage), do: :ok
    end
  end

  if Application.compile_env(:sdr_agent, :prototype_test_seams, false) do
    defmodule SdrAgent.Prototype.ContainmentGuard.TestSeam do
      @moduledoc """
      Test-build-only guard test protocol (K0/guard RED packet r1 section
      3). It never exists in dev or prod builds, and the authority flag
      alone does not enable it. It is refusal-only: it cannot produce
      `:ok`, supply a token, or move row 1e's wall sample earlier.

      - `with_refusal/2` arms ONE refusal of a closed code for the calling
        process and every process that finds the scope through its
        `$callers`. The first guard call that passes stage A and row 1e and
        wins the scope's atomic claim (`compare_exchange` 0 -> 1 on a
        one-slot atomics array) returns `{:error, code}` before any env or
        view read; every later call in the scope runs the real path (a
        claimed scope never falls through to an outer one).
      - `refusal_hits/0` is the innermost visible scope's claim count.
      - `with_wall_ms/2`: row 1e's sample becomes `max(real, ms)`.
      - `with_read_log/1` returns `{result, %{env: n, view: n}}`, the stage
        B and stage C entries of guard calls that find the log scope.

      Each scope binds its value in the calling process's dictionary,
      shadowing an outer scope of the same kind, and restores the prior
      binding (or removes it) on return, raise, throw and exit; a raise,
      throw or exit of `fun` passes through unchanged. Lookup is the
      calling process, then its explicit `$callers` in order (a dead
      caller contributes nothing). A lookup made before a scope ends may
      still claim after it ends: join inheriting work inside the scope.
      """

      alias SdrAgent.Prototype.ContainmentGuard

      @refusal_key {ContainmentGuard, :refusal}
      @wall_key {ContainmentGuard, :wall_floor}
      @log_key {ContainmentGuard, :read_log}

      @typedoc "Stage B (`env`) and stage C (`view`) entry counts."
      @type reads :: %{env: non_neg_integer(), view: non_neg_integer()}

      @doc """
      Runs `fun` with one armed refusal of `code` and returns its result.
      `:ok` or anything outside `ContainmentGuard.codes/0` raises without
      running `fun`.
      """
      @spec with_refusal(atom(), (-> result)) :: result when result: term()
      def with_refusal(code, fun) when is_function(fun, 0) do
        if code in ContainmentGuard.codes(),
          do: scoped(@refusal_key, {code, :atomics.new(1, signed: false)}, fun),
          else: raise(ArgumentError, "test seam: not a closed guard code")
      end

      @doc "The claim count (0 or 1) of the innermost visible refusal scope, or 0."
      @spec refusal_hits() :: 0 | 1
      def refusal_hits do
        case lookup(@refusal_key) do
          {_code, ref} -> :atomics.get(ref, 1)
          nil -> 0
        end
      end

      @doc "Runs `fun` with row 1e's wall sample floored at `ms` (it can only move later)."
      @spec with_wall_ms(integer(), (-> result)) :: result when result: term()
      def with_wall_ms(ms, fun) when is_integer(ms) and is_function(fun, 0),
        do: scoped(@wall_key, ms, fun)

      @doc "Runs `fun` and returns `{result, %{env: n, view: n}}`; see the moduledoc."
      @spec with_read_log((-> result)) :: {result, reads()} when result: term()
      def with_read_log(fun) when is_function(fun, 0) do
        log = :atomics.new(2, signed: false)
        result = scoped(@log_key, log, fun)
        {result, %{env: :atomics.get(log, 1), view: :atomics.get(log, 2)}}
      end

      @doc false
      # The guard's claim: the code of the innermost visible refusal scope
      # when this call wins its claim, else nil.
      @spec claim_refusal() :: atom() | nil
      def claim_refusal do
        case lookup(@refusal_key) do
          {code, ref} -> if :atomics.compare_exchange(ref, 1, 0, 1) == :ok, do: code
          nil -> nil
        end
      end

      @doc false
      # Row 1e's sample: `max(real, floor)` under a visible floor, else `real`.
      @spec floor_wall(integer()) :: integer()
      def floor_wall(real) when is_integer(real) do
        case lookup(@wall_key) do
          floor when is_integer(floor) -> max(real, floor)
          nil -> real
        end
      end

      @doc false
      # Counts one stage B (`:env`) or stage C (`:view`) entry in the
      # innermost visible read log, if any.
      @spec note_read(:env | :view) :: :ok
      def note_read(stage) do
        case lookup(@log_key) do
          nil -> :ok
          log -> :atomics.add(log, slot(stage), 1)
        end
      end

      defp slot(:env), do: 1
      defp slot(:view), do: 2

      defp scoped(key, value, fun) do
        previous = Process.put(key, value)

        try do
          fun.()
        after
          restore(key, previous)
        end
      end

      defp restore(key, nil), do: Process.delete(key)
      defp restore(key, previous), do: Process.put(key, previous)

      # The value of `key` in the calling process, else in the first of its
      # explicit `$callers` that has it; a dead caller contributes nil, and
      # `$callers` is never changed.
      defp lookup(key) do
        Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
          if pid == self(), do: Process.get(key), else: remote(pid, key)
        end)
      end

      defp remote(pid, key) do
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> dict |> List.keyfind(key, 0, {key, nil}) |> elem(1)
          nil -> nil
        end
      end
    end
  end
end
