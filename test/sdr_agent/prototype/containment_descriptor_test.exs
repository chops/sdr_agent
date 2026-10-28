# DRAFT r4a (outside the repository; review only; NOT formatted, compiled
# or run). PURE scope: every input is synthetic data built here; no VM state
# is read and no VM-effect API is called. The external function captures
# below name existing modules only; nothing is invoked.
defmodule SdrAgent.Prototype.ContainmentDescriptorTest do
  @moduledoc """
  Containment r4a PS-D (projections, bounds, evaluate), PS-F (canonical
  form and fingerprint) and PS-S (seal, advance and recheck decisions).
  `@descriptor` is the complete representative canonical descriptor (all
  eleven keys, D13 included); its own boundedness is asserted directly.

  RED (deny-only declarations): every test fails at its first assertion
  with its fixed message; later rows of a table are unexecuted.
  The local-fun names `-on_start/1-fun-0-` and `-on_end/1-fun-0-` are the
  values discovery must confirm (packet r4 section 7.4); they are pinned
  here as the reviewed expectation.
  """
  use ExUnit.Case, async: true

  alias SdrAgent.Prototype.Containment

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
  @tracer %{
    tag: :otel_tracer_default,
    module: :otel_tracer_default,
    sampler: {:otel_sampler_always_off, "AlwaysOffSampler", []},
    on_start: @on_start,
    on_end: @on_end
  }
  @formatter %Logger.Formatter{
    template: [:level, " ", :message, "\n"],
    metadata: [:request_id],
    truncate: 8096,
    colors: %{enabled: false},
    utc_log?: false
  }
  @std_handler %{
    id: :default,
    module: :logger_std_h,
    level: :all,
    filter_default: :log,
    filters: [],
    config: %{type: :standard_io, sync_mode_qlen: 10},
    formatter: {Logger.Formatter, @formatter}
  }
  @std_projection %{
    id: :default,
    module: :logger_std_h,
    level: :all,
    filter_default: :log,
    filters: [],
    destination: :standard_io,
    formatter: {Logger.Formatter, [:level, " ", :message, "\n"], [:request_id], 8096}
  }
  @query_log {"x.test.query_log", [:sdr_agent, :repo, :query],
              {SdrAgent.Repo.QueryLog, :handle_event, 4}, nil}
  @descriptor %{
    tracers: [{:global, @tracer}],
    sdk_tree: %{
      root: [:otel_resource_detector, :otel_span_sup, :otel_tracer_provider_sup],
      providers: 1,
      processors: 0
    },
    tree: %{children: [Oban, SdrAgent.Prototype.BootCheck, SdrAgent.Repo], endpoint: false},
    applications: [:kernel, :opentelemetry, :opentelemetry_api, :sdr_agent, :stdlib],
    handlers: [@query_log],
    logger: %{
      filters: [
        {:x_test_safe_log, {SdrAgent.Prototype.SafeLog, :filter, 2}, []},
        {:x_test_exception_filter, {SdrAgent.Logger.ExceptionFilter, :filter, 2}, []}
      ],
      handlers: [@std_projection]
    },
    ash_tracer: [],
    env: %{names: ["ERL_CRASH_DUMP_BYTES", "HOME", "PATH"], crash_dump_bytes: "0"},
    distributed: false,
    listeners: :none,
    anchor_sinks: []
  }
  @pinned Map.delete(@descriptor, :tracers)

  test "tracer_check: the always_off, zero-processor tracer and each deviation" do
    assert Containment.tracer_check(@tracer) == :ok, "the always_off tracer was refused"

    rows = [
      {%{@tracer | sampler: {:otel_sampler_always_on, "AlwaysOnSampler", []}}, :tracer_sampler},
      {%{@tracer | on_end: %{@on_end | env: [[{:otel_batch_processor, %{}}]]}},
       :tracer_processor},
      {%{@tracer | on_start: %{@on_start | env: [[{:otel_simple_processor, %{}}]]}},
       :tracer_processor},
      {%{@tracer | on_start: %{@on_start | name: :"-on_start/1-fun-1-"}}, :tracer_processor},
      {%{@tracer | on_end: %{@on_end | type: :external}}, :tracer_processor},
      {%{tag: :otel_tracer_noop}, :tracer_noop},
      {%{tag: :otel_tracer_default}, :descriptor_unknown},
      {%{@tracer | module: :other}, :descriptor_unknown},
      {:not_a_tracer, :descriptor_unknown}
    ]

    for {{value, code}, index} <- Enum.with_index(rows) do
      assert Containment.tracer_check(value) == {:error, code},
             "tracer row #{index} was not refused as #{code}"
    end
  end

  test "handler_projection: external callbacks with plain configs only" do
    assert Containment.handler_projection(%{
             id: "x.test.query_log",
             event_name: [:sdr_agent, :repo, :query],
             function: &SdrAgent.Repo.QueryLog.handle_event/4,
             config: nil
           }) == {:ok, @query_log},
           "a pinned external handler was not projected"

    base = %{
      id: "x.test.h",
      event_name: [:x, :test],
      function: &SdrAgent.Repo.QueryLog.handle_event/4
    }

    rows = [
      {Map.merge(base, %{function: fn _e, _m, _md, _c -> :ok end, config: nil}),
       :handler_closure},
      {Map.put(base, :config, %{owner: self()}), :descriptor_unknown},
      {Map.put(base, :config, String.duplicate("a", 257)), :descriptor_unbounded},
      {Map.merge(base, %{function: &OpentelemetryOban.JobHandler.handle_job_start/4, config: %{}}),
       :handler_forbidden},
      {Map.merge(base, %{function: &ReqLLM.OpenTelemetry.handle_event/4, config: %{}}),
       :handler_forbidden},
      {base, :descriptor_unknown}
    ]

    for {{handler, code}, index} <- Enum.with_index(rows) do
      assert Containment.handler_projection(handler) == {:error, code},
             "handler row #{index} was not refused as #{code}"
    end
  end

  test "filter_projection: external filter functions with plain configs only" do
    assert Containment.filter_projection(
             {:x_test_safe_log, {&SdrAgent.Prototype.SafeLog.filter/2, []}}
           ) == {:ok, {:x_test_safe_log, {SdrAgent.Prototype.SafeLog, :filter, 2}, []}},
           "a pinned external filter was not projected"

    rows = [
      {{:x_test_f, {fn _event, _config -> :stop end, []}}, :handler_closure},
      {{:x_test_f, {&SdrAgent.Prototype.SafeLog.filter/2, self()}}, :descriptor_unknown},
      {{:x_test_f}, :descriptor_unknown}
    ]

    for {{filter, code}, index} <- Enum.with_index(rows) do
      assert Containment.filter_projection(filter) == {:error, code},
             "filter row #{index} was not refused as #{code}"
    end
  end

  test "logger_handler_projection: standard streams and two pinned in-VM modules only" do
    assert Containment.logger_handler_projection(@std_handler) == {:ok, @std_projection},
           "the standard_io handler was not projected"

    pubsub = %{
      id: Phoenix.LiveDashboard.LoggerPubSubBackend,
      module: Phoenix.LiveDashboard.LoggerPubSubBackend,
      level: :all,
      filter_default: :log,
      filters: [],
      formatter: {Logger.Formatter, @formatter}
    }

    assert match?(
             {:ok, %{destination: {:module, Phoenix.LiveDashboard.LoggerPubSubBackend}}},
             Containment.logger_handler_projection(pubsub)
           ),
           "an in-VM handler module was not projected as its module"

    rows = [
      {put_in(@std_handler, [:config, :type], {:file, ~c"/tmp/x.test.log"}), :logger_handlers},
      {put_in(@std_handler, [:config, :type], {:file, ~c"/tmp/y.test.log"}), :logger_handlers},
      {%{pubsub | id: :x_test_other, module: :x_test_other_handler}, :descriptor_unknown},
      {Map.put(pubsub, :config, %{sink: :x_test}), :descriptor_unknown},
      {%{@std_handler | formatter: {:logger_formatter, %{}}}, :descriptor_unknown},
      {Map.delete(@std_handler, :module), :descriptor_unknown},
      {%{@std_handler | filters: [{:x_test_f, {fn _e, _c -> :stop end, []}}]}, :handler_closure},
      {put_in(@std_handler, [:config, :type], :somewhere_else), :descriptor_unknown}
    ]

    for {{config, code}, index} <- Enum.with_index(rows) do
      assert Containment.logger_handler_projection(config) == {:error, code},
             "logger handler row #{index} was not refused as #{code}"
    end
  end

  test "listener_projection: no listener, and fail closed on unknown or racing state" do
    assert Containment.listener_projection([]) == :ok, "an empty census was refused"

    clean = [
      {:inet, ~c"tcp_inet", {:ok, [:open, :connected]}},
      {:socket, {:ok, %{rstates: [:connected], wstates: []}}}
    ]

    assert Containment.listener_projection(clean) == :ok, "connected sockets were refused"

    rows = [
      {[{:inet, ~c"tcp_inet", {:ok, [:open, :listen]}}], :listener_present},
      {[{:inet, ~c"tcp_inet", {:ok, [:accepting]}}], :listener_present},
      {[{:inet, ~c"udp_inet", {:ok, [:open, :bound]}}], :listener_present},
      {[{:socket, {:ok, %{rstates: [:listening], wstates: []}}}], :listener_present},
      {[{:socket, {:ok, %{rstates: [:accepting], wstates: []}}}], :listener_present},
      {[{:inet, ~c"tcp_inet", {:error, :einval}}], :listener_unknown},
      {[{:inet, ~c"tcp_inet", {:ok, [:open, :mystery]}}], :listener_unknown},
      {[{:socket, {:ok, %{rstates: [:listen]}}}], :listener_unknown},
      {List.duplicate({:inet, ~c"tcp_inet", {:ok, [:open, :connected]}}, 1025),
       :descriptor_unbounded}
    ]

    for {{entries, code}, index} <- Enum.with_index(rows) do
      assert Containment.listener_projection(entries) == {:error, code},
             "listener row #{index} was not refused as #{code}"
    end
  end

  test "bounded?: the complete representative descriptor and the schema limits" do
    assert Containment.bounded?(@descriptor) == true, "the representative descriptor was refused"

    worst = %{
      @descriptor
      | tracers: List.duplicate({:global, @tracer}, 512),
        applications: Enum.map(1..512, &:"x_test_app_#{&1}"),
        handlers: List.duplicate(@query_log, 256)
    }

    assert Containment.bounded?(worst) == true, "the worst accepted descriptor was refused"
    assert Containment.bounded?(%{a: [1, "b", {:c, 2}]}) == true, "a plain term was refused"
    assert Containment.bounded?([[[[[[[[1]]]]]]]]) == true, "depth 8 was refused"

    assert Containment.bounded?(List.duplicate(Enum.to_list(1..60), 512)) == true,
           "31233 nodes were refused"

    rows = [
      Enum.to_list(1..513),
      String.duplicate("x", 257),
      [[[[[[[[[1]]]]]]]]],
      self(),
      make_ref(),
      fn -> :ok end,
      Map.new(1..65, &{&1, 1}),
      List.duplicate(Enum.to_list(1..64), 512)
    ]

    for {term, index} <- Enum.with_index(rows) do
      assert Containment.bounded?(term) == false, "bounds row #{index} was accepted"
    end
  end

  test "evaluate: the clean serve descriptor seals, and each deviation is its code" do
    assert Containment.evaluate(:seal, :serve, @descriptor, @pinned) == :ok,
           "a clean descriptor was refused"

    noop = [{:global, %{tag: :otel_tracer_noop}}]

    rows = [
      {%{@descriptor | tracers: noop}, :tracer_noop},
      {%{@descriptor | tracers: noop, distributed: true}, :tracer_noop},
      {%{@descriptor | tracers: [{:other, @tracer}]}, :tracer_provider},
      {put_in(@descriptor, [:sdk_tree, :processors], 1), :sdk_tree},
      {%{
         @descriptor
         | tree: %{children: [SdrAgentWeb.Endpoint | @descriptor.tree.children], endpoint: true}
       }, :endpoint_present},
      {put_in(@descriptor, [:tree, :children], [DNSCluster | @descriptor.tree.children]), :tree},
      {%{@descriptor | applications: [:phoenix_live_reload | @descriptor.applications]},
       :applications},
      {%{@descriptor | handlers: [put_elem(@query_log, 3, %{changed: true})]}, :handlers},
      {%{
         @descriptor
         | handlers: [
             put_elem(@query_log, 2, {OpentelemetryOban.JobHandler, :handle_job_start, 4})
           ]
       }, :handler_forbidden},
      {update_in(@descriptor, [:logger, :filters], &Enum.reverse/1), :logger_filters},
      {put_in(@descriptor, [:logger, :handlers], [%{@std_projection | destination: :file}]),
       :logger_handlers},
      {%{@descriptor | ash_tracer: [OpentelemetryAsh]}, :ash_tracer},
      {put_in(@descriptor, [:env, :names], ["HOME", "OTEL_X", "PATH"]), :otel_env},
      {put_in(@descriptor, [:env, :crash_dump_bytes], "1"), :crash_dump_env},
      {%{@descriptor | distributed: true}, :distributed},
      {%{@descriptor | listeners: :present}, :listener_present},
      {%{@descriptor | listeners: :unknown}, :listener_unknown},
      {%{@descriptor | listeners: []}, :descriptor_unknown},
      {%{@descriptor | anchor_sinks: [:git]}, :anchor_sinks},
      {%{@descriptor | anchor_sinks: [:ots]}, :anchor_sinks},
      {Map.delete(@descriptor, :anchor_sinks), :descriptor_unknown},
      {%{@descriptor | tracers: List.duplicate({:global, @tracer}, 513)}, :descriptor_unbounded},
      {Map.delete(@descriptor, :logger), :descriptor_unknown},
      {Map.put(@descriptor, :extra, 1), :descriptor_unknown}
    ]

    for {{descriptor, code}, index} <- Enum.with_index(rows) do
      assert Containment.evaluate(:seal, :serve, descriptor, @pinned) == {:error, code},
             "evaluate row #{index} was not refused as #{code}"
    end
  end

  test "evaluate: the precheck checks predicates, not equality with the pinned set" do
    extra = %{
      @descriptor
      | handlers: [
          {"x.test.extra", [:x, :test], {SdrAgent.Repo.QueryLog, :handle_event, 4}, nil}
          | @descriptor.handlers
        ]
    }

    assert Containment.evaluate(:precheck, :serve, extra, @pinned) == :ok,
           "the precheck required equality with the pinned set"

    forbidden = %{
      @descriptor
      | handlers: [
          {"x.test.otel", [:oban, :job, :start],
           {OpentelemetryOban.JobHandler, :handle_job_start, 4}, %{}}
        ]
    }

    assert Containment.evaluate(:precheck, :serve, forbidden, @pinned) ==
             {:error, :handler_forbidden},
           "the precheck accepted a forbidden handler family"
  end

  test "fingerprint: canonical ordering, and the tracer cache excluded" do
    fingerprint = Containment.fingerprint(@descriptor)

    assert is_binary(fingerprint) and String.match?(fingerprint, ~r/\A[0-9a-f]{64}\z/),
           "the fingerprint is not 64 lowercase hex characters"

    two = {"x.test.second", [:x, :test], {SdrAgent.Repo.QueryLog, :handle_event, 4}, nil}

    assert Containment.fingerprint(%{@descriptor | handlers: [@query_log, two]}) ==
             Containment.fingerprint(%{@descriptor | handlers: [two, @query_log]}),
           "the handler multiset order changed the fingerprint"

    refute Containment.fingerprint(update_in(@descriptor, [:logger, :filters], &Enum.reverse/1)) ==
             fingerprint,
           "the primary filter order did not change the fingerprint"

    assert Containment.fingerprint(%{
             @descriptor
             | tracers: [{:global, @tracer}, {:global, @tracer}]
           }) ==
             fingerprint,
           "a new valid tracer cache entry changed the fingerprint"
  end

  test "seal, advance and recheck decisions" do
    assert Containment.seal_decision(nil, :serve, [:sealed]) == {:put, {:serve, 0}},
           "a first seal was not put"

    rows = [
      {Containment.seal_decision({:serve, 0}, :serve, [:sealed]), {:error, :seal_exists}},
      {Containment.advance_decision({:setup, 0}, :setup, :maintenance), {:put, {:setup, 1}}},
      {Containment.advance_decision({:setup, 1}, :setup, :storage), {:put, {:setup, 2}}},
      {Containment.advance_decision({:setup, 2}, :setup, :repo), {:put, {:setup, 3}}},
      {Containment.advance_decision({:setup, 3}, :setup, :retained), {:put, {:setup, 4}}},
      {Containment.advance_decision({:setup, 4}, :setup, :retained), {:error, :seal_phase}},
      {Containment.advance_decision({:setup, 0}, :setup, :repo), {:error, :seal_phase}},
      {Containment.advance_decision({:setup, 3}, :setup, :sealed), {:error, :seal_phase}},
      {Containment.advance_decision({:serve, 0}, :setup, :maintenance), {:error, :seal_phase}},
      {Containment.advance_decision(nil, :setup, :maintenance), {:error, :seal_absent}},
      {Containment.recheck_decision(
         {:serve, 0},
         String.duplicate("a", 64),
         String.duplicate("a", 64)
       ), :ok},
      {Containment.recheck_decision(
         {:serve, 0},
         String.duplicate("a", 64),
         String.duplicate("b", 64)
       ), {:error, :seal_mismatch}},
      {Containment.recheck_decision(nil, String.duplicate("a", 64), String.duplicate("a", 64)),
       {:error, :seal_absent}}
    ]

    for {{actual, expected}, index} <- Enum.with_index(rows) do
      assert actual == expected, "decision row #{index} is not #{inspect(expected)}"
    end
  end
end
