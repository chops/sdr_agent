defmodule SdrAgent.SDR.OfflineSnoozeTest do
  @moduledoc """
  S-B6 RED (plan r2 5769d9ac; Codex PASS and tests-only RED GO d2cd2625):
  under the trusted `:remote` transport with ClaudeCLI selected, an agent
  job whose Mac worker is offline waits uncharged before START.

  Offline is `ClaudeCLI.Remote.availability/1`: no active worker
  (`:provider_not_running`), paused intake (`:provider_held`), or an
  active open worker whose `last_seen_at` is nil, older than 60 s or
  later than now (`:provider_offline`). The inclusive window is
  [now - 60 s, now] at microsecond precision.

  While offline, `AgentWorker` (run AND Operation queued) and
  `ReplyWorker` (run queued) return `{:snooze, 60}`: Oban reschedules the
  same job (attempt decremented, `max_attempts` 1 unchanged, meta
  `snoozed` counted) and nothing in the domain is written: no START, no
  ModelInvocation, no RemoteModelCall, no charge, no attention Failure.
  A fresh heartbeat lets the same job START. Non-queued rows, unknown
  providers, the Fake provider and incompatible pins never take the
  snooze path.

  Synthetic fixtures and a frozen server clock only; no model, CLI or
  network.
  """
  use SdrAgent.PrototypeCase, async: false

  import Ecto.Query, only: [where: 3]

  alias SdrAgent.Actor
  alias SdrAgent.Agents
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Clock
  alias SdrAgent.HostedOwnerFixtures, as: H
  alias SdrAgent.Operations
  alias SdrAgent.PrototypeGateFixtures, as: G
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.Repo
  alias SdrAgent.SDR.AgentWorker
  alias SdrAgent.SDR.ReplyWorker
  alias SdrAgent.SDR.Signals

  setup tags do
    ctx = H.activated!()
    admin = human(:admin, ctx.fx.tenant)
    # The seeded scenarios save the offering through the GTM seed itself.
    unless tags[:seeded], do: :ok = AgentsFixtures.ensure_offering!(ctx.fx.tenant)
    definition = AgentsFixtures.definition!(ctx.fx.tenant)
    agent = Actor.system(:agent_runtime, ctx.fx.tenant.id)
    fx = Map.merge(ctx.fx, %{admin: admin, definition: definition, agent: agent})
    F.remote!()
    put_env!(:model_provider, ClaudeCLI)
    # An admitted run never blocks the suite: the remote wait times out.
    put_env!(:remote_wait_ms, 50)
    t0 = Clock.utc_now()
    :ok = Clock.freeze(t0)
    on_exit(fn -> Clock.unfreeze() end)
    Map.merge(ctx, %{fx: fx, t0: t0})
  end

  ## Helpers

  defp put_env!(key, value) do
    previous = Application.fetch_env(:sdr_agent, key)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:sdr_agent, key, old)
        :error -> Application.delete_env(:sdr_agent, key)
      end
    end)

    Application.put_env(:sdr_agent, key, value)
  end

  # Hosted owner, live runtime and the provisioned grant; `worker:` is
  # :none (no enrolment), :never_seen (last_seen_at planted NULL) or :fresh
  # (enrolment and heartbeat at t0); `intake: :paused` is set by the owner
  # before the runtime is entered.
  defp world!(ctx, opts \\ []) do
    _owner = H.enrol!(ctx)
    pins = Keyword.get(opts, :pins, F.pins())

    enrolled =
      case Keyword.get(opts, :worker, :fresh) do
        :none -> %{}
        _enrolled -> F.enrol!(ctx.fx, pins)
      end

    if intake = Keyword.get(opts, :intake), do: F.set_intake!(ctx.fx, enrolled.worker, intake)
    H.enter!(ctx)

    case Keyword.get(opts, :worker, :fresh) do
      :fresh -> assert {:ok, _intake} = F.heartbeat(enrolled.token, pins)
      :never_seen -> never_seen!(enrolled.worker)
      :none -> :ok
    end

    grant = G.provision!(ctx.fx)
    Map.merge(ctx, %{grant: grant, enrolled: enrolled, pins: pins})
  end

  # Enrolment stamps last_seen_at; a worker with no heartbeat record at all
  # is planted directly (the row guard permits last_seen_at updates).
  defp never_seen!(worker) do
    sql = ~s[UPDATE "mac_workers" SET last_seen_at = NULL WHERE id = $1]
    assert %{num_rows: 1} = Repo.query!(sql, [F.dump(worker.id)])
  end

  defp now!(ctx, microseconds),
    do: :ok = Clock.freeze(DateTime.add(ctx.t0, microseconds, :microsecond))

  # A queued assignment exactly as SDR.assign_lead/2 writes it: the job,
  # its queued Operation and the queued run.
  defp agent_job!(ctx, extra_args \\ %{}) do
    ids = %{lead_id: Ecto.UUID.generate(), campaign_id: Ecto.UUID.generate()}
    {:ok, signal} = Signals.build("sdr.lead.assigned", ids)

    args =
      Map.merge(
        %{"tenant_id" => ctx.fx.tenant.id, "signal" => Signals.dump(signal)},
        extra_args
      )

    {:ok, job} = Oban.insert(AgentWorker.new(args))

    {:ok, operation} =
      Operations.create_operation(
        %{
          kind: :research_lead,
          queue: :research,
          oban_job_id: job.id,
          subject_resource: "SdrAgent.Sales.Lead",
          subject_id: Ecto.UUID.generate(),
          idempotency_key: "sb6:#{System.unique_integer([:positive])}",
          correlation_id: Ecto.UUID.generate(),
          max_attempts: 1
        },
        actor: ctx.fx.agent
      )

    attrs =
      ctx.fx.definition
      |> AgentsFixtures.run_attrs()
      |> Map.merge(%{operation_id: operation.id, trigger_signal_id: signal.id})
      |> Map.merge(ids)

    {:ok, run} = Agents.create_run(attrs, actor: ctx.fx.agent)
    %{job: job, operation: operation, run: run}
  end

  # A valid synthetic assignment that reaches the model path: the GTM seed,
  # one dossier row imported through the real route and `op assign`, as
  # the D-237 journey builds it (SdrAgent.DossierFixtures; reserved names).
  defp admitted_job!(ctx) do
    actor = ctx.fx.actor
    seed = SdrAgent.Prototype.Seed.run(SdrAgent.DossierFixtures.seed_read(), actor)
    assert {:ok, %{campaign_id: campaign_id}} = seed
    rows = SdrAgent.DossierFixtures.route_rows!([SdrAgent.DossierFixtures.company(1)], ["row-1"])
    imported = SdrAgent.Prototype.DossierImport.import_row(hd(rows), actor)
    assert {:ok, :imported, %{lead_id: lead_id}} = imported

    assigned =
      Mix.Tasks.Sdr.Prototype.Op.execute(
        %{command: :assign, agent: :claude_code, lead: lead_id, campaign: campaign_id},
        actor
      )

    assert {:ok, %{id: run_id}} = assigned
    {:ok, run} = Agents.get_run(run_id, actor: ctx.fx.agent)
    operation = Ash.get!(Operations.Operation, run.operation_id, authorize?: false)
    %{job: Repo.get!(Oban.Job, operation.oban_job_id), run: run, operation: operation}
  end

  # Exactly one ClaudeCLI invocation of `run`, with exactly one pending call.
  defp assert_one_pending_call!(run) do
    assert [invocation] = invocations(run)
    assert invocation["provider"] == "claude_cli"
    assert %{"state" => "pending"} = F.call_of(F.load(invocation["id"]))
  end

  # A queued reply run and its agent-queue job, as SDR.ReplyIntake writes them.
  defp reply_job!(ctx) do
    ids = %{lead_id: Ecto.UUID.generate(), campaign_id: Ecto.UUID.generate()}

    {:ok, signal} =
      Signals.build(
        "sdr.reply.received",
        Map.merge(ids, %{reply_id: Ecto.UUID.generate(), enrollment_id: Ecto.UUID.generate()})
      )

    attrs =
      ctx.fx.definition
      |> AgentsFixtures.run_attrs(usage_origin: :reply)
      |> Map.merge(%{
        phase: :reply,
        trigger_signal_type: signal.type,
        trigger_signal_id: signal.id
      })
      |> Map.merge(ids)

    {:ok, run} = Agents.create_run(attrs, actor: ctx.fx.agent)

    {:ok, job} =
      %{"tenant_id" => ctx.fx.tenant.id, "run_id" => run.id, "signal" => Signals.dump(signal)}
      |> ReplyWorker.new()
      |> Oban.insert()

    %{job: job, run: run}
  end

  defp drain(queue), do: Oban.drain_queue(queue: queue, with_safety: false)

  # Makes a snoozed job due now and drains only jobs due by now, so a job
  # that snoozes again is not re-run in the same drain.
  defp drain_due(queue, job) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    {1, _} = Repo.update_all(where(Oban.Job, [j], j.id == ^job.id), set: [scheduled_at: past])
    Oban.drain_queue(queue: queue, with_safety: false, with_scheduled: DateTime.utc_now())
  end

  defp job(job), do: Repo.get!(Oban.Job, job.id)
  defp run(ctx, run), do: elem(Agents.get_run(run.id, actor: ctx.fx.agent), 1)
  defp operation(operation), do: Ash.get!(Operations.Operation, operation.id, authorize?: false)

  defp invocations(run),
    do: F.rows(SdrAgent.Agents.ModelInvocation, "agent_run_id = $1", [F.dump(run.id)])

  defp ledger, do: %{calls: F.count(F.call_resource()), allocations: allocations()}

  # The grant and allocation rows: every charge moves one of them.
  defp allocations do
    for resource <- [SdrAgent.Agents.ModelCallGrant, SdrAgent.Agents.ModelCallAllocation],
        do: resource |> F.rows() |> Enum.sort_by(& &1["id"])
  end

  # The common waiting assertions after `n` snoozes.
  defp assert_waiting!(ctx, %{job: job} = rows, n, before) do
    job = job(job)
    assert job.state == "scheduled", "job not rescheduled: #{job.state}"
    assert job.attempt == 0
    assert job.max_attempts == 1
    assert job.meta["snoozed"] == n

    run = run(ctx, rows.run)
    assert run.status == :queued
    assert run.attention_failure_id == nil
    assert invocations(run) == []

    if Map.has_key?(rows, :operation), do: assert(operation(rows.operation).status == :queued)

    assert ledger() == before
  end

  ## AgentWorker offline

  describe "AgentWorker while the Mac is offline" do
    test "no active worker: snooze 60, nothing started or charged", ctx do
      ctx = world!(ctx, worker: :none)
      rows = agent_job!(ctx)
      before = ledger()
      assert %{snoozed: 1, success: 0, failure: 0, discard: 0} = drain(:research)
      assert_waiting!(ctx, rows, 1, before)
    end

    test "paused intake with a fresh heartbeat: snooze", ctx do
      ctx = world!(ctx, intake: :paused)
      rows = agent_job!(ctx)
      before = ledger()
      assert %{snoozed: 1} = drain(:research)
      assert_waiting!(ctx, rows, 1, before)
    end

    test "active open worker that never heartbeat (nil): snooze", ctx do
      ctx = world!(ctx, worker: :never_seen)
      rows = agent_job!(ctx)
      before = ledger()
      assert %{snoozed: 1} = drain(:research)
      assert_waiting!(ctx, rows, 1, before)
    end

    test "heartbeat 60 s + 1 us old: snooze", ctx do
      ctx = world!(ctx)
      now!(ctx, 60_000_001)
      rows = agent_job!(ctx)
      before = ledger()
      assert %{snoozed: 1} = drain(:research)
      assert_waiting!(ctx, rows, 1, before)
    end

    test "heartbeat 1 us in the future: snooze", ctx do
      ctx = world!(ctx)
      now!(ctx, -1)
      rows = agent_job!(ctx)
      before = ledger()
      assert %{snoozed: 1} = drain(:research)
      assert_waiting!(ctx, rows, 1, before)
    end

    test "two snoozes: attempt stays 0, max_attempts 1, snoozed 2", ctx do
      ctx = world!(ctx, worker: :none)
      rows = agent_job!(ctx)
      before = ledger()
      assert %{snoozed: 1} = drain(:research)
      assert %{snoozed: 1} = drain_due(:research, rows.job)
      assert_waiting!(ctx, rows, 2, before)
    end
  end

  ## Admission and resume

  describe "AgentWorker with a fresh worker" do
    # Codex RED review 344d7ca8: the admitted scenarios use a valid synthetic
    # lead (seed + one imported dossier row + op assign), so the run reaches
    # the model path: exactly one ClaudeCLI invocation reserved with its one
    # pending RemoteModelCall (the 50 ms wait then times out; no claim).
    @tag :seeded
    test "boundary: a heartbeat exactly 60 s old STARTs and reserves one call", ctx do
      ctx = world!(ctx)
      rows = admitted_job!(ctx)
      now!(ctx, 60_000_000)
      assert %{snoozed: 0} = drain(:research)
      refute job(rows.job).state == "scheduled"
      refute operation(rows.operation).status == :queued
      assert_one_pending_call!(rows.run)
    end

    @tag :seeded
    test "resume: the same snoozed job STARTs after a fresh heartbeat", ctx do
      ctx = world!(ctx, worker: :never_seen)
      rows = admitted_job!(ctx)
      assert %{snoozed: 1} = drain(:research)
      assert invocations(rows.run) == []

      assert {:ok, :open} = F.heartbeat(ctx.enrolled.token, ctx.pins)
      assert %{snoozed: 0} = drain_due(:research, rows.job)

      job = job(rows.job)
      assert job.id == rows.job.id
      refute job.state == "scheduled"
      assert job.meta["snoozed"] == 1
      refute run(ctx, rows.run).status == :queued
      assert_one_pending_call!(rows.run)
    end
  end

  ## ReplyWorker

  describe "ReplyWorker" do
    test "no active worker: snooze, run queued, nothing charged", ctx do
      ctx = world!(ctx, worker: :none)
      rows = reply_job!(ctx)
      before = ledger()
      assert %{snoozed: 1} = drain(:agent)
      assert_waiting!(ctx, rows, 1, before)
    end

    test "control: a terminal run is left alone, never snoozed", ctx do
      ctx = world!(ctx, worker: :none)
      rows = reply_job!(ctx)
      {:ok, started} = Agents.start_run(rows.run, actor: ctx.fx.agent)

      {:ok, _} =
        Agents.fail_run(started, %{status_reason: :crash, failure_reason: "sb6 control"},
          actor: ctx.fx.agent
        )

      assert %{snoozed: 0, success: 1} = drain(:agent)
      refute job(rows.job).state == "scheduled"
    end
  end

  ## Controls: never the snooze path

  describe "controls" do
    test "a running run (Operation queued) is never snoozed", ctx do
      ctx = world!(ctx, worker: :none)
      rows = agent_job!(ctx)
      {:ok, _} = Agents.start_run(rows.run, actor: ctx.fx.agent)
      result = drain(:research)
      assert result.snoozed == 0
      refute job(rows.job).state == "scheduled"
    end

    test "a running Operation (run queued) is never snoozed", ctx do
      ctx = world!(ctx, worker: :none)
      rows = agent_job!(ctx)
      {:ok, _} = Operations.start_operation(rows.operation, actor: ctx.fx.agent)
      result = drain(:research)
      assert result.snoozed == 0
      refute job(rows.job).state == "scheduled"
    end

    test "an unknown provider keeps START then provider_error", ctx do
      ctx = world!(ctx, worker: :none)
      rows = agent_job!(ctx, %{"model" => %{"provider" => "bogus"}})
      assert %{snoozed: 0} = drain(:research)
      run = run(ctx, rows.run)
      assert run.status == :failed
      assert run.status_reason == :provider_error
    end

    test "the Fake provider under :remote is not gated", ctx do
      ctx = world!(ctx, worker: :none)
      rows = agent_job!(ctx, %{"model" => %{"provider" => "fake"}})
      assert %{snoozed: 0} = drain(:research)
      refute run(ctx, rows.run).status == :queued
    end

    # Incompatible pins are a prepare refusal, not offline: the job STARTs
    # and the run ends on its existing terminal path (here before any model
    # call, since the synthetic lead does not exist), never a snooze. The
    # prepare refusal itself is pinned in RemoteProviderTest.
    test "incompatible pins with a fresh heartbeat are never snoozed", ctx do
      ctx = world!(ctx, pins: Map.put(F.pins(), "cli_version", "9.9.9-other"))
      rows = agent_job!(ctx)
      assert %{snoozed: 0} = drain(:research)
      run = run(ctx, rows.run)
      assert run.status == :failed
      assert invocations(rows.run) == []
    end
  end
end
