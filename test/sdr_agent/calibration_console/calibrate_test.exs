defmodule SdrAgent.CalibrationConsole.CalibrateTest do
  @moduledoc """
  R0-07 slice E, sub-slice d3c part 3: the `calibrate` orchestration
  (packet 8.14.1, 8.14.4, 8.14.8 and 8.14.9; entity PASS at 125102e and
  623e7db). Rows driven by existing seams only; the rows that need the
  ordering hook (4b, 5, 7, 8) follow its exact-head recheck.

  Hermetic: no real model call. The private server runs a stand-in command
  (a shell CLI, or the fake CLI playing shim and proxy store) under a
  synthetic pinned executable. Every assertion reads the record on disk,
  the committed rows and the evidence directory, never only the command's
  return value.
  """
  use SdrAgent.AuditCase, async: false

  defmodule ConsoleProbe do
    @moduledoc "The real ProcessProbe, except for a group answer set per test."
    use Agent

    alias SdrAgent.CalibrationConsole.ProcessProbe

    def start_link(_), do: Agent.start_link(fn -> :real end, name: __MODULE__)

    # `{:plus, pid}`: the real group plus a phantom member that never exits.
    def put(group), do: Agent.update(__MODULE__, fn _ -> group end)

    def self_pid, do: ProcessProbe.self_pid()
    def start_identity(pid), do: ProcessProbe.start_identity(pid)

    def group_members(pgid) do
      case Agent.get(__MODULE__, & &1) do
        :real ->
          ProcessProbe.group_members(pgid)

        {:plus, extra} ->
          with {:ok, members} <- ProcessProbe.group_members(pgid),
               do: {:ok, members ++ [extra]}
      end
    end
  end

  defmodule LaunchProbe do
    @moduledoc """
    The d3a launch-receipt probe (`:calibration_launch_probe`): the real
    ProcessProbe (`:real`), a root that reads as already gone
    (`:identity_absent`: an unverified receipt), or the real probe that
    then leaves a phantom member in the console probe's group
    (`:then_phantom`: quiescence is never established after the call).
    """
    use Agent

    alias SdrAgent.CalibrationConsole.ProcessProbe

    def start_link(_), do: Agent.start_link(fn -> :real end, name: __MODULE__)
    def put(mode), do: Agent.update(__MODULE__, fn _ -> mode end)

    def start_identity(pid) do
      case Agent.get(__MODULE__, & &1) do
        :identity_absent ->
          :absent

        :then_phantom ->
          ConsoleProbe.put({:plus, 999_999})
          ProcessProbe.start_identity(pid)

        :real ->
          ProcessProbe.start_identity(pid)
      end
    end

    def group_members(pgid), do: ProcessProbe.group_members(pgid)
  end

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.CalibrationConsole.Authority
  alias SdrAgent.CalibrationConsole.Calibrate
  alias SdrAgent.CalibrationConsole.Evidence
  alias SdrAgent.CalibrationConsole.LaunchRecord
  alias SdrAgent.CalibrationConsole.ProcessProbe
  alias SdrAgent.CalibrationConsole.Prompt
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Test.PinnedCLI

  @moduletag :tmp_dir
  @profile :claude_cli_opus
  @typed "CALIBRATE claude_cli_opus"
  @v3 "claude-message-json/3+prompt-builder/1"
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)

  setup %{tmp_dir: tmp} do
    start_supervised!(ConsoleProbe)
    start_supervised!(LaunchProbe)
    start_supervised!(Authority)
    %{root: store} = AdmissionFixtures.admit_tuples!()
    tenant = bootstrap!()
    g_r0!(tenant)

    previous = Application.get_env(:sdr_agent, :calibration_launch_probe)
    Application.put_env(:sdr_agent, :calibration_launch_probe, LaunchProbe)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sdr_agent, :calibration_launch_probe, previous),
        else: Application.delete_env(:sdr_agent, :calibration_launch_probe)
    end)

    # The synthetic pin: a harmless executable under a stand-in store.
    pins = Path.join(tmp, "pins")
    bin = Path.join([pins, String.duplicate("a", 32) <> "-app-claude-cli-2.1.294", "bin"])
    File.mkdir_p!(bin)
    executable = Path.join(bin, "claude-code")
    File.write!(executable, "#!/bin/sh\nexit 1\n")
    File.chmod!(executable, 0o555)
    PinnedCLI.inject_identity!(executable, store: pins)

    ran = Path.join(tmp, "ran")
    root = private_dir!(tmp, "launch")
    evidence = private_dir!(tmp, "evidence")

    ctx = %{
      tenant: tenant,
      store: store,
      executable: executable,
      ran: ran,
      root: root,
      evidence: evidence,
      tmp: tmp
    }

    # After every fixture: a missing command fails as an assertion.
    assert Code.ensure_loaded?(Calibrate), "SdrAgent.CalibrationConsole.Calibrate is not defined"
    assert function_exported?(Calibrate, :run, 2), "Calibrate.run/2 is not defined"

    Map.put(ctx, :cli, shell_cli!(ctx, 1))
  end

  ## Row 1: the claim

  describe "row 1: the claim" do
    test "a live claim refuses; nothing is created and the held record is untouched", ctx do
      {:ok, held} = LaunchRecord.claim(ctx.root, probe: ProcessProbe)
      before = counts(ctx)

      assert {:stop, :calibration_in_progress, summary} = run(ctx)
      assert summary.record == :none
      assert LaunchRecord.read(ctx.root) == {:ok, held}
      assert counts(ctx) == before
      refute File.exists?(ctx.ran), "the CLI ran"
      refute_received {:confirm, _prompt}
    end

    test "an unsafe root refuses before anything is created", ctx do
      File.chmod!(ctx.root, 0o755)
      before = counts(ctx)

      assert {:stop, :launch_record_unsafe, %{record: :none}} = run(ctx)
      assert counts(ctx) == before
      refute File.exists?(Path.join(ctx.root, "run.lock"))
    end
  end

  ## Row 2: preflight refusals (aborted, then released)

  describe "row 2: preflight" do
    for {name, line} <- [
          declined: "no",
          mistyped: "calibrate claude_cli_opus",
          other_profile: "CALIBRATE claude_cli_sonnet",
          blank: ""
        ] do
      test "a #{name} confirmation aborts and releases; no run, no reservation", ctx do
        before = counts(ctx)

        assert {:stop, :calibration_not_confirmed, summary} =
                 run(ctx, confirm: confirm(unquote(line)))

        assert summary.record == :released
        assert_received {:confirm, prompt}
        assert prompt =~ @typed
        assert released?(ctx)
        assert counts(ctx) == before
        refute File.exists?(ctx.ran), "the CLI ran"
      end
    end

    test "no G-R0 aborts and releases", ctx do
      # A tenant with no grant (the bootstrap tenant is a singleton).
      before = counts(ctx)

      assert {:stop, :calibration_grant_unavailable, %{record: :released}} =
               run(ctx, tenant_id: Ash.UUIDv7.generate())

      assert released?(ctx)
      assert counts(ctx) == before
    end

    test "an untrusted witness store aborts and releases", ctx do
      AdmissionFixtures.admit_tuples!(root: Path.join(ctx.tmp, "no-store"))
      before = counts(ctx)

      assert {:stop, :witness_store_untrusted, %{record: :released}} = run(ctx)
      assert released?(ctx)
      assert counts(ctx) == before
    end

    test "a pin that fails its check aborts and releases", ctx do
      PinnedCLI.inject_identity!(ctx.executable,
        store: Path.join(ctx.tmp, "pins"),
        sha256: String.duplicate("0", 64)
      )

      before = counts(ctx)

      assert {:stop, :pinned_cli_unavailable, %{record: :released}} = run(ctx)
      assert released?(ctx)
      assert counts(ctx) == before
    end

    test "unavailable isolation aborts and releases", ctx do
      before = counts(ctx)

      assert {:stop, :calibration_isolation_unavailable, %{record: :released}} =
               run(ctx, isolation: [target: "printf ready"])

      assert released?(ctx)
      assert counts(ctx) == before
    end
  end

  ## Row 3: an unconfirmed isolation cleanup is a hard owner conflict

  test "row 3: unconfirmed isolation cleanup keeps the claim; no reservation", ctx do
    ConsoleProbe.put({:plus, 999_999})
    before = counts(ctx)

    assert {:stop, :calibration_isolation_cleanup_unconfirmed, summary} = run(ctx)
    assert summary.record == {:kept, "claimed"}
    assert {:ok, %{state: "claimed"}} = LaunchRecord.read(ctx.root)
    assert counts(ctx) == before
    refute File.exists?(ctx.ran), "the CLI ran"
  end

  ## Row 6: the launch_pending write fails

  test "row 6: a failed launch_pending write keeps the claim; the reservation is bound", ctx do
    assert {:stop, :launch_record_write_failed, summary} =
             run(ctx, record: [replace: fail_writing("launch_pending")])

    assert summary.record == {:kept, "claimed"}
    assert {:ok, %{state: "claimed", instance_id: claim}} = LaunchRecord.read(ctx.root)
    assert %ModelInvocation{status: :reserved, sent_at: nil} = invocation!(summary.invocation_id)
    assert reserved_claim(ctx, summary.invocation_id) == claim
    refute File.exists?(ctx.ran), "the CLI ran"
    assert unconsumed_entries() == 0
  end

  ## Rows 9 and 11: the normal path

  describe "rows 9 and 11: the normal path" do
    test "an uncaptured call finishes: missing, evidence latched, run latched, released", ctx do
      unrelated = make_ref()
      send(self(), {:unrelated, unrelated})

      assert {:ok, summary} = run(ctx)
      assert summary.record == :released
      assert summary.outcome == "missing"
      assert released?(ctx)

      invocation = invocation!(summary.invocation_id)
      assert invocation.status == :completed
      assert launches(ctx) == 1
      assert_latched(ctx, invocation, summary)

      # Unrelated mailbox traffic is kept; this protocol's receipts are gone.
      assert_received {:unrelated, ^unrelated}
      refute_received {:calibration_launched, _ref, _receipt}
      refute_received {:calibration_launch_unverified, _ref, _receipt}
      assert unconsumed_entries() == 0
    end

    test "a captured exchange under the candidate is a match", ctx do
      cli = witness_cli!(ctx, "cli_shape_v3")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "match"

      invocation = invocation!(summary.invocation_id)
      document = assert_latched(ctx, invocation, summary)
      assert [%{id: link_id}] = document["links"]
      assert document["evaluated_projection_version"] == @v3
      assert document["evaluated_method"] == "propagated_id"
      assert is_binary(link_id)
    end

    test "a stale or foreign receipt in the mailbox is ignored", ctx do
      LaunchProbe.put(:identity_absent)

      forged = %{
        invocation_id: Ash.UUIDv7.generate(),
        root_pid: 1,
        root_identity: "forged",
        process_group_id: 1,
        server: self()
      }

      send(self(), {:calibration_launched, make_ref(), forged})

      # The real receipt is unverified: the forged one never makes the
      # record launched.
      assert {:stop, :calibration_launch_unverified, summary} = run(ctx)
      assert summary.record == {:kept, "launch_pending"}
    end

    test "every record write is made by the command process", ctx do
      test = self()

      writes = fn temp, final ->
        send(test, {:record_write, self(), File.read!(temp)})
        File.rename(temp, final)
      end

      assert {:ok, _summary} = run(ctx, record: [replace: writes])
      writers = collect_writes()
      assert writers != []
      assert Enum.all?(writers, fn {pid, _bytes} -> pid == test end)
    end
  end

  ## Row 10: sent, but the launch was never verified

  test "row 10: an unverified receipt keeps launch_pending; no evidence, no latch", ctx do
    LaunchProbe.put(:identity_absent)

    assert {:stop, :calibration_launch_unverified, summary} = run(ctx)
    assert summary.record == {:kept, "launch_pending"}
    assert {:ok, %{state: "launch_pending"}} = LaunchRecord.read(ctx.root)

    invocation = invocation!(summary.invocation_id)
    refute is_nil(invocation.sent_at)
    assert File.ls!(ctx.evidence) == []
    assert releases(invocation) == []
    assert launches(ctx) == 1
    assert unconsumed_entries() == 0
  end

  ## Row 12: no quiescence

  test "row 12: quiescence not established keeps launched; no evidence, no latch", ctx do
    LaunchProbe.put(:then_phantom)

    assert {:stop, :calibration_not_quiescent, summary} = run(ctx)
    assert summary.record == {:kept, "launched"}
    assert {:ok, %{state: "launched"}} = LaunchRecord.read(ctx.root)
    assert File.ls!(ctx.evidence) == []
    assert releases(invocation!(summary.invocation_id)) == []
  end

  ## Row 13: evidence, E1, finished and release failures

  describe "row 13" do
    test "an unsafe evidence directory stops before any latch", ctx do
      File.chmod!(ctx.evidence, 0o755)

      assert {:stop, :evidence_dir_unsafe, summary} = run(ctx)
      assert summary.record == {:kept, "launched"}
      assert releases(invocation!(summary.invocation_id)) == []
      assert run_of(summary.invocation_id).status == :running
    end

    test "a failed finished write keeps launched after the latch", ctx do
      assert {:stop, :launch_record_write_failed, summary} =
               run(ctx, record: [replace: fail_writing("finished")])

      assert summary.record == {:kept, "launched"}
      invocation = invocation!(summary.invocation_id)
      assert [%ModelResultRelease{disposition: :calibration}] = releases(invocation)
      assert {:ok, %{state: "launched"}} = LaunchRecord.read(ctx.root)
    end

    test "a failed release keeps finished; nothing removed", ctx do
      assert {:stop, :launch_record_write_failed, summary} =
               run(ctx, record: [remove: fn _path -> {:error, :eio} end])

      assert summary.record == {:kept, "finished"}
      assert {:ok, %{state: "finished"}} = LaunchRecord.read(ctx.root)
    end
  end

  ## 8.14.8: the bounded observation of the actual store

  describe "8.14.8: store failures are typed receipts" do
    test "a store root removed after the call is unreadable; the document has no link", ctx do
      cli = shell_cli!(ctx, 1, "rm -rf '#{ctx.store}'")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "unreadable"
      document = assert_latched(ctx, invocation!(summary.invocation_id), summary)
      assert document["links"] == []
      assert document["inventory_sha256"] == nil
    end

    test "an actual unreadable blob: unreadable, nil projection, propagated_id, valid init",
         ctx do
      cli = witness_cli!(ctx, "cli_shape_v3", "rm -f '#{ctx.store}'/witness/sha256/*/*.json")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "unreadable"

      invocation = invocation!(summary.invocation_id)
      document = assert_latched(ctx, invocation, summary)
      assert [%{"id" => _link}] = document["links"]
      assert document["evaluated_projection_version"] == nil
      assert document["evaluated_method"] == "propagated_id"
      assert document["attested_cli_version"] == invocation.provider_version
      assert document["attested_model_id"] == invocation.model_id
    end

    test "an unreadable inventory record is unreadable", ctx do
      corrupt =
        ~s(for f in '#{ctx.store}'/witnesses/"$SDR_MODEL_INVOCATION_ID"/*.json; ) <>
          ~s(do printf 'not json' > "$f"; done)

      cli = witness_cli!(ctx, "cli_shape_v3", corrupt)

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "unreadable"
      assert_latched(ctx, invocation!(summary.invocation_id), summary)
    end

    test "a mismatch opens one critical Failure that stays open after the latch", ctx do
      cli = witness_cli!(ctx, "cli_shape_v3_mismatch")

      assert {:ok, summary} = run(ctx, server: server(ctx, cli))
      assert summary.outcome == "mismatch"

      invocation = invocation!(summary.invocation_id)
      assert_latched(ctx, invocation, summary)

      assert [%Failure{severity: :critical, status: status}] = attention(ctx, invocation)
      assert status != :resolved
      assert run_of(invocation.id).attention_failure_id == nil
      assert Enum.map(releases(invocation), & &1.disposition) == [:calibration]
    end
  end

  ## Extras (8.14.7)

  test "command death while the VM lives: another recoverer refuses :owner_alive", ctx do
    test = self()
    cli = shell_cli!(ctx, 5)

    command =
      spawn(fn ->
        send(test, {:result, run(ctx, server: server(ctx, cli))})
      end)

    assert eventually(
             fn -> match?({:ok, %{state: "launched"}}, LaunchRecord.read(ctx.root)) end,
             10_000
           )

    Process.exit(command, :kill)

    assert LaunchRecord.recover(ctx.root, probe: ProcessProbe) == {:error, :owner_alive}
  end

  ## Fixtures

  defp run(ctx, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          tenant_id: ctx.tenant.id,
          root: ctx.root,
          evidence_dir: ctx.evidence,
          confirm: confirm(@typed),
          probe: ConsoleProbe,
          server: server(ctx, ctx.cli),
          isolation: [],
          record: []
        ],
        overrides
      )

    AdmissionFixtures.admitting(fn -> Calibrate.run(@profile, opts) end)
  end

  defp server(ctx, command),
    do: [command: command, executable: ctx.executable, environment: %{}]

  # The confirmation reader: reports the prompt it was shown, answers `line`.
  defp confirm(line) do
    test = self()

    fn prompt ->
      send(test, {:confirm, prompt})
      line
    end
  end

  # A stand-in CLI: reads the prompt, stays alive `delay` seconds (to be
  # probed), answers in the calibration schema, then runs `after`.
  defp shell_cli!(ctx, delay, after_script \\ "") do
    path = Path.join(ctx.tmp, "cli-#{System.unique_integer([:positive])}")

    init =
      ~s({"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"2.1.294","tools":[],"mcp_servers":[],"slash_commands":[]})

    result =
      ~s({"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"blue\\",\\"confidence\\":0.9}","usage":{"input_tokens":1,"output_tokens":1}})

    File.write!(path, """
    #!/bin/sh
    echo run >> '#{ctx.ran}'
    cat > /dev/null
    sleep #{delay}
    #{after_script}
    printf '%s\\n' '#{init}'
    printf '%s\\n' '#{result}'
    """)

    File.chmod!(path, 0o555)
    path
  end

  # The fake CLI playing shim and proxy store for one call: it captures the
  # exchange of `variant` under the propagated invocation id, then runs
  # `after` (an actual store fault made after capture).
  defp witness_cli!(ctx, variant, after_script \\ "") do
    path = Path.join(ctx.tmp, "witness-cli-#{System.unique_integer([:positive])}")
    elixir = System.find_executable("elixir")

    File.write!(path, """
    #!/bin/sh
    echo run >> '#{ctx.ran}'
    out=$('#{elixir}' '#{@fake}' witness '#{ctx.store}' #{variant} calibration "$@")
    status=$?
    #{after_script}
    printf '%s\\n' "$out"
    exit $status
    """)

    File.chmod!(path, 0o555)
    path
  end

  defp private_dir!(tmp, name) do
    path = Path.join(tmp, name)
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  # Creates the tenant's one G-R0 grant, valid around the real clock (the
  # private server reads it in its own process).
  defp g_r0!(tenant) do
    now = DateTime.utc_now()

    AgentsFixtures.grant!(tenant, %{
      name: "G-R0",
      profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
      total_attempts: 4,
      starts_at: DateTime.add(now, -1, :day),
      expires_at: DateTime.add(now, 5, :day),
      allocations: [
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_opus},
        %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
      ]
    })
  end

  # A record write that fails exactly when it would write `state`.
  defp fail_writing(state) do
    fn temp, final ->
      if File.read!(temp) =~ ~s("state":"#{state}"),
        do: {:error, :eio},
        else: File.rename(temp, final)
    end
  end

  defp collect_writes do
    receive do
      {:record_write, pid, bytes} -> [{pid, bytes} | collect_writes()]
    after
      0 -> []
    end
  end

  # The document is published, validated against the committed rows, and
  # its hash is the one the `:calibration` latch carries; the run is
  # latched. Returns the decoded document.
  defp assert_latched(ctx, invocation, summary) do
    agent = system_actor(:agent_runtime, ctx.tenant)
    %{path: path, sha256: sha} = summary.evidence

    target = %{
      invocation_id: invocation.id,
      run_id: invocation.agent_run_id,
      tenant_id: ctx.tenant.id,
      profile_id: @profile
    }

    assert {:ok, _validated} = Evidence.validate(path, target, actor: agent)
    bytes = File.read!(path)
    assert sha == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert [%ModelResultRelease{disposition: :calibration, evidence_sha256: ^sha}] =
             releases(invocation)

    run = run_of(invocation.id)
    assert {run.status, run.status_reason} == {:succeeded, :calibration_latched}
    refute bytes =~ Prompt.render()
    Jason.decode!(bytes)
  end

  defp released?(ctx), do: LaunchRecord.read(ctx.root) == {:ok, :none}

  defp counts(ctx) do
    {count(AgentRun, ctx.tenant), count(ModelInvocation, ctx.tenant)}
  end

  defp count(resource, tenant) do
    resource
    |> Ash.Query.filter(tenant_id == ^tenant.id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp invocation!(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  defp run_of(invocation_id),
    do: Ash.get!(AgentRun, invocation!(invocation_id).agent_run_id, authorize?: false)

  defp releases(invocation) do
    ModelResultRelease
    |> Ash.Query.filter(model_invocation_id == ^invocation.id)
    |> Ash.read!(authorize?: false)
  end

  defp attention(ctx, invocation) do
    Failure
    |> Ash.read!(SdrAgent.Audit.Kernel.opts(ctx.tenant.id))
    |> Enum.filter(&(&1.subject_id == invocation.id))
  end

  # The claim the invocation's original reservation event recorded.
  defp reserved_claim(ctx, invocation_id) do
    [event] =
      ctx.tenant
      |> events_of_type("model.invocation.reserved")
      |> Enum.filter(&(&1.subject_id == invocation_id))

    get_in(event.payload, ["arguments", "calibration_claim", "instance_id"])
  end

  defp launches(ctx) do
    case File.read(ctx.ran) do
      {:ok, lines} -> lines |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  defp unconsumed_entries do
    Authority.table()
    |> :ets.tab2list()
    |> Enum.count(&match?({_key, _binding, :unconsumed}, &1))
  end

  defp eventually(check, within) do
    until = System.monotonic_time(:millisecond) + within

    Stream.repeatedly(fn -> check.() || (Process.sleep(25) && false) end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > until end)
    |> Kernel.==(true)
  end
end
