defmodule SdrAgent.Agents.DemoExceptionAdmissionTest do
  @moduledoc """
  C2* S3 RED-5, the demo-exception admission guard (S3 plan r2 §6
  Admission, LinkRefusalAttention and ClaudeCLI; §8 row
  `demo_exception_admission_test.exs`; AC11; ADR-0005 C2* item 3; R5,
  OQ8-OQ10).

  With the selector on, a real call is refused `:demo_exception_window`
  unless `effective_starts_at ≤ now < effective_expires_at − (T +
  ResultGate.wait_ms() + 60_000 ms)`. The check is one of:

    * `:authorization_unavailable`: the entry names no authorization, or
      the Source has none registered for it (OQ9; the selector is not
      authority);
    * `:not_started`;
    * `:launch_margin`.

  The effective window is `DemoException.effective_window/3` of the
  call's own grant, allocation and authorization. T is the provider's
  effective validated startup timeout (OQ10):

    * at reservation, the app's named server's published value; else the
      configured `:timeout` (an integer ≥ 1000); else 240_000 ms, never
      the module's 120_000 default;
    * at launch, the launching server's own published value.

  The plan IDs covered:

    * **T-W2.** A refused reservation writes no invocation and changes no
      counter or charge. It records one critical `provider_error` Failure
      of the run, with the fixed message, and one
      `model.reservation.refused` event naming it. A refused launch fails
      the row: it is never sent, stays charged, and appends
      `model.launch.refused`.
    * **T-W2b (R5).** The reason is an admission reason, so at both stages
      the run stops `:model_not_admitted` linking exactly that Failure
      (`LinkRefusalAttention`). The existing reasons keep their mappings.
    * **T-W2c (OQ10).** The margin's T at reservation and at launch. The
      unit cases of the lookup are in
      `test/sdr_agent/ai/claude_cli_effective_timeout_test.exs`.
    * **The S3 half of T-W5.** Disjoint allocation windows A and B with a
      gap: A's own end bounds A's calls; a gap reservation is refused
      `:no_allocation` with nothing charged; a call in B is admitted; and
      A's demo output loses use authority at A's end while B is open.

  Each test starts in `DemoExceptionFixtures.demo_env!/1` at its default
  instant (inside the window), then freezes the clock at the instant under
  test. With no further option, the effective end is the policy end
  (2026-11-01T06:00:00Z): the authorization and grant end there, and the
  allocation is unbounded. No ClaudeCLI server is registered under the
  app's name, and none is configured, unless a test says so.

  Classification (RED-5 at b30364b9):

    * **behavioural:** every refusal (today the call is admitted) and
      `admission_reason?(:demo_exception_window)` (false today);
    * **structural:** `Admission.demo_exception_reasons/0` is absent;
    * **`control:`** (passes today and must stay green): admission inside
      the window, selector off, a Fake call, the 240_000 ms instant without
      a server, a server running 240_000 ms, the existing reason mappings,
      and the per-window T-W5 sequence.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.AdmissionFixtures
  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.Admission.SwitchFence
  alias SdrAgent.Agents.DemoException
  alias SdrAgent.Agents.ModelCallAllocation
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ReleasedOutput
  alias SdrAgent.Agents.ResultGate
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Clock
  alias SdrAgent.DemoExceptionFixtures, as: Fx
  alias SdrAgent.Operations.Failure
  alias SdrAgent.SDR
  alias SdrAgent.SDR.Context

  @end_at ~U[2026-11-01 06:00:00.000000Z]
  @run_resource "SdrAgent.Agents.AgentRun"
  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @variant "cli_shape_v4_thinking_count_tokens"
  @message_tail "the demo exception window leaves no time for this call"

  # The S3 half of T-W5: window A, a gap, then window B (to the policy end).
  @a_from ~U[2026-10-28 00:00:00.000000Z]
  @a_until ~U[2026-10-29 00:00:00.000000Z]
  @gap ~U[2026-10-29 12:00:00.000000Z]
  @b_from ~U[2026-10-30 00:00:00.000000Z]
  @in_b ~U[2026-10-30 12:00:00.000000Z]
  @windows [
    %{
      key: :daily_use,
      applies_to: ModelCallAllocation.buckets(),
      attempts: 20,
      available_from: @a_from,
      available_until: @a_until
    },
    %{
      key: :workshop,
      applies_to: ModelCallAllocation.buckets(),
      attempts: 20,
      available_from: @b_from
    }
  ]

  @grant_reasons [
    :no_usage_origin,
    :no_eligible_grant,
    :no_allocation,
    :ambiguous_allocation,
    {:budget_exhausted, :grant},
    {:budget_exhausted, :grant_day},
    {:budget_exhausted, :allocation}
  ]

  setup ctx do
    saved = Application.fetch_env(:sdr_agent, ClaudeCLI)
    Application.delete_env(:sdr_agent, ClaudeCLI)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:sdr_agent, ClaudeCLI, value)
        :error -> Application.delete_env(:sdr_agent, ClaudeCLI)
      end
    end)

    assert Process.whereis(ClaudeCLI.server()) == nil, "no app ClaudeCLI server runs in tests"
    %{env: Fx.demo_env!(Map.get(ctx, :demo_env, []))}
  end

  describe "admitted (controls)" do
    test "control: a real call inside the window with room is reserved, charged to the demo " <>
           "grant, and launched",
         %{env: env} do
      assert {:ok, invocation} = reserve(env, "inside")
      assert {invocation.grant_id, invocation.allocation_id} == {env.grant.id, env.allocation.id}
      assert {:ok, %{status: :sent}} = launch(env, invocation)
    end

    @tag demo_env: [selector: false]
    test "control: with the selector off the guard does not apply", %{env: env} do
      at!(before_end(250_000))
      assert {:ok, invocation} = reserve(env, "selector-off")
      assert {:ok, %{status: :sent}} = launch(env, invocation)
    end

    test "control: a Fake call is not a real call", %{env: env} do
      at!(before_end(250_000))
      attrs = AgentsFixtures.model_attrs("fake-call")

      assert {:ok, %{provider: :fake}} =
               Agents.reserve_model_invocation(env.run, attrs, actor: env.agent)
    end
  end

  describe "reservation (T-W2, AC11)" do
    test "launch_margin: with neither a running server nor a configured timeout, T is " <>
           "240_000 ms, never the module's 120_000; the run stops :model_not_admitted",
         %{env: env} do
      assert margin(120_000) < 250_000 and 250_000 < margin(240_000)
      at!(before_end(250_000))
      {refused, failure} = assert_reservation_refused(env, "margin", :launch_margin)
      assert_stopped(env, refused, failure)
    end

    test "launch_margin boundary: one microsecond before end − margin is admitted, exactly " <>
           "end − margin is refused",
         %{env: env} do
      t = margin(240_000)
      at!(DateTime.add(before_end(t), -1, :microsecond))
      assert {:ok, _invocation} = reserve(env, "boundary-in")
      at!(before_end(t))
      assert_reservation_refused(env, "boundary-at", :launch_margin)
    end

    test "not_started: the authorization starts after now", %{env: env} do
      late = %{env.authorization | starts_at: DateTime.add(env.now, 3_600, :second)}
      id = Fx.authorization_id()

      Fx.put_source!(:authorization, fn requested ->
        if requested == id, do: {:ok, late}, else: :error
      end)

      assert_reservation_refused(env, "not-started", :not_started)
    end

    test "authorization_unavailable: the entry names no authorization", %{env: env} do
      Fx.put_source!(:authorization_id, nil)
      assert DemoException.inert?()
      assert_reservation_refused(env, "inert", :authorization_unavailable)
    end

    test "authorization_unavailable: the Source has no authorization for the entry's id",
         %{env: env} do
      Fx.put_source!(:authorization, :error)
      assert_reservation_refused(env, "unregistered", :authorization_unavailable)
    end

    test "authorization_unavailable: the shipped Source (Unattested) with the selector on",
         %{env: env} do
      Application.delete_env(:sdr_agent, SdrAgent.Test.DemoExceptionSource)
      assert DemoException.source() == DemoException.Unattested
      assert DemoException.selected?() and DemoException.inert?()
      assert_reservation_refused(env, "shipped", :authorization_unavailable)
    end
  end

  describe "launch (T-W2, AC11)" do
    test "launch_margin: a call reserved inside the window and launched within the margin is " <>
           "failed, never sent and stays charged; the run stops :model_not_admitted",
         %{env: env} do
      assert {:ok, invocation} = reserve(env, "late-launch")
      at!(before_end(250_000))
      {refused, failure} = assert_launch_refused(env, invocation, :launch_margin)
      assert_stopped(env, refused, failure)
    end

    test "authorization_unavailable: the authorization is gone from the Source at launch",
         %{env: env} do
      assert {:ok, invocation} = reserve(env, "lapsed")
      Fx.put_source!(:authorization, :error)
      assert_launch_refused(env, invocation, :authorization_unavailable)
    end
  end

  describe "the startup timeout T (T-W2c, OQ10)" do
    test "reservation uses the app server's published timeout: 300_000 ms refuses where " <>
           "240_000 ms would admit",
         %{env: env} do
      assert margin(240_000) < 330_000 and 330_000 < margin(300_000)
      app_server!(300_000)
      at!(before_end(330_000))
      assert_reservation_refused(env, "app-server", :launch_margin)
    end

    test "control: without a server or a configuration the same instant is admitted (240_000)",
         %{env: env} do
      at!(before_end(330_000))
      assert {:ok, _invocation} = reserve(env, "neither")
    end

    test "the configured 300_000 ms applies without a server", %{env: env} do
      Application.put_env(:sdr_agent, ClaudeCLI, timeout: 300_000)
      at!(before_end(330_000))
      assert_reservation_refused(env, "configured", :launch_margin)
    end

    test "the running server's longer timeout wins over a shorter configuration", %{env: env} do
      Application.put_env(:sdr_agent, ClaudeCLI, timeout: 240_000)
      app_server!(300_000)
      at!(before_end(330_000))
      assert_reservation_refused(env, "longer", :launch_margin)
    end

    test "launch uses the launching server's own published timeout (300_000 ms), though the " <>
           "reservation (no app server, no configuration: 240_000 ms) was admitted",
         %{env: env} do
      at!(before_end(330_000))
      result = server_call(env, 300_000)

      assert match?(
               {:error,
                %Refused{stage: :launch, reason: :demo_exception_window, check: :launch_margin}},
               result
             ),
             "OQ10: the server's launch admission must refuse with its own 300_000 ms; got " <>
               inspect(result)

      assert [invocation] = invocations(env)
      assert {invocation.status, invocation.sent_at} == {:failed, nil}
      assert invocation.error["reason"] == "demo_exception_window"
    end

    test "control: a server running 240_000 ms launches at the same instant", %{env: env} do
      at!(before_end(330_000))
      assert {:ok, result} = server_call(env, 240_000)
      assert result.invocation.status == :completed
    end
  end

  describe "R5 mappings (T-W2b)" do
    test "Admission.demo_exception_reasons/0 is exactly [:demo_exception_window]" do
      assert Code.ensure_loaded?(Admission) and
               function_exported?(Admission, :demo_exception_reasons, 0),
             "C2* S3 R5: Admission.demo_exception_reasons/0 is absent"

      assert call(Admission, :demo_exception_reasons, []) == [:demo_exception_window]
    end

    test ":demo_exception_window is an admission reason (provider_error, :model_not_admitted)" do
      assert Admission.admission_reason?(:demo_exception_window),
             "R5: :demo_exception_window must be an admission reason"
    end

    test "control: the existing reasons keep their mappings" do
      for reason <- Gate.reasons() ++ SwitchFence.reasons(),
          do: assert(Admission.admission_reason?(reason), inspect(reason))

      for reason <- @grant_reasons,
          do: refute(Admission.admission_reason?(reason), inspect(reason))

      refute :demo_exception_window in (Gate.reasons() ++ SwitchFence.reasons())
    end
  end

  describe "per-allocation windows (the S3 half of T-W5)" do
    @describetag demo_env: [allocations: @windows]

    test "a call in window A within the margin of A's end is refused :launch_margin by A's " <>
           "own end, though B and the grant end later",
         %{env: env} do
      at!(DateTime.add(@a_until, -250_000, :millisecond))
      assert_reservation_refused(env, "end-of-a", :launch_margin)
    end

    test "control: A admitted; the gap refused :no_allocation, nothing charged; B admitted " <>
           "after A's end; A's demo output loses use authority at A's end while B is open",
         %{env: env} do
      a = Enum.find(env.allocations, &(&1.key == :daily_use))
      b = Enum.find(env.allocations, &(&1.key == :workshop))

      demo = Fx.demo_invocation!(env)
      assert demo.invocation.allocation_id == a.id
      assert DateTime.compare(demo.release.exception_expires_at, @a_until) == :eq

      at!(@gap)
      charged = charged(env)
      assert {:error, %Refused{reason: :no_allocation}} = reserve(env, "gap")
      assert charged(env) == charged

      at!(@in_b)

      assert DemoException.use_authority(demo.release, demo.invocation, Clock.utc_now()) ==
               {:error, :expired}

      assert ReleasedOutput.fetch(demo.invocation, env.agent) == {:error, :result_not_released}
      assert {:ok, call_b} = reserve(env, "window-b")
      assert call_b.allocation_id == b.id
    end
  end

  ## Harness

  # The instant `ms` milliseconds before the effective end.
  defp before_end(ms), do: DateTime.add(@end_at, -ms, :millisecond)

  # The guard's margin (ms) for a startup timeout `t`.
  defp margin(t), do: t + ResultGate.wait_ms() + 60_000

  defp at!(instant), do: :ok = Clock.freeze(instant)

  defp claude(key),
    do: key |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"request":"#{key}"}))

  defp reserve(env, key) do
    AdmissionFixtures.admitting(fn ->
      Agents.reserve_model_invocation(env.run, claude(key), actor: env.agent)
    end)
  end

  defp launch(env, invocation) do
    AdmissionFixtures.admitting(fn ->
      Agents.admit_launch(invocation.id, :claude_cli_opus, actor: env.agent)
    end)
  end

  defp invocations(env) do
    {:ok, invocations} = Agents.list_model_invocations(env.run.id, actor: env.agent)
    invocations
  end

  defp stored(invocation), do: Ash.get!(ModelInvocation, invocation.id, authorize?: false)

  defp reload(env) do
    {:ok, run} = Agents.get_run(env.run.id, actor: env.agent)
    run
  end

  defp run_failures(env) do
    Failure
    |> Ash.Query.filter(subject_resource == ^@run_resource and subject_id == ^env.run.id)
    |> Ash.read!(SdrAgent.Audit.Kernel.opts(env.tenant.id))
  end

  defp failure_ids(env), do: env |> run_failures() |> Enum.map(& &1.id)

  # Every attempt charged to the demo grant (attempts are never refunded).
  defp charged(env) do
    ModelInvocation
    |> Ash.Query.filter(grant_id == ^env.grant.id)
    |> Ash.count!(authorize?: false)
  end

  defp message(check) do
    "model call not admitted: demo_exception_window (#{check}) (profile claude_cli_opus); " <>
      @message_tail
  end

  # T-W2 at reservation: rolled back (no invocation, no counter or charge
  # change); one critical provider_error Failure of the run with the fixed
  # message and one `model.reservation.refused` event naming it.
  defp assert_reservation_refused(env, key, check) do
    before = {invocations(env), reload(env).budget, charged(env), failure_ids(env)}
    result = reserve(env, key)

    assert match?(
             {:error,
              %Refused{stage: :reservation, reason: :demo_exception_window, check: ^check}},
             result
           ),
           "AC11: the reservation must be refused :demo_exception_window (#{check}); got " <>
             inspect(result)

    {:error, refused} = result
    {invocations, budget, charged, failures} = before
    assert invocations(env) == invocations
    assert reload(env).budget == budget
    assert charged(env) == charged

    assert [failure] = Enum.reject(run_failures(env), &(&1.id in failures))
    assert failure.id == refused.failure_id
    assert {failure.class, failure.severity} == {:provider_error, :critical}
    assert failure.operation_id == env.run.operation_id
    assert failure.message == message(check)

    assert [event] =
             env.tenant
             |> events_of_type("model.reservation.refused")
             |> Enum.filter(&(&1.idempotency_key == key))

    assert {event.payload["reason"], event.payload["check"]} ==
             {"demo_exception_window", Atom.to_string(check)}

    assert event.payload["failure_id"] == failure.id
    assert {refused.event_id, refused.request_id} == {event.id, key}
    {refused, failure}
  end

  # T-W2 at launch: the row failed (never sent) and stays charged; one
  # critical provider_error Failure of the run and one `model.launch.refused`
  # event naming it and the reserved request.
  defp assert_launch_refused(env, invocation, check) do
    {charged, failures} = {charged(env), failure_ids(env)}
    result = launch(env, invocation)

    assert match?(
             {:error, %Refused{stage: :launch, reason: :demo_exception_window, check: ^check}},
             result
           ),
           "AC11: the launch must be refused :demo_exception_window (#{check}); got " <>
             inspect(result)

    {:error, refused} = result
    row = stored(invocation)
    assert {row.status, row.sent_at} == {:failed, nil}
    assert row.error["kind"] == "launch_refused"
    assert {row.error["reason"], row.error["check"]} == {"demo_exception_window", "#{check}"}
    assert {row.grant_id, row.allocation_id} == {invocation.grant_id, invocation.allocation_id}
    assert charged(env) == charged

    assert [failure] = Enum.reject(run_failures(env), &(&1.id in failures))
    assert failure.id == refused.failure_id
    assert {failure.class, failure.severity} == {:provider_error, :critical}
    assert failure.operation_id == env.run.operation_id

    assert [event] =
             env.tenant
             |> events_of_type("model.launch.refused")
             |> Enum.filter(&(&1.model_invocation_id == invocation.id))

    assert {event.payload["reason"], event.payload["check"]} ==
             {"demo_exception_window", Atom.to_string(check)}

    assert event.payload["failure_id"] == failure.id
    assert event.idempotency_key == invocation.idempotency_key
    assert {refused.event_id, refused.request_id} == {event.id, invocation.idempotency_key}

    refute Enum.any?(
             events_of_type(env.tenant, "model.invocation.sent"),
             &(&1.model_invocation_id == invocation.id)
           )

    {refused, failure}
  end

  # T-W2b: the run stops :model_not_admitted linking exactly the refusal's
  # Failure (LinkRefusalAttention accepts it), and opens no other.
  defp assert_stopped(env, refused, failure) do
    failures = failure_ids(env)

    ctx = %Context{
      actor: env.agent,
      tenant_id: env.tenant.id,
      run_id: env.run.id,
      correlation_id: env.run.correlation_id
    }

    result = SDR.Model.stop_refused(ctx, reload(env), refused)

    assert match?({:ok, %{status: :failed, status_reason: :model_not_admitted}}, result),
           "R5: the refusal must stop the run :model_not_admitted; got #{inspect(result)}"

    {:ok, stopped} = result
    assert stopped.attention_failure_id == failure.id
    assert Enum.sort(failure_ids(env)) == Enum.sort(failures)
  end

  # A ClaudeCLI server registered under the app's name (what reservation
  # reads), running `timeout`.
  defp app_server!(timeout) do
    start_supervised!(
      {ClaudeCLI,
       [
         name: ClaudeCLI.server(),
         command: System.find_executable("elixir"),
         test_launcher: true,
         command_args: [@fake, "sdr"],
         timeout: timeout
       ]}
    )
  end

  # One facade call through an unnamed ClaudeCLI server running `timeout`
  # that follows the test's frozen clock; the hermetic fake CLI writes a v4
  # exchange only if the call is launched. Returns the facade's result.
  defp server_call(env, timeout) do
    server =
      start_supervised!(
        {ClaudeCLI,
         [
           command: System.find_executable("elixir"),
           test_launcher: true,
           command_args: [@fake, "witness", env.root, @variant],
           timeout: timeout,
           clock_from: self()
         ]}
      )

    id = "demo-admission-#{System.unique_integer([:positive])}"

    audit =
      id
      |> AgentsFixtures.model_attrs()
      |> Map.take([
        :purpose,
        :parameters,
        :prompt_template_id,
        :prompt_template_version,
        :prompt_template_sha256,
        :output_schema_id,
        :output_schema_version,
        :output_schema_sha256
      ])

    AdmissionFixtures.admitting(fn ->
      ModelProvider.complete(
        %{
          id: id,
          run: env.run,
          actor: env.agent,
          operation: "model.complete",
          prompt: "Qualify the fixture lead #{@variant} (#{id})",
          schema: @schema,
          audit: audit
        },
        provider: ClaudeCLI,
        provider_options: [server: server]
      )
    end)
  end

  defp call(module, function, args), do: apply(module, function, args)
end
