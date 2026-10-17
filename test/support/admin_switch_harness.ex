defmodule SdrAgent.Test.AdminSwitchHarness do
  @moduledoc """
  R0-05 test support (`docs/product/r0/r0-05-interface.md` draft 3,
  interface PASS at `fbc3203`, Codex `232bd20d`): the admin model card, the
  switch request and the blocked-switch resolver, driven through the real
  admin LiveView over real coordinator fixtures. It reuses the b2β and
  C2-02c harnesses (`SdrAgent.Test.ResolveHarness`,
  `SdrAgent.Test.StatusHarness`); nothing is copied from them except the
  privileged "original" of the b2β race test 12 (`original!/3`), which no
  harness exports.

  **Page helpers.** `click!/3`, `change_form!/4` and `submit_form!/4` assert
  that the R0-05 element exists first (a missing element fails as an
  assertion after the fixture, never as a raised `ArgumentError`).
  `await_element!/4` and `wait_until/2` are bounded polls. `text_of/2` and
  `attr_of/3` read one element (nil when it is absent). `audit_refresh!/1`
  delivers what `SdrAgent.LiveEvents.Relay` sends after a commit (the shared
  sandbox never commits).

  **The card.** `assert_card!/3` checks every R0-05 card line against a
  `Runtime.status/0` map the test read itself, with the section 1 rules (no
  guessed values: `:unknown` shows "unknown", never a default profile).

  **Domain calls.** `trace_calls!/1` traces the given functions in every
  process (with their return values); `page_calls/3` keeps the calls not
  made by the test process itself (the page, its tasks and anything it
  caused). Cleanup stops the trace and joins the collector on exit.

  **Barriers.** `pause_view_samples!/2` pauses the page's own
  `Runtime.status/0` at C2-02c's sample points (the C2-02c seam), so a test
  can change the server between attempts; `view_replay_read/1` is a
  `ResolveHarness.query_pause!/2` matcher for the page's (or its task's)
  caller replay read by `attestation_id`.

  **Never logged (test 15).** `debug_logs/1` captures every log line at
  `:debug` (Logger restored after); `capture_telemetry!/0` records the
  application's telemetry and the console's URLs; `tables_containing/1`
  scans every public table; `spans_containing?/1` scans the exported spans.

  **Option B (draft 4, D-141; ADR-0005 R0-05 amendment).** Minimization
  (tests 9, 15a): `resolution_path_mfas/0` for `trace_calls!/1`,
  `resolution_dispatches/2`, and `holds?/2`, a structural search that
  bypasses `Inspect` (closure environments included). Crash reports (tests
  15b, 15c): `log_events/2` captures every event after the primary filters
  through a test `:logger` handler (`LogSink`); `crash_on_event!/3` is the
  test seam that makes the channel raise while it handles a real event (a
  `:handle_event` hook attached through `:sys.replace_state/2`);
  `crash!/2` awaits the view's death, its supervisor and its client proxy;
  `assert_withheld!/3`, `refute_canary!/4`, `exception_filter!/1` and
  `sasl_reports!/0` (SASL translation enabled in place, restored on exit).

  **Independent connections** (the race module only): `auto_sandbox!/0`
  runs the SQL sandbox in `:auto` mode for the test, truncating only a test
  database before and after (the b2β race test's table list), and
  `original!/3` is b2β's privileged uncommitted resolution. Synthetic data
  only; every server runs the fake CLI; zero model calls.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers, as: AuthHelpers
  alias Ecto.Adapters.SQL.Sandbox
  alias ExUnit.CaptureLog
  alias Phoenix.ConnTest
  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ProfileSwitches
  alias SdrAgent.Agents.SwitchResolution
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.AuditCase
  alias SdrAgent.LiveEvents
  alias SdrAgent.Repo
  alias SdrAgent.Telemetry.InMemoryExporter
  alias SdrAgent.Test.PinnedCLI
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH

  @sample [:sdr_agent, :runtime_status, :sample]
  @raw_terms ["{:error", "{:ok", "%Ash.", "#Ash.", "Elixir.", "#Reference<", "%{"]
  @replay_read ~r/FROM "model_profile_switches".*WHERE.*"attestation_id"/s
  @statement "No Claude CLI process started by any server in this range is still running, " <>
               "except work owned by the current held server's own live reaper. " <>
               "I checked this myself."
  @recorded "The resolution was recorded: the switch is failed. Readiness is checked " <>
              "separately; calls stay paused until the status shows the server accepting " <>
              "calls. A dead lease may still need an operator."
  @withheld "diagnostic withheld: process holds operator input"
  @safe_meta [:pid, :gl, :time, :line, :mfa, :file, :domain, :sdr_sensitive_input]
  @crash "r005 synthetic channel crash"
  @tables ~w(model_server_starts model_server_counters model_profile_switches
             model_profile_settings audit_accesses audit_events audit_chain_heads
             model_call_allocations model_call_grants failures operations model_invocations
             agent_runs agent_definitions tokens users payloads provenance_snapshots tenants)

  ## Contract text

  @doc "The b2β section 3 statement the page shows word for word."
  def statement, do: @statement

  @doc "The section 3 recorded-resolution message."
  def recorded_message, do: @recorded

  @doc "The exact typed confirmation for `switch`."
  def confirmation(switch), do: "STOPPED " <> switch.id

  ## Page helpers

  @doc "Asserts that `selector` is on the page (an R0-05 guard), then clicks it."
  def click!(view, selector, label) do
    assert has_element?(view, selector), "R0-05 #{label}: the page has no #{selector}"
    view |> element(selector) |> render_click()
  end

  @doc "Asserts that the form `selector` is on the page, then sends its change with `params`."
  def change_form!(view, selector, params, label) do
    assert has_element?(view, selector), "R0-05 #{label}: the page has no form #{selector}"
    view |> form(selector, params) |> render_change()
  end

  @doc "Asserts that the form `selector` is on the page, then submits it with `params`."
  def submit_form!(view, selector, params, label) do
    assert has_element?(view, selector), "R0-05 #{label}: the page has no form #{selector}"
    view |> form(selector, params) |> render_submit()
  end

  @doc "Asserts that `list` has exactly one element (`message` otherwise); returns it."
  def one!(list, message) do
    assert length(list) == 1, "#{message}; got #{length(list)}: #{inspect(list, limit: 5)}"
    hd(list)
  end

  @doc "The squished text of the element `selector`, or nil when it is absent."
  def text_of(view, selector) do
    if has_element?(view, selector) do
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
    end
  end

  @doc "The attribute `name` of the element `selector`, or nil."
  def attr_of(view, selector, name) do
    if has_element?(view, selector) do
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute(name)
      |> List.first()
    end
  end

  @doc "Polls (bounded) until `fun` is truthy; true, or false after `timeout` ms."
  def wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(25)
        poll(fun, deadline)
    end
  end

  @doc """
  Waits (bounded) for the element `selector` (containing `text`, when not
  nil); flunks with `message` and the element's last text otherwise.
  """
  def await_element!(view, selector, text, timeout, message) do
    found? =
      wait_until(
        fn ->
          if text, do: has_element?(view, selector, text), else: has_element?(view, selector)
        end,
        timeout
      )

    assert found?,
           "R0-05 #{message} (waited #{timeout} ms for #{selector}" <>
             if(text, do: " with #{inspect(text)}", else: "") <>
             "; last #{inspect(text_of(view, selector))})"
  end

  @doc """
  Delivers what `SdrAgent.LiveEvents.Relay` sends after an audit event
  commits (the shared sandbox never commits), as `SdrAgentWeb.AdminLiveTest`.
  """
  def audit_refresh!(tenant_id) do
    LiveEvents.broadcast(%{
      tenant_id: tenant_id,
      sequence: 0,
      event_type: "test.committed",
      category: "domain_change",
      subject_resource: nil,
      subject_id: nil,
      agent_run_id: nil
    })
  end

  @doc "Asserts that the page shows no raw Elixir term (every message comes from a mapping)."
  def refute_raw_terms!(view, label) do
    html = render(view)

    for term <- @raw_terms do
      refute html =~ term,
             "R0-05 #{label}: the page renders a raw term (#{inspect(term)}); messages must " <>
               "come from the operator-safe mapping, never inspect"
    end
  end

  ## The card (section 1)

  @doc """
  Asserts every R0-05 card line against `status` (the test's own
  `Runtime.status/0` read of the same quiescent state). `label` names the
  2b row.
  """
  def assert_card!(view, status, label) do
    desired!(view, status.desired_profile, label)
    running!(view, status.observed_profile, label)
    accepting!(view, status, label)
    hold!(view, status.hold, status.stage, label)
    switch_line!(view, status.switch, label)
    published!(view, status.published_at, label)
  end

  defp desired!(view, :not_applicable, label),
    do:
      refute(
        has_element?(view, "#desired-profile"),
        "R0-05 1 (#{label}): the desired-profile line is hidden for the Fake"
      )

  defp desired!(view, :unknown, label) do
    line!(view, "#desired-profile", [profile: "unknown"], ["unknown"], label)
    no_default!(view, "#desired-profile", label)
  end

  defp desired!(view, %{profile_id: id, source: source}, label) do
    words = if source == :setting, do: "(saved setting)", else: "(default)"

    line!(
      view,
      "#desired-profile",
      [profile: id, source: source],
      [to_string(id), words, "confirmed"],
      label
    )
  end

  defp running!(view, observed, label) do
    shown = if is_atom(observed), do: to_string(observed), else: inspect(observed)
    line!(view, "#running-profile", [profile: shown], [shown, "sampled"], label)
    if observed in [:unknown, :none], do: no_default!(view, "#running-profile", label)
  end

  defp accepting!(view, %{effective_profile: nil, refusal: refusal}, label) do
    line!(
      view,
      "#accepting-calls",
      [accepting: "no", refusal: refusal],
      ["no", Runtime.refusal_message(refusal)],
      label
    )

    refute text_of(view, "#accepting-calls") =~ "yes",
           "R0-05 1 (#{label}): a refused or held server never reads as accepting calls"
  end

  defp accepting!(view, %{effective_profile: profile}, label),
    do: line!(view, "#accepting-calls", [accepting: "yes"], ["yes, on #{profile}"], label)

  defp hold!(view, hold, stage, label) do
    attrs =
      if is_atom(stage) and not is_nil(stage), do: [hold: hold, stage: stage], else: [hold: hold]

    line!(view, "#provider-hold", attrs, [to_string(hold)], label)
  end

  defp switch_line!(view, %{state: :none}, label),
    do: line!(view, "#open-switch", [state: "none"], ["none (confirmed"], label)

  defp switch_line!(view, %{state: :open, status: status} = switch, label) do
    words = "#{switch.from_profile_id} → #{switch.to_profile_id}, #{status}"
    words = if status == :blocked, do: words <> ": ", else: words
    line!(view, "#open-switch", [state: status, "switch-id": switch.id], [words], label)
  end

  defp switch_line!(view, :unknown, label) do
    line!(view, "#open-switch", [state: "unknown"], ["unknown"], label)
    no_default!(view, "#open-switch", label)
  end

  defp published!(view, nil, label),
    do: line!(view, "#status-published-at", [], ["unknown"], label)

  defp published!(view, %DateTime{} = at, label) do
    line!(
      view,
      "#status-published-at",
      ["published-at": DateTime.to_iso8601(at)],
      ["coordinator published"],
      label
    )
  end

  defp line!(view, selector, attrs, words, label) do
    assert has_element?(view, selector),
           "R0-05 1 (#{label}): the card has no #{selector} line"

    for {key, value} <- attrs do
      got = attr_of(view, selector, "data-#{key}")

      assert got == to_string(value),
             "R0-05 1 (#{label}): #{selector} data-#{key} must be #{inspect(to_string(value))}; " <>
               "got #{inspect(got)} (#{inspect(text_of(view, selector))})"
    end

    text = text_of(view, selector)

    for word <- words do
      assert text =~ word,
             "R0-05 1 (#{label}): #{selector} must show #{inspect(word)}; got #{inspect(text)}"
    end
  end

  @doc "Asserts that `selector` names no profile and no default (section 1: no guessed values)."
  def no_default!(view, selector, label) do
    text = text_of(view, selector) || ""

    for guess <- ["claude_cli_opus", "claude_cli_sonnet", "opus", "sonnet", "(default)"] do
      refute text =~ guess,
             "R0-05 1 (#{label}): #{selector} is unknown and must never show #{inspect(guess)}; " <>
               "got #{inspect(text)}"
    end
  end

  ## Fixtures (real coordinator states; shared sandbox)

  @doc "A released, drained tree at the default profile (the fake CLI, launches recorded)."
  def released!(opts \\ []) do
    SH.tree!(opts)
    RH.await_status!(&(&1.hold == :released))
    RH.drain!()
  end

  @doc "A completed switch through the coordinator: the setting becomes `to` (revision + 1)."
  def switch_through_coordinator!(ctx) do
    switch = RH.request_switch!(ctx)
    completed = RH.await_switch!(ctx, switch.id, :completed)
    to = completed.to_profile_id
    RH.await_status!(&(&1.hold == :released and &1.profile_id == to), 20_000)
    RH.drain!()
    completed
  end

  @doc "A coordinator that positively binds no server (every start fails before init returns)."
  def no_server! do
    SH.tree!(server: [timeout: 1])

    RH.await!(
      fn -> match?(%{observed_profile: :none, desired_profile: %{}}, Runtime.status()) end,
      10_000,
      "fixture: the coordinator never bound no server"
    )
  end

  @doc """
  An unacknowledged re-hold (C2-02c 2b, hold `:pending`): the released
  server is suspended and the coordinator killed; the next boot publishes
  its survivor binding before the acknowledgement. Returns the server; it is
  resumed on exit.
  """
  def pending_hold! do
    first = released!()
    server = Process.whereis(ClaudeCLI.server())
    true = :erlang.suspend_process(server)
    on_exit(fn -> resume(server) end)
    RH.kill_coordinator!()
    SH.await_boot!(first.boot_id, &(&1.hold == :pending))
    Process.sleep(300)
    assert %{hold: :pending} = Coordinator.status(), "fixture: the re-hold is pending"
    server
  end

  @doc "Resumes a suspended process (no error when it is gone or running)."
  def resume(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  @doc "A released server whose eligibility refuses: the pinned CLI is missing."
  def refused_pin! do
    PinnedCLI.inject_identity!()
    released!(server: [executable: PinnedCLI.missing_store_path()])

    RH.await!(
      fn -> match?(%{refusal: :pinned_cli_unavailable}, Runtime.status()) end,
      10_000,
      "fixture: eligibility never refused on the missing pin"
    )
  end

  @doc "b2β's hard conflict: a `:dead_holder` resolution, held at `:cleanup_unprovable`."
  def cleanup_unprovable!(ctx) do
    blocked = RH.dead_holder!(ctx)
    attestation = RH.attestation(blocked, RH.latest_start!(ctx), :dead_holder)
    result = RH.resolve(blocked, attestation, ctx.admin)
    assert match?({:ok, %{switch: _}}, result), "fixture: the resolution; got #{inspect(result)}"
    RH.await_status!(&(&1.stage == :cleanup_unprovable), 15_000)
    RH.drain!()
    blocked
  end

  @doc """
  An uncertain finalization (C2-02c test 10): the coordinator's `complete`
  reply is lost and its reconciliation read is unavailable, so the ledger
  fields are `:unknown` while held. Returns the gate (`:read` settles it).
  """
  def uncertain_ledger!(ctx) do
    {:ok, gate} = Agent.start_link(fn -> :unavailable end)
    SH.tree!(faults: [lose_reply: [:complete], reconcile: fn -> Agent.get(gate, & &1) end])
    RH.await_status!(&(&1.hold == :released))
    switch = RH.request_switch!(ctx)
    RH.await_switch!(ctx, switch.id, :completed)
    RH.await_status!(&(&1.hold == :held and is_nil(&1.switch_id)), 20_000)
    RH.drain!()

    assert match?(%{desired_profile: :unknown, switch: :unknown}, Runtime.status()),
           "fixture: the ledger is unknown"

    gate
  end

  @doc "Settles `uncertain_ledger!/1` and waits for the release (bounded)."
  def settle_ledger!(gate) do
    Agent.update(gate, fn _ -> :read end)
    RH.await_status!(&(&1.hold == :released), 20_000)
    RH.drain!()
  end

  @doc "A live process (killed on exit), for a test-side lease-holder fault."
  def live_dummy! do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  @doc "The tenant's model invocation count (raw; no audit read)."
  def invocations! do
    [[n]] = Repo.query!("SELECT count(*) FROM model_invocations").rows
    n
  end

  @doc "Discards every `{:launch_admission, ...}` report already received."
  def flush_launches do
    receive do
      {:launch_admission, _, _, _} -> flush_launches()
    after
      0 -> :ok
    end
  end

  ## Barriers in the page's own process

  @doc """
  Pauses the page's own `Runtime.status/0` (the view process, or a task it
  started) at each `{point, attempt}` of `points` once, via the C2-02c
  sample seam: the paused process sends `{:r005_sample, point, attempt,
  pid}` and waits for `{:r005_continue, point, attempt}` (30 s). Detached,
  and every paused process resumed, on exit.
  """
  def pause_view_samples!(view_pid, points) do
    id = "r005-sample-#{System.unique_integer([:positive])}"
    {:ok, paused} = Agent.start(fn -> MapSet.new() end)

    :ok =
      :telemetry.attach(id, @sample, &__MODULE__.sample_handler/4, %{
        view: view_pid,
        parent: self(),
        points: points,
        paused: paused
      })

    on_exit(fn ->
      :telemetry.detach(id)

      for {point, attempt, pid} <- Agent.get(paused, &MapSet.to_list/1),
          do: send(pid, {:r005_continue, point, attempt})

      Agent.stop(paused)
    end)

    id
  end

  @doc false
  def sample_handler(_event, _measurements, %{point: point, attempt: attempt}, config) do
    key = {point, attempt}

    if page_process?(config.view) and key in config.points and first_pause?(config, key) do
      send(config.parent, {:r005_sample, point, attempt, self()})

      receive do
        {:r005_continue, ^point, ^attempt} -> :ok
      after
        30_000 -> :ok
      end
    end

    :ok
  end

  def sample_handler(_event, _measurements, _meta, _config), do: :ok

  defp first_pause?(config, {point, attempt}) do
    me = self()

    Agent.get_and_update(config.paused, fn set ->
      seen? = Enum.any?(set, &match?({^point, ^attempt, _}, &1))
      {not seen?, if(seen?, do: set, else: MapSet.put(set, {point, attempt, me}))}
    end)
  end

  defp page_process?(view_pid),
    do: self() == view_pid or view_pid in Process.get(:"$callers", [])

  @doc """
  `ResolveHarness.query_pause!/2` matcher: the page's (or its task's) stored
  switch read by `attestation_id` — the caller replay lookup.
  """
  def view_replay_read(view_pid) do
    fn meta -> page_process?(view_pid) and Regex.match?(@replay_read, to_string(meta.query)) end
  end

  ## Domain call tracing

  @doc """
  Traces every call of `mfas` (`{module, function, arity}`) in every
  process, with its return value. Returns the collector; tracing is
  stopped and the collector joined on exit.
  """
  def trace_calls!(mfas) do
    collector = spawn(fn -> collect([]) end)
    # A module not yet loaded would match no pattern.
    for {module, _f, _a} <- mfas, do: Code.ensure_loaded!(module)
    for mfa <- mfas, do: :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:global])
    :erlang.trace(:all, true, [:call, {:tracer, collector}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:global])
      stop_collector(collector)
    end)

    collector
  end

  defp stop_collector(collector) do
    ref = Process.monitor(collector)
    send(collector, :stop)

    receive do
      {:DOWN, ^ref, :process, ^collector, _} -> :ok
    after
      5_000 -> Process.exit(collector, :kill)
    end
  end

  defp collect(events) do
    receive do
      {:trace, pid, :call, {m, f, args}} ->
        collect([{:call, pid, {m, f, length(args)}, args} | events])

      {:trace, pid, :return_from, mfa, value} ->
        collect([{:return, pid, mfa, value} | events])

      {:r005_calls, from, ref} ->
        send(from, {:r005_calls, ref, Enum.reverse(events)})
        collect(events)

      :stop ->
        :ok

      _other ->
        collect(events)
    end
  end

  @doc """
  Every traced call so far, in order, as `%{pid, mfa, args, result}`
  (`result` is `:no_return` while the call runs). Every trace message
  already generated is delivered first.
  """
  def calls(collector) do
    delivered = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> flunk("trace messages were never delivered")
    end

    ref = make_ref()
    send(collector, {:r005_calls, self(), ref})

    events =
      receive do
        {:r005_calls, ^ref, events} -> events
      after
        5_000 -> flunk("the call trace collector did not answer")
      end

    pair(events)
  end

  defp pair(events) do
    {calls, _open} =
      events
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn
        {{:call, pid, mfa, args}, i}, {calls, open} ->
          call = %{pid: pid, mfa: mfa, args: args, result: :no_return}
          {Map.put(calls, i, call), Map.update(open, {pid, mfa}, [i], &[i | &1])}

        {{:return, pid, mfa, value}, _i}, {calls, open} ->
          case Map.get(open, {pid, mfa}, []) do
            [i | rest] ->
              {Map.update!(calls, i, &%{&1 | result: value}), Map.put(open, {pid, mfa}, rest)}

            [] ->
              {calls, open}
          end
      end)

    calls |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  @doc "The traced calls of `mfa` not made by the test process `test_pid`."
  def page_calls(collector, mfa, test_pid \\ self()),
    do: collector |> calls() |> Enum.filter(&(&1.mfa == mfa and &1.pid != test_pid))

  @doc "The `actor:` of a traced call (its last argument's keyword list)."
  def actor_of(%{args: args}) do
    case List.last(args) do
      opts when is_list(opts) -> Keyword.get(opts, :actor)
      _other -> nil
    end
  end

  @doc "The attestation map of a traced `Agents.resolve_blocked_switch/3` call."
  def attestation_of(%{args: [_switch, attestation, _opts]}), do: attestation

  ## Never logged (test 15)

  @doc "Runs `fun` with Logger at `:debug` (restored after); returns `{result, log}`."
  def debug_logs(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      CaptureLog.with_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  @doc """
  Records the application's own telemetry (`[:sdr_agent | _]` events with a
  handler, and repo queries with their parameters) and the console's URLs
  (LiveView `handle_params` URIs and router request paths) until exit.
  Returns the recorder; `telemetry_records/1` reads it.
  """
  def capture_telemetry! do
    {:ok, recorder} = Agent.start(fn -> [] end)
    id = "r005-telemetry-#{System.unique_integer([:positive])}"

    app_events =
      [:sdr_agent]
      |> :telemetry.list_handlers()
      |> Enum.map(& &1.event_name)
      |> Kernel.++([[:sdr_agent, :repo, :query]])
      |> Enum.uniq()

    url_events = [
      [:phoenix, :live_view, :handle_params, :start],
      [:phoenix, :router_dispatch, :start]
    ]

    :ok =
      :telemetry.attach_many(
        id,
        app_events ++ url_events,
        &__MODULE__.telemetry_handler/4,
        recorder
      )

    on_exit(fn ->
      :telemetry.detach(id)
      Agent.stop(recorder)
    end)

    recorder
  end

  @doc false
  def telemetry_handler([:phoenix, :live_view, :handle_params, :start], _m, meta, recorder),
    do: record(recorder, {:url, to_string(meta[:uri])})

  def telemetry_handler([:phoenix, :router_dispatch, :start], _m, %{conn: conn}, recorder),
    do: record(recorder, {:url, conn.request_path <> "?" <> conn.query_string})

  def telemetry_handler(event, measurements, meta, recorder),
    do: record(recorder, {:app, inspect({event, measurements, meta}, limit: :infinity)})

  defp record(recorder, entry) do
    Agent.update(recorder, &[entry | &1])
  catch
    :exit, _ -> :ok
  end

  @doc "The recorded `{:url | :app, text}` entries, oldest first."
  def telemetry_records(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()

  @doc "Every public table (with its row text) that contains `text` anywhere."
  def tables_containing(text) do
    %{rows: tables} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'"
      )

    for [table] <- tables,
        %{rows: [[n]]} =
          Repo.query!(~s|SELECT count(*) FROM "#{table}" t WHERE position($1 in t::text) > 0|, [
            text
          ]),
        n > 0,
        do: table
  end

  @doc "Whether any exported OpenTelemetry span contains `text`."
  def spans_containing?(text),
    do: inspect(InMemoryExporter.spans(), limit: :infinity) =~ text

  ## Independent connections (the race module only)

  @doc """
  Runs the SQL sandbox in `:auto` mode for this test (restored to
  `:manual` after) and truncates only a test database, before and after.
  """
  def auto_sandbox! do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      truncate!()
      Sandbox.mode(Repo, :manual)
    end)

    truncate!()
  end

  defp truncate! do
    database = Repo.config()[:database]

    unless is_binary(database) and Regex.match?(~r/\Asdr_agent_test[a-z0-9_]*\z/, database) do
      raise "refusing to truncate #{inspect(database)}: not a test database"
    end

    existing =
      Enum.filter(@tables, fn table ->
        Repo.query!("SELECT to_regclass($1) IS NOT NULL", [table]).rows == [[true]]
      end)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL session_replication_role = replica")
      Repo.query!("TRUNCATE #{Enum.join(existing, ", ")} CASCADE")
    end)
  end

  @doc "`conn` signed in as `user` (an `AuditCase` operator) through the real password strategy."
  def sign_in_user(conn, user) do
    {:ok, signed_in} = Accounts.sign_in(to_string(user.email), AuditCase.test_password())

    conn
    |> ConnTest.init_test_session(%{})
    |> AuthHelpers.store_in_session(signed_in)
  end

  @doc """
  b2β race test 12's privileged original (copied; no harness exports it):
  an independent test transaction on its own connection that takes the
  resolution write's locks in its order (setting `FOR UPDATE`, counter `FOR
  SHARE`, switch `FOR UPDATE`) and writes the resolution row carrying
  `attestation`, uncommitted until `commit_original!/1`. Rolled back on
  exit. Returns `{task, backend_pid}`.
  """
  def original!(switch, attestation, resolver) do
    parent = self()
    tenant = Ecto.UUID.dump!(switch.tenant_id)
    id = Ecto.UUID.dump!(switch.id)

    task =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            lock_like_the_write!(tenant, id)
            write_resolution!(id, attestation, resolver)
            send(parent, {:original_open, backend})

            receive do
              :commit -> :committed
              :rollback -> Repo.rollback(:fixture_rollback)
            after
              90_000 -> Repo.rollback(:fixture_timeout)
            end
          end,
          timeout: 120_000
        )
      end)

    assert_receive {:original_open, backend}, 10_000
    on_exit(fn -> send(task.pid, :rollback) end)
    {task, backend}
  end

  defp lock_like_the_write!(tenant, id) do
    Repo.query!("SELECT 1 FROM model_profile_settings WHERE tenant_id = $1 FOR UPDATE", [tenant])
    Repo.query!("SELECT 1 FROM model_server_counters WHERE tenant_id = $1 FOR SHARE", [tenant])
    Repo.query!("SELECT 1 FROM model_profile_switches WHERE id = $1 FOR UPDATE", [id])
  end

  defp write_resolution!(id, attestation, resolver) do
    Repo.query!(
      "UPDATE model_profile_switches SET status = 'failed', finished_at = now(), " <>
        "resolved_at = now(), resolution = 'owner_attested', resolved_by_id = $2, " <>
        "attestation_id = $3, attested_start_id = $4, attested_generation = $5, " <>
        "attested_lease_kind = $6, updated_at = now() WHERE id = $1",
      [
        id,
        Ecto.UUID.dump!(resolver.id),
        Ecto.UUID.dump!(attestation.attestation_id),
        Ecto.UUID.dump!(attestation.attested_start_id),
        attestation.attested_generation,
        Atom.to_string(attestation.attested_lease_kind)
      ]
    )
  end

  @doc "Commits `original!/3` and joins it."
  def commit_original!({task, _backend}) do
    send(task.pid, :commit)
    assert Task.await(task, 10_000) == {:ok, :committed}
  end

  @doc "The tenant's stored switches (as `actor`), newest first."
  def switches!(actor) do
    {:ok, switches} = Agents.list_profile_switches(actor: actor)
    switches
  end

  ## Minimization (test 15a; D-141 option B)

  @doc """
  The resolution path traced by tests 9 and 15a: the page's async start
  (the task's closure), every `Agents`, `ProfileSwitches` and
  `SwitchResolution` function, and every coordinator function (its
  `handle_call/3` included). For `trace_calls!/1`.
  """
  def resolution_path_mfas,
    do: [
      {Phoenix.LiveView.Async, :start_async, 4},
      {Agents, :_, :_},
      {ProfileSwitches, :_, :_},
      {SwitchResolution, :_, :_},
      {Coordinator, :_, :_}
    ]

  @doc """
  The resolution dispatches among the traced calls (`resolution_path_mfas/0`)
  not made by the test process: a `{:resolution, _}` async start, the
  domain's resolution entry points, the attestation checks and the
  coordinator's resolve request.
  """
  def resolution_dispatches(collector, test_pid \\ self()) do
    collector
    |> calls()
    |> Enum.filter(&(&1.pid != test_pid and dispatch?(&1)))
  end

  defp dispatch?(%{mfa: {Phoenix.LiveView.Async, :start_async, 4}, args: [_, key | _]}),
    do: match?({:resolution, _}, key)

  defp dispatch?(%{mfa: {Agents, :resolve_blocked_switch, 3}}), do: true

  defp dispatch?(%{mfa: {ProfileSwitches, f, _}}),
    do: f in [:resolve_blocked, :commit_resolution, :settle_resolution]

  defp dispatch?(%{mfa: {SwitchResolution, f, _}}),
    do: f in [:checked_attestation, :replay_lookup, :resolution_result]

  defp dispatch?(%{mfa: {Coordinator, :resolve_blocked, 2}}), do: true

  defp dispatch?(%{mfa: {Coordinator, :handle_call, 3}, args: [request | _]}),
    do: match?({:resolve_blocked, _, _}, request)

  defp dispatch?(_call), do: false

  @doc "A synthetic mismatched confirmation canary (one token, so its form encoding is itself)."
  def mismatch_canary,
    do: "r005canary" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc """
  Whether `term` holds `text` anywhere: a binary containing it, inside
  lists (improper too), tuples, maps (keys and values), structs and the
  environment of closures. `Inspect` is bypassed, so an opaque wrapper's
  text is found.
  """
  def holds?(term, text) when is_binary(text) and text != "", do: holds_term?(term, text)

  defp holds_term?(binary, text) when is_binary(binary),
    do: :binary.match(binary, text) != :nomatch

  defp holds_term?(list, text) when is_list(list), do: holds_list?(list, text)
  defp holds_term?(tuple, text) when is_tuple(tuple), do: holds_list?(Tuple.to_list(tuple), text)

  defp holds_term?(map, text) when is_map(map),
    do:
      Enum.any?(Map.to_list(map), fn {key, value} ->
        holds_term?(key, text) or holds_term?(value, text)
      end)

  defp holds_term?(fun, text) when is_function(fun) do
    case :erlang.fun_info(fun, :env) do
      {:env, env} -> holds_list?(env, text)
      _no_env -> false
    end
  end

  defp holds_term?(_other, _text), do: false

  defp holds_list?([head | tail], text), do: holds_term?(head, text) or holds_list?(tail, text)
  defp holds_list?([], _text), do: false
  defp holds_list?(tail, text), do: holds_term?(tail, text)

  ## Crash reports (tests 15b, 15c; ADR-0005 R0-05 amendment, option B)

  @doc "The fixed content-free diagnostic of a tagged process's report."
  def withheld, do: @withheld

  @doc """
  Runs `fun` with the primary logger level `level` (restored after) and
  returns `{result, text, events}`: the captured text (`CaptureLog` at
  `level`) and every log event that passed the primary filters
  (`SdrAgent.Logger.ExceptionFilter` among them), as a test `:logger`
  handler received it (`SdrAgent.Test.AdminSwitchHarness.LogSink`, removed
  after). The handler runs in each logging process, so a process's events
  are delivered before its later signals (a crashed view's `:DOWN`).
  """
  def log_events(level, fun) do
    previous = Logger.level()
    id = :"r005_log_sink_#{System.unique_integer([:positive])}"
    ref = make_ref()
    config = %{level: :all, config: %{to: self(), ref: ref}}
    :ok = :logger.add_handler(id, __MODULE__.LogSink, config)
    Logger.configure(level: level)

    try do
      {result, text} = CaptureLog.with_log([level: level], fun)
      {result, text, drain_events(ref, [])}
    after
      Logger.configure(level: previous)
      _ = :logger.remove_handler(id)
    end
  end

  defp drain_events(ref, events) do
    receive do
      {:r005_log_event, ^ref, event} -> drain_events(ref, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  @doc "The events logged by `pid`."
  def events_of(events, pid), do: Enum.filter(events, &(&1.meta[:pid] == pid))

  @doc """
  An event's message, report, format arguments and metadata as text: the
  `:logger_formatter` rendering of its message and the inspected `{level,
  msg, meta}` (no limits).
  """
  def event_text(%{msg: msg, meta: meta} = event) do
    format = %{
      single_line: false,
      chars_limit: :unlimited,
      max_size: :unlimited,
      depth: :unlimited,
      template: [:msg]
    }

    formatted =
      try do
        event |> :logger_formatter.format(format) |> IO.chardata_to_string()
      rescue
        _exception -> ""
      catch
        _kind, _reason -> ""
      end

    formatted <>
      "\n" <> inspect({event[:level], msg, meta}, limit: :infinity, printable_limit: :infinity)
  end

  @doc "Whether `event` holds `canary` (raw or form-encoded) in any part."
  def canary_in?(event, canary) do
    text = event_text(event)

    Enum.any?(
      Enum.uniq([canary, URI.encode_www_form(canary)]),
      &(String.contains?(text, &1) or holds?(event, &1))
    )
  end

  @doc """
  Asserts that every error-or-higher event of `pid` (a tagged process) is
  the fixed diagnostic at `:error`, with only the safe standard metadata
  (a `pid` of `pid`, a valid `mfa` unless `mfa: false` for a report that
  carries none, such as a `Task`'s) plus `sdr_sensitive_input: true`, and
  that there is at least one. Returns them.
  """
  def assert_withheld!(events, pid, label, opts \\ []) do
    own = Enum.filter(events_of(events, pid), &(:logger.compare_levels(&1.level, :error) != :lt))

    assert own != [],
           "R0-05 #{label}: no error report of #{inspect(pid)} was captured (positive control)"

    for event <- own do
      assert event.msg == {:string, @withheld},
             "R0-05 #{label}: a tagged process's report must be the fixed diagnostic " <>
               "#{inspect(@withheld)}; got #{String.slice(event_text(event), 0, 600)}"

      assert event.level == :error, "R0-05 #{label}: the diagnostic keeps the report's level"

      assert event.meta[:sdr_sensitive_input] == true,
             "R0-05 #{label}: the diagnostic carries sdr_sensitive_input: true"

      extra = Map.keys(event.meta) -- @safe_meta

      assert extra == [],
             "R0-05 #{label}: only the safe standard metadata is kept; got #{inspect(extra)}"

      assert event.meta[:pid] == pid, "R0-05 #{label}: the diagnostic keeps the pid"

      if Keyword.get(opts, :mfa, true) do
        assert match?(
                 {m, f, a} when is_atom(m) and is_atom(f) and is_integer(a),
                 event.meta[:mfa]
               ),
               "R0-05 #{label}: the safe mfa metadata is kept; got #{inspect(event.meta[:mfa])}"
      end
    end

    own
  end

  @doc "Asserts that no event in `events` (nor the captured `text`) holds `canary`."
  def refute_canary!(events, text, canary, label) do
    leaks = Enum.filter(events, &canary_in?(&1, canary))

    assert leaks == [],
           "R0-05 #{label}: the canary is in captured events of " <>
             inspect(Enum.map(leaks, &{&1.level, &1.meta[:pid], &1.meta[:mfa]}))

    for form <- Enum.uniq([canary, URI.encode_www_form(canary)]) do
      refute text =~ form, "R0-05 #{label}: the canary is in the captured log text"
    end
  end

  @doc """
  Test seam (tests 15b, 15c): attaches a `:handle_event` hook to the view's
  socket through `:sys.replace_state/2` (as the b2α `reconcile` fault), so
  the channel raises while it handles `event`, before the page's
  `handle_event/3`: the real event message is the channel's last message.
  `reason` is `:neutral` (a fixed `RuntimeError`) or `:params` (a
  `MatchError` on the decoded params: the crash reason carries the input).
  """
  def crash_on_event!(view, event, reason \\ :neutral) do
    hook = fn
      ^event, params, _socket -> crash(reason, params)
      _other, _params, socket -> {:cont, socket}
    end

    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.LiveView.attach_hook(socket, :r005_crash, :handle_event, hook)}
    end)

    :ok
  end

  @doc false
  def crash(:neutral, _params), do: raise(@crash)
  def crash(:params, params), do: raise(MatchError, term: params)

  @doc "Whether `reason` is the neutral seam crash of `crash_on_event!/3`."
  def seam_crash?({%RuntimeError{message: @crash}, _stack}), do: true
  def seam_crash?(_reason), do: false

  @doc """
  Runs `trigger` (an event that crashes the view through `crash_on_event!/3`,
  or a `:sys.terminate/2`) with the view unlinked and exits trapped, and
  returns the view's exit reason once the view is down, the ExUnit
  supervisor (the channel's parent) has handled its exit and the test's
  client proxy is down (bounded).
  """
  def crash!(view, trigger) do
    %{pid: pid, proxy: {_ref, _topic, proxy}} = view
    Process.unlink(pid)
    previous = Process.flag(:trap_exit, true)
    view_ref = Process.monitor(pid)
    proxy_ref = Process.monitor(proxy)

    try do
      try do
        trigger.()
      catch
        :exit, _reason -> :ok
      end

      reason = await_down!(view_ref, pid, "the view")
      {:ok, supervisor} = ExUnit.fetch_test_supervisor()
      _ = :sys.get_state(supervisor)
      _ = await_down!(proxy_ref, proxy, "the client proxy")
      reason
    after
      Process.flag(:trap_exit, previous)
      flush_exits()
    end
  end

  defp await_down!(ref, pid, what) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    after
      10_000 -> flunk("R0-05 crash: #{what} never went down")
    end
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  @doc """
  Tags the calling process as AdminLive's channel does (ADR-0005 R0-05
  amendment): the process logger metadata `sdr_sensitive_input: true`
  (`:logger.update_process_metadata/1`, what `Logger.metadata/1` updates).
  """
  def tag_process!, do: :logger.update_process_metadata(%{sdr_sensitive_input: true})

  @doc "Runs `fun` in an unlinked `Task` and waits (bounded) for it to end; returns its pid."
  def run_task!(fun) do
    {:ok, pid} = Task.start(fun)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> pid
    after
      10_000 -> flunk("R0-05 control: the task never ended")
    end
  end

  @doc "The attached primary `:sdr_agent_exception_filter` as `{fun, opts}` (asserted present)."
  def exception_filter!(label) do
    entry = List.keyfind(:logger.get_primary_config().filters, :sdr_agent_exception_filter, 0)

    assert match?({_, {fun, _}} when is_function(fun, 2), entry) and
             Function.info(elem(elem(entry, 1), 0))[:module] == SdrAgent.Logger.ExceptionFilter,
           "R0-05 #{label}: the primary :sdr_agent_exception_filter is not attached"

    elem(entry, 1)
  end

  @doc """
  Enables Elixir's SASL report translation (`handle_sasl_reports`) in place
  in the primary filter list (its order kept), restored on exit. For
  `async: false` tests only (test 15c).
  """
  def sasl_reports! do
    %{filters: filters} = :logger.get_primary_config()
    {:logger_translator, {fun, config}} = List.keyfind(filters, :logger_translator, 0)
    :ok = put_translator(filters, {fun, %{config | sasl: true}})

    on_exit(fn ->
      %{filters: now} = :logger.get_primary_config()
      :ok = put_translator(now, {fun, config})
    end)
  end

  defp put_translator(filters, filter),
    do:
      :logger.set_primary_config(
        :filters,
        List.keyreplace(filters, :logger_translator, 0, {:logger_translator, filter})
      )
end

defmodule SdrAgent.Test.AdminSwitchHarness.LogSink do
  @moduledoc """
  A test `:logger` handler (R0-05 tests 15b and 15c): forwards each event
  it receives — after the primary filters,
  `SdrAgent.Logger.ExceptionFilter` among them — to the test process in its
  config. It runs in the logging process. Added and removed by
  `SdrAgent.Test.AdminSwitchHarness.log_events/2`.
  """

  @doc "The `:logger` handler callback."
  def log(event, %{config: %{to: to, ref: ref}}), do: send(to, {:r005_log_event, ref, event})
end
