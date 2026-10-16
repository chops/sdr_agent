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
end
