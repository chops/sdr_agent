defmodule SdrAgent.Agents.ModelServerStartTest do
  @moduledoc """
  C2-02b2α RED (interface and entity PASS at `c00ed69`,
  `docs/product/r0/c2-02b2-interface.md` sections 1, 1a and 1b; binding
  obligations 1, 2 and 5): the durable start allocator, its forward-only
  lifecycle, the coordinator-only ledger boundary and the boot-fenced
  switch finalization.

  Every b2 ledger write is executed **in the registered coordinator
  process**. The test build's `Coordinator.test_run/2` seam (compile-time
  gated, like slice a's phase seam) runs a function there, with the
  coordinator's binding (`%{boot_id: ...}`). The coordinator is started
  with the test-build-only `manual: true` option, so it allocates nothing
  and starts no server by itself. A restart of the coordinator is a new
  boot.

  Every call is presence-guarded, so on the b1 head each test fails on an
  explicit assertion after its fixtures, not in setup or compilation. No
  CLI and no model call.
  """
  use SdrAgent.AuditCase, async: false

  alias SdrAgent.Agents

  @start SdrAgent.Agents.ModelServerStart
  @counter SdrAgent.Agents.ModelServerCounter
  @coordinator SdrAgent.AI.ModelProvider.Coordinator
  @profile_supervisor SdrAgent.AI.ModelProvider.ProfileSupervisor

  setup do
    tenant = bootstrap!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      auditor: human(:auditor, tenant),
      runtime: system_actor(:model_runtime, tenant),
      agent: system_actor(:agent_runtime, tenant)
    }
  end

  ## Presence-guarded calls and the coordinator harness

  defp call(fun, args) do
    Code.ensure_loaded!(Agents)

    assert function_exported?(Agents, fun, length(args)),
           "C2-02b2α: SdrAgent.Agents.#{fun}/#{length(args)} is not implemented"

    apply(Agents, fun, args)
  end

  # Starts the profile tree in manual mode (test builds only), after the
  # fixtures, and returns the coordinator's binding.
  defp coordinator!(id \\ :profile_tree) do
    for module <- [@profile_supervisor, @coordinator, @start, @counter] do
      assert Code.ensure_loaded?(module), "C2-02b2α: #{inspect(module)} is not implemented"
    end

    assert function_exported?(@coordinator, :test_run, 2),
           "C2-02b2α: the test-build Coordinator.test_run/2 seam is missing"

    start_supervised!({@profile_supervisor, manual: true}, id: id)
    in_coordinator(fn binding -> binding end)
  end

  defp restart_coordinator!(id \\ :profile_tree) do
    stop_supervised!(id)
    start_supervised!({@profile_supervisor, manual: true}, id: id)
    in_coordinator(fn binding -> binding end)
  end

  defp in_coordinator(fun), do: apply(@coordinator, :test_run, [fun, 5_000])

  defp allocate(ctx, binding, attrs) do
    in_coordinator(fn _ ->
      call(:allocate_server_start, [
        Map.merge(%{boot_id: binding.boot_id, profile_id: :claude_cli_opus}, attrs),
        [actor: ctx.runtime]
      ])
    end)
  end

  defp mark(ctx, binding, start, status, attrs \\ %{}) do
    in_coordinator(fn _ ->
      call(:mark_server_start, [
        start,
        status,
        Map.merge(%{boot_id: binding.boot_id}, attrs),
        [actor: ctx.runtime]
      ])
    end)
  end

  defp observed(pid \\ self()) do
    %{pid: pid, node: node(), reaper_pid: spawn(fn -> :ok end)}
  end

  defp started!(ctx, binding, start) do
    assert {:ok, start} = mark(ctx, binding, start, :started, observed())
    start
  end

  defp ready!(ctx, binding, start, evidence \\ :spawn_preflight) do
    start = started!(ctx, binding, start)

    assert {:ok, start} =
             mark(ctx, binding, start, :ready, %{pid: self(), ready_evidence: evidence})

    start
  end

  defp booted!(ctx, binding) do
    assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})
    ready!(ctx, binding, start)
  end

  defp request!(ctx, booted, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          to_profile_id: :claude_cli_sonnet,
          expected_revision: 1,
          server_generation: booted.generation
        },
        attrs
      )

    assert {:ok, switch} = call(:request_profile_switch, [attrs, [actor: ctx.admin]])
    switch
  end

  defp finalize(ctx, action, binding, switch, start, extra \\ %{}) do
    fun =
      Map.fetch!(
        %{
          complete: :complete_profile_switch,
          fail: :fail_profile_switch,
          block: :block_profile_switch
        },
        action
      )

    attrs =
      Map.merge(
        %{
          server_generation: switch.server_generation,
          boot_id: binding.boot_id,
          start_id: start && start.id,
          failure_reason: "b2α test"
        },
        extra
      )

    in_coordinator(fn _ -> call(fun, [switch, attrs, [actor: ctx.runtime]]) end)
  end

  defp starts(actor), do: call(:list_server_starts, [[actor: actor]])
  defp count(type, ctx), do: length(events_of_type(ctx.tenant, type))
  defp setting(ctx), do: call(:get_profile_setting, [[actor: ctx.admin]])

  ## Allocation and the boot claim (obligation 2)

  describe "allocation" do
    test "a cold boot needs neither a setting nor a switch, and creates no setting", ctx do
      binding = coordinator!()

      assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})
      assert {start.generation, start.status, start.reason} == {1, :allocated, :boot}
      assert start.boot_id == binding.boot_id

      assert {start.pid, start.node, start.reaper_pid, start.ready_evidence} ==
               {nil, nil, nil, nil}

      assert {:ok, nil} = setting(ctx)
      assert count("model.server.start_allocated", ctx) == 1
    end

    test "a new boot's first allocation claims the next generation", ctx do
      first = coordinator!()
      booted!(ctx, first)

      second = restart_coordinator!()
      refute second.boot_id == first.boot_id

      assert {:ok, replacement} = allocate(ctx, second, %{reason: :replacement})
      assert replacement.generation == 2
      assert replacement.boot_id == second.boot_id
    end

    test "generations are never reused across rollbacks and restarts", ctx do
      binding = coordinator!()
      booted = booted!(ctx, binding)
      switch = request!(ctx, booted)

      assert {:ok, _} =
               allocate(ctx, binding, %{
                 reason: :activation,
                 switch_id: switch.id,
                 profile_id: :claude_cli_sonnet
               })

      assert {:ok, _} = allocate(ctx, binding, %{reason: :rollback, switch_id: switch.id})
      binding = restart_coordinator!()
      assert {:ok, last} = allocate(ctx, binding, %{reason: :boot})

      assert {:ok, all} = starts(ctx.admin)
      generations = all |> Enum.map(& &1.generation) |> Enum.sort()
      assert generations == Enum.uniq(generations)
      assert last.generation == 4
    end

    test "activation and rollback require their switch; others forbid one", ctx do
      binding = coordinator!()
      booted = booted!(ctx, binding)
      switch = request!(ctx, booted)

      assert {:error, _} = allocate(ctx, binding, %{reason: :activation})
      assert {:error, _} = allocate(ctx, binding, %{reason: :rollback})
      assert {:error, _} = allocate(ctx, binding, %{reason: :boot, switch_id: switch.id})
      assert {:error, _} = allocate(ctx, binding, %{reason: :boot, profile_id: :fake})
    end
  end

  ## The coordinator-only boundary (obligation 1)

  describe "the ledger boundary" do
    test "a process other than the registered coordinator is forbidden every b2 write", ctx do
      binding = coordinator!()
      assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})

      attrs = %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :boot}

      assert {:error, %Ash.Error.Forbidden{}} =
               call(:allocate_server_start, [attrs, [actor: ctx.runtime]])

      for {status, extra} <- [started: observed(), failed: %{}] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 call(:mark_server_start, [
                   start,
                   status,
                   Map.put(extra, :boot_id, binding.boot_id),
                   [actor: ctx.runtime]
                 ])
      end

      assert {:ok, [%{status: :allocated}]} = starts(ctx.admin)
    end

    test "a direct Ash action on the resource is forbidden outside the coordinator", ctx do
      binding = coordinator!()

      result =
        @start
        |> Ash.Changeset.for_create(
          :allocate,
          %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :boot},
          actor: ctx.runtime
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} = result
      assert {:ok, []} = starts(ctx.admin)
    end

    test "complete, fail and block from a non-coordinator process are refused", ctx do
      binding = coordinator!()
      booted = booted!(ctx, binding)
      switch = request!(ctx, booted)

      for fun <- [:complete_profile_switch, :fail_profile_switch, :block_profile_switch] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 call(fun, [
                   switch,
                   %{
                     server_generation: switch.server_generation,
                     boot_id: binding.boot_id,
                     start_id: booted.id,
                     failure_reason: "forged"
                   },
                   [actor: ctx.runtime]
                 ])
      end

      assert count("model.profile.switch_blocked", ctx) == 0
    end

    test "an admin or an auditor is forbidden, even inside the coordinator", ctx do
      binding = coordinator!()

      for actor <- [ctx.admin, ctx.auditor, ctx.agent] do
        result =
          in_coordinator(fn _ ->
            call(:allocate_server_start, [
              %{boot_id: binding.boot_id, profile_id: :claude_cli_opus, reason: :boot},
              [actor: actor]
            ])
          end)

        assert {:error, %Ash.Error.Forbidden{}} = result
      end
    end

    test "starts are readable by admin, auditor (audited) and agent_runtime", ctx do
      binding = coordinator!()
      booted!(ctx, binding)

      assert {:ok, [_]} = starts(ctx.admin)
      assert {:ok, [_]} = starts(ctx.agent)

      accesses = fn ->
        hd(hd(SdrAgent.Repo.query!("SELECT count(*) FROM audit_accesses").rows))
      end

      before = accesses.()
      assert {:ok, [_]} = starts(ctx.auditor)
      assert accesses.() == before + 1
    end
  end

  ## The lifecycle (obligation 5)

  describe "the start lifecycle" do
    test "allocated → started → ready records the observed facts and events", ctx do
      binding = coordinator!()
      assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})

      assert {:ok, start} = mark(ctx, binding, start, :started, observed())
      assert start.status == :started
      assert start.pid == inspect(self())
      assert is_binary(start.node) and is_binary(start.reaper_pid)

      assert {:ok, start} =
               mark(ctx, binding, start, :ready, %{pid: self(), ready_evidence: :spawn_preflight})

      assert {start.status, start.ready_evidence} == {:ready, :spawn_preflight}
      assert count("model.server.start_started", ctx) == 1
      assert count("model.server.start_ready", ctx) == 1

      for event <- events(ctx.tenant), String.starts_with?(event.event_type, "model.server.") do
        refute inspect(event.payload) =~ "#PID<", "pids stay out of events"
      end
    end

    test "a failure before the start has no observed identity", ctx do
      binding = coordinator!()
      assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})

      assert {:ok, failed} = mark(ctx, binding, start, :failed)

      assert {failed.status, failed.pid, failed.node, failed.reaper_pid} ==
               {:failed, nil, nil, nil}
    end

    test "a failure after the start keeps its observed identity", ctx do
      binding = coordinator!()
      assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})
      start = started!(ctx, binding, start)

      assert {:ok, failed} = mark(ctx, binding, start, :failed)
      assert failed.status == :failed
      assert failed.pid == start.pid and failed.reaper_pid == start.reaper_pid
    end

    test "status is forward-only", ctx do
      binding = coordinator!()
      assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})

      assert {:error, _} =
               mark(ctx, binding, start, :ready, %{pid: self(), ready_evidence: :spawn_preflight}),
             "allocated cannot skip to ready"

      ready = ready!(ctx, binding, start)
      assert {:error, _} = mark(ctx, binding, ready, :started, observed())
      assert {:error, _} = mark(ctx, binding, ready, :failed)

      assert {:ok, other} = allocate(ctx, binding, %{reason: :replacement})
      assert {:ok, failed} = mark(ctx, binding, other, :failed)
      assert {:error, _} = mark(ctx, binding, failed, :started, observed())
    end

    test "started requires its observed identity; ready requires the recorded pid", ctx do
      binding = coordinator!()
      assert {:ok, start} = allocate(ctx, binding, %{reason: :boot})

      assert {:error, _} = mark(ctx, binding, start, :started, %{pid: self()})
      start = started!(ctx, binding, start)

      other = spawn(fn -> :ok end)

      assert {:error, _} =
               mark(ctx, binding, start, :ready, %{pid: other, ready_evidence: :spawn_preflight})

      assert {:error, _} = mark(ctx, binding, start, :ready, %{pid: self()})
    end

    test ":adopted evidence is allowed only on a replacement", ctx do
      binding = coordinator!()
      assert {:ok, boot} = allocate(ctx, binding, %{reason: :boot})
      boot = started!(ctx, binding, boot)

      assert {:error, _} =
               mark(ctx, binding, boot, :ready, %{pid: self(), ready_evidence: :adopted})

      assert {:ok, replacement} = allocate(ctx, binding, %{reason: :replacement})
      assert %{ready_evidence: :adopted} = ready!(ctx, binding, replacement, :adopted)
    end

    test "a same-stage replay changes no fact and appends no event", ctx do
      binding = coordinator!()
      ready = booted!(ctx, binding)
      before = count("model.server.start_ready", ctx)

      assert {:ok, again} =
               mark(ctx, binding, ready, :ready, %{pid: self(), ready_evidence: :spawn_preflight})

      assert again.updated_at == ready.updated_at
      assert count("model.server.start_ready", ctx) == before

      assert {:error, _} =
               mark(ctx, binding, ready, :ready, %{pid: self(), ready_evidence: :adopted}),
             "a nominal replay cannot rewrite the evidence"
    end

    test "only the latest start of the caller's boot can transition", ctx do
      first = coordinator!()
      assert {:ok, old} = allocate(ctx, first, %{reason: :boot})

      assert {:ok, newer} = allocate(ctx, first, %{reason: :replacement})
      assert {:error, _} = mark(ctx, first, old, :started, observed()), "not latest"

      second = restart_coordinator!()
      assert {:error, _} = mark(ctx, second, newer, :started, observed()), "another boot's start"

      assert {:ok, claimed} = allocate(ctx, second, %{reason: :replacement})
      assert {:error, _} = mark(ctx, first, claimed, :started, observed()), "a stale boot"
      assert {:ok, _} = mark(ctx, second, claimed, :started, observed())
    end
  end

  ## The finalization fence (section 1a)

  describe "complete, fail and block" do
    test "complete needs this boot's ready activation for S with to", ctx do
      binding = coordinator!()
      switch = request!(ctx, booted!(ctx, binding))

      assert {:ok, candidate} =
               allocate(ctx, binding, %{
                 reason: :activation,
                 switch_id: switch.id,
                 profile_id: :claude_cli_sonnet
               })

      assert {:error, _} = finalize(ctx, :complete, binding, switch, candidate), "allocated only"
      candidate = started!(ctx, binding, candidate)
      assert {:error, _} = finalize(ctx, :complete, binding, switch, candidate), "started only"

      assert {:ok, candidate} =
               mark(ctx, binding, candidate, :ready, %{
                 pid: self(),
                 ready_evidence: :spawn_preflight
               })

      assert {:ok, %{status: :completed}} = finalize(ctx, :complete, binding, switch, candidate)
      assert {:ok, %{desired_profile_id: :claude_cli_sonnet, revision: 2}} = setting(ctx)
    end

    test "a failed preflight cannot be completed with valid latest ids", ctx do
      binding = coordinator!()
      switch = request!(ctx, booted!(ctx, binding))

      assert {:ok, candidate} =
               allocate(ctx, binding, %{
                 reason: :activation,
                 switch_id: switch.id,
                 profile_id: :claude_cli_sonnet
               })

      candidate = started!(ctx, binding, candidate)
      assert {:ok, failed} = mark(ctx, binding, candidate, :failed)

      assert {:error, _} = finalize(ctx, :complete, binding, switch, failed)
      assert {:ok, %{desired_profile_id: :claude_cli_opus}} = setting(ctx)
    end

    test "complete and fail have disjoint prerequisites", ctx do
      binding = coordinator!()
      switch = request!(ctx, booted!(ctx, binding))

      assert {:ok, candidate} =
               allocate(ctx, binding, %{
                 reason: :activation,
                 switch_id: switch.id,
                 profile_id: :claude_cli_sonnet
               })

      candidate = ready!(ctx, binding, candidate)
      assert {:error, _} = finalize(ctx, :fail, binding, switch, candidate)

      assert {:ok, rollback} = allocate(ctx, binding, %{reason: :rollback, switch_id: switch.id})
      rollback = ready!(ctx, binding, rollback)
      assert {:error, _} = finalize(ctx, :complete, binding, switch, rollback)
      assert {:ok, %{status: :failed}} = finalize(ctx, :fail, binding, switch, rollback)
    end

    test "an adopted start can't complete or fail a switch", ctx do
      binding = coordinator!()
      switch = request!(ctx, booted!(ctx, binding))
      assert {:ok, adopted} = allocate(ctx, binding, %{reason: :replacement})
      adopted = ready!(ctx, binding, adopted, :adopted)

      assert {:error, _} = finalize(ctx, :complete, binding, switch, adopted)
      assert {:error, _} = finalize(ctx, :fail, binding, switch, adopted)
    end

    test "block works with an allocated or failed latest start of this boot", ctx do
      binding = coordinator!()
      switch = request!(ctx, booted!(ctx, binding))

      assert {:ok, candidate} =
               allocate(ctx, binding, %{
                 reason: :activation,
                 switch_id: switch.id,
                 profile_id: :claude_cli_sonnet
               })

      assert {:ok, failed} = mark(ctx, binding, candidate, :failed)
      assert {:ok, %{status: :blocked}} = finalize(ctx, :block, binding, switch, failed)
    end

    test "a stale boot is refused after the stale-generation check", ctx do
      first = coordinator!()
      switch = request!(ctx, booted!(ctx, first))
      second = restart_coordinator!()
      assert {:ok, claimed} = allocate(ctx, second, %{reason: :replacement})

      assert {:error, _} = finalize(ctx, :block, first, switch, claimed)

      assert {:error, stale} =
               finalize(ctx, :block, second, switch, claimed, %{
                 server_generation: switch.server_generation + 1
               })

      assert Exception.message(stale) =~ "stale"
      assert {:ok, %{status: :blocked}} = finalize(ctx, :block, second, switch, claimed)
    end

    test "a same-action replay doesn't bump the revision or append twice", ctx do
      binding = coordinator!()
      switch = request!(ctx, booted!(ctx, binding))

      assert {:ok, candidate} =
               allocate(ctx, binding, %{
                 reason: :activation,
                 switch_id: switch.id,
                 profile_id: :claude_cli_sonnet
               })

      candidate = ready!(ctx, binding, candidate)
      assert {:ok, _} = finalize(ctx, :complete, binding, switch, candidate)
      before = count("model.profile.switch_completed", ctx)

      assert {:ok, %{status: :completed}} = finalize(ctx, :complete, binding, switch, candidate)
      assert count("model.profile.switch_completed", ctx) == before
      assert {:ok, %{revision: 2}} = setting(ctx)
    end
  end
end
