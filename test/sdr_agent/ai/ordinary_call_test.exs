defmodule SdrAgent.AI.OrdinaryCallTest do
  @moduledoc """
  L2 E3 RED (`notes/features/l2-e3-ordinary-calls.org`, plan PASS at
  e462d48): lifting `:real_model_staged` for ordinary calls, at the
  facade and `SDR.Model.call/4` level. Plan items 1 (applicability, model
  level), 1a (direct entries), 2 (pre-launch refusals), 3 (post-launch init
  drift), 4 (after merge, no grant), 8 (withholding boundaries), 9
  (calibration still needs its exemption) and 12 (no real model call).

  Every ordinary path here uses a pinned server **without** `test_launcher`
  (`executable:` from `PinnedCLI.inject_identity!/2`, attestation
  `test_launcher?: false`), so the real `Agents.admit_launch/3` runs. Its
  command is either the hermetic fake CLI (`fake_claude_cli.exs`, playing
  shim, v3 proxy store and CLI) or the recording stub `llm-proxy-shim`
  (`PinnedCLI.stub_shim!/1`) where nothing may launch. The witness store
  root and the promoted tuples are the trusted fresh root and the tuples
  shipped in `config/config.exs` (as the R0-06 test reads them). No test
  launches the app's pinned Claude CLI or makes a real model call.

  The fake CLI's `sdr` mode answers the evidence_extraction, qualification
  and reply_classification schemas; it has no outreach_proposal answer, so
  that purpose is played by a responder script generated per test under
  the test's temporary directory (same v3 witness shape as `sdr` mode;
  synthetic text only).

  Tests named "control" assert behaviour that already holds today.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.Agents.UsageBucket
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProfiles
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.PinnedExecutable
  alias SdrAgent.AI.ModelProvider.Runtime
  alias SdrAgent.CalibrationConsole.Prompt, as: CalibrationPrompt
  alias SdrAgent.Operations.Failure
  alias SdrAgent.SDR.Context
  alias SdrAgent.SDR.Model
  alias SdrAgent.SDR.Prompts
  alias SdrAgent.SDR.Schemas
  alias SdrAgent.Test.PinnedCLI

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @proxy Path.expand("../../support/fake_witness_proxy.exs", __DIR__)
  @purposes [:evidence_extraction, :qualification, :outreach_proposal, :reply_classification]
  @profiles [:claude_cli_opus, :claude_cli_sonnet]
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)

  setup do
    tenant = bootstrap!()
    admin = human(:admin, tenant)
    dir = Path.join(System.tmp_dir!(), "sdr-l2e3oc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    counter = PinnedCLI.stub_shim!(dir)
    bin = PinnedCLI.inject_identity!()
    %{tenant: tenant, admin: admin, dir: dir, counter: counter, bin: bin}
  end

  ## 1. Applicability, at the SDR.Model level

  describe "E3 1: every ordinary purpose on every promoted profile" do
    for profile <- @profiles, purpose <- @purposes do
      test "#{purpose} on #{profile}: reserved, launched, released and read downstream", ctx do
        purpose = unquote(purpose)
        profile = unquote(profile)
        root = healthy!()
        grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)

        %{run: run, agent: agent} =
          AgentsFixtures.running_run(ctx.tenant, usage_origin: origin(purpose))

        server = purpose_server!(ctx, purpose, profile, root, "cli_shape_v3")
        assert %{test_launcher?: false, executable: bin} = ClaudeCLI.attestation(server)
        assert bin == ctx.bin

        result =
          Model.call(sdr(run, agent, server), purpose, input(purpose), Ecto.UUID.generate())

        assert match?({:ok, _output, _invocation}, result),
               "E3: an ordinary #{purpose} call on #{profile} must be released, got #{inspect(result)}"

        {:ok, output, invocation} = result

        assert {invocation.provider, invocation.profile_id, invocation.ledger_generation} ==
                 {:claude_cli, profile, 2}

        assert {invocation.status, invocation.purpose} == {:completed, purpose}
        assert invocation.prompt_template_id == Prompts.ref(purpose).id
        assert invocation.output_schema_id == Schemas.ref(purpose).id
        assert invocation.sent_at != nil
        assert invocation.grant_id == grant.id
        assert UsageBucket.bucket(run.usage_origin, purpose) == bucket(purpose)

        assert {:ok, %{disposition: :released}} =
                 Agents.get_result_release(invocation.id, actor: agent)

        assert {:ok, read} = Agents.released_output(invocation, actor: agent)
        assert json(read) == json(output)
        assert consumed(ctx, grant) == 1
        assert run_state(run, agent) == {:running, nil}
      end

      test "#{purpose} on #{profile}: a witness mismatch is withheld, charged, unreadable",
           ctx do
        purpose = unquote(purpose)
        profile = unquote(profile)
        root = healthy!()
        grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)

        %{run: run, agent: agent} =
          AgentsFixtures.running_run(ctx.tenant, usage_origin: origin(purpose))

        server = purpose_server!(ctx, purpose, profile, root, "cli_shape_v3_mismatch")

        result =
          Model.call(sdr(run, agent, server), purpose, input(purpose), Ecto.UUID.generate())

        assert result == {:error, {:halt, :witness_mismatch}},
               "E3: a mismatched ordinary #{purpose} capture must be withheld after spend, " <>
                 "got #{inspect(result)}"

        assert [invocation] = invocations(run, agent)
        assert {invocation.status, invocation.profile_id} == {:completed, profile}

        assert {:ok, %{disposition: :withheld, reason: :witness_mismatch}} =
                 Agents.get_result_release(invocation.id, actor: agent)

        assert {:error, :result_not_released} = Agents.released_output(invocation, actor: agent)
        assert consumed(ctx, grant) == 1
        assert run_state(run, agent) == {:failed, :witness_mismatch}
      end
    end

    test "control: the fixed calibration prompt and schema are no ordinary purpose's" do
      calibration = {CalibrationPrompt.prompt_ref(), CalibrationPrompt.schema_ref()}

      for purpose <- @purposes do
        prompt = Prompts.ref(purpose)
        schema = Schemas.ref(purpose)

        refute {prompt.id, prompt.sha256} ==
                 {elem(calibration, 0).id, elem(calibration, 0).sha256}

        refute {schema.id, schema.sha256} ==
                 {elem(calibration, 1).id, elem(calibration, 1).sha256}

        refute Prompts.render(purpose, input(purpose)) == CalibrationPrompt.render()
      end
    end
  end

  ## 1a. Direct entries to the pinned ordinary server

  describe "E3 1a: direct entries to the pinned ordinary server launch nothing" do
    setup ctx do
      healthy!()
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      %{grant: grant, run: run, agent: agent, server: server!(ctx)}
    end

    test "a witness naming no invocation of the actor's tenant is :invocation_not_found", ctx do
      reserved = reserve!(ctx.run, ctx.agent, "direct-foreign")
      foreign = %SdrAgent.Actor{type: :agent_runtime, tenant_id: Ecto.UUID.generate()}

      for {id, actor} <- [{Ecto.UUID.generate(), ctx.agent}, {reserved.id, foreign}] do
        result = direct(ctx.server, %{actor: actor, witness: witness(id)})

        assert result == {:error, :invocation_not_found},
               "E3: a pinned ordinary server must reach launch admission for #{inspect(id)}, " <>
                 "got #{inspect(result)}"
      end

      assert status(reserved) == {:reserved, nil}
      assert consumed(ctx, ctx.grant) == 1
      assert PinnedCLI.launches(ctx.counter) == 0
    end

    test "an invocation already sent or terminal is :invocation_not_reserved", ctx do
      sent = reserve!(ctx.run, ctx.agent, "direct-sent")
      {:ok, sent} = Agents.mark_model_invocation_sent(sent, actor: ctx.agent)
      failed = reserve!(ctx.run, ctx.agent, "direct-failed")

      {:ok, failed} =
        Agents.fail_model_invocation(failed, %{error: %{"kind" => "fixture"}}, actor: ctx.agent)

      for invocation <- [sent, failed] do
        result = direct(ctx.server, %{actor: ctx.agent, witness: witness(invocation.id)})

        assert result == {:error, :invocation_not_reserved},
               "E3: a #{invocation.status} row must be refused by launch admission, " <>
                 "got #{inspect(result)}"
      end

      assert {status(sent), elem(status(failed), 0)} == {{:sent, sent.sent_at}, :failed}
      assert consumed(ctx, ctx.grant) == 2
      assert PinnedCLI.launches(ctx.counter) == 0
    end

    test "a missing or malformed witness context is :invalid_witness_context", ctx do
      reserved = reserve!(ctx.run, ctx.agent, "direct-witness")
      good = witness(reserved.id)

      for request <- [
            %{actor: ctx.agent},
            %{actor: ctx.agent, witness: nil},
            %{
              actor: ctx.agent,
              witness: %{good | model_invocation_id: String.upcase(reserved.id)}
            },
            %{actor: ctx.agent, witness: %{good | traceparent: "00-bad-trace-01"}},
            %{actor: ctx.agent, witness: Map.delete(good, :traceparent)}
          ] do
        result = direct(ctx.server, request)

        assert result == {:error, :invalid_witness_context},
               "E3: an ordinary request to a pinned server must reach the witness check, " <>
                 "got #{inspect(result)} for #{inspect(Map.get(request, :witness))}"
      end

      assert status(reserved) == {:reserved, nil}
      assert launch_refusals(ctx.tenant, reserved) == []
      assert PinnedCLI.launches(ctx.counter) == 0
    end

    test "a non-AGT actor is :launch_not_admitted, with its denial audit", ctx do
      reserved = reserve!(ctx.run, ctx.agent, "direct-actor")
      denials = length(events_of_type(ctx.tenant, "authz.denied"))

      result = direct(ctx.server, %{actor: ctx.admin, witness: witness(reserved.id)})

      assert result == {:error, :launch_not_admitted},
             "E3: a non-AGT actor's ordinary launch must be Forbidden at launch admission, " <>
               "got #{inspect(result)}"

      assert length(events_of_type(ctx.tenant, "authz.denied")) == denials + 1
      assert status(reserved) == {:reserved, nil}
      assert PinnedCLI.launches(ctx.counter) == 0
    end
  end

  ## 2. Pre-launch refusals, each with every earlier predicate passing

  describe "E3 2: pre-launch conditions refuse with their typed reasons and no launch" do
    setup ctx do
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      %{run: run, agent: agent}
    end

    test "control: no server is :provider_not_running, nothing reserved", ctx do
      healthy!()
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      for server <- [dead, :"sdr_l2e3oc_absent_#{System.unique_integer([:positive])}"] do
        assert {:error, :provider_not_running} = complete(server, ctx.run, ctx.agent, "absent")
      end

      assert invocations(ctx.run, ctx.agent) == []
      assert consumed(ctx, grant) == 0
      assert PinnedCLI.launches(ctx.counter) == 0
    end

    test "control: no pin, or a missing pinned build, is :pinned_cli_unavailable", ctx do
      healthy!()
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)

      for executable <- [nil, PinnedCLI.missing_store_path()] do
        server = server!(ctx, executable: executable)
        assert {:error, :pinned_cli_unavailable} = resolve(server)

        assert {:error, :pinned_cli_unavailable} =
                 complete(server, ctx.run, ctx.agent, "unpinned")
      end

      assert invocations(ctx.run, ctx.agent) == []
      assert consumed(ctx, grant) == 0
      assert PinnedCLI.launches(ctx.counter) == 0
    end

    test "the reviewed version binding admits a matching pin at resolution", ctx do
      healthy!()
      server = server!(ctx)

      result = resolve(server)

      assert match?({:ok, _model}, result),
             "E3: a pinned server whose reviewed version is " <>
               "#{ModelProfiles.cli_version()} must resolve, got #{inspect(result)}"

      {:ok, model} = result
      assert {model[:provider], model[:provider_options][:server]} == {ClaudeCLI, server}
    end

    test "a mismatched, missing or malformed identity version refuses at resolution", ctx do
      healthy!()
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      server = server!(ctx)

      for version <- ["2.1.293", nil, "", "2.1.294 ", :"2.1.294", 2_001_294] do
        PinnedCLI.inject_identity!(ctx.bin, version: version)
        result = resolve(server)

        assert result == {:error, :pinned_cli_version_mismatch},
               "E3: identity version #{inspect(version)} must refuse " <>
                 ":pinned_cli_version_mismatch, got #{inspect(result)}"

        assert {:error, :pinned_cli_version_mismatch} =
                 complete(server, ctx.run, ctx.agent, "version-#{inspect(version)}")
      end

      message =
        try do
          Function.capture(Runtime, :refusal_message, 1).(:pinned_cli_version_mismatch)
        rescue
          FunctionClauseError -> nil
        end

      assert is_binary(message) and message =~ "no model call was made",
             "E3: Runtime.refusal_message(:pinned_cli_version_mismatch) needs a fixed message"

      assert invocations(ctx.run, ctx.agent) == []
      assert consumed(ctx, grant) == 0
      assert PinnedCLI.launches(ctx.counter) == 0
    end

    test "a version mismatch at the server's launch fails the charged row, never launched",
         ctx do
      healthy!()
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      server = server!(ctx)
      :ok = :sys.suspend(server)
      task = Task.async(fn -> complete(server, ctx.run, ctx.agent, "launch-version") end)

      {stage, result} =
        case reserved_or_done(task, ctx.run, ctx.agent) do
          :reserved ->
            PinnedCLI.inject_identity!(ctx.bin, version: "2.1.293")
            :ok = :sys.resume(server)
            {:reserved, Task.await(task, 30_000)}

          {:done, result} ->
            :ok = :sys.resume(server)
            {:done, result}
        end

      assert stage == :reserved,
             "E3: the call must resolve and reserve before the server's launch check, " <>
               "got #{inspect(result)}"

      assert result == {:error, :pinned_cli_version_mismatch},
             "E3: the server must re-check the version binding before launch, got #{inspect(result)}"

      assert [invocation] = invocations(ctx.run, ctx.agent)
      assert {invocation.status, invocation.sent_at} == {:failed, nil}
      assert invocation.error["reason"] == "pinned_cli_version_mismatch"
      assert consumed(ctx, grant) == 1
      assert PinnedCLI.launches(ctx.counter) == 0
    end

    test "a tuple not promoted is :tuple_not_promoted at reservation", ctx do
      AdmissionFixtures.admit_tuples!(entries: [])
      assert_reservation_refused(ctx, :tuple_not_promoted, :not_promoted)
    end

    test "an unset store root is :witness_store_untrusted (:store_unset)", ctx do
      healthy!()
      AdmissionFixtures.put_root!(nil)
      assert_reservation_refused(ctx, :witness_store_untrusted, :store_unset)
    end

    test "an untrusted store root is :witness_store_untrusted (:store_untrusted)", ctx do
      healthy!()
      AdmissionFixtures.put_root!(Path.join(ctx.dir, "untrusted-store"))
      assert_reservation_refused(ctx, :witness_store_untrusted, :store_untrusted)
    end

    test "an inactive result gate is :result_gate_inactive (refuse-only seam)", ctx do
      healthy!()
      AdmissionFixtures.gate_inactive!()
      assert_reservation_refused(ctx, :result_gate_inactive, :inactive)
    end

    test "no grant is :no_eligible_grant at reservation", ctx do
      healthy!()
      server = server!(ctx)
      result = complete(server, ctx.run, ctx.agent, "no-grant")

      assert match?(
               {:error, %Refused{stage: :reservation, reason: :no_eligible_grant, check: nil}},
               result
             ),
             "E3: with provider and store healthy and no grant the refusal must be " <>
               ":no_eligible_grant, got #{inspect(result)}"

      assert invocations(ctx.run, ctx.agent) == []
      assert PinnedCLI.launches(ctx.counter) == 0
    end
  end

  ## 3. Post-launch init drift

  describe "E3 3: post-launch init drift is charged and withheld, never retried" do
    for {mode, reason} <- [
          {"model_drift", :model_attestation_drift},
          {"version_drift", :version_attestation_drift}
        ] do
      test "#{mode}: charged, withheld, one attempt, a critical provider_error", ctx do
        reason = unquote(reason)
        healthy!()
        grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
        %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
        server = fake_server!(ctx, [unquote(mode)])

        result =
          Model.call(sdr(run, agent, server), :qualification, input(:qualification), lead())

        attempts = invocations(run, agent)

        assert length(attempts) == 1,
               "E3: a drifted ordinary launch must be one charged attempt, got " <>
                 "#{inspect(result)} with #{length(attempts)} invocation(s)"

        [invocation] = attempts
        assert result == {:error, {:halt, :provider_error}}
        assert invocation.status == :failed
        assert invocation.sent_at != nil
        assert invocation.error["reason"] == Atom.to_string(reason)
        assert consumed(ctx, grant) == 1
        assert {:ok, nil} = Agents.get_result_release(invocation.id, actor: agent)
        assert {:error, :result_not_released} = Agents.released_output(invocation, actor: agent)
        assert %{status: :drift, reason: ^reason} = ClaudeCLI.attestation(server)

        assert [failure] = failures(invocation)

        assert {failure.class, failure.severity, failure.status} ==
                 {:provider_error, :critical, :open}

        assert run_state(run, agent) == {:failed, :provider_error}
      end
    end
  end

  ## 4. After merge, no grant

  describe "E3 4: after merge, before any grant" do
    test "provider and store healthy: :no_eligible_grant, the run stops, nothing launches",
         ctx do
      healthy!()
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      server = server!(ctx)

      assert match?({:ok, _model}, resolve(server)),
             "E3: the pinned server must be eligible, got #{inspect(resolve(server))}"

      result = Model.call(sdr(run, agent, server), :qualification, input(:qualification), lead())
      assert result == {:error, {:halt, :grant_unavailable}}

      {:ok, stopped} = Agents.get_run(run.id, actor: agent)
      assert {stopped.status, stopped.status_reason} == {:failed, :grant_unavailable}
      assert stopped.attention_failure_id != nil
      assert invocations(run, agent) == []
      assert PinnedCLI.launches(ctx.counter) == 0
    end
  end

  ## 8. Withholding boundaries (the mismatch boundary is item 1's negative)

  describe "E3 8: every withholding boundary stays charged and withheld" do
    setup ctx do
      root = healthy!()
      grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant)
      %{root: root, grant: grant, run: run, agent: agent}
    end

    test "a capture still missing at the gate's bound is withheld :witness_timeout", ctx do
      previous = Application.get_env(:sdr_agent, ResultGate, [])

      Application.put_env(
        :sdr_agent,
        ResultGate,
        Keyword.merge(previous, wait_ms: 300, poll_ms: 50)
      )

      on_exit(fn -> Application.put_env(:sdr_agent, ResultGate, previous) end)
      server = fake_server!(ctx, ["sdr", ctx.root, "none"])

      result =
        Model.call(sdr(ctx.run, ctx.agent, server), :qualification, input(:qualification), lead())

      assert result == {:error, {:halt, :witness_unreconciled}},
             "E3: a timed-out ordinary capture must be withheld after spend, got #{inspect(result)}"

      assert [invocation] = invocations(ctx.run, ctx.agent)
      assert invocation.status == :completed

      assert {:ok, %{disposition: :withheld, reason: :witness_timeout}} =
               Agents.get_result_release(invocation.id, actor: ctx.agent)

      assert {:error, :result_not_released} =
               Agents.released_output(invocation, actor: ctx.agent)

      assert consumed(ctx, ctx.grant) == 1
      assert run_state(ctx.run, ctx.agent) == {:failed, :witness_unreconciled}
    end

    test "a CLI that never answers is killed at its deadline: unknown, charged, withheld",
         ctx do
      server = fake_server!(ctx, ["hang", Path.join(ctx.dir, "hang")], timeout: 2_000)

      result =
        Model.call(sdr(ctx.run, ctx.agent, server), :qualification, input(:qualification), lead())

      attempts = invocations(ctx.run, ctx.agent)

      assert match?([%{status: :unknown}], attempts),
             "E3: a timed-out ordinary launch must leave one unknown charged attempt, got " <>
               "#{inspect(result)} with #{inspect(Enum.map(attempts, & &1.status))}"

      [invocation] = attempts
      assert result == {:error, {:halt, :provider_error}}
      assert invocation.sent_at != nil
      assert {:ok, nil} = Agents.get_result_release(invocation.id, actor: ctx.agent)

      assert {:error, :result_not_released} =
               Agents.released_output(invocation, actor: ctx.agent)

      assert consumed(ctx, ctx.grant) == 1
      assert run_state(ctx.run, ctx.agent) == {:failed, :provider_error}
    end

    test "a CLI that exits before answering (crash) is failed, charged, withheld", ctx do
      # `pinned` mode exits 3 without an init event unless it was told the
      # exact pinned path: here it never is.
      server = fake_server!(ctx, ["pinned", Path.join(ctx.dir, "not-the-pin")])

      result =
        Model.call(sdr(ctx.run, ctx.agent, server), :qualification, input(:qualification), lead())

      attempts = invocations(ctx.run, ctx.agent)

      assert match?([%{status: :failed, sent_at: %DateTime{}}], attempts),
             "E3: a crashed ordinary launch must leave one failed, sent, charged attempt, got " <>
               "#{inspect(result)} with #{inspect(Enum.map(attempts, & &1.status))}"

      [invocation] = attempts
      assert result == {:error, {:halt, :provider_error}}
      assert invocation.error["reason"] == "missing_init_attestation"
      assert {:ok, nil} = Agents.get_result_release(invocation.id, actor: ctx.agent)

      assert {:error, :result_not_released} =
               Agents.released_output(invocation, actor: ctx.agent)

      assert consumed(ctx, ctx.grant) == 1
      assert run_state(ctx.run, ctx.agent) == {:failed, :provider_error}
    end
  end

  ## 9. Calibration still needs its exemption

  describe "E3 9: calibration on the ordinary pinned server" do
    test "control: a :calibration request without its exemption entry stays staged", ctx do
      healthy!()
      AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
      %{run: run, agent: agent} = AgentsFixtures.running_run(ctx.tenant, usage_origin: :proof)
      key = "calibration-#{System.unique_integer([:positive])}"

      {:ok, reserved} =
        Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs(key),
          actor: agent,
          calibration: AdmissionFixtures.calibration()
        )

      server = server!(ctx)

      request = %{
        id: key,
        operation: "calibration.complete",
        prompt: CalibrationPrompt.render(),
        schema: CalibrationPrompt.schema(),
        actor: agent,
        witness: witness(reserved.id),
        calibration: %{
          authority: {SdrAgent.CalibrationConsole.Authority, "never-issued"},
          run_id: run.id,
          tenant_id: run.tenant_id,
          instance: String.duplicate("a", 32),
          observer: {self(), make_ref()}
        }
      }

      assert ClaudeCLI.complete(request, server: server) == {:error, :real_model_staged}
      assert Process.alive?(server)
      assert status(reserved) == {:reserved, nil}
      assert launch_refusals(ctx.tenant, reserved) == []
      assert PinnedCLI.launches(ctx.counter) == 0
    end
  end

  ## 12. No real model call

  describe "E3 12: no real model call" do
    test "control: the pin here is a stand-in and the shim on PATH is the recording stub",
         ctx do
      assert ctx.bin == System.find_executable("elixir")
      refute ctx.bin in Enum.map(Map.values(PinnedExecutable.recorded()), & &1.executable)
      refute ctx.bin =~ "app-claude-cli"
      assert String.starts_with?(System.find_executable("llm-proxy-shim"), ctx.dir)
      assert PinnedCLI.launches(ctx.counter) == 0
    end
  end

  ## Helpers

  # The promoted tuples shipped in config/config.exs (R0-06, #172) and a
  # fresh trusted store root; returns the root.
  defp healthy! do
    shipped =
      Config.Reader.read!("config/config.exs", env: :prod, target: :host)
      |> Keyword.fetch!(:sdr_agent)
      |> Keyword.fetch!(SdrAgent.Agents.Witness)
      |> Keyword.fetch!(:reconciled_methods)

    assert Enum.any?(shipped, &(&1.profile_id == :claude_cli_opus))
    assert Enum.any?(shipped, &(&1.profile_id == :claude_cli_sonnet))
    %{root: root} = AdmissionFixtures.admit_tuples!(entries: shipped)
    root
  end

  # A pinned, unnamed, non-test-launcher server; its command defaults to the
  # recording stub shim (nothing may launch).
  defp server!(ctx, opts \\ []) do
    opts =
      Keyword.merge([executable: ctx.bin, profile: :claude_cli_opus, environment: %{}], opts)

    start_supervised!(%{id: make_ref(), start: {ClaudeCLI, :start_link, [opts]}})
  end

  defp fake_server!(ctx, args, opts \\ []) do
    server!(
      ctx,
      [command: System.find_executable("elixir"), command_args: [@fake | args]] ++ opts
    )
  end

  # The fake CLI's `sdr` mode answers evidence_extraction, qualification and
  # reply_classification, and its v3 capture always names the Opus model;
  # outreach_proposal and every Sonnet call use the generated responder.
  defp purpose_server!(ctx, purpose, profile, root, variant)
       when purpose == :outreach_proposal or profile == :claude_cli_sonnet do
    server!(ctx,
      command: System.find_executable("elixir"),
      command_args: responder_args(ctx.dir, answer(purpose), root, variant),
      profile: profile
    )
  end

  defp purpose_server!(ctx, _purpose, profile, root, variant),
    do: fake_server!(ctx, ["sdr", root, variant], profile: profile)

  @doc false
  # The responder's command args for one answer: a script that plays shim,
  # v3 proxy store and CLI for one call, as the fake CLI's `sdr` mode does,
  # with the captured request naming the launched model (`--model`) and
  # `answer` as the output (synthetic text only). Written under `dir`.
  def responder_args(dir, answer, root, variant) do
    path = Path.join(dir, "responder.exs")
    answer_path = Path.join(dir, "answer-#{System.unique_integer([:positive])}.json")
    File.write!(answer_path, JSON.encode!(answer))

    File.write!(path, """
    Code.require_file(#{inspect(@proxy)})
    alias SdrAgent.Test.FakeWitnessProxy, as: Proxy

    [answer_path, root, variant | _] =
      Enum.take_while(System.argv(), &(not String.starts_with?(&1, "-")))

    text = File.read!(answer_path)

    model =
      case Enum.drop_while(System.argv(), &(&1 != "--model")) do
        ["--model", "opus" | _] -> "claude-opus-5-5"
        ["--model", "sonnet" | _] -> "claude-sonnet-5-5"
        _ -> "claude-unreviewed"
      end

    stdin = IO.read(:stdio, :eof)
    id = System.get_env("SDR_MODEL_INVOCATION_ID")
    tp = System.get_env("SDR_TRACEPARENT")

    shape = [
      cache_ttl: "1h",
      trailing_message_extra: %{"output_config" => %{"effort" => "high"}},
      top: %{"model" => model}
    ]

    reminders = ["<system-reminder>\\nSynthetic date.\\n</system-reminder>\\n"]

    if id do
      case variant do
        "cli_shape_v3" ->
          Proxy.exchange!(root, id,
            traceparent: tp,
            request: Proxy.cli_request(stdin, [reminders: reminders] ++ shape),
            response: Proxy.sse_response(text)
          )

        "cli_shape_v3_mismatch" ->
          Proxy.exchange!(root, id,
            traceparent: tp,
            request: Proxy.cli_request(stdin <> " (edited)", shape),
            response: Proxy.sse_response(text)
          )
      end
    end

    init = %{
      "type" => "system",
      "subtype" => "init",
      "model" => model,
      "claude_code_version" => "2.1.294",
      "tools" => [],
      "mcp_servers" => [],
      "slash_commands" => []
    }

    IO.puts(JSON.encode!(init))

    IO.puts(
      JSON.encode!(%{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => text,
        "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
      })
    )
    """)

    [path, answer_path, root, variant]
  end

  @doc false
  # The answers of the fake CLI's `sdr` mode, plus an outreach proposal.
  def answer(:evidence_extraction), do: %{"claims" => []}

  def answer(:qualification) do
    %{
      "qualified" => false,
      "score" => 5,
      "criteria" => %{
        "company_size" => "unknown",
        "industry" => "unknown",
        "geography" => "unknown",
        "persona" => "unknown",
        "trigger" => "unknown"
      },
      "confidence" => 0.4,
      "evidence_ids" => [],
      "reason" => "no evidence was extracted"
    }
  end

  def answer(:reply_classification) do
    %{
      "classification" => "interested",
      "sentiment" => "positive",
      "intent" => "wants a call next week",
      "suggested_next_action" => "hand_off",
      "confidence" => 0.9,
      "reason" => "asks to set up a call"
    }
  end

  def answer(:outreach_proposal) do
    %{
      "subject" => "Warehouse automation at Example Robotics",
      "body" =>
        "Hi Ada, Example Robotics builds warehouse robots.\n\n" <>
          "Would a 15-minute call next week be useful? Best, Sam",
      "angle" => "warehouse automation",
      "cta" => "A 15-minute call next week",
      "claims" => [
        %{
          "claim" => "Example Robotics builds warehouse robots.",
          "evidence_id" => "ev-1",
          "confidence" => 0.9
        }
      ],
      "personalization" => [
        %{"text" => "Example Robotics builds warehouse robots.", "evidence_id" => "ev-1"}
      ],
      "risk_flags" => [],
      "evidence_ids" => ["ev-1"]
    }
  end

  # Synthetic inputs in each SDR action's input shape.
  defp input(:evidence_extraction) do
    %{
      company: %{name: "Example Robotics", domain: "example.com"},
      contact: %{name: "Ada Example", title: "VP Operations"},
      sources: [
        %{
          index: 0,
          source_type: "website",
          title: "About Example Robotics",
          url: "https://example.com/about",
          trust_level: "first_party",
          content: "Example Robotics builds warehouse robots."
        }
      ]
    }
  end

  defp input(:qualification) do
    %{
      icp: %{
        name: "Synthetic ICP",
        version: 1,
        employee_count_min: 50,
        employee_count_max: 500,
        industries: ["robotics"],
        geographies: ["US"],
        personas: ["operations"],
        triggers: ["expansion"]
      },
      company: %{
        name: "Example Robotics",
        industry: "robotics",
        employee_count: 120,
        geography: "US"
      },
      contact: %{title: "VP Operations", persona: "operations"},
      evidence: []
    }
  end

  defp input(:outreach_proposal) do
    %{
      contact: %{name: "Ada Example", title: "VP Operations"},
      company: %{name: "Example Robotics", domain: "example.com"},
      sender: %{name: "Sam Sender", title: "SDR"},
      step: %{instructions: "Introduce the offering in two short paragraphs."},
      evidence: [%{id: "ev-1", claim: "Example Robotics builds warehouse robots."}],
      triggers: []
    }
  end

  defp input(:reply_classification),
    do: %{reply: %{subject: "Re: hello", text: "Sounds interesting, could we talk next week?"}}

  defp origin(:reply_classification), do: :reply
  defp origin(_purpose), do: :assignment

  defp bucket(:reply_classification), do: :b5
  defp bucket(_purpose), do: :b1

  defp sdr(run, agent, server) do
    %Context{
      actor: agent,
      tenant_id: run.tenant_id,
      run_id: run.id,
      correlation_id: run.correlation_id,
      signal_id: "sig-#{System.unique_integer([:positive])}",
      model: [provider: ClaudeCLI, provider_options: [server: server]]
    }
  end

  defp lead, do: Ecto.UUID.generate()

  # Through a capture: the result is compared with E3 reasons the current
  # code cannot yet return (no type-checker warning).
  defp resolve(server),
    do:
      Function.capture(Runtime, :resolve, 1).(
        provider: ClaudeCLI,
        provider_options: [server: server]
      )

  defp request(run, agent, key) do
    attrs = AgentsFixtures.model_attrs(key)

    %{
      id: key,
      run: run,
      actor: agent,
      operation: "model.complete",
      prompt: "Qualify the fixture lead (#{key})",
      schema: @schema,
      audit:
        Map.take(attrs, [
          :purpose,
          :parameters,
          :prompt_template_id,
          :prompt_template_version,
          :prompt_template_sha256,
          :output_schema_id,
          :output_schema_version,
          :output_schema_sha256
        ])
    }
  end

  defp complete(server, run, agent, key) do
    ModelProvider.complete(request(run, agent, "#{key}-#{System.unique_integer([:positive])}"),
      provider: ClaudeCLI,
      provider_options: [server: server]
    )
  end

  # A request sent straight to the server, past the facade.
  defp direct(server, fields) do
    %{id: "direct", operation: "model.complete", prompt: "Direct entry", schema: @schema}
    |> Map.merge(fields)
    |> ClaudeCLI.complete(server: server)
  end

  defp witness(id) do
    trace = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    span = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    %{model_invocation_id: id, traceparent: "00-#{trace}-#{span}-01"}
  end

  defp reserve!(run, agent, key) do
    attrs = AgentsFixtures.claude_attrs("#{key}-#{System.unique_integer([:positive])}")
    {:ok, reserved} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    reserved
  end

  defp assert_reservation_refused(ctx, reason, check) do
    grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    server = server!(ctx)
    result = complete(server, ctx.run, ctx.agent, "refused-#{reason}")

    assert match?(
             {:error, %Refused{stage: :reservation, reason: ^reason, check: ^check}},
             result
           ),
           "E3: with every earlier predicate passing the refusal must be #{reason} (#{check}), " <>
             "got #{inspect(result)}"

    assert invocations(ctx.run, ctx.agent) == []
    assert consumed(ctx, grant) == 0
    assert PinnedCLI.launches(ctx.counter) == 0
  end

  defp reserved_or_done(task, run, agent, attempts \\ 1_000) do
    case Agents.list_model_invocations(run.id, actor: agent) do
      {:ok, [%{status: :reserved}]} ->
        :reserved

      _none ->
        case Task.yield(task, 0) do
          {:ok, result} ->
            {:done, result}

          nil when attempts > 0 ->
            Process.sleep(10) && reserved_or_done(task, run, agent, attempts - 1)

          other ->
            {:done, {:no_reservation, other}}
        end
    end
  end

  defp invocations(run, agent) do
    {:ok, invocations} = Agents.list_model_invocations(run.id, actor: agent)
    invocations
  end

  defp status(invocation) do
    row = Ash.get!(ModelInvocation, invocation.id, authorize?: false)
    {row.status, row.sent_at}
  end

  defp run_state(run, agent) do
    {:ok, run} = Agents.get_run(run.id, actor: agent)
    {run.status, run.status_reason}
  end

  defp consumed(ctx, grant) do
    {:ok, usage} = Agents.grant_usage([grant.id], actor: ctx.admin)
    usage[grant.id].consumed
  end

  defp failures(invocation) do
    Failure
    |> Ash.Query.filter(subject_id == ^invocation.id)
    |> Ash.read!(authorize?: false)
  end

  defp launch_refusals(tenant, invocation) do
    tenant
    |> events_of_type("model.launch.refused")
    |> Enum.filter(&(&1.model_invocation_id == invocation.id or &1.subject_id == invocation.id))
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()
end

defmodule SdrAgent.AI.OrdinaryCallWorkerTest do
  @moduledoc """
  L2 E3 RED, plan item 1 at the worker level: `AgentWorker`
  (evidence_extraction; `:assignment` → `:b1`) and `ReplyWorker`
  (reply_classification; `:reply` → `:b5`) through the one named ClaudeCLI
  server, pinned and **without** `test_launcher`, so the real launch
  admission runs. Opus calls are played by the fake CLI's `sdr` mode; Sonnet
  calls by the generated responder of `SdrAgent.AI.OrdinaryCallTest` (the
  `sdr` mode's v3 capture always names the Opus model). A released output
  is consumed by the run's next step; a mismatched capture is withheld,
  charged and never consumed.

  With the fake's empty evidence claims the assignment run ends after
  evidence_extraction, so qualification and outreach_proposal are covered
  at the `SDR.Model.call/4` level in `SdrAgent.AI.OrdinaryCallTest`.
  """
  use SdrAgent.SDRCase, async: false

  import SdrAgent.OutreachFixtures
  import SdrAgent.WebhookFixtures

  alias SdrAgent.Agents
  alias SdrAgent.Agents.UsageBucket
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.OrdinaryCallTest
  alias SdrAgent.Operations
  alias SdrAgent.Test.PinnedCLI

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @profiles [:claude_cli_opus, :claude_cli_sonnet]

  setup ctx do
    shipped =
      Config.Reader.read!("config/config.exs", env: :prod, target: :host)
      |> Keyword.fetch!(:sdr_agent)
      |> Keyword.fetch!(SdrAgent.Agents.Witness)
      |> Keyword.fetch!(:reconciled_methods)

    %{root: root} = SdrAgent.AdmissionFixtures.admit_tuples!(entries: shipped)
    grant = AgentsFixtures.grant!(ctx.tenant, %{}, ctx.admin)
    dir = Path.join(System.tmp_dir!(), "sdr-l2e3ocw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{root: root, grant: grant, dir: dir, bin: PinnedCLI.inject_identity!()}
  end

  # Opus: the fake CLI's `sdr` mode; Sonnet: the generated responder
  # answering `purpose` (the `sdr` mode's v3 capture always names Opus).
  defp named!(ctx, profile, variant, purpose) do
    args =
      if profile == :claude_cli_opus,
        do: [@fake, "sdr", ctx.root, variant],
        else:
          OrdinaryCallTest.responder_args(
            ctx.dir,
            OrdinaryCallTest.answer(purpose),
            ctx.root,
            variant
          )

    start_supervised!(
      {ClaudeCLI,
       name: ClaudeCLI.server(),
       command: System.find_executable("elixir"),
       command_args: args,
       executable: ctx.bin,
       profile: profile,
       environment: %{}}
    )

    assert %{test_launcher?: false, executable: bin} = ClaudeCLI.attestation()
    assert bin == ctx.bin
  end

  defp consumed(ctx) do
    {:ok, usage} = Agents.grant_usage([ctx.grant.id], actor: ctx.admin)
    usage[ctx.grant.id].consumed
  end

  defp consuming_decisions(ctx, run, invocation),
    do: Enum.filter(decisions!(ctx, run), &(&1.model_invocation_id == invocation.id))

  describe "E3 1: AgentWorker on the ordinary pinned server" do
    setup do
      put_env!(:model_provider, ClaudeCLI)
      :ok
    end

    for profile <- @profiles do
      test "evidence_extraction on #{profile} is released and the run consumes it", ctx do
        profile = unquote(profile)
        named!(ctx, profile, "cli_shape_v3", :evidence_extraction)
        %{run: run, operation: operation} = assign!(ctx, "01")

        drained = drain!()
        run = run!(ctx, run)

        assert {drained.success, run.status} == {1, :succeeded},
               "E3: an ordinary assignment run on #{profile} must succeed, got " <>
                 inspect({drained, run.status, run.status_reason, run.failure_reason})

        # The fake's empty claims end the research: no qualification call.
        assert [invocation] = invocations!(ctx, run)

        assert {invocation.purpose, invocation.provider, invocation.profile_id} ==
                 {:evidence_extraction, :claude_cli, profile}

        assert {invocation.status, invocation.grant_id} == {:completed, ctx.grant.id}

        assert {:ok, %{disposition: :released}} =
                 Agents.get_result_release(invocation.id, actor: ctx.agent)

        assert {:ok, %{"claims" => []}} = Agents.released_output(invocation, actor: ctx.agent)
        assert "sdr.research.completed" in signal_types(ctx.tenant, run)
        assert consumed(ctx) == 1

        assert {:ok, %{status: :succeeded}} =
                 Operations.get_operation(operation.id, actor: ctx.admin)
      end
    end

    test "a mismatched capture is withheld, charged and never consumed", ctx do
      named!(ctx, :claude_cli_opus, "cli_shape_v3_mismatch", :evidence_extraction)
      %{run: run} = assign!(ctx, "01")

      drained = drain!()
      run = run!(ctx, run)

      assert {drained.success, run.status, run.status_reason} == {1, :failed, :witness_mismatch},
             "E3: a mismatched ordinary capture must stop the run :witness_mismatch, got " <>
               inspect({drained, run.status, run.status_reason, run.failure_reason})

      assert [invocation] = invocations!(ctx, run)
      assert invocation.purpose == :evidence_extraction

      assert {:ok, %{disposition: :withheld, reason: :witness_mismatch}} =
               Agents.get_result_release(invocation.id, actor: ctx.agent)

      assert {:error, :result_not_released} = Agents.released_output(invocation, actor: ctx.agent)
      assert consuming_decisions(ctx, run, invocation) == []
      assert consumed(ctx) == 1
    end
  end

  describe "E3 1: ReplyWorker on the ordinary pinned server" do
    # The outreach is drafted and delivered on the Fake; only the reply's
    # classification runs with ClaudeCLI selected.
    setup ctx do
      approved = approved!(ctx, "01")
      assert %{success: 1} = deliver!()
      delivery = outreach!(ctx, approved.delivery)

      put_env!(:model_provider, ClaudeCLI)
      text = "Thanks, this sounds interesting. Could we set up a call next week?"
      assert {:ok, %{status: :accepted}} = ingest!("reply", reply_body(delivery, text))
      assert %{success: 1} = process!()

      {:ok, runs} = Agents.list_runs(actor: ctx.agent, lead_id: approved.lead.id)
      [run] = Enum.filter(runs, &(&1.trigger_signal_type == "sdr.reply.received"))
      assert {run.status, run.usage_origin} == {:queued, :reply}
      assert UsageBucket.bucket(:reply, :reply_classification) == :b5
      %{reply_run: run, before: consumed(ctx)}
    end

    defp classify!, do: Oban.drain_queue(queue: :agent, with_safety: false)

    for profile <- @profiles do
      test "reply_classification on #{profile} is released and consumed", ctx do
        profile = unquote(profile)
        named!(ctx, profile, "cli_shape_v3", :reply_classification)
        drained = classify!()
        run = run!(ctx, ctx.reply_run)

        assert {drained.success, run.status} == {1, :succeeded},
               "E3: an ordinary reply run on #{profile} must succeed, got " <>
                 inspect({drained, run.status, run.status_reason, run.failure_reason})

        assert [invocation] = invocations!(ctx, run)

        assert {invocation.purpose, invocation.provider, invocation.profile_id} ==
                 {:reply_classification, :claude_cli, profile}

        assert {:ok, %{disposition: :released}} =
                 Agents.get_result_release(invocation.id, actor: ctx.agent)

        assert {:ok, %{}} = Agents.released_output(invocation, actor: ctx.agent)
        assert [_ | _] = consuming_decisions(ctx, run, invocation)
        assert consumed(ctx) == ctx.before + 1
      end
    end

    test "a mismatched reply capture is withheld, charged and never consumed", ctx do
      named!(ctx, :claude_cli_opus, "cli_shape_v3_mismatch", :reply_classification)
      drained = classify!()
      run = run!(ctx, ctx.reply_run)

      assert {drained.success, run.status, run.status_reason} == {1, :failed, :witness_mismatch},
             "E3: a mismatched ordinary reply capture must stop the run :witness_mismatch, got " <>
               inspect({drained, run.status, run.status_reason, run.failure_reason})

      assert [invocation] = invocations!(ctx, run)

      assert {:ok, %{disposition: :withheld, reason: :witness_mismatch}} =
               Agents.get_result_release(invocation.id, actor: ctx.agent)

      assert {:error, :result_not_released} = Agents.released_output(invocation, actor: ctx.agent)
      assert consuming_decisions(ctx, run, invocation) == []
      assert consumed(ctx) == ctx.before + 1
    end
  end
end
