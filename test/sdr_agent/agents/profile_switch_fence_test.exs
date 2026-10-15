defmodule SdrAgent.Agents.ProfileSwitchFenceTest do
  @moduledoc """
  C2-02b1 (#52, slice b1): the admission fence, the epoch rule and the
  drain's ledger contract (`docs/product/r0/c2-02b1-interface.md`,
  interface and entity PASS at cda8ee5). Sandboxed; the independent-
  connection orders are in `ProfileSwitchFenceRaceTest`, and Operation
  settlement in `SdrAgent.SDR.ProfileSwitchSettlementTest`.

  RED: the fence reason, the epoch rule and `drain_profile_switch/3` don't
  exist on the base (slice a). Presence is asserted after the fixtures, so
  each test fails on an explicit assertion.
  """
  use SdrAgent.AuditCase, async: false

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission
  alias SdrAgent.Agents.Admission.Refused
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure

  @now ~U[2026-10-20 12:00:00.000000Z]
  @starts ~U[2026-10-12 00:00:00.000000Z]
  @expires ~U[2026-11-06 00:00:00.000000Z]
  @run_resource "SdrAgent.Agents.AgentRun"
  @reason "profile_switch_fenced"

  setup do
    SdrAgent.AdmissionFixtures.admit_tuples!()
    Clock.freeze(@now)
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    admin = human(:admin, tenant)

    grant =
      AgentsFixtures.grant!(
        tenant,
        %{
          total_attempts: 50,
          starts_at: @starts,
          expires_at: @expires,
          profile_ids: [:claude_cli_opus, :claude_cli_sonnet],
          allocations: [%{key: :b1, applies_to: [:b1], attempts: 50}]
        },
        admin
      )

    %{run: run, agent: agent} = AgentsFixtures.running_run(tenant)

    %{
      tenant: tenant,
      admin: admin,
      grant: grant,
      run: run,
      agent: agent,
      runtime: system_actor(:model_runtime, tenant)
    }
  end

  ## Helpers

  defp fence! do
    assert function_exported?(Admission, :fence_reasons, 0),
           "C2-02b1: Admission.fence_reasons/0 is not implemented"

    assert :profile_switch_fenced in Admission.fence_reasons()
  end

  defp drain(switch, attrs, actor) do
    assert function_exported?(Agents, :drain_profile_switch, 3),
           "C2-02b1: Agents.drain_profile_switch/3 is not implemented"

    Agents.drain_profile_switch(switch, attrs, actor: actor)
  end

  defp drain!(ctx, switch, timeout_ms \\ 2_000),
    do:
      drain(
        switch,
        %{server_generation: switch.server_generation, timeout_ms: timeout_ms},
        ctx.agent
      )

  defp reserve(ctx, key, run \\ nil) do
    attrs =
      key
      |> AgentsFixtures.claude_attrs()
      |> Map.put(:request, ~s({"request":"#{key}"}))

    Agents.reserve_model_invocation(run || ctx.run, attrs, actor: ctx.agent)
  end

  defp reserve!(ctx, key, run \\ nil) do
    assert {:ok, invocation} = reserve(ctx, key, run)
    invocation
  end

  defp admit(ctx, id, profile \\ :claude_cli_opus),
    do: Agents.admit_launch(id, profile, actor: ctx.agent)

  defp request!(ctx, to, revision, generation) do
    assert {:ok, switch} =
             Agents.request_profile_switch(
               %{to_profile_id: to, expected_revision: revision, server_generation: generation},
               actor: ctx.admin
             )

    switch
  end

  defp complete!(ctx, switch) do
    assert {:ok, done} =
             Agents.complete_profile_switch(
               switch,
               %{server_generation: switch.server_generation},
               actor: ctx.runtime
             )

    done
  end

  defp transition!(ctx, action, switch) do
    assert {:ok, done} =
             apply(Agents, action, [
               switch,
               %{server_generation: switch.server_generation, failure_reason: "test"},
               [actor: ctx.runtime]
             ])

    done
  end

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)

  defp failures(ctx, run_id) do
    Failure
    |> Ash.Query.filter(subject_resource == ^@run_resource and subject_id == ^run_id)
    |> Ash.read!(Audit.Kernel.opts(ctx.tenant.id))
  end

  defp refused_events(ctx, type),
    do: Enum.filter(events_of_type(ctx.tenant, type), &(&1.payload["reason"] == @reason))

  defp sent?(ctx, invocation) do
    Enum.any?(
      events_of_type(ctx.tenant, "model.invocation.sent"),
      &(&1.model_invocation_id == invocation.id)
    )
  end

  defp assert_launch_fenced(ctx, invocation, check) do
    refused = stored(invocation.id)
    assert {refused.status, refused.sent_at} == {:failed, nil}
    assert refused.error["kind"] == "launch_refused"
    assert refused.error["reason"] == @reason
    refute sent?(ctx, invocation)
    assert [failure] = failures(ctx, invocation.agent_run_id)
    assert failure.class == :provider_error

    assert [event] =
             ctx
             |> refused_events("model.launch.refused")
             |> Enum.filter(&(&1.model_invocation_id == invocation.id))

    assert event.payload["check"] == Atom.to_string(check)
    assert event.payload["failure_id"] == failure.id
    {refused, failure, event}
  end

  ## 2. The fence

  describe "the fence at reservation" do
    for {label, close} <- [pending: nil, blocked: :block_profile_switch] do
      test "a #{label} switch refuses a real-profile reservation", ctx do
        switch = request!(ctx, :claude_cli_sonnet, 1, 1)
        if unquote(close), do: transition!(ctx, unquote(close), switch)
        fence!()

        assert {:error,
                %Refused{
                  stage: :reservation,
                  reason: :profile_switch_fenced,
                  check: check,
                  failure_id: failure_id,
                  request_id: request_id
                }} = reserve(ctx, "fenced-#{unquote(label)}")

        assert check == :"switch_#{unquote(label)}"
        assert {:ok, []} = Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)

        assert [failure] = failures(ctx, ctx.run.id)
        assert {failure.id, failure.class} == {failure_id, :provider_error}

        assert [event] = refused_events(ctx, "model.reservation.refused")
        assert event.payload["check"] == "switch_#{unquote(label)}"
        assert event.payload["failure_id"] == failure_id
        assert event.idempotency_key == request_id
      end
    end

    test "a completed or failed switch doesn't fence a new reservation", ctx do
      fence!()
      first = request!(ctx, :claude_cli_sonnet, 1, 1)
      transition!(ctx, :fail_profile_switch, first)
      assert {:ok, _} = reserve(ctx, "after-fail")

      second = request!(ctx, :claude_cli_sonnet, 1, 2)
      complete!(ctx, second)
      assert {:ok, _} = reserve(ctx, "after-complete")
    end

    test "the Fake is never fenced", ctx do
      _switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      fence!()

      assert {:ok, %{provider: :fake}} =
               Agents.reserve_model_invocation(ctx.run, AgentsFixtures.model_attrs("fake-open"),
                 actor: ctx.agent
               )
    end
  end

  describe "the fence at launch" do
    for {label, close} <- [pending: nil, blocked: :block_profile_switch] do
      test "a #{label} switch refuses the launch of an earlier reservation", ctx do
        invocation = reserve!(ctx, "launch-#{unquote(label)}")
        switch = request!(ctx, :claude_cli_sonnet, 1, 1)
        if unquote(close), do: transition!(ctx, unquote(close), switch)
        fence!()

        assert {:error,
                %Refused{stage: :launch, reason: :profile_switch_fenced, check: check} = refused} =
                 admit(ctx, invocation.id)

        assert check == :"switch_#{unquote(label)}"
        {_row, failure, event} = assert_launch_fenced(ctx, invocation, check)
        assert {refused.failure_id, refused.event_id} == {failure.id, event.id}
        assert refused.request_id == invocation.idempotency_key
      end
    end

    test "a sent row settles while the switch is open", ctx do
      invocation = reserve!(ctx, "in-flight")
      assert {:ok, sent} = admit(ctx, invocation.id)
      _switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      fence!()

      assert {:ok, %{status: :completed}} =
               Agents.complete_model_invocation(sent, AgentsFixtures.completion(),
                 actor: ctx.agent
               )
    end
  end

  ## 3. The epoch rule

  describe "the epoch rule" do
    test "a reservation older than a round-trip switch is never sent (ABA)", ctx do
      old = reserve!(ctx, "before-round-trip")
      complete!(ctx, request!(ctx, :claude_cli_sonnet, 1, 1))
      complete!(ctx, request!(ctx, :claude_cli_opus, 2, 2))
      fence!()

      assert {:error, %Refused{stage: :launch, check: :reserved_before_switch}} =
               admit(ctx, old.id, :claude_cli_opus)

      assert_launch_fenced(ctx, old, :reserved_before_switch)
    end

    test "a reservation after both switches launches normally", ctx do
      complete!(ctx, request!(ctx, :claude_cli_sonnet, 1, 1))
      complete!(ctx, request!(ctx, :claude_cli_opus, 2, 2))
      fence!()
      fresh = reserve!(ctx, "after-round-trip")
      assert {:ok, %{status: :sent}} = admit(ctx, fresh.id, :claude_cli_opus)
    end

    # The round trip ends on Opus, the row's own profile, so the existing
    # profile check passes. Tampering with the row's reserved event is
    # caught first by the admission gate's own chain checks, which fail
    # closed too; the fence's provenance check is then pinned directly on a
    # row id with no reserved event.
    test "missing reservation provenance fails closed", ctx do
      invocation = reserve!(ctx, "no-provenance")
      complete!(ctx, request!(ctx, :claude_cli_sonnet, 1, 1))
      complete!(ctx, request!(ctx, :claude_cli_opus, 2, 2))
      hide_reserved_event!(invocation)
      fence!()

      assert {:error, %Refused{stage: :launch}} = admit(ctx, invocation.id, :claude_cli_opus)
      refute sent?(ctx, invocation)

      assert {:error, :profile_switch_fenced, :reservation_provenance_missing} =
               SdrAgent.Agents.Admission.SwitchFence.launch(ctx.tenant.id, Ecto.UUID.generate())
    end
  end

  # Relabels the row's reserved event (inside the test's sandbox
  # transaction, triggers off), so its provenance reads as missing.
  defp hide_reserved_event!(invocation) do
    SdrAgent.Repo.query!("SET LOCAL session_replication_role = replica")

    SdrAgent.Repo.query!(
      "UPDATE audit_events SET event_type = 'test.hidden' " <>
        "WHERE event_type = 'model.invocation.reserved' AND model_invocation_id = $1",
      [Ecto.UUID.dump!(invocation.id)]
    )

    SdrAgent.Repo.query!("SET LOCAL session_replication_role = origin")
  end

  ## 4. Consumers

  describe "the refusal's consumers" do
    test "the reason is an admission reason, recorded as provider_error", _ctx do
      fence!()
      assert Admission.admission_reason?(:profile_switch_fenced)
      assert Admission.reason_name(:profile_switch_fenced) == @reason
    end

    for stage <- [:reservation, :launch] do
      test "a #{stage} receipt stops the run :model_not_admitted linking its Failure, even resolved",
           ctx do
        invocation = if unquote(stage) == :launch, do: reserve!(ctx, "consumer-launch")
        _switch = request!(ctx, :claude_cli_sonnet, 1, 1)
        fence!()

        refused =
          case unquote(stage) do
            :reservation -> elem(reserve(ctx, "consumer-reservation"), 1)
            :launch -> elem(admit(ctx, invocation.id), 1)
          end

        assert %Refused{reason: :profile_switch_fenced} = refused
        {:ok, failure} = SdrAgent.Operations.get_failure(refused.failure_id, actor: ctx.admin)

        {:ok, _} =
          SdrAgent.Operations.resolve_failure(failure, %{resolution_note: "seen"},
            actor: ctx.admin
          )

        assert {:ok, stopped} =
                 Agents.fail_run(
                   ctx.run,
                   %{
                     status_reason: :model_not_admitted,
                     failure_reason: "model call not admitted",
                     refusal_failure_id: refused.failure_id,
                     refusal_request_id: refused.request_id
                   },
                   actor: ctx.agent
                 )

        assert {stopped.status, stopped.attention_failure_id} == {:failed, refused.failure_id}
        assert [_one] = failures(ctx, ctx.run.id)
        refute Enum.any?(failures(ctx, ctx.run.id), &(&1.class == :budget_exhausted))
      end
    end
  end

  ## 5. The drain (sandboxed cases)

  describe "the drain" do
    test "a dead caller's reserved row is refused, its run stopped, its charge kept", ctx do
      invocation = reserve!(ctx, "abandoned")
      {:ok, usage_before} = Agents.grant_usage([ctx.grant.id], actor: ctx.admin)
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)

      assert {:ok, %{refused: 1}} = drain!(ctx, switch)

      {row, failure, event} = assert_launch_fenced(ctx, invocation, :reserved_before_switch)
      assert event.payload["switch_id"] == switch.id

      assert {row.profile_id, row.grant_id, row.allocation_id} ==
               {invocation.profile_id, invocation.grant_id, invocation.allocation_id}

      assert {:ok, ^usage_before} = Agents.grant_usage([ctx.grant.id], actor: ctx.admin)

      {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)

      assert {run.status, run.status_reason, run.attention_failure_id} ==
               {:failed, :model_not_admitted, failure.id}
    end

    test "a refused row's later launch is refused as not reserved", ctx do
      invocation = reserve!(ctx, "queued")
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      assert {:ok, %{refused: 1}} = drain!(ctx, switch)
      assert {:error, :invocation_not_reserved} = admit(ctx, invocation.id)
      refute sent?(ctx, invocation)
    end

    test "a row whose run already stopped is failed with no Failure", ctx do
      invocation = reserve!(ctx, "stopped-run")
      {:ok, _} = Agents.cancel_run(ctx.run, actor: ctx.admin)
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)

      assert {:ok, %{refused: 1}} = drain!(ctx, switch)
      assert %{status: :failed, sent_at: nil} = stored(invocation.id)
      assert failures(ctx, ctx.run.id) == []
    end

    test "a settled sent row: drained", ctx do
      invocation = reserve!(ctx, "settled")
      assert {:ok, sent} = admit(ctx, invocation.id)

      {:ok, _} =
        Agents.complete_model_invocation(sent, AgentsFixtures.completion(), actor: ctx.agent)

      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      assert {:ok, %{refused: 0}} = drain!(ctx, switch)
    end

    test "a sent row that never settles times out at the deadline; the switch stays open",
         ctx do
      invocation = reserve!(ctx, "stuck")
      assert {:ok, _sent} = admit(ctx, invocation.id)
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      started = System.monotonic_time(:millisecond)

      assert {:error, :drain_timeout, %{reserved: 0, sent: 1}} = drain!(ctx, switch, 300)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 300 and elapsed < 3_000
      assert {:ok, [%{status: :pending}]} = Agents.list_profile_switches(actor: ctx.admin)
    end
  end

  describe "the drain's provenance" do
    test "a reserved row with missing provenance fails closed: nothing written", ctx do
      invocation = reserve!(ctx, "drain-no-provenance")
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      hide_reserved_event!(invocation)

      assert {:error, :drain_observation_failed} = drain!(ctx, switch)
      assert %{status: :reserved} = stored(invocation.id)
      assert failures(ctx, ctx.run.id) == []
      {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
      assert run.status == :running
    end
  end

  ## 8. Drain authority

  describe "auditor denials of the drain entry points (GREEN review MF3)" do
    test "an auditor's drain is refused and audited exactly once, nothing changed", ctx do
      row = reserve!(ctx, "auditor-drain")
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      auditor = human(:auditor, ctx.tenant)

      for target <- [switch, nil, "not-a-switch"] do
        denials = length(events_of_type(ctx.tenant, "authz.denied"))

        assert {:error, %Ash.Error.Forbidden{}} =
                 Agents.drain_profile_switch(target, %{server_generation: 1, timeout_ms: 500},
                   actor: auditor
                 )

        assert length(events_of_type(ctx.tenant, "authz.denied")) == denials + 1
      end

      assert stored(row.id).status == :reserved
      {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
      assert run.status == :running
    end

    test "an auditor's per-row refusal is refused and audited exactly once", ctx do
      row = reserve!(ctx, "auditor-refuse")
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      auditor = human(:auditor, ctx.tenant)

      for target <- [row.id, %{}, nil, 42, %{id: :not_a_string}] do
        denials = length(events_of_type(ctx.tenant, "authz.denied"))

        assert {:error, %Ash.Error.Forbidden{}} =
                 Agents.refuse_reserved_for_switch(target, switch.id, 1, auditor)

        assert length(events_of_type(ctx.tenant, "authz.denied")) == denials + 1
      end

      assert stored(row.id).status == :reserved
      {:ok, run} = Agents.get_run(ctx.run.id, actor: ctx.agent)
      assert run.status == :running
    end
  end

  describe "drain authority and validation" do
    test "only agent_runtime of the switch's tenant may drain; others change nothing", ctx do
      _row = reserve!(ctx, "kept")
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      attrs = %{server_generation: 1, timeout_ms: 500}
      foreign = struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: Ecto.UUID.generate())

      for actor <- [ctx.runtime, ctx.admin, nil] do
        assert {:error, %Ash.Error.Forbidden{}} = drain(switch, attrs, actor)
      end

      # Its own type, but not this switch's tenant: the stored switch isn't
      # found for it.
      assert {:error, :switch_not_open} = drain(switch, attrs, foreign)

      assert {:ok, [%{status: :reserved}]} =
               Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    end

    test "a switch that isn't open, or another generation, is refused before any write", ctx do
      _row = reserve!(ctx, "kept")
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)

      assert {:error, :stale_server_generation} =
               drain(switch, %{server_generation: 2, timeout_ms: 500}, ctx.agent)

      failed = transition!(ctx, :fail_profile_switch, switch)

      assert {:error, :switch_not_open} =
               drain(failed, %{server_generation: 1, timeout_ms: 500}, ctx.agent)

      assert {:ok, [%{status: :reserved}]} =
               Agents.list_model_invocations(ctx.run.id, actor: ctx.agent)
    end

    test "timeout_ms is required, positive and finite", ctx do
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)

      for attrs <- [
            %{server_generation: 1},
            %{server_generation: 1, timeout_ms: 0},
            %{server_generation: 1, timeout_ms: :infinity}
          ] do
        assert {:error, %Ash.Error.Invalid{}} = drain(switch, attrs, ctx.agent)
      end
    end

    test "results are counts only", ctx do
      _row = reserve!(ctx, "counted")
      switch = request!(ctx, :claude_cli_sonnet, 1, 1)
      assert {:ok, result} = drain!(ctx, switch)
      assert result == %{refused: 1}
    end
  end
end
