defmodule SdrAgent.AI.ClaudeCLITest do
  use ExUnit.Case, async: false

  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AI.ModelProvider.CodexAppServer

  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()})
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  test "requires a tool-free init attestation and returns structured output" do
    {:ok, server} = start_server("ready")
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    assert result.output == %{"answer" => "qualified", "score" => 42}
    assert result.model == "claude-opus-5-5"

    assert %{"alias" => "opus", "resolved_id" => "claude-opus-5-5"} =
             result.provenance.model_catalog_entry
  end

  test "fails closed on missing, malformed, model-drifted, and tool-enabled init" do
    for {mode, expected} <- [
          {"missing_init", :missing_init_attestation},
          {"malformed", :invalid_cli_stream},
          {"model_drift", :model_attestation_drift},
          {"version_drift", :version_attestation_drift},
          {"tool_drift", :tool_attestation_drift}
        ] do
      {:ok, server} = start_server(mode)
      assert {:error, ^expected} = ClaudeCLI.complete(request(), server: server)
    end
  end

  test "accepts one JSON object wrapped in a Markdown code fence, nothing else" do
    {:ok, server} = start_server("fenced")
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    assert result.output == %{"answer" => "qualified", "score" => 42}

    {:ok, server} = start_server("prose")
    assert {:error, :missing_structured_output} = ClaudeCLI.complete(request(), server: server)
  end

  test "stderr cannot leak into a successful response" do
    {:ok, server} = start_server("stderr_secret")
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    refute inspect(result) =~ "SECRET_DO_NOT_EXPOSE"
  end

  test "timeout reports unknown and kills the spawned process tree" do
    pid_file =
      Path.join(System.tmp_dir!(), "sdr-claude-child-#{System.unique_integer([:positive])}")

    {:ok, server} = start_server("timeout", [pid_file], timeout: 1_000)

    assert {:unknown, :claude_cli_timeout} = ClaudeCLI.complete(request(), server: server)
    child_pid = pid_file |> File.read!() |> String.trim()

    assert eventually(fn ->
             match?({_, 1}, System.cmd("kill", ["-0", child_pid], stderr_to_stdout: true))
           end)

    File.rm(pid_file)
  end

  describe "Q0.1 the named, supervised server" do
    test "without :server the call goes to the named server; absent, it is a typed error" do
      refute GenServer.whereis(ClaudeCLI.server())
      assert {:error, :provider_not_running} = ClaudeCLI.complete(request(), [])

      start_supervised!({ClaudeCLI, named_opts("ready")})
      assert {:ok, result} = ClaudeCLI.complete(request(), [])
      assert result.model == "claude-opus-5-5"
    end

    test "a dead server pid is a typed error, not an exit" do
      {:ok, server} = start_server("ready")
      GenServer.stop(server)
      assert {:error, :provider_not_running} = ClaudeCLI.complete(request(), server: server)
    end

    test "boot records a pending attestation (no no-call probe); the first call attests" do
      start_supervised!({ClaudeCLI, named_opts("ready")})

      assert %{status: :pending, command?: true} = ClaudeCLI.attestation()

      assert {:ok, _} = ClaudeCLI.complete(request(), [])

      assert %{
               status: :attested,
               model: "claude-opus-5-5",
               version: "2.1.291",
               reason: nil,
               at: %DateTime{}
             } = ClaudeCLI.attestation()
    end

    test "drift and a missing init are recorded as the last attestation" do
      for {mode, reason} <- [
            {"model_drift", :model_attestation_drift},
            {"tool_drift", :tool_attestation_drift},
            {"missing_init", :missing_init_attestation}
          ] do
        start_supervised!({ClaudeCLI, named_opts(mode)}, id: mode)
        assert {:error, ^reason} = ClaudeCLI.complete(request(), [])
        assert %{status: :drift, reason: ^reason, at: %DateTime{}} = ClaudeCLI.attestation()
        stop_supervised!(mode)
      end
    end

    test "a missing llm-proxy-shim is surfaced at boot" do
      start_supervised!(
        {ClaudeCLI, name: ClaudeCLI.server(), command: nil, command_args: ["claude"]}
      )

      assert %{status: :pending, command?: false} = ClaudeCLI.attestation()
      assert {:error, :llm_proxy_shim_not_found} = ClaudeCLI.complete(request(), [])
    end

    test "no server, no attestation" do
      assert %{status: :not_running} = ClaudeCLI.attestation()
    end

    test "concurrent callers of the named server are serialized (concurrency 1)" do
      dump = Path.join(System.tmp_dir!(), "sdr-claude-env-#{System.unique_integer([:positive])}")
      on_exit(fn -> dump |> dumps() |> Enum.each(&File.rm/1) end)

      start_supervised!(
        {ClaudeCLI,
         name: ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         command_args: [@fake, "env_dump", dump, "300"]}
      )

      [witness(), witness(), witness()]
      |> Enum.map(fn witness ->
        Task.async(fn -> ClaudeCLI.complete(request(witness), []) end)
      end)
      |> Task.await_many(30_000)
      |> Enum.each(&assert({:ok, _} = &1))

      assert [one, two, three] = read_dumps(dump)
      assert one["finished_us"] <= two["started_us"], "CLI launches overlapped"
      assert two["finished_us"] <= three["started_us"], "CLI launches overlapped"
    end
  end

  describe "Q0.1 review: CLI process lifecycle (crash, caller, deadline)" do
    setup do
      prefix =
        Path.join(System.tmp_dir!(), "sdr-claude-hang-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        for record <- Path.wildcard(prefix <> ".*") do
          launch = record |> File.read!() |> JSON.decode!()
          # Only the exact synthetic PIDs this test's fixture recorded.
          for pid <- [launch["child"], launch["root"]], os_alive?(pid), do: os_kill(pid)
          File.rm(record)
        end
      end)

      %{prefix: prefix}
    end

    test "a killed supervised server's CLI tree and workspace are reaped before its replacement starts",
         %{prefix: prefix} do
      server = start_supervised!({ClaudeCLI, hang_opts(prefix, timeout: 30_000)})
      caller = Task.async(fn -> catch_exit(ClaudeCLI.complete(request(), [])) end)
      launch = await_launch!(prefix)

      Process.exit(server, :kill)
      assert {:killed, _} = Task.await(caller, 10_000)

      replacement = await_replacement!(server)
      # init has returned: the replacement admits no call before the old tree is gone.
      _ = :sys.get_state(replacement)

      refute os_alive?(launch["root"]), "old CLI root survived the restart"
      refute os_alive?(launch["child"]), "old CLI child survived the restart"
      refute File.exists?(launch["cwd"]), "old private workspace survived the restart"
    end

    test "a timeout reaps the CLI root as well as its descendants, and the workspace",
         %{prefix: prefix} do
      {:ok, server} = ClaudeCLI.start_link(hang_opts(prefix, timeout: 1_500))

      assert {:unknown, :claude_cli_timeout} = ClaudeCLI.complete(request(), server: server)
      assert [launch] = launches(prefix)

      assert eventually(fn -> not os_alive?(launch["root"]) end), "CLI root survived its timeout"
      assert eventually(fn -> not os_alive?(launch["child"]) end)
      refute File.exists?(launch["cwd"])
    end

    test "a caller killed while queued never launches its model request" do
      root =
        Path.join(System.tmp_dir!(), "sdr-claude-queue-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, server} =
        ClaudeCLI.start_link(
          command: System.find_executable("elixir"),
          command_args: [@fake, "env_dump", Path.join(root, "call"), "700"],
          timeout: 10_000
        )

      first = Task.async(fn -> ClaudeCLI.complete(request(), server: server) end)
      assert eventually(fn -> launching?(server) end, 250)

      second = Task.async(fn -> ClaudeCLI.complete(request(), server: server) end)
      Process.unlink(second.pid)
      assert eventually(fn -> queued?(server, second.pid) end, 250)

      Process.exit(second.pid, :kill)
      assert {:ok, _} = Task.await(first, 10_000)
      # Synchronises behind anything still queued on the server (no call).
      _ = :sys.get_state(server, 10_000)

      assert length(File.ls!(root)) == 1,
             "a model subprocess ran for a caller that died before dispatch"
    end

    test "a caller that dies during its call stops the CLI tree; the server stays up",
         %{prefix: prefix} do
      {:ok, server} = ClaudeCLI.start_link(hang_opts(prefix, timeout: 30_000))
      caller = spawn(fn -> ClaudeCLI.complete(request(), server: server) end)
      launch = await_launch!(prefix)

      Process.exit(caller, :kill)

      assert eventually(fn -> not os_alive?(launch["root"]) end, 250),
             "the CLI kept running for a dead caller"

      assert eventually(fn -> not os_alive?(launch["child"]) end, 250)
      assert Process.alive?(server)
      assert eventually(fn -> not launching?(server) end, 250)
    end

    test "the timeout is end to end: a request whose deadline passes in the queue is refused unlaunched",
         %{prefix: prefix} do
      {:ok, server} = ClaudeCLI.start_link(hang_opts(prefix, timeout: 2_000))

      first = Task.async(fn -> ClaudeCLI.complete(request(), server: server) end)
      assert eventually(fn -> launching?(server) end, 250)
      # Queued behind a call that uses its whole budget, this one has
      # (almost) none left when it reaches the front.
      second = Task.async(fn -> ClaudeCLI.complete(request(), server: server) end)

      assert {:unknown, :claude_cli_timeout} = Task.await(first, 10_000)
      assert {:error, :provider_queue_timeout} = Task.await(second, 10_000)
      assert length(launches(prefix)) == 1, "the expired request was launched"
    end
  end

  describe "Q0.1 re-review: launch ownership and fail-closed cleanup" do
    setup do
      prefix =
        Path.join(System.tmp_dir!(), "sdr-claude-hang-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        for record <- Path.wildcard(prefix <> ".*") do
          launch = record |> File.read!() |> JSON.decode!()
          for pid <- [launch["child"], launch["root"]], os_alive?(pid), do: os_kill(pid)
          File.rm(record)
        end

        Reaper.release(ClaudeCLI.server())
      end)

      %{prefix: prefix}
    end

    # Codex re-review: the launch handoff must not release admission while
    # the launched process is live.
    test "an owner killed right after it opened a launch never releases admission while it runs" do
      root =
        Path.join(System.tmp_dir!(), "sdr-reaper-handoff-#{System.unique_integer([:positive])}")

      File.mkdir!(root)
      parent = self()
      name = :"sdr_reaper_handoff_#{System.unique_integer([:positive])}"

      # The launch is opened by the reaper itself: its OS pid is owned
      # before the owner can be killed "between" opening and handing it off.
      owner =
        spawn(fn ->
          {:ok, reaper} = Reaper.start(name)
          Reaper.track(reaper, root)

          {:ok, _port, pid} =
            Reaper.open(reaper, root, {:spawn_executable, System.find_executable("sleep")}, [
              {:args, ["60"]},
              {:cd, root}
            ])

          send(parent, {:opened, pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:opened, pid}, 5_000
      on_exit(fn -> if os_alive?(pid), do: os_kill(pid) end)

      Process.exit(owner, :kill)
      assert eventually(fn -> Reaper.lease(name) == nil end, 500), "no cleanup receipt"
      refute os_alive?(pid), "admission was released while the launched process was live"
      refute File.exists?(root)
    end

    test "a tree that cannot be stopped after a timeout holds admission closed until it is gone",
         %{prefix: prefix} do
      {:ok, server} =
        ClaudeCLI.start_link(hang_opts(prefix, timeout: 1_500, reaper: unkillable()))

      assert {:unknown, :claude_cli_timeout} = ClaudeCLI.complete(request(), server: server)
      assert [launch] = launches(prefix)
      assert os_alive?(launch["root"])

      assert {:error, :provider_not_quiescent} = ClaudeCLI.complete(request(), server: server)
      assert length(launches(prefix)) == 1, "a call was admitted while the old tree ran"

      os_kill(launch["child"])
      os_kill(launch["root"])
      assert eventually(fn -> not os_alive?(launch["root"]) end, 250)

      assert {:unknown, :claude_cli_timeout} = ClaudeCLI.complete(request(), server: server)
      assert length(launches(prefix)) == 2
    end

    test "a reaper that cannot stop a dead server's tree keeps the replacement closed",
         %{prefix: prefix} do
      server =
        start_supervised!({ClaudeCLI, hang_opts(prefix, timeout: 30_000, reaper: unkillable())})

      caller = Task.async(fn -> catch_exit(ClaudeCLI.complete(request(), [])) end)
      launch = await_launch!(prefix)

      Process.exit(server, :kill)
      assert {:killed, _} = Task.await(caller, 10_000)
      replacement = await_replacement!(server)

      assert {:error, :provider_not_quiescent} = ClaudeCLI.complete(request(), [])
      assert length(launches(prefix)) == 1
      assert %{admission: :blocked} = ClaudeCLI.admission()

      os_kill(launch["child"])
      os_kill(launch["root"])

      assert eventually(fn -> ClaudeCLI.admission() == %{admission: :open} end, 500),
             "admission stayed closed after the old tree was gone"

      assert Process.alive?(replacement)
    end

    test "a reaper and server that both die leave admission closed until an operator releases it",
         %{prefix: prefix} do
      server = start_supervised!({ClaudeCLI, hang_opts(prefix, timeout: 30_000)})
      caller = Task.async(fn -> catch_exit(ClaudeCLI.complete(request(), [])) end)
      launch = await_launch!(prefix)
      reaper = reaper_of(server, [caller.pid])

      Process.exit(reaper, :kill)
      Process.exit(server, :kill)
      Task.await(caller, 10_000)
      await_replacement!(server)

      assert {:error, :provider_not_quiescent} = ClaudeCLI.complete(request(), [])
      assert length(launches(prefix)) == 1, "a call was admitted without a cleanup receipt"
      assert %{admission: :blocked} = ClaudeCLI.admission()

      # The operator confirms the old CLI is gone, then releases.
      os_kill(launch["child"])
      os_kill(launch["root"])
      assert eventually(fn -> not os_alive?(launch["root"]) end, 250)
      assert :ok = Reaper.release(ClaudeCLI.server())

      assert eventually(fn -> ClaudeCLI.admission() == %{admission: :open} end, 250)
    end

    test "a reaper lost while the server is idle is replaced without closing admission" do
      server = start_supervised!({ClaudeCLI, named_opts("ready")})
      reaper = reaper_of(server)

      Process.exit(reaper, :kill)
      assert eventually(fn -> reaper_of(server) not in [nil, reaper] end, 250)

      assert {:ok, _} = ClaudeCLI.complete(request(), [])
      assert Process.alive?(server)
    end

    test "an already expired deadline is refused unlaunched; a sub-second timeout is rejected",
         %{prefix: prefix} do
      assert {:error, {:invalid_timeout, 1}} =
               GenServer.start(
                 ClaudeCLI,
                 prefix |> hang_opts(timeout: 1) |> Keyword.delete(:name)
               )

      {:ok, server} =
        prefix |> hang_opts(timeout: 1_000) |> Keyword.delete(:name) |> ClaudeCLI.start_link()

      # White-box: requests enqueued exactly at, and long before, their
      # deadline (the message complete/2 sends).
      now = System.monotonic_time(:millisecond)

      for enqueued_at <- [now - 1_000, now - 60_000] do
        assert {:error, :provider_queue_timeout} =
                 GenServer.call(server, {:complete, request(), enqueued_at})
      end

      Process.sleep(300)
      assert launches(prefix) == []
    end
  end

  defp unkillable,
    do: [signal: fn _pid, _signal -> :ok end, exit_wait_ms: 200, retry_ms: 100]

  # The server monitors its reaper (and, during a call, its caller).
  defp reaper_of(server, callers \\ []) do
    case Process.info(server, :monitors) do
      {:monitors, monitors} ->
        Enum.find(
          for({:process, pid} when is_pid(pid) <- monitors, do: pid),
          &(&1 not in callers)
        )

      nil ->
        nil
    end
  end

  defp hang_opts(prefix, opts) do
    Keyword.merge(
      [
        name: ClaudeCLI.server(),
        command: System.find_executable("elixir"),
        command_args: [@fake, "hang", prefix]
      ],
      opts
    )
  end

  defp launches(prefix),
    do:
      prefix
      |> Kernel.<>(".*")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))

  defp await_launch!(prefix) do
    assert eventually(fn -> launches(prefix) != [] end, 500), "the CLI never launched"
    [launch | _] = launches(prefix)
    launch
  end

  defp await_replacement!(old) do
    assert eventually(
             fn ->
               case GenServer.whereis(ClaudeCLI.server()) do
                 pid when is_pid(pid) -> pid != old
                 _ -> false
               end
             end,
             500
           )

    GenServer.whereis(ClaudeCLI.server())
  end

  # A launch's port is owned by the server's reaper (a process it monitors).
  defp launching?(server) do
    case Process.info(server, :monitors) do
      {:monitors, monitors} ->
        Enum.any?(monitors, fn
          {:process, pid} when is_pid(pid) -> port_linked?(pid)
          _ -> false
        end)

      nil ->
        false
    end
  end

  defp port_linked?(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.any?(links, &is_port/1)
      nil -> false
    end
  end

  defp queued?(server, pid) do
    {:messages, messages} = Process.info(server, :messages)

    Enum.any?(messages, fn
      {:"$gen_call", {^pid, _tag}, _request} -> true
      _ -> false
    end)
  end

  # A process counts as alive unless it is gone or a zombie.
  defp os_alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> String.trim(stat) != "" and not String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  defp os_kill(pid),
    do: System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

  defp named_opts(mode) do
    [
      name: ClaudeCLI.server(),
      command: System.find_executable("elixir"),
      command_args: [@fake, mode]
    ]
  end

  test "Codex app-server is retained fail-closed" do
    assert {:error, :codex_app_server_disabled} = CodexAppServer.prepare(request(), [])
    assert {:error, :codex_app_server_disabled} = CodexAppServer.complete(request(), [])
  end

  @tag :external
  @tag timeout: 180_000
  test "real Claude CLI smoke attests the resolved opus model and no capabilities" do
    {:ok, server} = ClaudeCLI.start_link([])
    assert {:ok, result} = ClaudeCLI.complete(request(), server: server)
    assert result.model == "claude-opus-5-5"
  end

  describe "S12b witness propagation (child environment only)" do
    setup do
      dump = Path.join(System.tmp_dir!(), "sdr-claude-env-#{System.unique_integer([:positive])}")
      on_exit(fn -> dump |> dumps() |> Enum.each(&File.rm/1) end)
      %{dump: dump}
    end

    test "passes the invocation UUID and traceparent to the child, nothing global", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      before = System.get_env()
      witness = witness()

      assert {:ok, _result} = ClaudeCLI.complete(request(witness), server: server)
      assert [child] = read_dumps(dump)
      assert child["SDR_MODEL_INVOCATION_ID"] == witness.model_invocation_id
      assert child["SDR_TRACEPARENT"] == witness.traceparent
      assert System.get_env() == before
      assert System.get_env("SDR_MODEL_INVOCATION_ID") == nil
      assert System.get_env("SDR_TRACEPARENT") == nil
    end

    test "the caller's W3C sampling flag is forwarded as given (00 or 01)", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      sampled = witness()

      unsampled = %{
        witness()
        | traceparent: String.replace_suffix(witness().traceparent, "-01", "-00")
      }

      assert {:ok, _} = ClaudeCLI.complete(request(sampled), server: server)
      assert {:ok, _} = ClaudeCLI.complete(request(unsampled), server: server)
      assert [one, two] = read_dumps(dump)
      assert one["SDR_TRACEPARENT"] == sampled.traceparent
      assert two["SDR_TRACEPARENT"] == unsampled.traceparent
      assert String.ends_with?(two["SDR_TRACEPARENT"], "-00")
    end

    test "two serial calls carry their own distinct ids and contexts", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      first = witness()
      second = witness()

      assert {:ok, _} = ClaudeCLI.complete(request(first), server: server)
      assert {:ok, _} = ClaudeCLI.complete(request(second), server: server)

      assert [one, two] = read_dumps(dump)

      assert {one["SDR_MODEL_INVOCATION_ID"], one["SDR_TRACEPARENT"]} ==
               {first.model_invocation_id, first.traceparent}

      assert {two["SDR_MODEL_INVOCATION_ID"], two["SDR_TRACEPARENT"]} ==
               {second.model_invocation_id, second.traceparent}
    end

    test "concurrent callers are serialized through one CLI at a time", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump, "300"])

      [witness(), witness()]
      |> Enum.map(fn witness ->
        Task.async(fn -> ClaudeCLI.complete(request(witness), server: server) end)
      end)
      |> Task.await_many(30_000)
      |> Enum.each(&assert({:ok, _} = &1))

      assert [one, two] = read_dumps(dump)
      assert one["finished_us"] <= two["started_us"], "CLI launches overlapped"
    end

    test "Bedrock/Vertex/Foundry routing is scrubbed from the child environment",
         %{dump: dump} do
      bypass = %{
        "CLAUDE_CODE_USE_BEDROCK" => "1",
        "CLAUDE_CODE_USE_VERTEX" => "1",
        "CLAUDE_CODE_USE_FOUNDRY" => "1",
        "ANTHROPIC_BEDROCK_BASE_URL" => "https://bedrock.example.invalid",
        "ANTHROPIC_VERTEX_BASE_URL" => "https://vertex.example.invalid",
        "ANTHROPIC_FOUNDRY_BASE_URL" => "https://foundry.example.invalid"
      }

      # The inherited OS environment carries the bypass; the refusal check is
      # given a clean view so this test isolates the child-env scrub itself.
      {:ok, server} = start_server("env_dump", [dump], environment: %{})
      Enum.each(bypass, fn {name, value} -> System.put_env(name, value) end)

      try do
        assert {:ok, _} = ClaudeCLI.complete(request(), server: server)
      after
        Enum.each(Map.keys(bypass), &System.delete_env/1)
      end

      assert [child] = read_dumps(dump)
      for name <- Map.keys(bypass), do: assert(child[name] == nil, "#{name} reached the CLI")
    end

    test "an enabled bypass route in the environment refuses before launch", %{dump: dump} do
      for {name, value} <- [
            {"CLAUDE_CODE_USE_BEDROCK", "1"},
            {"CLAUDE_CODE_USE_VERTEX", "true"},
            {"CLAUDE_CODE_USE_FOUNDRY", "1"},
            {"ANTHROPIC_BEDROCK_BASE_URL", "https://bedrock.example.invalid"},
            {"ANTHROPIC_VERTEX_BASE_URL", "https://vertex.example.invalid"},
            {"ANTHROPIC_FOUNDRY_BASE_URL", "https://foundry.example.invalid"}
          ] do
        {:ok, server} = start_server("env_dump", [dump], environment: %{name => value})

        assert match?(
                 {:error, :witness_bypass_environment},
                 ClaudeCLI.complete(request(), server: server)
               ),
               name
      end

      assert read_dumps(dump) == []
    end

    test "missing or malformed witness context refuses before launch", %{dump: dump} do
      {:ok, server} = start_server("env_dump", [dump])
      good = witness()

      for witness <- [
            nil,
            %{good | model_invocation_id: String.upcase(good.model_invocation_id)},
            %{good | model_invocation_id: "../../etc/passwd"},
            %{good | model_invocation_id: good.model_invocation_id <> "\nx-evil: 1"},
            %{good | traceparent: "00-" <> String.duplicate("0", 32) <> "-0123456789abcdef-01"},
            %{
              good
              | traceparent:
                  "00-0123456789abcdef0123456789abcdef-" <> String.duplicate("0", 16) <> "-01"
            },
            %{good | traceparent: "ff-0123456789abcdef0123456789abcdef-0123456789abcdef-01"},
            %{good | traceparent: String.upcase(good.traceparent)},
            %{good | traceparent: good.traceparent <> "\ntracestate: x"}
          ] do
        assert match?(
                 {:error, :invalid_witness_context},
                 ClaudeCLI.complete(request(witness), server: server)
               ),
               inspect(witness)
      end

      assert read_dumps(dump) == []
    end

    test "init attestation is unchanged when witness context is present" do
      for {mode, expected} <- [
            {"missing_init", :missing_init_attestation},
            {"model_drift", :model_attestation_drift},
            {"version_drift", :version_attestation_drift},
            {"tool_drift", :tool_attestation_drift}
          ] do
        {:ok, server} = start_server(mode)
        assert {:error, ^expected} = ClaudeCLI.complete(request(witness()), server: server)
      end
    end
  end

  defp dumps(dump), do: Path.wildcard(dump <> ".*")

  defp read_dumps(dump) do
    dump
    |> dumps()
    |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))
    |> Enum.sort_by(& &1["started_us"])
  end

  defp witness do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    %{model_invocation_id: Ash.UUIDv7.generate(), traceparent: "00-#{trace}-#{span}-01"}
  end

  defp start_server(mode, extra_args \\ [], opts \\ []) do
    ClaudeCLI.start_link(
      Keyword.merge(
        [
          command: System.find_executable("elixir"),
          command_args: [@fake, mode | extra_args]
        ],
        opts
      )
    )
  end

  defp request(witness \\ witness()) do
    %{
      id: "claude-test",
      operation: "model.complete",
      prompt: "qualify",
      schema: @schema,
      witness: witness
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
