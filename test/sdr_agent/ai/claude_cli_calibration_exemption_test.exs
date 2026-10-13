defmodule SdrAgent.AI.ClaudeCLICalibrationExemptionTest do
  @moduledoc """
  R0-07 slice E, sub-slice d1b (packet 8.13, entity PASS at b77426a): the
  staging exemption of a private ClaudeCLI server, in test-seam builds.

    * **A** (`staged/1`, before the call's own process exists): a private,
      unnamed server; a closed `request.calibration`; the code-owned
      calibration prompt and schema; observed claims; one consume of the
      sealed authority entry. Every failure is `:real_model_staged` and
      leaves the entry unconsumed.
    * **C** (the locked launch transaction, `calibration_launch:`): the
      target's actual run and tenant (identity refusal, no mutation), the
      proof/no-Operation scope, the fixed refs and the stored request
      (the existing receipt), and a required G-R0 binding.
    * Admission never stops the run, and a refused launch never opens the
      port.

  Refusal tests launch nothing: the server's command is a tripwire script
  that leaves a marker if it ever runs. The positive test needs the real
  `llm-proxy-shim` and a pinned stand-in, and is skipped (never claimed)
  where the shim is not installed.
  """
  use SdrAgent.AuditCase, async: false

  defmodule ProbeStub do
    @moduledoc "d3a: a ProcessProbe stand-in whose answers are set per test."

    def mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)

    # Tells the test which root is being probed, when it asked to know.
    def watch(test), do: :persistent_term.put({__MODULE__, :test}, test)

    defp notify(pid) do
      case :persistent_term.get({__MODULE__, :test}, nil) do
        nil -> :ok
        test -> send(test, {:probing, pid, self()})
      end
    end

    defp mode, do: :persistent_term.get({__MODULE__, :mode})

    def start_identity(pid) do
      notify(pid)
      identity(mode(), pid)
    end

    defp identity(:identity_absent, _pid), do: :absent
    defp identity(:identity_error, _pid), do: {:error, :ps_failed}
    defp identity(:identity_empty, _pid), do: {:ok, ""}
    defp identity(:identity_not_binary, _pid), do: {:ok, 123}
    defp identity(:probe_raises, _pid), do: raise("probe failure")
    defp identity(:slow, _pid), do: Process.sleep(2_200) && {:error, :ps_failed}
    defp identity(:hung, _pid), do: Process.sleep(:infinity)
    defp identity(:probe_exits, _pid), do: exit(:probe_crashed)
    defp identity(:probe_killed, _pid), do: Process.exit(self(), :kill)
    defp identity(_mode, pid), do: {:ok, "Tue Oct 13 12:00:00 2026 #{pid}"}

    def group_members(pgid) do
      case mode() do
        :group_error -> {:error, :ps_failed}
        :root_not_in_group -> {:ok, [pgid + 1]}
        :member_not_a_pid -> {:ok, [pgid, "x"]}
        :slow_group -> Process.sleep(2_200) && {:ok, [pgid]}
        :hung_group -> Process.sleep(:infinity)
        :group_not_a_list -> {:ok, :members}
        _other -> {:ok, [pgid]}
      end
    end
  end

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.Checks.CalibrationAdmission
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.JsonSchema
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.Audit.Canonical
  alias SdrAgent.CalibrationConsole.Authority
  alias SdrAgent.CalibrationConsole.Prompt
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Test.PinnedCLI

  @now ~U[2026-10-15 12:00:00.000000Z]
  @shim System.find_executable("llm-proxy-shim")
  @capability ~s({"proxy_version":"0.0.0-test","strips":["traceparent","tracestate","x-sdr-model-invocation-id"],"witness_schema":1})

  setup do
    assert Code.ensure_loaded?(Authority), "SdrAgent.CalibrationConsole.Authority is not defined"
    AdmissionFixtures.admit_tuples!()
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    start_supervised!(Authority)

    suffix = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "sdr-d1b-#{suffix}")
    store = Path.join(dir, "store")
    bin = Path.join([store, String.duplicate("a", 32) <> "-app-claude-cli-2.1.294", "bin"])
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(dir) end)

    records = %{stdin: Path.join(dir, "stdin"), tripped: Path.join(dir, "tripped")}
    stand_in = stand_in!(bin, records.stdin)
    tripwire = tripwire!(dir, records.tripped)
    PinnedCLI.inject_identity!(stand_in, store: store)

    %{tenant: tenant, stand_in: stand_in, tripwire: tripwire, records: records}
  end

  ## A: before consumption (staged, entry unconsumed, nothing launched)

  describe "A: the private server" do
    for {label, name} <- [
          runtime: :runtime,
          local: :local,
          global: :global,
          via: :via
        ] do
      test "a #{label}-named server stays staged with a valid entry", ctx do
        if unquote(name) == :via,
          do: start_supervised!({Registry, keys: :unique, name: __MODULE__.Names})

        server = server!(ctx, name: name_for(unquote(name)))
        %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
        ref = issue!(server, invocation, run)

        assert complete(server, request(invocation, run, agent, ref)) ==
                 {:error, :real_model_staged}

        assert_untouched(ctx, ref, invocation)
      end
    end
  end

  describe "A: the closed calibration value and the request" do
    for variant <- [
          :absent,
          :nil_value,
          :missing_key,
          :extra_key,
          :bad_run_id,
          :forged_authority,
          :bad_instance,
          :missing_witness,
          :missing_observer,
          :observer_not_a_pair,
          :observer_bad_pid,
          :observer_bad_ref,
          :missing_traceparent,
          :bad_traceparent,
          :zero_trace_id,
          :zero_span_id,
          :bad_flags,
          :unrenderable_schema
        ] do
      test "#{variant} is staged before consumption", ctx do
        server = server!(ctx)
        %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
        ref = issue!(server, invocation, run)
        request = invocation |> request(run, agent, ref) |> malform(unquote(variant))

        assert complete(server, request) == {:error, :real_model_staged}
        assert Process.alive?(server)
        assert_untouched(ctx, ref, invocation)
      end
    end
  end

  describe "A: fixed, server-owned input" do
    test "a custom prompt is staged even when its hash was registered", ctx do
      server = server!(ctx)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      custom = "A custom calibration prompt."

      ref =
        issue!(server, invocation, run, %{prompt_sha256: lower_hex(:crypto.hash(:sha256, custom))})

      request = %{request(invocation, run, agent, ref) | prompt: custom}

      assert complete(server, request) == {:error, :real_model_staged}
      assert_untouched(ctx, ref, invocation)
    end

    test "a custom schema is staged even when its hash was registered", ctx do
      server = server!(ctx)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      schema = Zoi.object(%{colour: Zoi.string()})
      ref = issue!(server, invocation, run, %{schema_sha256: lower_hex(schema_sha(schema))})
      request = %{request(invocation, run, agent, ref) | schema: schema}

      assert complete(server, request) == {:error, :real_model_staged}
      assert_untouched(ctx, ref, invocation)
    end
  end

  describe "A: claims" do
    for claim <- [:caller, :server, :invocation, :run, :tenant, :profile, :instance] do
      test "a mismatched #{claim} claim is staged and leaves the entry unconsumed", ctx do
        %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
        {server, ref, request} = mismatch(ctx, unquote(claim), invocation, run, agent)

        result =
          if unquote(claim) == :caller,
            do: Task.await(Task.async(fn -> complete(server, request) end), 30_000),
            else: complete(server, request)

        assert result == {:error, :real_model_staged}
        assert_untouched(ctx, ref, invocation)
      end
    end

    test "an unavailable registry fails closed without crashing the server", ctx do
      server = server!(ctx)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      :ok = stop_supervised(Authority)

      assert complete(server, request) == {:error, :real_model_staged}

      assert Process.alive?(server)
      refute File.exists?(ctx.records.tripped)
      assert status(invocation) == :reserved
    end
  end

  ## C: the locked launch transaction (entry consumed, nothing launched)

  describe "C7: target identity" do
    test "an entry naming another run refuses without mutation", ctx do
      server = server!(ctx)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      %{run: other} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)
      ref = issue!(server, invocation, other)

      result = admitting(fn -> complete(server, request(invocation, other, agent, ref)) end)

      assert result == {:error, :calibration_target_mismatch}, inspect(result)
      assert consumed?(ref)
      refute File.exists?(ctx.records.tripped)
      assert status(invocation) == :reserved
      assert run_status(run) == :running
      assert run_status(other) == :running
      assert failures(ctx) == []

      assert [event] = launch_events(ctx, invocation)
      assert event.payload["reason"] == "calibration_target_mismatch"
      assert is_nil(event.model_invocation_id)
    end
  end

  describe "C8: exemption scope, input and request" do
    test "an ordinary run's invocation is refused :exemption_scope", ctx do
      AgentsFixtures.grant!(ctx.tenant, %{}, human(:admin, ctx.tenant))
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      {invocation, _request} = reserve!(run, agent, nil)

      assert_owned_refusal(
        ctx,
        run,
        agent,
        invocation,
        :calibration_not_authorized,
        :exemption_scope
      )
    end

    test "an operated proof run's invocation is refused :exemption_scope", ctx do
      %{run: run, agent: agent} = AgentsFixtures.operated_run(ctx.tenant, usage_origin: :proof)
      {invocation, _request} = reserve!(run, agent, marker(ctx, agent))

      assert_owned_refusal(
        ctx,
        run,
        agent,
        invocation,
        :calibration_not_authorized,
        :exemption_scope
      )
    end

    test "an invocation reserved with another prompt ref is refused :exemption_input", ctx do
      %{invocation: invocation, run: run, agent: agent} =
        proof!(ctx, %{prompt_template_sha256: :crypto.hash(:sha256, "another prompt")})

      assert_owned_refusal(
        ctx,
        run,
        agent,
        invocation,
        :calibration_not_authorized,
        :exemption_input
      )
    end

    test "an invocation reserved with another schema ref is refused :exemption_input", ctx do
      %{invocation: invocation, run: run, agent: agent} =
        proof!(ctx, %{output_schema_version: "2"})

      assert_owned_refusal(
        ctx,
        run,
        agent,
        invocation,
        :calibration_not_authorized,
        :exemption_input
      )
    end

    test "an invocation reserved with another request body is refused :exemption_request", ctx do
      %{invocation: invocation, run: run, agent: agent} =
        proof!(ctx, %{request: body(base_request("another-request-id"))})

      assert_owned_refusal(
        ctx,
        run,
        agent,
        invocation,
        :calibration_not_authorized,
        :exemption_request
      )
    end
  end

  describe "C9: the required binding" do
    test "an unbound proof invocation is refused :binding_unrecorded; a replay stays staged",
         ctx do
      %{invocation: invocation, run: run, agent: agent, ref: ref, server: server} =
        assert_owned_refusal(
          ctx,
          nil,
          nil,
          proof!(ctx, %{}, unbound: true),
          :calibration_grant_mismatch,
          :binding_unrecorded
        )

      assert complete(server, request(invocation, run, agent, ref)) ==
               {:error, :real_model_staged}
    end
  end

  ## The domain option (every build): refusal-only

  describe "calibration_launch: at the domain" do
    test "absent keeps ordinary launch behaviour", ctx do
      %{invocation: invocation, agent: agent} = proof!(ctx)
      assert {:ok, %{status: :sent}} = launch(invocation, agent, [])
    end

    test "a well-formed matching expectation launches", ctx do
      %{invocation: invocation, run: run, agent: agent, request: request} = proof!(ctx)

      assert {:ok, %{status: :sent}} =
               launch(invocation, agent, calibration_launch: expected(run, request))
    end

    for variant <- [:explicit_nil, :not_a_map, :missing_key, :extra_key, :short_sha, :bad_ref] do
      test "a present malformed expectation (#{variant}) is :calibration_launch_invalid", ctx do
        %{invocation: invocation, run: run, agent: agent, request: request} = proof!(ctx)
        value = malformed_expectation(expected(run, request), unquote(variant))

        result = launch(invocation, agent, calibration_launch: value)

        assert result == {:error, :calibration_launch_invalid}, inspect(result)
        assert status(invocation) == :reserved
        assert failures(ctx) == []
        assert [event] = launch_events(ctx, invocation)
        assert event.payload["reason"] == "calibration_launch_invalid"
      end
    end

    test "ModelProvider.request_body/1 is the one public request serialization" do
      Code.ensure_loaded!(ModelProvider)

      assert function_exported?(ModelProvider, :request_body, 1),
             "ModelProvider.request_body/1 is not public"

      request = base_request("serialization")
      assert apply(ModelProvider, :request_body, [request]) == body(request)
    end
  end

  ## d3a: the launch receipt (packet 8.14.2)

  describe "d3a: the launch receipt" do
    setup ctx do
      previous = Application.fetch_env(:sdr_agent, :calibration_launch_probe)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:sdr_agent, :calibration_launch_probe, value)
          :error -> Application.delete_env(:sdr_agent, :calibration_launch_probe)
        end

        :persistent_term.erase({ProbeStub, :mode})
        :persistent_term.erase({ProbeStub, :test})
      end)

      %{cli: cli!(ctx, "cli", 0), slow_cli: cli!(ctx, "slow-cli", 1)}
    end

    test "a verified receipt reaches the command before the call's reply", ctx do
      server = server!(ctx, command: ctx.slow_cli)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      {_command, receipt_ref} = request.calibration.observer

      result = admitting(fn -> complete(server, request) end)
      assert match?({:ok, _}, result), inspect(result)

      # Already queued when the reply arrived: no waiting, exactly one.
      assert [{:calibration_launched, receipt}] = receipts(receipt_ref)
      assert Enum.sort(Map.keys(receipt)) == receipt_keys()
      assert {receipt.invocation_id, receipt.server} == {invocation.id, server}
      assert is_integer(receipt.root_pid) and receipt.root_pid > 0
      assert receipt.process_group_id == receipt.root_pid
      assert is_binary(receipt.root_identity) and receipt.root_identity != ""
    end

    for mode <- [
          :identity_absent,
          :identity_error,
          :identity_empty,
          :group_error,
          :root_not_in_group,
          :member_not_a_pid,
          :identity_not_binary,
          :group_not_a_list,
          :probe_raises
        ] do
      test "an unproven launch (#{mode}) sends an unverified receipt, no launch fields", ctx do
        ProbeStub.mode(unquote(mode))
        Application.put_env(:sdr_agent, :calibration_launch_probe, ProbeStub)
        server = server!(ctx, command: ctx.cli)
        %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
        ref = issue!(server, invocation, run)
        request = request(invocation, run, agent, ref)
        {_command, receipt_ref} = request.calibration.observer

        result = admitting(fn -> complete(server, request) end)
        assert match?({:ok, _}, result), inspect(result)

        assert [{:calibration_launch_unverified, receipt}] = receipts(receipt_ref)
        assert Enum.sort(Map.keys(receipt)) == [:invocation_id, :reason, :root_pid, :server]
        assert {receipt.invocation_id, receipt.server} == {invocation.id, server}
        assert is_integer(receipt.root_pid) and receipt.root_pid > 0
      end
    end

    # Codex d3a@3b82624: the proof is bounded by the call's own deadline; a
    # slow probe never stretches the call or reports a late success.
    test "a slow probe is bounded by the call deadline and is unverified", ctx do
      ProbeStub.mode(:slow)
      Application.put_env(:sdr_agent, :calibration_launch_probe, ProbeStub)
      server = server!(ctx, command: ctx.slow_cli, timeout: 1_000)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      {_command, receipt_ref} = request.calibration.observer

      started = System.monotonic_time(:millisecond)
      result = admitting(fn -> complete(server, request) end)
      elapsed = System.monotonic_time(:millisecond) - started

      assert result == {:unknown, :claude_cli_timeout}, inspect(result)
      assert elapsed < 1_800, "the proof exceeded the call deadline: #{elapsed} ms"

      assert [{:calibration_launch_unverified, %{reason: :probe_timeout}}] =
               receipts(receipt_ref)
    end

    test "a slow group read is bounded by the call deadline and is unverified", ctx do
      ProbeStub.mode(:slow_group)
      Application.put_env(:sdr_agent, :calibration_launch_probe, ProbeStub)
      server = server!(ctx, command: ctx.slow_cli, timeout: 1_000)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      {_command, receipt_ref} = request.calibration.observer

      started = System.monotonic_time(:millisecond)
      result = admitting(fn -> complete(server, request) end)
      elapsed = System.monotonic_time(:millisecond) - started

      assert result == {:unknown, :claude_cli_timeout}, inspect(result)
      assert elapsed < 1_800, "the proof exceeded the call deadline: #{elapsed} ms"

      assert [{:calibration_launch_unverified, %{reason: :probe_timeout}}] =
               receipts(receipt_ref)
    end

    # Codex d3a@0a47a27: the probe helper is not linked to the server, so
    # a probe that exits or is killed is only an unverified receipt.
    for mode <- [:probe_exits, :probe_killed] do
      test "a #{mode} probe is :probe_failed and the call goes on", ctx do
        ProbeStub.mode(unquote(mode))
        Application.put_env(:sdr_agent, :calibration_launch_probe, ProbeStub)
        server = server!(ctx, command: ctx.cli)
        %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
        ref = issue!(server, invocation, run)
        request = request(invocation, run, agent, ref)
        {_command, receipt_ref} = request.calibration.observer

        result = admitting(fn -> complete(server, request) end)

        assert match?({:ok, _}, result), inspect(result)
        assert Process.alive?(server)

        assert [{:calibration_launch_unverified, %{reason: :probe_failed}}] =
                 receipts(receipt_ref)
      end
    end

    # The CLI answers at once, so its output is queued while the probe runs
    # past the deadline: the expired call is a timeout, never a late success.
    test "queued output after an expired proof is a timeout, not a late success", ctx do
      ProbeStub.mode(:slow)
      Application.put_env(:sdr_agent, :calibration_launch_probe, ProbeStub)
      server = server!(ctx, command: ctx.cli, timeout: 1_000)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      {_command, receipt_ref} = request.calibration.observer

      result = admitting(fn -> complete(server, request) end)

      assert result == {:unknown, :claude_cli_timeout}, inspect(result)
      assert [{:calibration_launch_unverified, _receipt}] = receipts(receipt_ref)
      assert ClaudeCLI.admission(server) == %{admission: :open}
    end

    test "a caller lost while probing stops the launch without waiting out the probe", ctx do
      ProbeStub.mode(:hung)
      ProbeStub.watch(self())
      Application.put_env(:sdr_agent, :calibration_launch_probe, ProbeStub)
      server = server!(ctx, command: ctx.slow_cli, timeout: 30_000)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      test = self()

      caller =
        spawn(fn ->
          receive do
            {:go, request} ->
              send(test, {:result, admitting(fn -> complete(server, request) end)})
          end
        end)

      ref = issue!(server, invocation, run, %{command_pid: caller})
      send(caller, {:go, request(invocation, run, agent, ref)})
      assert_receive {:probing, os_pid, _probe}, 10_000

      started = System.monotonic_time(:millisecond)
      Process.exit(caller, :kill)

      # The launched tree is stopped by the existing caller-down path well
      # before the 30 s call deadline, and the server admits again.
      assert eventually(fn -> not Reaper.alive?(os_pid) end, 10_000),
             "the launched tree survived the lost caller"

      assert System.monotonic_time(:millisecond) - started < 10_000
      assert eventually(fn -> ClaudeCLI.admission(server) == %{admission: :open} end, 5_000)
      # The command died, so the registry removed its entry (8.2 step 7).
      {Authority, key} = ref
      assert :ets.lookup(Authority.table(), key) == []
    end

    # Codex d3a@cbe1e0f: the probe's lifetime is bound to the provider and
    # to its own budget, so a hung probe never outlives a dead provider.
    for mode <- [:hung, :hung_group] do
      test "a #{mode} probe dies with its provider; no late receipt", ctx do
        ProbeStub.mode(unquote(mode))
        ProbeStub.watch(self())
        Application.put_env(:sdr_agent, :calibration_launch_probe, ProbeStub)
        server = server!(ctx, command: ctx.slow_cli, timeout: 10_000)
        %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
        test = self()

        caller =
          spawn(fn ->
            receive do
              {:go, request} ->
                try do
                  send(test, {:result, admitting(fn -> complete(server, request) end)})
                catch
                  :exit, _provider_gone -> :ok
                end
            end
          end)

        ref = issue!(server, invocation, run, %{command_pid: caller})
        request = request(invocation, run, agent, ref)
        {_command, receipt_ref} = request.calibration.observer
        send(caller, {:go, request})
        assert_receive {:probing, os_pid, probe}, 10_000
        on_exit(fn -> Process.exit(probe, :kill) end)

        Process.exit(server, :kill)

        assert eventually(fn -> not Process.alive?(probe) end, 1_000),
               "the probe outlived its provider"

        assert eventually(fn -> not Reaper.alive?(os_pid) end, 10_000)
        assert receipts(receipt_ref) == []
      end
    end

    # A refusal before Reaper.open is the reachable no-launch case:
    # admission refuses an unbound invocation; nothing is sent or opened.
    test "a launch refused before Reaper.open sends no receipt", ctx do
      server = server!(ctx, command: ctx.cli)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx, %{}, unbound: true)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      {_command, receipt_ref} = request.calibration.observer

      result = admitting(fn -> complete(server, request) end)

      assert match?({:error, %Refused{check: :binding_unrecorded}}, result), inspect(result)
      assert consumed?(ref)
      assert status(invocation) == :failed
      assert receipts(receipt_ref) == []
    end

    # The launcher opens /bin/sh, which then fails to find the CLI: the
    # launch did open, so exactly one receipt is sent (packet 8.14.2).
    test "a missing CLI behind an opened shell still sends exactly one receipt", ctx do
      server = server!(ctx, command: Path.join(System.tmp_dir!(), "d3a-no-such-cli"))
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      {_command, receipt_ref} = request.calibration.observer

      result = admitting(fn -> complete(server, request) end)

      assert result == {:error, :missing_init_attestation}, inspect(result)
      assert consumed?(ref)
      assert status(invocation) == :sent
      assert [{kind, receipt}] = receipts(receipt_ref)
      assert kind in [:calibration_launched, :calibration_launch_unverified]
      assert receipt.invocation_id == invocation.id
    end

    # A failure after the port opened (the reaper's existing on_open hook):
    # the outcome is unknown, the call stays sent and no receipt is sent.
    test "a post-open unknown launch sends no receipt", ctx do
      hook = fn _os_pid -> raise "synthetic post-open failure" end
      server = server!(ctx, command: ctx.slow_cli, reaper: [on_open: hook])
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = request(invocation, run, agent, ref)
      {_command, receipt_ref} = request.calibration.observer

      result = admitting(fn -> complete(server, request) end)

      assert result == {:unknown, :post_spawn_failure}, inspect(result)
      assert consumed?(ref)
      assert status(invocation) == :sent
      assert receipts(receipt_ref) == []
    end

    # Real ordinary calls stay staged; this control runs an injected test
    # launcher, which is never exempted.
    test "an ordinary call through an injected test launcher sends no receipt", ctx do
      {:ok, server} =
        ClaudeCLI.start_link(
          command: ctx.cli,
          test_launcher: true,
          launch_admission: &SdrAgent.Test.LaunchAdmission.admitted/3,
          executable: ctx.stand_in,
          environment: %{}
        )

      request = Map.delete(request_shape(), :calibration)
      assert {:ok, _} = complete(server, request)
      assert all_receipts() == []
    end
  end

  ## d3b: the seam-only reserved-call wrapper (packet 8.14.3)

  describe "d3b: ModelProvider.calibration_call/3" do
    setup ctx do
      ran = Path.join(Path.dirname(ctx.tripwire), "d3b-cli-ran")
      %{cli: cli!(ctx, "d3b-cli", 0, ran), ran: ran}
    end

    test "a valid reserved target is called and settled through the facade's helper", ctx do
      server = server!(ctx, command: ctx.cli)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)
      request = call_request(invocation, run, agent, ref)

      result = admitting(fn -> calibration_call(request, invocation.id, server: server) end)

      assert match?({:ok, %{invocation: %ModelInvocation{status: :completed}}}, result),
             inspect(result)

      {:ok, settled} = result
      assert settled.output == %{answer: "blue", confidence: 0.9}
      assert consumed?(ref)
      # The witness was captured by the wrapper in this process: the
      # server launched exactly this invocation.
      {_command, receipt_ref} = request.calibration.observer
      assert [{_kind, receipt}] = receipts(receipt_ref)
      assert receipt.invocation_id == invocation.id
    end

    for variant <- [
          :foreign_tenant,
          :not_reserved,
          :other_provider,
          :other_profile,
          :other_run,
          :ordinary_run,
          :operated_run,
          :stopped_run,
          :other_request,
          :other_prompt_ref,
          :malformed_request,
          :fabricated_id
        ] do
      test "#{variant} is :calibration_call_invalid with no provider call or write", ctx do
        %{server: server, ref: ref, request: request, id: id, before: before} =
          call_target(ctx, unquote(variant))

        # Direct evidence: every message the private server receives is
        # traced, and the CLI leaves a marker if it ever runs.
        :erlang.trace(server, true, [:receive])
        result = admitting(fn -> calibration_call(request, id, server: server) end)
        :erlang.trace(server, false, [:receive])

        assert result == {:error, :calibration_call_invalid}, inspect(result)
        assert provider_calls(server) == 0, "the provider was called"
        refute File.exists?(ctx.ran), "the CLI was launched"
        refute consumed?(ref), "the entry was consumed"
        assert snapshot(id) == before, "the target was written"
      end
    end

    test "ordinary ModelProvider.complete/2 keeps the Fake's sent ordering", ctx do
      AgentsFixtures.grant!(ctx.tenant, %{}, human(:admin, ctx.tenant))
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

      request = %{
        id: "d3b-fake",
        operation: "model.complete",
        prompt: "qualify",
        schema: Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true),
        run: run,
        actor: agent,
        audit: AgentsFixtures.model_attrs("d3b-fake") |> Map.drop([:request, :idempotency_key])
      }

      assert {:ok, %{invocation: %{status: :completed}}} =
               ModelProvider.complete(request,
                 provider: SdrAgent.AI.ModelProvider.Fake,
                 provider_options: []
               )
    end
  end

  ## Positive (real shim)

  describe "the exemption" do
    if is_nil(@shim), do: @tag(skip: "llm-proxy-shim is not installed on this machine")

    test "a private server with a matching entry launches the fixed input once", ctx do
      proxy_env!()
      server = server!(ctx, command: @shim)
      %{invocation: invocation, run: run, agent: agent} = proof!(ctx)
      ref = issue!(server, invocation, run)

      result = admitting(fn -> complete(server, request(invocation, run, agent, ref)) end)

      assert match?({:ok, _}, result), inspect(result)
      assert consumed?(ref)
      assert status(invocation) == :sent
      assert run_status(run) == :running

      # The prompt file the CLI read holds exactly the rendered fixed input.
      assert File.read!(ctx.records.stdin) ==
               ClaudeCLI.render_prompt(Prompt.render(), Prompt.json_schema())

      assert complete(server, request(invocation, run, agent, ref)) ==
               {:error, :real_model_staged}
    end
  end

  ## Assertions

  defp assert_untouched(ctx, ref, invocation) do
    refute consumed?(ref), "the entry was consumed"
    refute File.exists?(ctx.records.tripped), "a process was launched"
    assert status(invocation) == :reserved
    assert launch_events(ctx, invocation) == []
  end

  # A C8/C9 refusal: the targeted invocation's existing receipt; the entry
  # stays consumed, nothing is launched and the run is not stopped.
  defp assert_owned_refusal(ctx, nil, nil, proof, reason, check) do
    assert_owned_refusal(ctx, proof.run, proof.agent, proof.invocation, reason, check)
  end

  defp assert_owned_refusal(ctx, run, agent, invocation, reason, check) do
    server = server!(ctx)
    ref = issue!(server, invocation, run)
    result = admitting(fn -> complete(server, request(invocation, run, agent, ref)) end)

    assert match?({:error, %Refused{stage: :launch, reason: ^reason, check: ^check}}, result),
           inspect(result)

    {:error, refused} = result
    assert consumed?(ref)
    refute File.exists?(ctx.records.tripped), "a refused launch opened the port"

    row = Ash.get!(ModelInvocation, invocation.id, authorize?: false)
    assert {row.status, row.sent_at} == {:failed, nil}
    assert {row.grant_id, row.allocation_id} == {invocation.grant_id, invocation.allocation_id}
    assert run_status(run) == :running

    assert [failure] = failures(ctx)
    assert failure.id == refused.failure_id
    assert {failure.class, failure.subject_id} == {:provider_error, run.id}
    assert [%{id: event_id}] = launch_events(ctx, invocation)
    assert event_id == refused.event_id

    %{invocation: invocation, run: run, agent: agent, ref: ref, server: server}
  end

  ## Fixtures

  defp server!(ctx, opts \\ []) do
    opts =
      Keyword.merge(
        [
          command: ctx.tripwire,
          executable: ctx.stand_in,
          profile: :claude_cli_opus,
          environment: %{}
        ],
        opts
      )

    opts = if Keyword.get(opts, :name), do: opts, else: Keyword.delete(opts, :name)
    server = start_supervised!(%{id: make_ref(), start: {ClaudeCLI, :start_link, [opts]}})
    # Launch admission reads the clock in the server process.
    :sys.replace_state(server, fn state ->
      :ok = Clock.freeze(@now)
      state
    end)

    server
  end

  defp name_for(:runtime), do: ClaudeCLI.server()
  defp name_for(:local), do: :"d1b_named_#{System.unique_integer([:positive])}"
  defp name_for(:global), do: {:global, {__MODULE__, System.unique_integer([:positive])}}

  defp name_for(:via),
    do: {:via, Registry, {__MODULE__.Names, System.unique_integer([:positive])}}

  # A bound (or unbound) proof invocation reserved with the fixed input.
  defp proof!(ctx, overrides \\ %{}, opts \\ []) do
    g_r0!(ctx.tenant)
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)

    marker =
      if Keyword.get(opts, :unbound),
        do: CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry()),
        else: marker(ctx, agent)

    {invocation, request} = reserve!(run, agent, marker, overrides)
    %{invocation: invocation, run: run, agent: agent, request: request}
  end

  defp marker(ctx, agent) do
    g_r0!(ctx.tenant)

    {:ok, binding} =
      Agents.select_calibration_grant(ctx.tenant.id, :claude_cli_opus, actor: agent)

    CalibrationAdmission.context(:claude_cli_opus, AdmissionFixtures.entry(),
      claim: Ash.UUIDv7.generate(),
      binding: binding
    )
  end

  defp reserve!(run, agent, marker, overrides \\ %{}) do
    key = "d1b-#{System.unique_integer([:positive])}"
    request = base_request(key)
    prompt = Prompt.prompt_ref()
    schema = Prompt.schema_ref()

    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.merge(%{
        prompt_template_id: prompt.id,
        prompt_template_version: prompt.version,
        prompt_template_sha256: prompt.sha256,
        output_schema_id: schema.id,
        output_schema_version: schema.version,
        output_schema_sha256: schema.sha256,
        request: body(request)
      })
      |> Map.merge(overrides)

    opts = if marker, do: [actor: agent, calibration: marker], else: [actor: agent]

    {:ok, invocation} =
      admitting(fn -> Agents.reserve_model_invocation(run, attrs, opts) end)

    {invocation, request}
  end

  # Creates the tenant's one G-R0 grant once.
  defp g_r0!(tenant) do
    if Process.get(:d1b_g_r0) do
      :ok
    else
      Process.put(:d1b_g_r0, true)

      AgentsFixtures.grant!(tenant, %{
        name: "G-R0",
        profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
        total_attempts: 4,
        starts_at: ~U[2026-10-12 00:00:00.000000Z],
        expires_at: ~U[2026-10-19 05:59:00.000000Z],
        allocations: [
          %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_opus},
          %{key: :proof, applies_to: [:proof], attempts: 2, profile_id: :claude_cli_sonnet}
        ]
      })
    end
  end

  defp issue!(server, invocation, run, overrides \\ %{}) do
    {:ok, ref} =
      %{
        invocation_id: invocation.id,
        run_id: run.id,
        tenant_id: run.tenant_id,
        profile_id: :claude_cli_opus,
        command_pid: self(),
        server_pid: server,
        prompt_sha256: lower_hex(Prompt.prompt_ref().sha256),
        schema_sha256: lower_hex(Prompt.schema_ref().sha256),
        instance: Authority.instance()
      }
      |> Map.merge(overrides)
      |> Authority.issue()

    ref
  end

  defp base_request(id),
    do: %{
      id: id,
      operation: "calibration.complete",
      prompt: Prompt.render(),
      schema: Prompt.schema()
    }

  # The stored request body: the same serialization as ModelProvider's.
  defp body(request) do
    Jason.encode!(%{
      id: request.id,
      operation: request.operation,
      prompt: request.prompt,
      schema: JsonSchema.render(request.schema)
    })
  end

  defp request(invocation, run, agent, ref) do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    invocation.idempotency_key
    |> base_request()
    |> Map.merge(%{
      witness: %{model_invocation_id: invocation.id, traceparent: "00-#{trace}-#{span}-01"},
      actor: agent,
      calibration: %{
        authority: ref,
        run_id: run.id,
        tenant_id: run.tenant_id,
        instance: Authority.instance(),
        observer: {self(), make_ref()}
      }
    })
  end

  defp malform(request, :absent), do: Map.delete(request, :calibration)
  defp malform(request, :nil_value), do: %{request | calibration: nil}

  defp malform(request, :missing_key),
    do: update_in(request.calibration, &Map.delete(&1, :instance))

  defp malform(request, :extra_key), do: put_in(request.calibration[:extra], 1)
  defp malform(request, :bad_run_id), do: put_in(request.calibration.run_id, "nope")

  defp malform(request, :forged_authority),
    do: put_in(request.calibration.authority, {Authority, "forged"})

  defp malform(request, :bad_instance), do: put_in(request.calibration.instance, "short")
  defp malform(request, :missing_witness), do: Map.delete(request, :witness)

  # d3a (packet 8.14.2): the closed value carries `observer: {pid, ref}`.
  defp malform(request, :missing_observer),
    do: update_in(request.calibration, &Map.delete(&1, :observer))

  defp malform(request, :observer_not_a_pair), do: put_in(request.calibration.observer, self())

  defp malform(request, :observer_bad_pid),
    do: put_in(request.calibration.observer, {"pid", make_ref()})

  defp malform(request, :observer_bad_ref),
    do: put_in(request.calibration.observer, {self(), "ref"})

  # Codex d1b@21eb641: the strict witness validator runs before the consume.
  defp malform(request, :missing_traceparent),
    do: update_in(request.witness, &Map.delete(&1, :traceparent))

  defp malform(request, :bad_traceparent), do: put_in(request.witness.traceparent, "not-w3c")

  defp malform(request, :zero_trace_id),
    do:
      put_in(
        request.witness.traceparent,
        "00-#{String.duplicate("0", 32)}-#{String.duplicate("1", 16)}-01"
      )

  defp malform(request, :zero_span_id),
    do:
      put_in(
        request.witness.traceparent,
        "00-#{String.duplicate("1", 32)}-#{String.duplicate("0", 16)}-01"
      )

  defp malform(request, :bad_flags),
    do:
      put_in(
        request.witness.traceparent,
        "00-#{String.duplicate("1", 32)}-#{String.duplicate("1", 16)}-ff"
      )

  defp malform(request, :unrenderable_schema), do: %{request | schema: :not_a_schema}

  # A server, entry and request differing from the target in one claim.
  defp mismatch(ctx, :server, invocation, run, agent) do
    bound = server!(ctx)
    other = server!(ctx)
    ref = issue!(bound, invocation, run)
    {other, ref, request(invocation, run, agent, ref)}
  end

  defp mismatch(ctx, :profile, invocation, run, agent) do
    server = server!(ctx, profile: :claude_cli_sonnet)
    ref = issue!(server, invocation, run)
    {server, ref, request(invocation, run, agent, ref)}
  end

  defp mismatch(ctx, claim, invocation, run, agent) do
    server = server!(ctx)
    ref = issue!(server, invocation, run)
    request = request(invocation, run, agent, ref)

    request =
      case claim do
        :caller -> request
        :invocation -> put_in(request.witness.model_invocation_id, Ash.UUIDv7.generate())
        :run -> put_in(request.calibration.run_id, Ash.UUIDv7.generate())
        :tenant -> put_in(request.calibration.tenant_id, Ash.UUIDv7.generate())
        :instance -> put_in(request.calibration.instance, String.duplicate("0", 32))
      end

    {server, ref, request}
  end

  defp expected(run, request) do
    %{
      run_id: run.id,
      tenant_id: run.tenant_id,
      request_sha256: :crypto.hash(:sha256, body(request)),
      prompt_ref: Prompt.prompt_ref(),
      schema_ref: Prompt.schema_ref()
    }
  end

  defp malformed_expectation(_expected, :explicit_nil), do: nil
  defp malformed_expectation(_expected, :not_a_map), do: :expected
  defp malformed_expectation(expected, :missing_key), do: Map.delete(expected, :schema_ref)
  defp malformed_expectation(expected, :extra_key), do: Map.put(expected, :extra, 1)
  defp malformed_expectation(expected, :short_sha), do: %{expected | request_sha256: "short"}

  defp malformed_expectation(expected, :bad_ref),
    do: %{expected | prompt_ref: Map.delete(expected.prompt_ref, :version)}

  defp launch(invocation, agent, opts) do
    admitting(fn ->
      Agents.admit_launch(invocation.id, :claude_cli_opus, [actor: agent] ++ opts)
    end)
  end

  defp complete(server, request), do: ClaudeCLI.complete(request, server: server)

  defp admitting(fun), do: AdmissionFixtures.admitting(fun)

  defp consumed?({Authority, key}) do
    [{^key, _binding, state}] = :ets.lookup(Authority.table(), key)
    state == :consumed
  end

  defp status(invocation), do: Ash.get!(ModelInvocation, invocation.id, authorize?: false).status
  defp run_status(run), do: Ash.get!(AgentRun, run.id, authorize?: false).status

  defp launch_events(ctx, invocation) do
    ctx.tenant
    |> events_of_type("model.launch.refused")
    |> Enum.filter(&(&1.subject_id == invocation.id))
  end

  defp failures(ctx), do: Ash.read!(Failure, SdrAgent.Audit.Kernel.opts(ctx.tenant.id))

  defp lower_hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp schema_sha(schema), do: Canonical.sha256(JsonSchema.render(schema))

  # A harmless stand-in for the pinned CLI: keeps the prompt it read and
  # answers with a canned init and a result matching the calibration schema.
  defp stand_in!(bin, stdin) do
    path = Path.join(bin, "claude-code")

    init =
      ~s({"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"#{ClaudeCLI.provenance().provider_version}","tools":[],"mcp_servers":[],"slash_commands":[]})

    result =
      ~s({"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"blue\\",\\"confidence\\":0.9}","usage":{"input_tokens":1,"output_tokens":1}})

    File.write!(path, """
    #!/bin/sh
    cat > '#{stdin}'
    printf '%s\\n' '#{init}'
    printf '%s\\n' '#{result}'
    """)

    File.chmod!(path, 0o555)
    path
  end

  # d3a: a CLI stand-in run directly as the command (no shim): it reads the
  # prompt and answers; `delay` seconds keep it alive to be probed.
  defp cli!(ctx, name, delay, marker \\ nil) do
    path = Path.join(Path.dirname(ctx.tripwire), name)
    touch = if marker, do: "touch '#{marker}'\n", else: ""

    init =
      ~s({"type":"system","subtype":"init","model":"claude-opus-5-5","claude_code_version":"#{ClaudeCLI.provenance().provider_version}","tools":[],"mcp_servers":[],"slash_commands":[]})

    result =
      ~s({"type":"result","subtype":"success","is_error":false,"result":"{\\"answer\\":\\"blue\\",\\"confidence\\":0.9}","usage":{"input_tokens":1,"output_tokens":1}})

    File.write!(path, """
    #!/bin/sh
    #{touch}cat > /dev/null
    sleep #{delay}
    printf '%s\\n' '#{init}'
    printf '%s\\n' '#{result}'
    """)

    File.chmod!(path, 0o555)
    path
  end

  # d3b: the console's request: no witness (the wrapper captures it).
  defp call_request(invocation, run, agent, ref) do
    invocation
    |> request(run, agent, ref)
    |> Map.delete(:witness)
    |> Map.put(:run, run)
  end

  defp calibration_call(request, id, opts) do
    Code.ensure_loaded!(ModelProvider)

    if function_exported?(ModelProvider, :calibration_call, 3),
      do: apply(ModelProvider, :calibration_call, [request, id, opts]),
      else: {:error, :calibration_call_undefined}
  end

  # Counts the provider calls `server` received: tracing is stopped, every
  # trace message is acknowledged as delivered (bounded), then drained.
  defp provider_calls(server) do
    delivered = :erlang.trace_delivered(server)

    receive do
      {:trace_delivered, ^server, ^delivered} -> :ok
    after
      5_000 -> flunk("the trace of the private server was not acknowledged")
    end

    count_calls(server)
  end

  defp count_calls(server) do
    receive do
      {:trace, ^server, :receive, {:"$gen_call", _from, {:complete, _request, _at}}} ->
        1 + count_calls(server)

      {:trace, ^server, :receive, _other} ->
        count_calls(server)
    after
      0 -> 0
    end
  end

  defp snapshot(id) do
    case Ash.get(ModelInvocation, id, authorize?: false) do
      {:ok, row} -> {row.status, row.sent_at, row.updated_at}
      _missing -> :missing
    end
  end

  # One target per d3b refusal variant: a valid entry is issued for the
  # private server, then the target or the request is made wrong.
  defp call_target(ctx, variant) do
    profile = if variant == :other_profile, do: :claude_cli_sonnet, else: :claude_cli_opus
    server = server!(ctx, command: ctx.cli, profile: profile)
    %{invocation: invocation, run: run, agent: agent} = target_for(ctx, variant)
    ref = issue!(server, invocation, run, %{profile_id: profile})
    request = call_request(invocation, run, agent, ref)
    {request, id} = wrong(ctx, variant, request, invocation)
    %{server: server, ref: ref, request: request, id: id, before: snapshot(id)}
  end

  defp target_for(ctx, :ordinary_run) do
    AgentsFixtures.grant!(ctx.tenant, %{}, human(:admin, ctx.tenant))
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
    {invocation, _request} = reserve!(run, agent, nil)
    %{invocation: invocation, run: run, agent: agent}
  end

  defp target_for(ctx, :operated_run) do
    %{run: run, agent: agent} = AgentsFixtures.operated_run(ctx.tenant, usage_origin: :proof)
    {invocation, _request} = reserve!(run, agent, marker(ctx, agent))
    %{invocation: invocation, run: run, agent: agent}
  end

  defp target_for(ctx, :other_prompt_ref),
    do: proof!(ctx, %{prompt_template_sha256: :crypto.hash(:sha256, "another prompt")})

  defp target_for(ctx, _variant), do: proof!(ctx)

  defp wrong(_ctx, :foreign_tenant, request, invocation) do
    foreign = SdrAgent.Actor |> struct(type: :agent_runtime, tenant_id: Ash.UUIDv7.generate())
    {%{request | actor: foreign}, invocation.id}
  end

  defp wrong(_ctx, :not_reserved, request, invocation) do
    {:ok, _sent} =
      admitting(fn ->
        Agents.admit_launch(invocation.id, :claude_cli_opus, actor: request.actor)
      end)

    {request, invocation.id}
  end

  defp wrong(ctx, :other_provider, request, _invocation) do
    AgentsFixtures.grant!(ctx.tenant, %{}, human(:admin, ctx.tenant))
    %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)

    {:ok, fake} =
      Agents.reserve_model_invocation(run, AgentsFixtures.model_attrs("d3b-fake-target"),
        actor: agent
      )

    {%{request | run: run, actor: agent}, fake.id}
  end

  defp wrong(ctx, :other_run, request, invocation) do
    %{run: other} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)
    {%{request | run: other}, invocation.id}
  end

  defp wrong(_ctx, :stopped_run, request, invocation) do
    {:ok, _cancelled} = Agents.cancel_run(request.run, actor: request.actor)
    {request, invocation.id}
  end

  defp wrong(_ctx, :other_request, request, invocation),
    do: {%{request | id: "another-request-id"}, invocation.id}

  defp wrong(_ctx, :malformed_request, request, invocation),
    do: {Map.drop(request, [:prompt, :schema]), invocation.id}

  defp wrong(_ctx, :fabricated_id, request, _invocation), do: {request, Ash.UUIDv7.generate()}

  defp wrong(_ctx, _variant, request, invocation), do: {request, invocation.id}

  defp eventually(check, within) do
    until = System.monotonic_time(:millisecond) + within

    Stream.repeatedly(fn -> check.() || (Process.sleep(25) && false) end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > until end)
    |> Kernel.==(true)
  end

  # Every queued receipt message carrying `ref`, in order, drained.
  defp receipts(ref) do
    receive do
      {kind, ^ref, receipt}
      when kind in [:calibration_launched, :calibration_launch_unverified] ->
        [{kind, receipt} | receipts(ref)]
    after
      0 -> []
    end
  end

  defp all_receipts do
    receive do
      {kind, _ref, receipt}
      when kind in [:calibration_launched, :calibration_launch_unverified] ->
        [{kind, receipt} | all_receipts()]
    after
      0 -> []
    end
  end

  defp receipt_keys,
    do: [:invocation_id, :process_group_id, :root_identity, :root_pid, :server]

  defp request_shape do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    "d3a-ordinary"
    |> base_request()
    |> Map.put(:witness, %{
      model_invocation_id: Ash.UUIDv7.generate(),
      traceparent: "00-#{trace}-#{span}-01"
    })
  end

  # The command of every refusal test: it must never run.
  defp tripwire!(dir, marker) do
    path = Path.join(dir, "tripwire")
    File.write!(path, "#!/bin/sh\ntouch '#{marker}'\nexit 1\n")
    File.chmod!(path, 0o555)
    path
  end

  # The real shim needs a loopback "proxy" that answers its health probes.
  defp proxy_env! do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> accept(listener) end)
    names = ~w(LLM_OTEL_PROXY_URL ANTHROPIC_BASE_URL LLM_PROXY_SHIM_CLAUDE_BIN)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    System.put_env("LLM_OTEL_PROXY_URL", "http://127.0.0.1:#{port}")
    System.delete_env("ANTHROPIC_BASE_URL")
    System.delete_env("LLM_PROXY_SHIM_CLAUDE_BIN")

    on_exit(fn ->
      :gen_tcp.close(listener)
      Enum.each(previous, &restore_env/1)
    end)
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)

  defp accept(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket)
        accept(listener)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket) do
    with {:ok, head} <- read_head(socket, ""),
         [_method, path | _] <- head |> String.split("\r\n") |> hd() |> String.split(" ") do
      {status, body} =
        case path do
          "/healthz" -> {"200 OK", "ok"}
          "/healthz/witness" -> {"200 OK", @capability}
          _other -> {"404 Not Found", ""}
        end

      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status}\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )
    end

    :gen_tcp.close(socket)
  end

  defp read_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read_head(socket, acc <> data)
        error -> error
      end
    end
  end
end
