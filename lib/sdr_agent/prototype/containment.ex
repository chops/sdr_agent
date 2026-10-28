# Containment pure GREEN (proposal r1). The pure functions are implemented;
# `pinned/2` and every VM-effect function stay deny-only. Compiled only in
# builds with the prototype authority; the production build has no
# containment code.
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.Containment do
    @moduledoc """
    D-237 prototype runtime emission containment (containment packet r4,
    addendum r4a, pure GREEN proposal r1).

    Two term forms, never mixed:

      * the **descriptor**: a map with exactly the eleven keys `tracers`
        (D1, the projected tracer-cache entries `{provider, tracer}`),
        `sdk_tree`, `tree`, `applications`, `handlers`, `logger`,
        `ash_tracer`, `env`, `distributed`, `listeners` and `anchor_sinks`.
        It is what `evaluate/4` checks; D1 is validated entry by entry.
      * the **fingerprint projection** (`canonical/1`): the descriptor
        without `tracers`, with `applications`, `sdk_tree.root`,
        `tree.children`, `handlers`, `logger.handlers`, `env.names` and
        `anchor_sinks` sorted and `logger.filters` kept in order. It is what
        `fingerprint/1` hashes and what `pinned/2` returns. Tracer-cache
        entries are therefore validated but never fingerprinted.

    Pure functions (no VM state, no I/O):

      * `kinds/0` - `[:setup, :provision, :import, :op, :serve]`.
      * `codes/0` - the closed refusal family.
      * `phases/1` - setup `[:sealed, :maintenance, :storage, :repo,
        :retained]`; every other kind `[:sealed]`.
      * `config_check/2` - the K0/K-block check over an environment map
        and the entry token: the entry is one of the kinds, then the map is
        plain (not struct-shaped) with binary names and values, read with
        `:maps.to_list/1` and never by protocol dispatch on the supplied
        term (else `descriptor_unknown`), then no `OTEL_` name, then
        `ERL_CRASH_DUMP_BYTES` exactly `"0"`, then no `PHX_SERVER` name.
      * `paused_queues/1` - the K7 queue list: a non-empty keyword list
        with unique names and positive integer limits becomes
        `[name: [limit: n, paused: true]]` in the same order.
      * `tracer_check/1`, `handler_projection/1`, `filter_projection/1`,
        `logger_handler_projection/1`, `listener_projection/1` - one
        descriptor element each, from data.
        Handlers and filters: the callback must not belong to a forbidden
        family (`handler_forbidden`), then must be an EXTERNAL fun
        (`handler_closure`); ids, events and configs must be bounded plain
        terms. Logger handlers: `:logger_std_h` with destination
        `:standard_io` or `:standard_error` (a `{:file, _}` destination
        refuses `logger_handlers`), or one of the two pinned in-VM modules
        `Phoenix.LiveDashboard.LoggerPubSubBackend` and `Tidewave.MCP.Logger`
        (id equal to the module, no handler config); the formatter
        projection is `{Logger.Formatter, template, metadata, truncate}`.
        Listener census: at most 1024 entries; the verdict is `:ok`,
        `listener_present`, `listener_unknown` (unknown state, malformed or
        racing entry) or `descriptor_unbounded`.
      * `bounded?/1` - the term schema: leaves are atoms, integers and
        binaries of at most 256 bytes; containers are proper lists of at
        most 512 elements, tuples (bounded only by the depth and node
        limits) and maps of at most 64 entries; depth (a leaf 0, a container
        1 + its deepest element) at most 8; nodes (every leaf and container
        1, a map entry its key's and value's nodes) at most 32768; no pid,
        port, reference, fun or float.
      * `evaluate/4` - `(gate, kind, descriptor, pinned)` with gate
        `:precheck`, `:seal` or `:advance`: `:ok` or the first failing code.
        Precedence: the gate and kind; then the descriptor's shape
        (`descriptor_unknown`, `descriptor_unbounded`), including the
        PROJECTED Logger-handler schema (exact keys, an atom id, a Logger
        level, `:log` or `:stop`, projected filters `{atom, {m, f, a},
        config}`, the formatter tuple, and `:logger_std_h` with
        `:standard_io`, `:standard_error` or `:file`, or a pinned in-VM
        module with id equal to the module and destination
        `{:module, module}`); then the predicates in `codes/0` order (D9
        env, D1/D2 tracers, D4 SDK tree, D5 endpoint, the forbidden family
        over D6 handlers AND every D7 primary and per-handler filter, D7
        head filters and destinations, D8, D10, D11, D13). `:seal` and
        `:advance` then require the fingerprint projection to equal
        `canonical(pinned)`: the first differing group in `codes/0`
        order (`sdk_tree`, `tree`, `applications`, `handlers`,
        `logger_filters`, `logger_handlers`), else `seal_mismatch` for any
        other difference, so a seal and a later recheck agree.
      * `canonical/1`, `fingerprint/1` - the fingerprint projection and the
        sha256 of its deterministic external term format, as 64 lowercase
        hex characters.
      * `seal_decision/3`, `advance_decision/3`, `recheck_decision/3` - the
        seal state machine over `{kind, phase_index}`.

    Held (positive contracts outside this pure stage, each separately
    granted): `pinned/2` (the reviewed constants come from discovery) and
    the VM-effect functions `snapshot/0`, `precheck/1`, `seal/1`,
    `advance/2`, `recheck/1`, `put_entry/1` and `entry/0`, including the
    snapshot sender lifetime, the snapshot's tracer projection, readiness
    and descendant cleanup, and S1's setup placements.

    Stage: pure GREEN.
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
    @type seal :: {kind(), non_neg_integer()}

    @kinds [:setup, :provision, :import, :op, :serve]
    @codes [
      :entry_unadopted,
      :otel_env,
      :crash_dump_env,
      :phx_server_env,
      :tracer_noop,
      :tracer_sampler,
      :tracer_processor,
      :tracer_provider,
      :sdk_tree,
      :tree,
      :endpoint_present,
      :applications,
      :handler_forbidden,
      :handler_closure,
      :handlers,
      :logger_filters,
      :logger_handlers,
      :ash_tracer,
      :distributed,
      :listener_present,
      :listener_unknown,
      :anchor_sinks,
      :descriptor_unknown,
      :descriptor_unbounded,
      :snapshot_failed,
      :seal_exists,
      :seal_absent,
      :seal_phase,
      :seal_mismatch
    ]
    @setup_phases [:sealed, :maintenance, :storage, :repo, :retained]
    @gates [:precheck, :seal, :advance]
    # Sorted, so they compare with a sorted key list.
    @keys [
      :anchor_sinks,
      :applications,
      :ash_tracer,
      :distributed,
      :env,
      :handlers,
      :listeners,
      :logger,
      :sdk_tree,
      :tracers,
      :tree
    ]
    @canonical_keys List.delete(@keys, :tracers)
    # D1 (otel_tracer_server.erl:185-197, otel_sampler.erl:108-116): the
    # always_off sampler and the two processor funs with empty captured env.
    @always_off {:otel_sampler_always_off, "AlwaysOffSampler", []}
    @on_start %{
      module: :otel_tracer_server,
      name: :"-on_start/1-fun-0-",
      arity: 2,
      type: :local,
      env: [[]]
    }
    @on_end %{
      module: :otel_tracer_server,
      name: :"-on_end/1-fun-0-",
      arity: 1,
      type: :local,
      env: [[]]
    }
    # D4 (opentelemetry_sup.erl:29-64): the SDK supervisor ids, sorted.
    @sdk_tree %{
      root: [:otel_resource_detector, :otel_span_sup, :otel_tracer_provider_sup],
      providers: 1,
      processors: 0
    }
    @endpoint SdrAgentWeb.Endpoint
    # D6 (containment packet r3 section 4.1): each family is a module and its
    # submodules.
    @forbidden_families [
      "Elixir.OpentelemetryBandit",
      "Elixir.OpentelemetryPhoenix",
      "Elixir.OpentelemetryOban",
      "Elixir.OpentelemetryEcto",
      "Elixir.OpentelemetryReq",
      "Elixir.ReqLLM.OpenTelemetry",
      "Elixir.Phoenix.LiveDashboard.TelemetryListener"
    ]
    # D7: the primary filters that must come first, in this order.
    @head_filters [
      {SdrAgent.Prototype.SafeLog, :filter, 2},
      {SdrAgent.Logger.ExceptionFilter, :filter, 2}
    ]
    @module_handlers [Phoenix.LiveDashboard.LoggerPubSubBackend, Tidewave.MCP.Logger]
    @std_destinations [:standard_io, :standard_error]
    @levels [:all, :emergency, :alert, :critical, :error, :warning, :notice, :info, :debug, :none]
    @handler_keys [:config, :filter_default, :filters, :formatter, :id, :level, :module]
    @projection_keys [:destination, :filter_default, :filters, :formatter, :id, :level, :module]
    # D11 (prim_inet.erl:2750-2760, socket.erl:2837-2856).
    @inet_names [~c"tcp_inet", ~c"udp_inet", ~c"sctp_inet"]
    @inet_states [:busy, :accepting, :connecting, :listen, :connected, :bound, :open]
    @socket_states [
      :accepting,
      :bound,
      :busy,
      :connected,
      :connecting,
      :listen,
      :listening,
      :open,
      :selected
    ]
    @listening [:listen, :listening, :accepting]
    @listeners [:none, :present, :unknown]
    @max_depth 8
    @max_nodes 32_768
    @max_list 512
    @max_map 64
    @max_binary 256
    @max_handlers 256
    @max_census 1024
    @max_states 16

    @doc "The process kinds."
    @spec kinds() :: [kind()]
    def kinds, do: @kinds

    @doc "The closed refusal family."
    @spec codes() :: [code()]
    def codes, do: @codes

    @doc "The pinned phase sequence of `kind`."
    @spec phases(term()) :: [atom()] | {:error, :descriptor_unknown}
    def phases(kind) when kind in @kinds, do: sequence(kind)
    def phases(_kind), do: {:error, :descriptor_unknown}

    @doc "The K0/K-block check; see the moduledoc."
    @spec config_check(term(), term()) :: :ok | {:error, code()}
    def config_check(env, entry) do
      cond do
        entry not in @kinds -> {:error, :entry_unadopted}
        not env_map?(env) -> {:error, :descriptor_unknown}
        true -> env_check(Map.keys(env), Map.get(env, "ERL_CRASH_DUMP_BYTES"))
      end
    end

    @doc "The K7 paused queue list; see the moduledoc."
    @spec paused_queues(term()) :: keyword() | {:error, :descriptor_unknown}
    def paused_queues([_ | _] = queues) do
      if queue_list?(queues),
        do: Enum.map(queues, fn {name, limit} -> {name, [limit: limit, paused: true]} end),
        else: {:error, :descriptor_unknown}
    end

    def paused_queues(_queues), do: {:error, :descriptor_unknown}

    @doc "Pure: `:ok` when one projected D1 tracer value is the always_off, zero-processor tracer, else `{:error, code}`."
    @spec tracer_check(term()) :: :ok | {:error, code()}
    def tracer_check(%{tag: :otel_tracer_noop} = tracer) when map_size(tracer) == 1,
      do: {:error, :tracer_noop}

    def tracer_check(
          %{
            tag: :otel_tracer_default,
            module: :otel_tracer_default,
            sampler: sampler,
            on_start: on_start,
            on_end: on_end
          } = tracer
        )
        when map_size(tracer) == 5 do
      cond do
        sampler != @always_off -> {:error, :tracer_sampler}
        on_start != @on_start or on_end != @on_end -> {:error, :tracer_processor}
        true -> :ok
      end
    end

    def tracer_check(_projection), do: {:error, :descriptor_unknown}

    @doc "Pure: one telemetry handler map to `{:ok, {id, event, {m, f, a}, config}}` or `{:error, code}`."
    @spec handler_projection(term()) :: {:ok, tuple()} | {:error, code()}
    def handler_projection(%{id: id, event_name: event, function: fun, config: config} = handler)
        when map_size(handler) == 4 do
      with {:ok, mfa} <- fun_mfa(fun),
           :ok <- event_name(event),
           :ok <- plain(id),
           :ok <- plain(config) do
        {:ok, {id, event, mfa, config}}
      end
    end

    def handler_projection(_handler), do: {:error, :descriptor_unknown}

    @doc "Pure: one Logger primary filter to `{:ok, {id, {m, f, a}, config}}` or `{:error, code}`."
    @spec filter_projection(term()) :: {:ok, tuple()} | {:error, code()}
    def filter_projection({id, {fun, config}}) when is_atom(id) do
      with {:ok, mfa} <- fun_mfa(fun),
           :ok <- plain(config) do
        {:ok, {id, mfa, config}}
      end
    end

    def filter_projection(_filter), do: {:error, :descriptor_unknown}

    @doc "Pure: one Logger handler config to its bounded projection or `{:error, code}`."
    @spec logger_handler_projection(term()) :: {:ok, map()} | {:error, code()}
    def logger_handler_projection(
          %{
            id: id,
            module: module,
            level: level,
            filter_default: filter_default,
            filters: raw_filters,
            formatter: raw_formatter
          } = config
        ) do
      with :ok <- handler_keys(config),
           {:ok, destination} <- destination(config),
           {:ok, formatter} <- formatter(raw_formatter),
           :ok <- handler_settings(level, filter_default),
           {:ok, filters} <- project_all(raw_filters, &filter_projection/1),
           projection = %{
             id: id,
             module: module,
             level: level,
             filter_default: filter_default,
             filters: filters,
             destination: destination,
             formatter: formatter
           },
           :ok <- plain(projection),
           :ok <- projected_schema(projection) do
        {:ok, projection}
      end
    end

    def logger_handler_projection(_config), do: {:error, :descriptor_unknown}

    @doc "Pure: D11 census entries (at most 1024) to `:ok`, `{:error, :listener_present}`, `{:error, :listener_unknown}` or `{:error, :descriptor_unbounded}`."
    @spec listener_projection(term()) :: :ok | {:error, code()}
    def listener_projection(entries) do
      with :ok <- census_shape(entries) do
        verdicts = Enum.map(entries, &listener_entry/1)

        first_failure(
          listener_present: :present in verdicts,
          listener_unknown: :unknown in verdicts
        )
      end
    end

    @doc "Pure: the term schema; see the moduledoc."
    @spec bounded?(term()) :: boolean()
    def bounded?(term), do: plain(term) == :ok

    @doc "Pure: `:ok` or the first failing code; see the moduledoc."
    @spec evaluate(term(), term(), term(), term()) :: :ok | {:error, code()}
    def evaluate(gate, kind, descriptor, pinned) do
      cond do
        gate not in @gates -> {:error, :descriptor_unknown}
        kind not in @kinds -> {:error, :entry_unadopted}
        gate == :precheck -> with :ok <- shape(descriptor, @keys), do: predicates(descriptor)
        true -> evaluate_equal(descriptor, pinned)
      end
    end

    @doc "Pure: the fingerprint projection of a descriptor (or of a pinned constant), or `{:error, code}`."
    @spec canonical(term()) :: map() | {:error, code()}
    def canonical(%{tracers: _tracers} = descriptor) do
      with :ok <- shape(descriptor, @keys), do: projection(descriptor)
    end

    def canonical(descriptor) do
      with :ok <- shape(descriptor, @canonical_keys), do: projection(descriptor)
    end

    @doc "Pure: the sha256 of the fingerprint projection, as 64 lowercase hex characters, or `{:error, code}`."
    @spec fingerprint(term()) :: String.t() | {:error, code()}
    def fingerprint(descriptor) do
      case canonical(descriptor) do
        {:error, _code} = error ->
          error

        form ->
          form
          |> :erlang.term_to_binary([:deterministic])
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)
      end
    end

    @doc "Pure: `{:put, {kind, 0}}` with no seal and the kind's own phases, else a seal code."
    @spec seal_decision(term(), term(), term()) :: {:put, seal()} | {:error, code()}
    def seal_decision(nil, kind, phases) do
      if kind in @kinds and phases == sequence(kind),
        do: {:put, {kind, 0}},
        else: {:error, :seal_phase}
    end

    def seal_decision(_existing, _kind, _phases), do: {:error, :seal_exists}

    @doc "Pure: `{:put, {kind, index + 1}}` only for the next pinned phase, else a seal code."
    @spec advance_decision(term(), term(), term()) :: {:put, seal()} | {:error, code()}
    def advance_decision(nil, _kind, _to_phase), do: {:error, :seal_absent}

    def advance_decision({kind, index}, kind, to_phase)
        when kind in @kinds and is_integer(index) and index >= 0 and is_atom(to_phase) and
               not is_nil(to_phase) do
      if Enum.at(sequence(kind), index + 1) == to_phase,
        do: {:put, {kind, index + 1}},
        else: {:error, :seal_phase}
    end

    def advance_decision(_seal, _kind, _to_phase), do: {:error, :seal_phase}

    @doc "Pure: `:ok` when the live fingerprint is the current phase's, else a seal code."
    @spec recheck_decision(term(), term(), term()) :: :ok | {:error, code()}
    def recheck_decision(nil, _pinned_fingerprint, _live_fingerprint),
      do: {:error, :seal_absent}

    # The index must name a phase of the kind's own sequence: a fingerprint
    # cannot make an absent current phase valid (Codex 9584536a R1).
    def recheck_decision({kind, index}, pinned_fingerprint, live_fingerprint)
        when kind in @kinds and is_integer(index) and index >= 0 do
      valid? = index < length(sequence(kind)) and hex64?(pinned_fingerprint)

      if valid? and pinned_fingerprint == live_fingerprint,
        do: :ok,
        else: {:error, :seal_mismatch}
    end

    def recheck_decision(_seal, _pinned_fingerprint, _live_fingerprint),
      do: {:error, :seal_mismatch}

    @doc "Held: the reviewed fingerprint projection of `{kind, phase}`, from discovery."
    def pinned(_kind, _phase), do: red({:error, :not_implemented})

    @doc "Held VM effect (IT/SV only): the bounded descriptor of this VM."
    def snapshot, do: red({:error, :not_implemented})

    @doc "Held VM effect (IT/SV only): G0."
    def precheck(_kind), do: red({:error, :not_implemented})

    @doc "Held VM effect (IT/SV only): G1."
    def seal(_kind), do: red({:error, :not_implemented})

    @doc "Held VM effect (IT/SV only): one pinned phase transition."
    def advance(_kind, _phase), do: red({:error, :not_implemented})

    @doc "Held VM effect (IT/SV only): G2."
    def recheck(_point), do: red({:error, :not_implemented})

    @doc "Held VM effect (TaskBoundary only): records the entry token in this process."
    def put_entry(_kind), do: red({:error, :not_implemented})

    @doc "Held: the entry token of this process, or nil."
    def entry, do: red({:error, :not_implemented})

    # -- Phases, K0/K-block and K7 -------------------------------------------

    defp sequence(:setup), do: @setup_phases
    defp sequence(_kind), do: [:sealed]

    # Plain-map inspection only (Codex 9e3fa4bd R5): a struct-shaped map is refused before any
    # enumeration, and the map is read with :maps.to_list/1, never by protocol dispatch on the
    # supplied term.
    defp env_map?(env) when is_map(env) and not is_struct(env),
      do: Enum.all?(:maps.to_list(env), &env_entry?/1)

    defp env_map?(_env), do: false

    defp env_entry?({name, value}), do: is_binary(name) and is_binary(value)

    defp env_check(names, crash_dump_bytes) do
      first_failure(
        otel_env: Enum.any?(names, &String.starts_with?(&1, "OTEL_")),
        crash_dump_env: crash_dump_bytes != "0",
        phx_server_env: "PHX_SERVER" in names
      )
    end

    defp queue_list?(queues) do
      Keyword.keyword?(queues) and
        Enum.all?(queues, fn {_name, limit} -> is_integer(limit) and limit > 0 end) and
        length(Enum.uniq(Keyword.keys(queues))) == length(queues)
    end

    # -- Projections ---------------------------------------------------------

    # The forbidden family comes first (a forbidden vendor's closure is still
    # forbidden); then the fun must be external.
    defp fun_mfa(fun) when is_function(fun) do
      {:module, module} = :erlang.fun_info(fun, :module)
      {:name, name} = :erlang.fun_info(fun, :name)
      {:arity, arity} = :erlang.fun_info(fun, :arity)

      cond do
        forbidden?(module) -> {:error, :handler_forbidden}
        :erlang.fun_info(fun, :type) != {:type, :external} -> {:error, :handler_closure}
        true -> {:ok, {module, name, arity}}
      end
    end

    defp fun_mfa(_fun), do: {:error, :descriptor_unknown}

    defp forbidden?(module) when is_atom(module) do
      name = Atom.to_string(module)

      Enum.any?(@forbidden_families, fn family ->
        name == family or String.starts_with?(name, family <> ".")
      end)
    end

    defp forbidden?(_module), do: false

    defp event_name([_ | _] = event) do
      with :ok <- plain(event) do
        if Enum.all?(event, &is_atom/1), do: :ok, else: {:error, :descriptor_unknown}
      end
    end

    defp event_name(_event), do: {:error, :descriptor_unknown}

    defp handler_keys(config) do
      if Enum.all?(Map.keys(config), &(&1 in @handler_keys)),
        do: :ok,
        else: {:error, :descriptor_unknown}
    end

    defp destination(%{module: :logger_std_h, config: %{type: type}}), do: std_destination(type)

    defp destination(%{module: module, id: module} = config)
         when module in @module_handlers and not is_map_key(config, :config),
         do: {:ok, {:module, module}}

    defp destination(_config), do: {:error, :descriptor_unknown}

    defp std_destination(type) when type in @std_destinations, do: {:ok, type}
    defp std_destination({:file, _path}), do: {:error, :logger_handlers}
    defp std_destination(_type), do: {:error, :descriptor_unknown}

    defp formatter({Logger.Formatter, %Logger.Formatter{} = formatter}),
      do: {:ok, {Logger.Formatter, formatter.template, formatter.metadata, formatter.truncate}}

    defp formatter(_formatter), do: {:error, :descriptor_unknown}

    defp handler_settings(level, filter_default) do
      if level in @levels and filter_default in [:log, :stop],
        do: :ok,
        else: {:error, :descriptor_unknown}
    end

    defp project_all(list, project) do
      step = &project_step(&1, &2, project)

      with :ok <- list_shape(list, @max_list),
           {:ok, reversed} <- Enum.reduce_while(list, {:ok, []}, step) do
        {:ok, Enum.reverse(reversed)}
      end
    end

    defp project_step(item, {:ok, projected}, project) do
      case project.(item) do
        {:ok, one} -> {:cont, {:ok, [one | projected]}}
        error -> {:halt, error}
      end
    end

    # -- D11 census ----------------------------------------------------------

    defp census_shape(entries) do
      case list_shape(entries, @max_census) do
        :ok -> :ok
        {:error, :descriptor_unbounded} = error -> error
        {:error, _shape} -> {:error, :listener_unknown}
      end
    end

    defp listener_entry({:inet, name, {:ok, states}}) when name in @inet_names do
      cond do
        states == [] or not states?(states, @inet_states) -> :unknown
        Enum.any?(states, &(&1 in @listening)) -> :present
        name != ~c"tcp_inet" and :bound in states -> :present
        true -> :none
      end
    end

    defp listener_entry({:socket, {:ok, %{rstates: rstates, wstates: wstates} = info}})
         when map_size(info) == 2 do
      cond do
        not (states?(rstates, @socket_states) and states?(wstates, @socket_states)) -> :unknown
        Enum.any?(rstates ++ wstates, &(&1 in @listening)) -> :present
        true -> :none
      end
    end

    defp listener_entry(_entry), do: :unknown

    defp states?(states, known),
      do: list_shape(states, @max_states) == :ok and Enum.all?(states, &(&1 in known))

    # -- Term schema ---------------------------------------------------------

    defp plain(term) do
      case walk(term, 0, 0) do
        {:ok, _nodes} -> :ok
        error -> error
      end
    end

    # `level` is the nesting of the enclosing containers; `nodes` counts the
    # terms walked so far.
    defp walk(_term, _level, nodes) when nodes >= @max_nodes, do: {:error, :descriptor_unbounded}
    defp walk(term, _level, nodes) when is_atom(term) or is_integer(term), do: {:ok, nodes + 1}

    defp walk(term, _level, nodes) when is_binary(term) and byte_size(term) <= @max_binary,
      do: {:ok, nodes + 1}

    defp walk(term, _level, _nodes) when is_binary(term), do: {:error, :descriptor_unbounded}

    defp walk(term, level, _nodes)
         when (is_list(term) or is_tuple(term) or is_map(term)) and level >= @max_depth,
         do: {:error, :descriptor_unbounded}

    defp walk(term, level, nodes) when is_list(term), do: walk_list(term, level + 1, nodes + 1, 0)

    defp walk(term, level, nodes) when is_tuple(term),
      do: walk_tuple(term, level + 1, nodes + 1, 0)

    defp walk(term, level, nodes) when is_map(term) and map_size(term) <= @max_map,
      do: walk_entries(Map.to_list(term), level + 1, nodes + 1)

    defp walk(term, _level, _nodes) when is_map(term), do: {:error, :descriptor_unbounded}
    defp walk(_term, _level, _nodes), do: {:error, :descriptor_unknown}

    defp walk_list([], _level, nodes, _count), do: {:ok, nodes}

    defp walk_list([_head | _tail], _level, _nodes, count) when count >= @max_list,
      do: {:error, :descriptor_unbounded}

    defp walk_list([head | tail], level, nodes, count) do
      with {:ok, nodes} <- walk(head, level, nodes), do: walk_list(tail, level, nodes, count + 1)
    end

    defp walk_list(_improper_tail, _level, _nodes, _count), do: {:error, :descriptor_unknown}

    defp walk_tuple(tuple, _level, nodes, index) when index == tuple_size(tuple), do: {:ok, nodes}

    defp walk_tuple(tuple, level, nodes, index) do
      with {:ok, nodes} <- walk(elem(tuple, index), level, nodes),
           do: walk_tuple(tuple, level, nodes, index + 1)
    end

    defp walk_entries([], _level, nodes), do: {:ok, nodes}

    defp walk_entries([{key, value} | rest], level, nodes) do
      with {:ok, nodes} <- walk(key, level, nodes),
           {:ok, nodes} <- walk(value, level, nodes),
           do: walk_entries(rest, level, nodes)
    end

    # A proper list of at most `max` elements, without walking the elements.
    defp list_shape(list, max), do: list_shape(list, max, 0)
    defp list_shape([], _max, _count), do: :ok

    defp list_shape([_head | _tail], max, count) when count >= max,
      do: {:error, :descriptor_unbounded}

    defp list_shape([_head | tail], max, count), do: list_shape(tail, max, count + 1)
    defp list_shape(_other, _max, _count), do: {:error, :descriptor_unknown}

    # -- Descriptor shape, predicates and equality ----------------------------

    # Exact keys, then the term schema, then each field's shape, then the
    # D6 handler cap.
    defp shape(descriptor, keys)
         when is_map(descriptor) and map_size(descriptor) == length(keys) do
      with :ok <- exact_keys(descriptor, keys),
           :ok <- plain(descriptor),
           :ok <- fields(descriptor) do
        if length(descriptor.handlers) > @max_handlers,
          do: {:error, :descriptor_unbounded},
          else: :ok
      end
    end

    defp shape(_descriptor, _keys), do: {:error, :descriptor_unknown}

    defp exact_keys(map, keys) do
      if map |> Map.keys() |> Enum.sort() == keys, do: :ok, else: {:error, :descriptor_unknown}
    end

    defp fields(descriptor) do
      if Enum.all?(descriptor, fn {key, value} -> field?(key, value) end),
        do: :ok,
        else: {:error, :descriptor_unknown}
    end

    defp field?(:tracers, tracers), do: is_list(tracers) and Enum.all?(tracers, &tracer_entry?/1)

    defp field?(:sdk_tree, %{root: root, providers: providers, processors: processors} = tree)
         when map_size(tree) == 3 and is_integer(providers) and is_integer(processors),
         do: atoms?(root)

    defp field?(:tree, %{children: children, endpoint: endpoint} = tree)
         when map_size(tree) == 2 and is_boolean(endpoint),
         do: is_list(children)

    defp field?(:handlers, handlers), do: is_list(handlers) and Enum.all?(handlers, &handler?/1)

    defp field?(:logger, %{filters: filters, handlers: handlers} = logger)
         when map_size(logger) == 2 and is_list(filters) and is_list(handlers),
         do: Enum.all?(filters, &filter?/1) and Enum.all?(handlers, &projection?/1)

    defp field?(:env, %{names: names, crash_dump_bytes: crash_dump_bytes} = env)
         when map_size(env) == 2 and (is_binary(crash_dump_bytes) or is_nil(crash_dump_bytes)),
         do: is_list(names) and Enum.all?(names, &is_binary/1)

    defp field?(:distributed, distributed), do: is_boolean(distributed)
    defp field?(:listeners, listeners), do: listeners in @listeners

    defp field?(key, value) when key in [:applications, :ash_tracer, :anchor_sinks],
      do: atoms?(value)

    defp field?(_key, _value), do: false

    defp atoms?(value), do: is_list(value) and Enum.all?(value, &is_atom/1)

    defp tracer_entry?({provider, tracer}) when is_atom(provider),
      do: tracer_check(tracer) != {:error, :descriptor_unknown}

    defp tracer_entry?(_entry), do: false

    defp handler?({_id, event, {module, function, arity}, _config})
         when is_atom(module) and is_atom(function) and is_integer(arity),
         do: atoms?(event)

    defp handler?(_handler), do: false

    defp filter?({id, {module, function, arity}, _config})
         when is_atom(id) and is_atom(module) and is_atom(function) and is_integer(arity) and
                arity >= 0,
         do: true

    defp filter?(_filter), do: false

    # The PROJECTED Logger-handler schema (Codex 9584536a R2), enforced at
    # the descriptor boundary and on the raw projection's own output.
    defp projection?(projection) when is_map(projection) do
      exact_keys(projection, @projection_keys) == :ok and is_atom(projection.id) and
        projection.level in @levels and projection.filter_default in [:log, :stop] and
        is_list(projection.filters) and Enum.all?(projection.filters, &filter?/1) and
        projected_formatter?(projection.formatter) and
        projected_destination?(projection.module, projection.id, projection.destination)
    end

    defp projection?(_projection), do: false

    defp projected_schema(projection) do
      if projection?(projection), do: :ok, else: {:error, :descriptor_unknown}
    end

    defp projected_formatter?({Logger.Formatter, template, metadata, truncate}) do
      is_list(template) and (is_list(metadata) or metadata == :all) and
        (is_integer(truncate) or truncate == :infinity)
    end

    defp projected_formatter?(_formatter), do: false

    # `:file` is a well-formed projection that the predicates refuse
    # (`logger_handlers`); any other destination or correlation is unknown.
    defp projected_destination?(:logger_std_h, _id, destination),
      do: destination in [:standard_io, :standard_error, :file]

    defp projected_destination?(module, module, {:module, module}), do: module in @module_handlers
    defp projected_destination?(_module, _id, _destination), do: false

    defp predicates(descriptor) do
      %{env: env, tree: tree, logger: logger} = descriptor

      with :ok <- env_check(env.names, env.crash_dump_bytes),
           :ok <- tracers_check(descriptor.tracers) do
        first_failure(
          sdk_tree: projection_tree(descriptor.sdk_tree) != @sdk_tree,
          endpoint_present: tree.endpoint or @endpoint in tree.children,
          handler_forbidden: forbidden_callbacks?(descriptor),
          logger_filters: head_filters(logger.filters) != @head_filters,
          logger_handlers: not Enum.all?(logger.handlers, &allowed_destination?/1),
          ash_tracer: descriptor.ash_tracer != [],
          distributed: descriptor.distributed,
          listener_present: descriptor.listeners == :present,
          listener_unknown: descriptor.listeners == :unknown,
          anchor_sinks: descriptor.anchor_sinks != []
        )
      end
    end

    defp tracers_check(tracers) do
      results = Enum.map(tracers, fn {_provider, tracer} -> tracer_check(tracer) end)
      providers = tracers |> Enum.map(fn {provider, _tracer} -> provider end) |> Enum.uniq()

      first_failure(
        tracer_noop: {:error, :tracer_noop} in results,
        tracer_sampler: {:error, :tracer_sampler} in results,
        tracer_processor: {:error, :tracer_processor} in results,
        tracer_provider: providers != [:global]
      )
    end

    defp projection_tree(sdk_tree), do: %{sdk_tree | root: Enum.sort(sdk_tree.root)}

    # Every projected callback collection (Codex 9584536a R3): D6 handlers,
    # D7 primary filters and every D7 handler's own filters.
    defp forbidden_callbacks?(descriptor) do
      handler_filters = Enum.flat_map(descriptor.logger.handlers, & &1.filters)
      filters = descriptor.logger.filters ++ handler_filters

      Enum.any?(descriptor.handlers, &forbidden_handler?/1) or
        Enum.any?(filters, &forbidden_filter?/1)
    end

    defp forbidden_handler?({_id, _event, {module, _function, _arity}, _config}),
      do: forbidden?(module)

    defp forbidden_filter?({_id, {module, _function, _arity}, _config}), do: forbidden?(module)

    defp head_filters(filters) do
      filters |> Enum.take(2) |> Enum.map(fn {_id, mfa, _config} -> mfa end)
    end

    defp allowed_destination?(%{module: :logger_std_h, destination: destination}),
      do: destination in @std_destinations

    defp allowed_destination?(%{module: module, destination: {:module, module}}),
      do: module in @module_handlers

    defp allowed_destination?(_projection), do: false

    defp evaluate_equal(descriptor, pinned) do
      with :ok <- shape(descriptor, @keys),
           :ok <- shape(pinned, @canonical_keys),
           :ok <- predicates(descriptor) do
        equality(projection(descriptor), projection(pinned))
      end
    end

    defp equality(live, pinned) do
      first_failure(
        sdk_tree: live.sdk_tree != pinned.sdk_tree,
        tree: live.tree != pinned.tree,
        applications: live.applications != pinned.applications,
        handlers: live.handlers != pinned.handlers,
        logger_filters: live.logger.filters != pinned.logger.filters,
        logger_handlers: live.logger.handlers != pinned.logger.handlers,
        seal_mismatch: live != pinned
      )
    end

    # The fingerprint projection of a shape-checked descriptor or constant.
    defp projection(descriptor) do
      %{
        anchor_sinks: Enum.sort(descriptor.anchor_sinks),
        applications: Enum.sort(descriptor.applications),
        ash_tracer: descriptor.ash_tracer,
        distributed: descriptor.distributed,
        env: %{descriptor.env | names: Enum.sort(descriptor.env.names)},
        handlers: Enum.sort(descriptor.handlers),
        listeners: descriptor.listeners,
        logger: %{descriptor.logger | handlers: Enum.sort(descriptor.logger.handlers)},
        sdk_tree: projection_tree(descriptor.sdk_tree),
        tree: %{descriptor.tree | children: Enum.sort(descriptor.tree.children)}
      }
    end

    defp first_failure(checks) do
      case Enum.find(checks, fn {_code, failed?} -> failed? end) do
        nil -> :ok
        {code, true} -> {:error, code}
      end
    end

    defp hex64?(fingerprint) when is_binary(fingerprint) and byte_size(fingerprint) == 64,
      do: fingerprint |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

    defp hex64?(_fingerprint), do: false

    # Held result (pinned constants and VM effects), typed dynamic() so
    # callers compile against it.
    defp red(default), do: :persistent_term.get({__MODULE__, :red_stub}, default)
  end
end
