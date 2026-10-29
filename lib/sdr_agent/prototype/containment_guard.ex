# The D-237 task-body containment guard (S4 K0/guard GREEN r1 plus the
# reduced view r1). Compiled only with the prototype authority
# (config/dev.exs and config/test.exs); the production build has neither
# module below. The test seam exists only in builds that also set
# `prototype_test_seams: true` (config/test.exs).
if Application.compile_env(:sdr_agent, :prototype_authority_compiled, false) do
  defmodule SdrAgent.Prototype.ContainmentGuard do
    @moduledoc """
    The containment guard a task body calls before protected work
    (D-237 S4 reduced-containment plan r5 sections 3-4, as amended by r6
    section 2, r7 section 2 and r8 section 2; K0/guard RED packet r1-r5).
    `guard(kind)` returns `:ok` or `{:error, code}` with `code` in the
    closed `codes/0`. It prints and logs nothing, never writes or alters a
    token, and its refusal is a value the body returns unchanged
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
      4. Stage C, the view (rows 3a-12): `check_view(build_view())`.

    The view is a plain map with exactly eight keys, each an INDEPENDENT
    component result built from this VM's current state, read-only:

      * `exporter` - `{:ok, %{traces_exporter, span_processor,
        processors}}`, the three `:opentelemetry` application settings;
      * `tracers` - `{:ok, list}` of `{provider, name, projection}` or
        `:invalid_entry`, sorted; `:over_cap` past 512 cached tracers;
        `:unreadable`. Read by an isolated reader process (plan r5
        section 3.1): only keys `{:opentelemetry, provider, :tracer,
        name}` are kept, and each value is projected and validated in the
        reader's heap before anything is sent;
      * `logger_filters` - `{:ok, list}` of `{id, {m, f, a}, config}` or
        `:invalid_entry`, in installed order; `:over_cap` past 64;
        `:unreadable`;
      * `logger_handlers` - `{:ok, list}`, sorted by id, of
        `handler_element/1` results; `:over_cap` past 64 ids;
        `:unreadable` (kernel pin miss, or a handler removed during the
        read on four attempts);
      * `endpoint` - `{:ok, boolean}`, the endpoint's registered name;
      * `listeners` - `{:ok, :none}`, `{:refused, :listener_present}`,
        `{:refused, :listener_unknown}` or `:over_cap` (port census, at
        most 1024 ports, plus the socket-NIF socket count, which must be 0);
      * `distributed` - `{:ok, boolean}`, `Node.alive?/0`;
      * `anchor_sinks` - `{:ok, list}` of configured sink kinds, or
        `:invalid_entry`; `:over_cap` past 8; `:unreadable`.

    A component whose read raises, throws or exits is `:unreadable`. The
    filters come from the public passive `get_primary_config/0` and the
    handler ids from `get_handler_ids/0` of `:logger` (no handler callback);
    each handler's raw config is one `logger_config` ETS lookup, only under
    the pinned kernel 11.0.3.

    `check_view/1` (pure, total) applies one global precedence:

      * 3a form: a plain map with exactly the eight keys, each value a
        whitelisted top-level form; any `:unreadable` -> `descriptor_unknown`;
      * 3b caps, in key order (`exporter.processors` 8, `tracers` 512,
        `logger_filters` 64, `logger_handlers` 64, `anchor_sinks` 8):
        `:over_cap` -> `descriptor_unbounded`; else the kept
        `Containment.list_shape/2` error;
      * 3c elements, in key order, only after every cap passed: any
        `:invalid_entry`, an element not of its declared form, a failed
        `Containment.bounded?/1`, duplicate or unsorted tracer keys or
        handler ids -> `descriptor_unknown`;
      * 5 the exporter is not exactly `%{traces_exporter: :none,
        span_processor: :undefined, processors: []}` -> `exporter_destination`;
      * 6a the provider set is not `[:global]` -> `tracer_provider`; 6b no
        global default tracer -> `tracer_noop`; 6c the kept
        `Containment.tracer_check/1` over every cached tracer (`tracer_noop`,
        then `tracer_sampler`, then `tracer_processor`);
      * 7 the filters do not begin with exactly ExceptionFilter then
        SafeLog -> `logger_filters`;
      * 8 a refused handler marker, or a destination outside the standard
        streams and the two pinned in-VM modules -> `logger_handlers`;
      * 9 `endpoint_present`; 10 the listeners' code; 11 `distributed`;
        12 a non-empty sink list -> `anchor_sinks`.

    No form falls through to `:ok`. The guard never accepts a view from
    its caller: `guard/1` always builds its own.

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
    # Plan r5 section 4.1: the view's keys, in the order rows 3a-3c use.
    @view_keys [
      :exporter,
      :tracers,
      :logger_filters,
      :logger_handlers,
      :endpoint,
      :listeners,
      :distributed,
      :anchor_sinks
    ]
    # Plan r5 section 4.2: list caps (`exporter.processors` separately).
    @caps %{tracers: 512, logger_filters: 64, logger_handlers: 64, anchor_sinks: 8}
    @max_processors 8
    @max_tracers 512
    @max_filters 64
    @max_handler_ids 64
    @max_anchors 8
    @max_ports 1024
    # A race (a handler or port gone mid-read) restarts a read at most 3 times.
    @restarts 3
    # Plan r5 section 3.1 (H2): the reader's reply and exit waits, ms.
    @reply_ms 1_000
    @exit_ms 200
    # Plan r5 section 4.4: the kernel whose logger_config layout is read.
    @kernel_vsn ~c"11.0.3"
    # Plan r7 section 2.2: the same seven atoms as Containment's handler keys.
    @handler_keys_view [:config, :filter_default, :filters, :formatter, :id, :level, :module]
    @endpoint SdrAgentWeb.Endpoint
    @inet_names [~c"tcp_inet", ~c"udp_inet", ~c"sctp_inet"]
    # Row 5: the only accepted exporter settings (OG-2).
    @thin_exporter %{traces_exporter: :none, span_processor: :undefined, processors: []}
    # Row 6c, in this order.
    @tracer_codes [:tracer_noop, :tracer_sampler, :tracer_processor, :descriptor_unknown]
    # Row 7: the exact head of the primary filter list.
    @head_filters [
      {:sdr_agent_exception_filter, {SdrAgent.Logger.ExceptionFilter, :filter, 2}, []},
      {:sdr_prototype_content_free, {SdrAgent.Prototype.SafeLog, :filter, 2}, []}
    ]
    # Row 8: the std destinations and the two pinned in-VM handler modules.
    @std_destinations [:standard_io, :standard_error]
    @module_handlers [Phoenix.LiveDashboard.LoggerPubSubBackend, Tidewave.MCP.Logger]

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

    @doc false
    # Pure and total: rows 3a-12 over a view term; see the moduledoc.
    @spec check_view(term()) :: :ok | {:error, code()}
    def check_view(view) do
      with :ok <- view_form(view),
           :ok <- first_error(@view_keys, &cap(&1, :erlang.map_get(&1, view))),
           :ok <- first_error(@view_keys, &elements(&1, :erlang.map_get(&1, view))) do
        view_rows(view)
      end
    end

    @doc false
    # Read-only: the eight independent components of this VM's view.
    @spec build_view() :: map()
    def build_view do
      %{
        exporter: component(&exporter_component/0),
        tracers: component(&tracers_component/0),
        logger_filters: component(&logger_filters_component/0),
        logger_handlers: component(&logger_handlers_component/0),
        endpoint: component(&endpoint_component/0),
        listeners: component(&listeners_component/0),
        distributed: component(&distributed_component/0),
        anchor_sinks: component(&anchor_sinks_component/0)
      }
    end

    @doc false
    # Pure (plan r8 section 2.1): one raw stored handler map to one
    # `logger_handlers` element: a bare kept projection, the refusal
    # marker `{:handler_refused, id, :logger_handlers}`, or
    # `:invalid_entry`.
    @spec handler_element(term()) :: map() | tuple() | :invalid_entry
    def handler_element(raw) when is_map(raw) and map_size(raw) <= 7 do
      if std_file_form?(raw), do: refused_handler(raw), else: kept_handler(raw)
    end

    def handler_element(_raw), do: :invalid_entry

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

    # Stage C (rows 3a-12): this VM's own view, never a caller's.
    defp view do
      note_read(:view)
      check_view(build_view())
    end

    # -- Rows 3a-3c ------------------------------------------------------------

    defp view_form(view) when is_map(view) and map_size(view) == 8 do
      if Enum.all?(@view_keys, &(is_map_key(view, &1) and form?(&1, :erlang.map_get(&1, view)))),
        do: :ok,
        else: {:error, :descriptor_unknown}
    end

    defp view_form(_view), do: {:error, :descriptor_unknown}

    # 3a: the whitelisted top-level forms (plan r5 section 4.1).
    defp form?(:exporter, {:ok, %{traces_exporter: _, span_processor: _, processors: p} = e})
         when map_size(e) == 3,
         do: is_list(p)

    defp form?(key, {:ok, list}) when is_map_key(@caps, key), do: is_list(list)
    defp form?(key, :over_cap) when is_map_key(@caps, key) or key == :listeners, do: true
    defp form?(key, {:ok, flag}) when key in [:endpoint, :distributed], do: is_boolean(flag)
    defp form?(:listeners, {:ok, :none}), do: true

    defp form?(:listeners, {:refused, code}),
      do: code in [:listener_present, :listener_unknown]

    defp form?(_key, _value), do: false

    # 3b: `:over_cap`, else the kept cap walk, at every list position.
    defp cap(_key, :over_cap), do: {:error, :descriptor_unbounded}

    defp cap(:exporter, {:ok, %{processors: processors}}),
      do: Containment.list_shape(processors, @max_processors)

    defp cap(key, {:ok, list}) when is_map_key(@caps, key),
      do: Containment.list_shape(list, Map.fetch!(@caps, key))

    defp cap(_key, _value), do: :ok

    # 3c: elements, reached only when every list position passed 3b.
    defp elements(:exporter, {:ok, exporter}) do
      terms = [exporter.traces_exporter, exporter.span_processor | exporter.processors]
      verdict(Enum.all?(terms, &Containment.bounded?/1))
    end

    defp elements(:tracers, {:ok, tracers}) do
      verdict(
        Enum.all?(tracers, &tracer_element?/1) and
          ascending?(Enum.map(tracers, fn {provider, name, _projection} -> {provider, name} end))
      )
    end

    defp elements(:logger_filters, {:ok, filters}),
      do: verdict(Enum.all?(filters, &filter_element?/1))

    defp elements(:logger_handlers, {:ok, handlers}) do
      verdict(
        Enum.all?(handlers, &handler_entry?/1) and
          ascending?(Enum.map(handlers, &handler_id/1))
      )
    end

    defp elements(:anchor_sinks, {:ok, kinds}),
      do: verdict(Enum.all?(kinds, &(is_atom(&1) and &1 != :invalid_entry)))

    defp elements(_key, _value), do: :ok

    defp verdict(true), do: :ok
    defp verdict(false), do: {:error, :descriptor_unknown}

    # A tracer element: an atom provider, a bounded name, and a bounded
    # projection of exactly the two H3 forms (plan r6 section 2.3).
    defp tracer_element?({provider, name, projection}) when is_atom(provider) do
      Containment.bounded?(name) and Containment.bounded?(projection) and
        tracer_projection?(projection)
    end

    defp tracer_element?(_element), do: false

    defp tracer_projection?(%{tag: :otel_tracer_noop} = projection),
      do: map_size(projection) == 1

    defp tracer_projection?(
           %{
             tag: :otel_tracer_default,
             module: :otel_tracer_default,
             sampler: _sampler,
             on_start: on_start,
             on_end: on_end
           } = projection
         )
         when map_size(projection) == 5,
         do: fun_projection?(on_start) and fun_projection?(on_end)

    defp tracer_projection?(_projection), do: false

    defp fun_projection?(%{module: m, name: n, arity: a, type: t, env: env} = fun)
         when map_size(fun) == 5 and is_atom(m) and is_atom(n) and is_integer(a) and is_atom(t),
         do: is_list(env)

    defp fun_projection?(_fun), do: false

    defp filter_element?({id, {module, function, arity}, _config} = filter)
         when is_atom(id) and is_atom(module) and is_atom(function) and is_integer(arity) and
                arity >= 0,
         do: Containment.bounded?(filter)

    defp filter_element?(_filter), do: false

    defp handler_entry?({:handler_refused, id, :logger_handlers}), do: is_atom(id)

    defp handler_entry?(projection) when is_map(projection),
      do: Containment.bounded?(projection) and Containment.projected_handler?(projection)

    defp handler_entry?(_entry), do: false

    defp handler_id({:handler_refused, id, :logger_handlers}), do: id
    defp handler_id(%{id: id}), do: id

    # Strictly ascending in term order (sorted and unique).
    defp ascending?([first, second | rest]), do: first < second and ascending?([second | rest])
    defp ascending?(_short), do: true

    # -- Rows 5-12 -------------------------------------------------------------

    defp view_rows(
           %{
             exporter: {:ok, exporter},
             tracers: {:ok, tracers},
             logger_filters: {:ok, filters},
             logger_handlers: {:ok, handlers}
           } = view
         ) do
      with :ok <- exporter_row(exporter),
           :ok <- tracer_rows(tracers),
           :ok <- filters_row(filters),
           :ok <- handlers_row(handlers) do
        state_rows(view)
      end
    end

    defp view_rows(_view), do: {:error, :descriptor_unknown}

    defp exporter_row(@thin_exporter), do: :ok
    defp exporter_row(_exporter), do: {:error, :exporter_destination}

    defp tracer_rows(tracers) do
      providers = tracers |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      cond do
        providers != [:global] -> {:error, :tracer_provider}
        not Enum.any?(tracers, &default_tracer?/1) -> {:error, :tracer_noop}
        true -> tracer_values(tracers)
      end
    end

    defp default_tracer?({:global, :"$__default_tracer", _projection}), do: true
    defp default_tracer?(_tracer), do: false

    defp tracer_values(tracers) do
      results = Enum.map(tracers, fn {_provider, _name, p} -> Containment.tracer_check(p) end)
      Enum.find_value(@tracer_codes, :ok, &({:error, &1} in results and {:error, &1}))
    end

    defp filters_row(filters) do
      if Enum.take(filters, 2) == @head_filters, do: :ok, else: {:error, :logger_filters}
    end

    defp handlers_row(handlers) do
      if Enum.all?(handlers, &allowed_handler?/1), do: :ok, else: {:error, :logger_handlers}
    end

    defp allowed_handler?(%{module: :logger_std_h, destination: destination}),
      do: destination in @std_destinations

    defp allowed_handler?(%{module: module, destination: {:module, module}}),
      do: module in @module_handlers

    defp allowed_handler?(_entry), do: false

    defp state_rows(view) do
      cond do
        view.endpoint == {:ok, true} -> {:error, :endpoint_present}
        match?({:refused, _code}, view.listeners) -> {:error, elem(view.listeners, 1)}
        view.distributed == {:ok, true} -> {:error, :distributed}
        view.anchor_sinks != {:ok, []} -> {:error, :anchor_sinks}
        true -> :ok
      end
    end

    defp first_error(keys, check), do: Enum.find_value(keys, :ok, &failure(check.(&1)))

    defp failure(:ok), do: nil
    defp failure(error), do: error

    # -- Components (read-only) ------------------------------------------------

    # Isolation: a raise, throw or exit in one reader is that component's
    # `:unreadable` (row 3a); the other components are unaffected.
    defp component(read) do
      read.()
    catch
      _kind, _reason -> :unreadable
    end

    defp exporter_component do
      {:ok,
       %{
         traces_exporter: Application.get_env(:opentelemetry, :traces_exporter),
         span_processor: Application.get_env(:opentelemetry, :span_processor),
         processors: Application.get_env(:opentelemetry, :processors)
       }}
    end

    defp endpoint_component, do: {:ok, Process.whereis(@endpoint) != nil}

    defp distributed_component, do: {:ok, Node.alive?()}

    defp anchor_sinks_component do
      sinks = Application.get_env(:sdr_agent, :anchor_sinks)

      case Containment.list_shape(sinks, @max_anchors) do
        :ok -> {:ok, Enum.map(sinks, &anchor_kind/1)}
        {:error, :descriptor_unbounded} -> :over_cap
        {:error, _shape} -> :unreadable
      end
    end

    defp anchor_kind({kind, _module, _opts}) when is_atom(kind), do: kind
    defp anchor_kind(_sink), do: :invalid_entry

    # -- Logger components (plan r5 section 4.2; r6-r8 section 2) ------------

    # Public passive read: the primary config map (no callback).
    defp logger_filters_component do
      case :logger.get_primary_config() do
        %{filters: filters} -> filters_result(filters)
        _other -> :unreadable
      end
    end

    # Unbounded -> `:over_cap`; an improper or non-list value passes
    # through unchanged (3a or 3b refuses it); else each element through
    # the kept `Containment.filter_projection/1`.
    defp filters_result(filters) do
      case Containment.list_shape(filters, @max_filters) do
        :ok -> {:ok, Enum.map(filters, &filter_view/1)}
        {:error, :descriptor_unbounded} -> :over_cap
        {:error, _shape} -> {:ok, filters}
      end
    end

    defp filter_view(raw) do
      case Containment.filter_projection(raw) do
        {:ok, filter} -> filter
        _other -> :invalid_entry
      end
    catch
      _kind, _reason -> :invalid_entry
    end

    defp logger_handlers_component do
      if kernel_pinned?(), do: handlers_read(@restarts), else: :unreadable
    end

    # Public passive read of the handler ids; the per-id raw lookup below
    # stays the pinned internal read (the public per-handler getters
    # invoke Module:filter_config/1 and are excluded, plan r7 2.2).
    defp handlers_read(restarts), do: handler_ids(:logger.get_handler_ids(), restarts)

    # The id cap comes before any per-id lookup; the capped ids are sorted.
    defp handler_ids(ids, restarts) do
      case Containment.list_shape(ids, @max_handler_ids) do
        :ok -> handler_lookups(Enum.sort(ids), restarts)
        {:error, :descriptor_unbounded} -> :over_cap
        {:error, _shape} -> :unreadable
      end
    end

    defp handler_lookups(ids, restarts) do
      case Enum.reduce_while(ids, {:ok, []}, &handler_lookup/2) do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        :race when restarts > 0 -> handlers_read(restarts - 1)
        :race -> :unreadable
      end
    end

    # One ETS lookup of the stored handler map (never a handler callback).
    defp handler_lookup(id, {:ok, elements}) do
      case :logger_config.get(:logger, id) do
        {:ok, raw} -> {:cont, {:ok, [handler_element(raw) | elements]}}
        {:error, {:not_found, _id}} -> {:halt, :race}
      end
    end

    defp kernel_pinned?, do: Application.spec(:kernel, :vsn) == @kernel_vsn

    # Plan r7 section 2.2 step 3: the stored (normalized) `logger_std_h`
    # file form, judged by keys, module and `config.type` alone.
    defp std_file_form?(raw) do
      map_size(raw) == 7 and Enum.all?(@handler_keys_view, &is_map_key(raw, &1)) and
        :erlang.map_get(:module, raw) === :logger_std_h and
        file_config?(:erlang.map_get(:config, raw))
    end

    defp file_config?(%{type: type}), do: type === :file
    defp file_config?(_config), do: false

    defp refused_handler(%{id: id}) when is_atom(id), do: {:handler_refused, id, :logger_handlers}
    defp refused_handler(_raw), do: :invalid_entry

    # Plan r8 section 2.1 step 4: the kept helper, unwrapped exactly.
    defp kept_handler(raw) do
      case Containment.logger_handler_projection(raw) do
        {:ok, projection} -> projection
        {:error, :logger_handlers} -> refused_handler(raw)
        _other -> :invalid_entry
      end
    catch
      _kind, _reason -> :invalid_entry
    end

    # -- Listeners (plan r3 section 4 reader table; r5 section 4.4) ----------

    defp listeners_component do
      if :erlang.system_info(:port_count) > @max_ports,
        do: :over_cap,
        else: port_census(@restarts)
    end

    defp port_census(restarts) do
      ports = :erlang.ports()

      case Containment.list_shape(ports, @max_ports) do
        :ok -> census_verdict(Enum.reduce_while(ports, {:ok, []}, &census_entry/2), restarts)
        {:error, :descriptor_unbounded} -> :over_cap
        {:error, _shape} -> :unreadable
      end
    end

    # Only inet driver ports are census entries; a port gone mid-census
    # (no name, or a failed status) is a race.
    defp census_entry(port, {:ok, entries}) do
      case :erlang.port_info(port, :name) do
        {:name, name} when name in @inet_names -> inet_entry(port, name, entries)
        {:name, _other} -> {:cont, {:ok, entries}}
        _closed -> {:halt, :race}
      end
    end

    defp inet_entry(port, name, entries) do
      case :prim_inet.getstatus(port) do
        {:ok, _states} = status -> {:cont, {:ok, [{:inet, name, status} | entries]}}
        _closed -> {:halt, :race}
      end
    end

    defp census_verdict({:ok, entries}, _restarts),
      do: listener_verdict(Containment.listener_projection(entries))

    defp census_verdict(:race, 0), do: {:refused, :listener_unknown}
    defp census_verdict(:race, restarts), do: port_census(restarts - 1)

    defp listener_verdict(:ok), do: socket_verdict()
    defp listener_verdict({:error, :descriptor_unbounded}), do: :over_cap

    defp listener_verdict({:error, code}) when code in [:listener_present, :listener_unknown],
      do: {:refused, code}

    defp listener_verdict(_other), do: :unreadable

    # The socket NIF backend has no passive inspection: any socket there
    # is unknown (plan r3, disclosed assumption).
    defp socket_verdict do
      case :socket.info() do
        %{counters: %{num_sockets: 0}} -> {:ok, :none}
        _other -> {:refused, :listener_unknown}
      end
    end

    # -- Tracers: the isolated reader (plan r5 section 3.1, H2) ---------------

    # Runs in the guard's caller. The reader captures only `reply`; every
    # exit path releases it in the H2 order (unalias, kill unless its DOWN
    # was seen, a bounded DOWN wait, demonitor with flush, drain).
    defp tracers_component do
      reply = :erlang.alias([:reply])
      {pid, mref} = spawn_reader(reply)
      {result, down_seen?} = await_released(reply, pid, mref)
      release_reader(reply, pid, mref, down_seen?)
      reader_result(result)
    end

    defp spawn_reader(reply) do
      spawn_monitor(fn -> send(reply, {reply, tracer_entries()}) end)
    catch
      kind, reason ->
        :erlang.unalias(reply)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    # A caller exception while waiting releases the reader, then re-raises.
    defp await_released(reply, pid, mref) do
      await_reader(reply, mref)
    catch
      kind, reason ->
        release_reader(reply, pid, mref, false)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end

    # Success is the reply within 1000 ms AND THEN a normal DOWN within
    # 200 ms; anything else is unreadable.
    defp await_reader(reply, mref) do
      receive do
        {^reply, result} -> await_normal_exit(result, mref)
        {:DOWN, ^mref, :process, _pid, _reason} -> {:unreadable, true}
      after
        @reply_ms -> {:unreadable, false}
      end
    end

    defp await_normal_exit(result, mref) do
      receive do
        {:DOWN, ^mref, :process, _pid, :normal} -> {result, true}
        {:DOWN, ^mref, :process, _pid, _abnormal} -> {:unreadable, true}
      after
        @exit_ms -> {:unreadable, false}
      end
    end

    defp release_reader(reply, pid, mref, down_seen?) do
      :erlang.unalias(reply)
      stop_reader(down_seen?, pid, mref)
      Process.demonitor(mref, [:flush])

      receive do
        {^reply, _late} -> :ok
      after
        0 -> :ok
      end
    end

    # No death is claimed when no DOWN arrives within the wait.
    defp stop_reader(true, _pid, _mref), do: :ok

    defp stop_reader(false, pid, mref) do
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^mref, :process, _pid, _reason} -> :ok
      after
        @exit_ms -> :ok
      end
    end

    defp reader_result({:ok, tracers} = result) when is_list(tracers), do: result
    defp reader_result(:over_cap), do: :over_cap
    defp reader_result(_other), do: :unreadable

    # In the reader process: keep only tracer-cache keys, stop counting
    # at 513 with nothing projected, else project and validate each entry
    # here; a failing entry becomes `:invalid_entry`. A reader failure is
    # sent as `:unreadable`, so the reader always exits normally and
    # never logs.
    defp tracer_entries do
      case tracer_terms(:persistent_term.get(), [], 0) do
        {:ok, kept} -> {:ok, kept |> Enum.map(&tracer_view/1) |> Enum.sort()}
        :over_cap -> :over_cap
      end
    catch
      _kind, _reason -> :unreadable
    end

    defp tracer_terms(_terms, _kept, count) when count > @max_tracers, do: :over_cap
    defp tracer_terms([], kept, _count), do: {:ok, kept}

    defp tracer_terms([{{:opentelemetry, provider, :tracer, name}, value} | rest], kept, count),
      do: tracer_terms(rest, [{provider, name, value} | kept], count + 1)

    defp tracer_terms([_other | rest], kept, count), do: tracer_terms(rest, kept, count)

    defp tracer_view({provider, name, value}) do
      element = {provider, name, tracer_projection(value)}
      if tracer_element?(element), do: element, else: :invalid_entry
    end

    # H3 (holds r1 items 2-4): the SDK record `{:otel_tracer_default,
    # #tracer{}}` (otel_tracer.hrl: module, on_start_processors,
    # on_end_processors, sampler, id_generator, instrumentation_scope), the
    # API noop, or nothing.
    defp tracer_projection(
           {:otel_tracer_default, {:tracer, module, on_start, on_end, sampler, _ids, _scope}}
         )
         when is_function(on_start) and is_function(on_end) do
      %{
        tag: :otel_tracer_default,
        module: module,
        sampler: sampler,
        on_start: fun_projection(on_start),
        on_end: fun_projection(on_end)
      }
    end

    defp tracer_projection({:otel_tracer_noop, _state}), do: %{tag: :otel_tracer_noop}
    defp tracer_projection(_value), do: :invalid_entry

    defp fun_projection(fun) do
      {:module, module} = :erlang.fun_info(fun, :module)
      {:name, name} = :erlang.fun_info(fun, :name)
      {:arity, arity} = :erlang.fun_info(fun, :arity)
      {:type, type} = :erlang.fun_info(fun, :type)
      {:env, env} = :erlang.fun_info(fun, :env)
      %{module: module, name: name, arity: arity, type: type, env: env}
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
