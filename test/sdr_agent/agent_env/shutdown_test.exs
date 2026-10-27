defmodule SdrAgent.AgentEnv.ShutdownTest do
  @moduledoc """
  C2* S1 PR-B RED-2: the run-exit contract P5 (the P5 correction
  `claude-c2star-s1-prb-p5-correction-r1.md` sections 2-3, tests P5-1 and
  P5-3 to P5-6, as corrected by Codex `e01021f5` binding details 2-5;
  P5-2(a) and (b) are in `instance_test.exs` and `boot_test.exs`, P5-2(c)
  is RED-3).

  `SdrAgent.AgentEnv.Shutdown` is the only writer of the run receipt
  `instance.<nonce>.exit`, and only the application callbacks call it:

    * `plan(top)` (`SdrAgent.Application.prep_stop/1`, run mode only, the
      top supervisor alive) returns `{:ok, plan}` — `%{nonce, boot_id,
      root, top: {pid, monitor_ref}, model_tree: {pid, monitor_ref} |
      :none}`, the model tree being the top's `ProfileSupervisor` child,
      `:none` only for the Fake with no such child and the ClaudeCLI
      server name unregistered — or `:not_orderly` (the top dead, the tree
      missing for ClaudeCLI or present for the Fake, the boot binding
      absent or of another nonce).
    * `complete(planned)` (`SdrAgent.Application.stop/1`, which always
      returns `:ok`) re-validates the boot binding and the plan's monitored
      identities, then requires, within ONE 30 s deadline: the top's DOWN
      `:shutdown`, the model tree's DOWN `:shutdown`/`{:shutdown, _}` (or
      `:none`), the server name unregistered and the Reaper key clear
      (polled). Only then does it exclusively create the receipt (closed
      keys `nonce`, `boot_id`, `completed_at`; canonical bytes). Otherwise
      `{:error, reason}`: `:not_orderly`, `:instance_not_terminated`,
      `:model_tree_not_terminated`, `:server_still_registered`,
      `:reaper_cleanup_unconfirmed` or `:receipt_write_failed`, with no
      receipt, the lease and the boot marker untouched, and no force, kill
      or reclaim.

  Test builds only (`:claude_cli_test_seams`, as `runtime.ex:73`), `plan/2`
  and `complete/2` take the seams `model_tree_id:`, `provider:`,
  `server_name:`, `reaper_lease:` (`fn -> nil | {:held, pid} end`),
  `budget_ms:`, `boot:` and `root:`; these tests pass the same keyword to
  both, and each function uses the seams it needs. Dev and prod builds
  export only `plan/1` and `complete/1` (the compiled-branch row). The
  synthetic processes are test-owned: a test `Supervisor` as the top, a
  synthetic model-tree supervisor holding a server registered under a
  unique name, an `Agent` holding the Reaper key and a synthetic reaper
  that clears it after the tree's DOWN. These are unit proofs of the
  barrier; S5's owned live run is the integration proof (Codex detail 6).

  RED: `SdrAgent.AgentEnv.Shutdown`, `SdrAgent.AgentEnv.Instance` and
  `SdrAgent.Application.prep_stop/1` do not exist (structural, guarded
  after the fixtures).

  Hermetic: SQL sandbox (shared: the ignored Instance runs its checks in its
  own process), physical roots under `tmp/agent-env-roots`, no port, real
  CLI, VM or application stop.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.Fake
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.Test.AgentEnvBootFixtures, as: BootFx
  alias SdrAgent.Test.AgentEnvFixtures, as: Fx

  @shutdown SdrAgent.AgentEnv.Shutdown
  @instance SdrAgent.AgentEnv.Instance
  @application SdrAgent.Application
  @shutdown_source "lib/sdr_agent/agent_env/shutdown.ex"
  @tree_id :c2star_s1_synthetic_model_tree
  @budget_ms 30_000

  setup do
    tenant = bootstrap!()
    root = Fx.root!("shutdown")
    bound = Fx.bound!(root, lease: :run)
    Fx.configure!(root, mode: :run, nonce: bound.nonce, step: :run)
    BootFx.erase_boot_binding!()

    key = start_supervised!(%{id: :reaper_key, start: {Agent, :start_link, [fn -> nil end]}})
    trace = start_supervised!(%{id: :trace, start: {Agent, :start_link, [fn -> [] end]}})

    %{
      tenant: tenant,
      root: root,
      nonce: bound.nonce,
      key: key,
      trace: trace,
      server: :"c2star_s1_synthetic_server_#{System.unique_integer([:positive])}",
      lease_sha: Fx.file_sha256!(root, :lease)
    }
  end

  ## Guards and calls

  defp require!(module, functions) do
    assert Code.ensure_loaded?(module), "C2* S1 RED-2: #{inspect(module)} is not available"

    for {function, arity} <- functions do
      assert function_exported?(module, function, arity),
             "C2* S1 RED-2: #{inspect(module)}.#{function}/#{arity} is not exported"
    end

    :ok
  end

  defp require_shutdown!, do: require!(@shutdown, plan: 1, complete: 1, plan: 2, complete: 2)

  defp plan(top, seams), do: apply(@shutdown, :plan, [top, seams])
  defp complete(planned, seams), do: apply(@shutdown, :complete, [planned, seams])

  # The guard, then this test's boot binding and its marker (as a
  # successful Instance.init/1 leaves them; passed through the `boot:` seam).
  defp ready!(ctx) do
    require_shutdown!()
    boot = %{nonce: ctx.nonce, boot_id: Fx.hex(16)}
    marker_sha = BootFx.write_boot_marker!(ctx.root, ctx.nonce, boot.boot_id)
    Map.merge(ctx, %{boot: boot, marker_sha: marker_sha})
  end

  defp seams(ctx, overrides \\ []) do
    key = ctx.key

    Keyword.merge(
      [
        model_tree_id: @tree_id,
        provider: ClaudeCLI,
        server_name: ctx.server,
        reaper_lease: fn -> Agent.get(key, & &1) end,
        budget_ms: 2_000,
        boot: ctx.boot,
        root: ctx.root
      ],
      overrides
    )
  end

  ## Synthetic processes

  defp start_top!(children) do
    {:ok, top} =
      Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 20, max_seconds: 5)

    Process.unlink(top)
    on_exit(fn -> if Process.alive?(top), do: Process.exit(top, :kill) end)
    top
  end

  defp tree_child(server) do
    %{
      id: @tree_id,
      type: :supervisor,
      start: {Supervisor, :start_link, [[server_child(server)], [strategy: :one_for_one]]}
    }
  end

  defp server_child(server),
    do: %{
      id: :synthetic_server,
      start: {Agent, :start_link, [fn -> :serving end, [name: server]]}
    }

  defp extra_child, do: %{id: :extra, start: {Agent, :start_link, [fn -> :other end]}}

  defp child_pid(top, id) do
    Enum.find_value(Supervisor.which_children(top), fn
      {^id, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end

  defp seq, do: System.unique_integer([:monotonic])

  # Holds the Reaper key while alive; `delay` ms after the tree's DOWN it
  # records whether a receipt exists yet, then clears the key and exits.
  defp start_reaper!(ctx, tree, delay) do
    receipt = BootFx.run_receipt_path(ctx.root, ctx.nonce)
    %{key: key, trace: trace} = ctx
    test = self()

    reaper =
      spawn(fn ->
        ref = Process.monitor(tree)
        send(test, {:reaper_armed, self()})

        receive do
          {:DOWN, ^ref, :process, ^tree, reason} ->
            Agent.update(trace, &[{:tree_down, seq(), reason} | &1])
            Process.sleep(delay)
            Agent.update(trace, &[{:key_cleared, seq(), File.exists?(receipt)} | &1])
            Agent.update(key, fn _held -> nil end)
        end
      end)

    assert_receive {:reaper_armed, ^reaper}
    on_exit(fn -> Process.exit(reaper, :kill) end)
    Agent.update(key, fn _none -> {:held, reaper} end)
    reaper
  end

  defp holder!(:live) do
    holder =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    holder
  end

  defp holder!(:dead) do
    {holder, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^holder, :normal}
    holder
  end

  defp kill!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("C2* S1 test: the condition never held")
      true -> retry(fun, attempts)
    end
  end

  defp retry(fun, attempts) do
    Process.sleep(20)
    wait_until(fun, attempts - 1)
  end

  defp trace_events(ctx), do: ctx.trace |> Agent.get(& &1) |> Enum.reverse()

  ## Files

  defp receipt_path(ctx), do: BootFx.run_receipt_path(ctx.root, ctx.nonce)

  defp receipt!(ctx) do
    bytes = File.read!(receipt_path(ctx))
    assert BootFx.canonical?(bytes), "C2* S1 P5: the run receipt must be canonical bytes"
    data = Jason.decode!(bytes)
    assert data |> Map.keys() |> Enum.sort() == ["boot_id", "completed_at", "nonce"]
    assert data["nonce"] == ctx.nonce
    assert {:ok, _at, 0} = DateTime.from_iso8601(data["completed_at"])
    data
  end

  defp assert_nothing_completed(ctx) do
    refute File.exists?(receipt_path(ctx)), "C2* S1 P5: no run receipt may exist"
    assert Fx.file_sha256!(ctx.root, :lease) == ctx.lease_sha, "C2* S1 P5: the lease stays"

    if Map.has_key?(ctx, :marker_sha) do
      marker = BootFx.boot_marker_path(ctx.root, ctx.nonce)
      assert BootFx.file_sha256!(marker) == ctx.marker_sha, "C2* S1 P5: the boot marker stays"
    end
  end

  ## Orderly completion (P5-3, P5-3F)

  describe "orderly completion" do
    test "P5-3: after an orderly stop, the receipt follows the tree's DOWN and the key clear",
         ctx do
      ctx = ready!(ctx)
      top = start_top!([tree_child(ctx.server), extra_child()])
      tree = child_pid(top, @tree_id)
      assert is_pid(Process.whereis(ctx.server))
      start_reaper!(ctx, tree, 300)

      planned = plan(top, seams(ctx))

      assert {:ok, %{top: {^top, top_ref}, model_tree: {^tree, tree_ref}} = plan} = planned
      assert {plan.nonce, plan.boot_id, plan.root} == {ctx.nonce, ctx.boot.boot_id, ctx.root}
      assert is_reference(top_ref) and is_reference(tree_ref)
      refute File.exists?(receipt_path(ctx))

      :ok = Supervisor.stop(top, :shutdown)
      assert complete(planned, seams(ctx)) == :ok

      assert receipt!(ctx)["boot_id"] == ctx.boot.boot_id
      assert [{:tree_down, down, :shutdown}, {:key_cleared, cleared, false}] = trace_events(ctx)
      assert down < cleared, "C2* S1 P5-3: the key clears after the model tree's DOWN"
      assert Fx.file_sha256!(ctx.root, :lease) == ctx.lease_sha
      assert BootFx.file_sha256!(BootFx.boot_marker_path(ctx.root, ctx.nonce)) == ctx.marker_sha
    end

    test "P5-3F: the Fake tree completes; a single child stop and restart write nothing", ctx do
      ctx = ready!(ctx)
      top = start_top!([extra_child()])
      seams = seams(ctx, provider: Fake)

      {:ok, calls} =
        BootFx.trace_calls(@shutdown, fn ->
          :ok = Supervisor.terminate_child(top, :extra)
          {:ok, _pid} = Supervisor.restart_child(top, :extra)
          :ok
        end)

      assert calls == [], "C2* S1 P5: a single child stop calls no Shutdown function"
      refute File.exists?(receipt_path(ctx))

      planned = plan(top, seams)
      assert {:ok, %{top: {^top, _ref}, model_tree: :none}} = planned

      :ok = Supervisor.stop(top, :shutdown)
      assert complete(planned, seams) == :ok
      assert receipt!(ctx)["boot_id"] == ctx.boot.boot_id
    end
  end

  ## Plans that are not orderly

  describe "plan" do
    test "a missing or misplaced model tree, a registered Fake server or a bad binding is not orderly",
         ctx do
      ctx = ready!(ctx)

      bare = start_top!([extra_child()])
      assert plan(bare, seams(ctx)) == :not_orderly, "ClaudeCLI configured, no model tree"

      {:ok, stray} = Agent.start(fn -> :stray end, name: ctx.server)
      assert plan(bare, seams(ctx, provider: Fake)) == :not_orderly, "Fake, server registered"
      kill!(stray)

      with_tree = start_top!([tree_child(ctx.server)])
      assert plan(with_tree, seams(ctx, provider: Fake)) == :not_orderly, "Fake with a model tree"
      assert plan(with_tree, seams(ctx, boot: nil)) == :not_orderly, "no boot binding"

      assert plan(with_tree, seams(ctx, boot: %{ctx.boot | nonce: Fx.nonce()})) == :not_orderly,
             "a binding of another nonce"

      assert {:ok, _plan} = plan(with_tree, seams(ctx)), "control"
      assert match?({:ok, _plan}, plan(bare, seams(ctx, provider: Fake))), "Fake control"
      assert_nothing_completed(ctx)
    end

    test "P5-5(b): plan after the top is already dead (the crash path) is not orderly", ctx do
      ctx = ready!(ctx)
      top = start_top!([tree_child(ctx.server)])
      kill!(top)

      assert plan(top, seams(ctx)) == :not_orderly
      assert complete(:not_orderly, seams(ctx)) == {:error, :not_orderly}
      assert complete(:anything_else, seams(ctx)) == {:error, :not_orderly}
      assert_nothing_completed(ctx)
    end
  end

  ## Completions that write nothing (P5-4, P5-5)

  describe "no receipt" do
    for holder <- [:live, :dead] do
      @holder holder

      test "P5-4: a Reaper key held by a #{holder} holder past the budget writes no receipt",
           ctx do
        ctx = ready!(ctx)
        top = start_top!([tree_child(ctx.server), extra_child()])
        Agent.update(ctx.key, fn _none -> {:held, holder!(@holder)} end)
        planned = plan(top, seams(ctx))
        assert {:ok, _plan} = planned

        :ok = Supervisor.stop(top, :shutdown)

        assert complete(planned, seams(ctx, budget_ms: 1_000)) ==
                 {:error, :reaper_cleanup_unconfirmed}

        assert_nothing_completed(ctx)
      end
    end

    test "one budget covers every wait: a late top stop leaves only the rest of it", ctx do
      ctx = ready!(ctx)
      top = start_top!([tree_child(ctx.server)])
      Agent.update(ctx.key, fn _none -> {:held, holder!(:live)} end)
      planned = plan(top, seams(ctx))
      assert {:ok, _plan} = planned

      spawn(fn ->
        Process.sleep(1_400)
        Supervisor.stop(top, :shutdown)
      end)

      started = System.monotonic_time(:millisecond)
      result = complete(planned, seams(ctx, budget_ms: 2_000))
      elapsed = System.monotonic_time(:millisecond) - started

      assert result == {:error, :reaper_cleanup_unconfirmed}

      assert elapsed >= 1_900 and elapsed < 2_900,
             "C2* S1 P5: one deadline across all waits (elapsed #{elapsed} ms; budget 2000 ms, " <>
               "top stopped at 1400 ms)"

      assert_nothing_completed(ctx)
    end

    test "P5-5(a): a killed top is not a terminated instance", ctx do
      ctx = ready!(ctx)
      top = start_top!([tree_child(ctx.server)])
      planned = plan(top, seams(ctx))
      assert {:ok, _plan} = planned

      kill!(top)
      assert complete(planned, seams(ctx)) == {:error, :instance_not_terminated}
      assert_nothing_completed(ctx)
    end

    test "P5-5(c): a model tree killed during the stop is not a terminated tree", ctx do
      ctx = ready!(ctx)
      top = start_top!([tree_child(ctx.server), extra_child()])
      tree = child_pid(top, @tree_id)
      planned = plan(top, seams(ctx))
      assert {:ok, _plan} = planned

      kill!(tree)
      :ok = Supervisor.stop(top, :shutdown)
      assert complete(planned, seams(ctx)) == {:error, :model_tree_not_terminated}
      assert_nothing_completed(ctx)
    end

    test "a server name still registered after the stop writes no receipt", ctx do
      ctx = ready!(ctx)
      top = start_top!([tree_child(ctx.server)])
      planned = plan(top, seams(ctx))
      assert {:ok, _plan} = planned

      :ok = Supervisor.stop(top, :shutdown)
      {:ok, stray} = Agent.start(fn -> :stray end, name: ctx.server)
      on_exit(fn -> Process.exit(stray, :kill) end)

      assert complete(planned, seams(ctx, budget_ms: 500)) == {:error, :server_still_registered}
      assert_nothing_completed(ctx)
    end

    test "complete re-validates the boot binding and the plan's monitored identities", ctx do
      ctx = ready!(ctx)

      top = start_top!([tree_child(ctx.server)])
      planned = plan(top, seams(ctx))
      assert {:ok, _plan} = planned
      :ok = Supervisor.stop(top, :shutdown)
      rebound = %{ctx.boot | boot_id: Fx.hex(16)}

      assert complete(planned, seams(ctx, boot: rebound)) == {:error, :not_orderly},
             "the current binding is no longer the plan's"

      top = start_top!([tree_child(ctx.server)])
      assert {:ok, plan} = plan(top, seams(ctx))
      :ok = Supervisor.stop(top, :shutdown)

      assert complete({:ok, %{plan | boot_id: Fx.hex(16)}}, seams(ctx)) == {:error, :not_orderly},
             "a plan altered by its caller"

      top = start_top!([extra_child()])
      :ok = Supervisor.stop(top, :shutdown)

      fabricated =
        {:ok,
         %{
           nonce: ctx.nonce,
           boot_id: ctx.boot.boot_id,
           root: ctx.root,
           top: {top, make_ref()},
           model_tree: :none
         }}

      assert complete(fabricated, seams(ctx, provider: Fake, budget_ms: 500)) in [
               {:error, :instance_not_terminated},
               {:error, :not_orderly}
             ],
             "a caller-built plan whose monitor was never made"

      assert_nothing_completed(ctx)
    end

    test "an existing receipt is never overwritten", ctx do
      ctx = ready!(ctx)
      top = start_top!([tree_child(ctx.server)])
      planned = plan(top, seams(ctx))
      assert {:ok, _plan} = planned
      :ok = Supervisor.stop(top, :shutdown)

      bytes =
        Canonical.encode!(%{
          "nonce" => ctx.nonce,
          "boot_id" => Fx.hex(16),
          "completed_at" => DateTime.utc_now()
        })

      File.write!(receipt_path(ctx), bytes)

      assert complete(planned, seams(ctx)) == {:error, :receipt_write_failed}
      assert File.read!(receipt_path(ctx)) == bytes
    end
  end

  ## Arbitrary child stops and the ignored Instance (P5-1)

  describe "child stops" do
    test "P5-1: the ignored Instance's re-entry is refused; child stops and restarts write nothing",
         ctx do
      require!(@instance, init: 1, child_spec: 1)
      require_shutdown!()

      top = start_top!([{@instance, :run}, tree_child(ctx.server), extra_child()])
      marker = BootFx.boot_marker_path(ctx.root, ctx.nonce)
      marker_sha = BootFx.file_sha256!(marker)
      binding = BootFx.boot_binding()
      assert %{nonce: nonce, boot_id: _boot_id} = binding
      assert nonce == ctx.nonce

      assert {@instance, :undefined, :worker, _modules} =
               List.keyfind(Supervisor.which_children(top), @instance, 0),
             "C2* S1 P5: the Instance keeps no process after init/1 (a killed Instance is impossible)"

      {:ok, calls} =
        BootFx.trace_calls(@shutdown, fn ->
          {:ok, _log} = with_log(fn -> child_stops(ctx, top) end)
          :ok
        end)

      assert calls == [], "C2* S1 P5-1: a child stop or restart calls no Shutdown function"
      assert BootFx.file_sha256!(marker) == marker_sha
      assert BootFx.boot_binding() == binding

      assert {@instance, :undefined, :worker, _modules} =
               List.keyfind(Supervisor.which_children(top), @instance, 0)

      assert_nothing_completed(ctx)
    end
  end

  defp child_stops(ctx, top) do
    reentry = Supervisor.child_spec({@instance, :run}, id: :reentry)
    assert Supervisor.restart_child(top, @instance) == {:error, :run_nonce_already_booted}
    assert Supervisor.start_child(top, reentry) == {:error, :run_nonce_already_booted}
    assert Supervisor.terminate_child(top, @instance) == :ok
    assert Supervisor.restart_child(top, @instance) == {:error, :run_nonce_already_booted}

    assert Supervisor.terminate_child(top, @tree_id) == :ok
    assert {:ok, tree} = Supervisor.restart_child(top, @tree_id)
    kill!(tree)
    wait_until(fn -> is_pid(Process.whereis(ctx.server)) and child_pid(top, @tree_id) != tree end)

    assert Supervisor.terminate_child(top, :extra) == :ok
    assert {:ok, _extra} = Supervisor.restart_child(top, :extra)
    refute File.exists?(receipt_path(ctx))
    :ok
  end

  ## The application callbacks (P5-6)

  describe "application callbacks" do
    @tag timeout: 120_000
    test "P5-6: prep_stop/1 and stop/1 while the real tree is alive: :ok, no receipt, no release",
         ctx do
      require_shutdown!()
      require!(@application, prep_stop: 1, stop: 1)
      require!(@instance, init: 1, child_spec: 1)
      assert Process.whereis(ClaudeCLI.server()) == nil, "precondition: no ClaudeCLI server runs"

      assert apply(@instance, :init, [:run]) == :ignore
      binding = BootFx.boot_binding()
      top = Process.whereis(SdrAgent.Supervisor)

      callbacks =
        Task.async(fn ->
          prepped = apply(@application, :prep_stop, [:app_state])
          {prepped, apply(@application, :stop, [prepped])}
        end)

      direct =
        Task.async(fn ->
          planned = apply(@shutdown, :plan, [SdrAgent.Supervisor])
          {planned, apply(@shutdown, :complete, [planned])}
        end)

      started = System.monotonic_time(:millisecond)
      [{prepped, stopped}, {planned, completed}] = Task.await_many([callbacks, direct], 60_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert {:ok, %{top: {^top, _ref}, model_tree: :none} = plan} = prepped
      assert {plan.nonce, plan.boot_id, plan.root} == {ctx.nonce, binding.boot_id, ctx.root}
      assert stopped == :ok, "C2* S1 P5-6: Application.stop/1 always returns :ok"

      assert {:ok, %{top: {^top, _ref}}} = planned
      assert completed == {:error, :instance_not_terminated}

      assert elapsed >= @budget_ms - 1_000 and elapsed < @budget_ms + 15_000,
             "C2* S1 P5: the production budget is one fixed 30 s deadline (elapsed #{elapsed} ms)"

      assert Process.alive?(top)
      assert_nothing_completed(ctx)
    end

    for mode <- [:none, :check, :bootstrap, :provisioning] do
      @mode mode

      test "P5-6: outside run mode (#{mode}) the callbacks are inert and read no file", ctx do
        require!(@application, prep_stop: 1, stop: 1)

        if @mode == :none,
          do: Fx.unconfigure!(),
          else: Fx.configure!(ctx.root, mode: @mode, nonce: ctx.nonce)

        {result, calls} =
          Fx.trace_file_calls(fn ->
            prepped = apply(@application, :prep_stop, [:app_state])
            {prepped, apply(@application, :stop, [prepped])}
          end)

        assert result == {:app_state, :ok}
        assert calls == [], "C2* S1 P5: inert callbacks read no file: #{inspect(calls)}"
        assert_nothing_completed(ctx)
      end
    end
  end

  ## The compiled branch (Codex detail 3)

  describe "compiled branch" do
    test "the seams compile only into test builds: dev and prod export plan/1 and complete/1 only" do
      require_shutdown!()

      {ast, gated} =
        @shutdown_source
        |> File.read!()
        |> Code.string_to_quoted!(file: @shutdown_source)
        |> Macro.prewalk(0, &unseamed/2)

      assert gated > 0,
             "C2* S1 P5: the Shutdown seams must be gated by Application.compile_env(:sdr_agent, " <>
               ":claude_cli_test_seams, false)"

      copy =
        Module.concat(SdrAgent.Test, "ShutdownWithoutSeams#{System.unique_integer([:positive])}")

      {modules, _diagnostics} =
        ExUnit.CaptureIO.with_io(:stderr, fn ->
          ast |> Macro.prewalk(&rename(&1, copy)) |> Code.compile_quoted(@shutdown_source)
        end)

      try do
        assert copy in Enum.map(modules, &elem(&1, 0))
        assert function_exported?(copy, :plan, 1) and function_exported?(copy, :complete, 1)
        refute function_exported?(copy, :plan, 2), "dev/prod builds must not take seams"
        refute function_exported?(copy, :complete, 2), "dev/prod builds must not take seams"
      after
        for {module, _binary} <- modules do
          :code.purge(module)
          :code.delete(module)
        end
      end
    end
  end

  # The test-seam flag as a dev or prod build compiles it.
  defp unseamed(
         {{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _,
          [:sdr_agent, :claude_cli_test_seams | _]},
         gated
       ),
       do: {false, gated + 1}

  defp unseamed(node, gated), do: {node, gated}

  defp rename(
         {:defmodule, meta, [{:__aliases__, _, [:SdrAgent, :AgentEnv, :Shutdown]}, body]},
         copy
       ),
       do: {:defmodule, meta, [copy, body]}

  defp rename(node, _copy), do: node
end
