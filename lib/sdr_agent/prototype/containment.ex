# DRAFT r4a (outside the repository; review only; NOT formatted, compiled
# or run). Deny-only declarations: every function returns
# {:error, :not_implemented}. Compiled only in builds with the prototype
# authority; the production build has no containment code.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Containment do
    @moduledoc """
    D-237 prototype runtime emission containment (containment packet r4,
    addendum r4a).

    Pure functions (no VM state, no I/O):

      * `kinds/0` - `[:setup, :provision, :import, :op, :serve]`.
      * `codes/0` - the closed refusal family, in check order.
      * `phases/1` - the pinned phase sequence of a kind (setup:
        `[:sealed, :maintenance, :storage, :repo, :retained]`; every other
        kind `[:sealed]`); a seal only ever advances along it.
      * `config_check/2` - the K0/K-block check over an environment map and
        the entry token: `:ok` or `{:error, code}`.
      * `paused_queues/1` - the K7 queue list: every configured queue with
        its limit and `paused: true`.
      * `tracer_check/1`, `handler_projection/1`, `filter_projection/1`,
        `logger_handler_projection/1`, `listener_projection/1` - one
        descriptor each, from data (fun_info lists, maps), never from the VM.
        Logger handlers: only `:logger_std_h` with destination
        `:standard_io` or `:standard_error`, and the two pinned in-VM
        modules `Phoenix.LiveDashboard.LoggerPubSubBackend` and
        `Tidewave.MCP.Logger` with no handler config beyond the formatter;
        a file destination refuses `:logger_handlers`, any other module or
        shape `:descriptor_unknown`. The formatter projection is
        `{Logger.Formatter, template, metadata, truncate}`: colors and
        `utc_log?` are outside the fingerprint scope (presentation only).
      * `bounded?/1` - the descriptor term schema. Leaves: atoms, integers,
        binaries of at most 256 bytes. Containers: lists of at most 512
        elements, tuples, maps of at most 64 entries. Depth: a leaf is 0, a
        container is 1 + its deepest element; at most 8. Nodes: every leaf
        and container is 1, a map entry adds its key's and value's nodes;
        at most 32768 in total. No pid, port, reference or fun.
      * `evaluate/4` - `(phase, kind, descriptor, pinned)`: `:ok` or the
        first failing code. The descriptor has exactly the keys `tracers`,
        `sdk_tree`, `tree`, `applications`, `handlers`, `logger`,
        `ash_tracer`, `env`, `distributed`, `listeners` (`:none`,
        `:present` or `:unknown`, the D11 census verdict) and
        `anchor_sinks` (D13; pinned `[]`).
      * `canonical/1`, `fingerprint/1` - the canonical form (D5 children,
        D6 handlers and D7 handlers sorted; D7 primary filters in order;
        D1 tracers excluded) and its sha256 (64 lowercase hex characters).
      * `seal_decision/3`, `advance_decision/3`, `recheck_decision/3` - the
        seal state machine over `{kind, phase_index}`.
      * `pinned/2` - the reviewed descriptor constant of `{kind, phase}`.

    VM-effect functions (isolated or scratch-service tests only; never
    called from pure tests): `snapshot/0`, `precheck/1`, `seal/1`,
    `advance/2`, `recheck/1`, `put_entry/1`, `entry/0`.

    `snapshot/0` protocol: a fresh tag; `spawn_monitor/1` of the reader (no
    link); the reader sends `{tag, descriptor}` and exits. The caller waits
    for that message within an overall 5000 ms deadline, then for the
    reader's `:DOWN` within 1000 ms more; on the deadline it kills the
    reader, waits up to 1000 ms for `:DOWN`, and flushes any late `{tag, _}`
    message. Every path other than "descriptor received, then :DOWN normal"
    is `{:error, :snapshot_failed}`. The bound covers the protocol's own
    waits; BEAM scheduling may delay a `:DOWN` (the refusal never depends on
    it). The reader's `:persistent_term.get/0` allocation is proportional to
    the VM's persistent-term count and is NOT bounded by these caps; the
    raw list stays in the reader's heap and dies with it.

    Stage: deny-only (containment r4a draft).
    """

    @type kind :: :setup | :provision | :import | :op | :serve
    @type code ::
            :entry_unadopted
            | :otel_env
            | :crash_dump_env
            | :phx_server_env
            | :tracer_noop
            | :tracer_sampler
            | :tracer_processor
            | :tracer_provider
            | :sdk_tree
            | :tree
            | :endpoint_present
            | :applications
            | :handler_forbidden
            | :handler_closure
            | :handlers
            | :logger_filters
            | :logger_handlers
            | :ash_tracer
            | :distributed
            | :listener_present
            | :listener_unknown
            | :anchor_sinks
            | :descriptor_unknown
            | :descriptor_unbounded
            | :snapshot_failed
            | :seal_exists
            | :seal_absent
            | :seal_phase
            | :seal_mismatch

    @doc "The process kinds."
    def kinds, do: red({:error, :not_implemented})

    @doc "The closed refusal family, in check order."
    def codes, do: red({:error, :not_implemented})

    @doc "The pinned phase sequence of `kind`."
    def phases(_kind), do: red({:error, :not_implemented})

    @doc "The K0/K-block check; see the moduledoc."
    def config_check(_env, _entry), do: red({:error, :not_implemented})

    @doc "The K7 paused queue list; see the moduledoc."
    def paused_queues(_queues), do: red({:error, :not_implemented})

    @doc "Pure: `:ok` when one projected D1 tracer value is the always_off, zero-processor tracer, else `{:error, code}`."
    def tracer_check(_projection), do: red({:error, :not_implemented})

    @doc "Pure: one telemetry handler map to `{:ok, {id, event, {m, f, a}, config}}` or `{:error, code}`."
    def handler_projection(_handler), do: red({:error, :not_implemented})

    @doc "Pure: one Logger primary filter to `{:ok, {id, {m, f, a}, config}}` or `{:error, code}`."
    def filter_projection(_filter), do: red({:error, :not_implemented})

    @doc "Pure: one Logger handler config to its bounded projection or `{:error, code}`."
    def logger_handler_projection(_config), do: red({:error, :not_implemented})

    @doc "Pure: D11 census entries (at most 1024) to `:ok`, `{:error, :listener_present}`, `{:error, :listener_unknown}` or `{:error, :descriptor_unbounded}`."
    def listener_projection(_entries), do: red({:error, :not_implemented})

    @doc "Pure: the descriptor term schema; see the moduledoc."
    def bounded?(_term), do: red({:error, :not_implemented})

    @doc "Pure: `:ok` or the first failing code."
    def evaluate(_phase, _kind, _descriptor, _pinned), do: red({:error, :not_implemented})

    @doc "Pure: the canonical descriptor."
    def canonical(_descriptor), do: red({:error, :not_implemented})

    @doc "Pure: the sha256 of the canonical descriptor, as lowercase hex."
    def fingerprint(_descriptor), do: red({:error, :not_implemented})

    @doc "Pure: `{:put, {kind, 0}}` with no seal, else `{:error, :seal_exists}`."
    def seal_decision(_existing, _kind, _phases), do: red({:error, :not_implemented})

    @doc "Pure: `{:put, {kind, index + 1}}` only for the next pinned phase, else `{:error, :seal_phase}`."
    def advance_decision(_seal, _kind, _to_phase), do: red({:error, :not_implemented})

    @doc "Pure: `:ok` when the live fingerprint is the current phase's, else a seal code."
    def recheck_decision(_seal, _pinned_fingerprint, _live_fingerprint),
      do: red({:error, :not_implemented})

    @doc "The reviewed descriptor constant of `{kind, phase}`."
    def pinned(_kind, _phase), do: red({:error, :not_implemented})

    @doc "VM effect (IT/SV only): the bounded canonical descriptor of this VM."
    def snapshot, do: red({:error, :not_implemented})

    @doc "VM effect (IT/SV only): G0."
    def precheck(_kind), do: red({:error, :not_implemented})

    @doc "VM effect (IT/SV only): G1."
    def seal(_kind), do: red({:error, :not_implemented})

    @doc "VM effect (IT/SV only): one pinned phase transition."
    def advance(_kind, _phase), do: red({:error, :not_implemented})

    @doc "VM effect (IT/SV only): G2."
    def recheck(_point), do: red({:error, :not_implemented})

    @doc "VM effect (TaskBoundary only): records the entry token in this process."
    def put_entry(_kind), do: red({:error, :not_implemented})

    @doc "The entry token of this process, or nil."
    def entry, do: red({:error, :not_implemented})

    # RED stub result, typed dynamic() so callers compile against it.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
