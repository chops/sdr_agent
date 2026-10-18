defmodule SdrAgent.SDR.TerminalSentRecoveryTest do
  @moduledoc """
  L2 E1 (`docs/product/r0/l2-enablement.md`, contract PASS `ed819b7`; plan
  `notes/features/l2-e1-terminal-sent.org`, PASS `e9200cf`; owner D-156).

  A terminal, non-proof run's `sent` ModelInvocation with `sent_at`
  strictly before `now − stale_after_seconds` becomes `unknown` through the
  existing `:mark_unknown` action, by `StaleRunSweeper` case (c) and
  `Agents.mark_terminal_run_sent_unknown/3`. Ledger-only: the run is not
  settled or written, no Failure or Operation changes, the charge stays,
  nothing is released, re-sent or retried. Proof runs and rows with
  recorded calibration authority (any invocation of the run) keep the
  whole run unchanged; unbindable evidence fails closed.
  """
  use SdrAgent.AuditCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias SdrAgent.Agents
  alias SdrAgent.Agents.Admission.Gate
  alias SdrAgent.Agents.AgentRun
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Agents.ModelResultRelease
  alias SdrAgent.AgentsFixtures
  alias SdrAgent.AI.ModelProvider
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.Audit
  alias SdrAgent.Clock
  alias SdrAgent.Operations
  alias SdrAgent.SDR.StaleRunSweeper

  @fake Path.expand("../../support/fake_claude_cli.exs", __DIR__)
  @schema Zoi.object(%{answer: Zoi.string(), score: Zoi.integer()}, coerce: true)
  @t0 ~U[2026-10-20 12:00:00.000000Z]
  @unknown "model.invocation.unknown"
  @warning "stale_run_sweeper.invalid_stale_after"

  setup do
    SdrAgent.AdmissionFixtures.admit_tuples!()
    on_exit(&Clock.unfreeze/0)
    tenant = bootstrap!()
    admin = human(:admin, tenant)

    grant =
      AgentsFixtures.grant!(
        tenant,
        %{
          total_attempts: 40,
          allocations: [
            %{key: :b1, applies_to: [:b1], attempts: 30},
            %{key: :proof, applies_to: [:proof], attempts: 10}
          ]
        },
        admin
      )

    %{
      tenant: tenant,
      admin: admin,
      grant: grant,
      agent: system_actor(:agent_runtime, tenant),
      kernel: system_actor(:kernel, tenant)
    }
  end

  ## The E1 entry points (absent before GREEN: an assertion, not a crash)

  defp e1(run_id, grace, actor) do
    assert Code.ensure_loaded?(Agents) and
             function_exported?(Agents, :mark_terminal_run_sent_unknown, 3),
           "E1: Agents.mark_terminal_run_sent_unknown/3 is not defined"

    Function.capture(Agents, :mark_terminal_run_sent_unknown, 3).(run_id, grace, actor: actor)
  end

  defp authority(invocation) do
    assert Code.ensure_loaded?(Gate) and function_exported?(Gate, :reservation_authority, 1),
           "E1: Admission.Gate.reservation_authority/1 is not defined"

    Function.capture(Gate, :reservation_authority, 1).(invocation)
  end

  ## Fixtures

  defp stale, do: StaleRunSweeper.stale_after_seconds()
  defp past_cutoff(sent_at), do: DateTime.add(sent_at, stale() + 1, :second)

  defp run!(ctx, opts \\ []), do: AgentsFixtures.running_run(ctx.tenant, opts)

  defp at(time, fun) do
    Clock.freeze(time)
    fun.()
  end

  # ClaudeCLI generation 2, sent by launch admission.
  defp sent_claude!(%{run: run, agent: agent}, key) do
    attrs = key |> AgentsFixtures.claude_attrs() |> Map.put(:request, ~s({"r":"#{key}"}))
    {:ok, reserved} = Agents.reserve_model_invocation(run, attrs, actor: agent)
    {:ok, _} = Agents.admit_launch(reserved.id, :claude_cli_opus, actor: agent)
    stored(reserved.id)
  end

  # The Fake, generation 2.
  defp sent_fake!(%{run: run, agent: agent}, key) do
    {:ok, reserved} =
      Agents.reserve_model_invocation(run, AgentsFixtures.model_attrs(key), actor: agent)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    sent
  end

  # A calibration reservation (recorded tuple) on a :proof run, sent.
  defp sent_calibration!(%{run: run, agent: agent}, key) do
    {:ok, reserved} =
      SdrAgent.AdmissionFixtures.admitting(fn ->
        Agents.reserve_model_invocation(run, AgentsFixtures.claude_attrs(key),
          actor: agent,
          calibration: SdrAgent.AdmissionFixtures.calibration()
        )
      end)

    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: agent)
    sent
  end

  defp stop!(ctx, run, :cancelled), do: Agents.cancel_run(run.run, actor: ctx.admin)
  defp stop!(_ctx, run, :succeeded), do: Agents.succeed_run(run.run, actor: run.agent)

  defp stop!(_ctx, run, :failed),
    do: Agents.fail_run(run.run, %{status_reason: :crash, failure_reason: "x"}, actor: run.agent)

  defp stop!(_ctx, run, :budget_exhausted),
    do: Agents.exhaust_run_budget(run.run, %{status_reason: :run_budget_tokens}, actor: run.agent)

  defp stored(id), do: Ash.get!(ModelInvocation, id, authorize?: false)
  defp stored_run(%{run: run}), do: Ash.get!(AgentRun, run.id, authorize?: false)

  defp sweep_at(ctx, time) do
    Clock.freeze(time)
    assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
  end

  defp unknown_events(ctx, invocation),
    do: Enum.filter(events_of_type(ctx.tenant, @unknown), &(&1.subject_id == invocation.id))

  defp released?(invocation) do
    ModelResultRelease
    |> Ash.Query.filter(model_invocation_id == ^invocation.id)
    |> Ash.exists?(authorize?: false)
  end

  defp usage(ctx), do: Agents.grant_usage([ctx.grant.id], actor: ctx.admin)

  defp failures,
    do:
      SdrAgent.Operations.Failure
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.id, &1.status})
      |> Enum.sort()

  defp frozen_run(row),
    do:
      Map.take(row, [
        :status,
        :status_reason,
        :attention_failure_id,
        :finished_at,
        :budget,
        :usage_origin,
        :updated_at
      ])

  # Fixture SQL in the sandboxed test database only, with the append-only
  # triggers off for the statement (legacy and inconsistent states the
  # domain API cannot write).
  defp fixture_sql!(sql, params) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL session_replication_role = replica")
        Repo.query!(sql, params)
      end)

    result
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp set_origin!(%{run: run}, origin),
    do:
      fixture_sql!("UPDATE agent_runs SET usage_origin = $2 WHERE id = $1", [uuid(run.id), origin])

  defp set_generation!(invocation, generation),
    do:
      fixture_sql!("UPDATE model_invocations SET ledger_generation = $2 WHERE id = $1", [
        uuid(invocation.id),
        generation
      ])

  @reservation "event_type = 'model.invocation.reserved' AND model_invocation_id = $1"

  defp drop_reservation_event!(invocation),
    do: fixture_sql!("DELETE FROM audit_events WHERE #{@reservation}", [uuid(invocation.id)])

  defp set_arguments!(invocation, json),
    do:
      fixture_sql!(
        "UPDATE audit_events SET payload = jsonb_set(payload, '{arguments}', $2::jsonb) " <>
          "WHERE #{@reservation}",
        [uuid(invocation.id), json]
      )

  defp malform_tuple!(invocation),
    do:
      fixture_sql!(
        "UPDATE audit_events SET payload = jsonb_set(payload, '{arguments}', " <>
          "coalesce(payload->'arguments', '{}'::jsonb) || '{\"calibration_tuple\": \"bogus\"}') " <>
          "WHERE #{@reservation}",
        [uuid(invocation.id)]
      )

  defp duplicate_reservation_event!(kernel, invocation) do
    {:ok, _} =
      Audit.append(
        %{
          event_type: "model.invocation.reserved",
          category: :model,
          subject_resource: "SdrAgent.Agents.ModelInvocation",
          subject_id: invocation.id,
          action: "reserve",
          model_invocation_id: invocation.id,
          agent_run_id: invocation.agent_run_id,
          payload: %{"arguments" => %{}}
        },
        actor: kernel
      )
  end

  ## (c) eligible rows

  describe "a terminal non-proof run's old sent row" do
    test "becomes unknown for every terminal status; the run, Failure and charge stay", ctx do
      for status <- [:succeeded, :failed, :budget_exhausted, :cancelled] do
        run = run!(ctx)
        sent = at(@t0, fn -> sent_claude!(run, "c-#{status}") end)
        {:ok, _} = stop!(ctx, run, status)
        before = frozen_run(stored_run(run))
        failures = failures()
        charged = usage(ctx)

        sweep_at(ctx, past_cutoff(sent.sent_at))

        row = stored(sent.id)

        assert row.status == :unknown,
               "E1 (#{status}): the terminal run's old sent row becomes unknown; got #{row.status}"

        assert [_] = unknown_events(ctx, sent)
        assert row.sent_at == sent.sent_at
        assert frozen_run(stored_run(run)) == before, "E1: the run is not written or settled"
        assert failures() == failures, "E1: no new Failure"
        assert usage(ctx) == charged, "E1: the charge stays in grant_usage"
        refute released?(sent)

        # Idempotent: a second sweep appends nothing.
        count = length(events(ctx.tenant))
        assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
        assert length(events(ctx.tenant)) == count
        assert stored(sent.id).status == :unknown
      end
    end

    test "an operated run's Operation is unchanged", ctx do
      run = AgentsFixtures.operated_run(ctx.tenant)
      sent = at(@t0, fn -> sent_claude!(run, "c-operated") end)
      {:ok, _} = stop!(ctx, run, :cancelled)
      {:ok, operation} = Operations.get_operation(run.operation.id, actor: ctx.admin)

      sweep_at(ctx, past_cutoff(sent.sent_at))

      assert stored(sent.id).status == :unknown, "E1: the operated run's old sent row is unknown"
      assert {:ok, ^operation} = Operations.get_operation(run.operation.id, actor: ctx.admin)
    end

    test "a failed run whose attention Failure is resolved: nothing is reopened", ctx do
      run = run!(ctx)
      sent = at(@t0, fn -> sent_claude!(run, "c-resolved") end)
      {:ok, failed} = stop!(ctx, run, :failed)
      {:ok, failure} = Operations.get_failure(failed.attention_failure_id, actor: ctx.admin)

      {:ok, resolved} =
        Operations.resolve_failure(failure, %{resolution_note: "handled"}, actor: ctx.admin)

      sweep_at(ctx, past_cutoff(sent.sent_at))

      assert stored(sent.id).status == :unknown, "E1: the row is unknown"
      assert {:ok, ^resolved} = Operations.get_failure(failure.id, actor: ctx.admin)
    end

    test "several rows of one run: old ones in order; fresh and equal-cutoff rows wait", ctx do
      run = run!(ctx)
      first = at(@t0, fn -> sent_claude!(run, "c-first") end)
      second = at(DateTime.add(@t0, 1, :second), fn -> sent_fake!(run, "c-second") end)
      equal = at(DateTime.add(@t0, 10, :second), fn -> sent_fake!(run, "c-equal") end)
      fresh = at(DateTime.add(@t0, 60, :second), fn -> sent_fake!(run, "c-fresh") end)
      {:ok, _} = stop!(ctx, run, :cancelled)

      # now − stale == equal.sent_at: equal is not eligible.
      sweep_at(ctx, DateTime.add(equal.sent_at, stale(), :second))

      assert {stored(first.id).status, stored(second.id).status} == {:unknown, :unknown},
             "E1: both old rows become unknown"

      assert {stored(equal.id).status, stored(fresh.id).status} == {:sent, :sent}
      [one] = unknown_events(ctx, first)
      [two] = unknown_events(ctx, second)
      assert one.sequence < two.sequence, "rows are normalized in sequence_in_run order"

      # A later pass, once they have aged, takes the rest.
      sweep_at(ctx, past_cutoff(fresh.sent_at))
      assert {stored(equal.id).status, stored(fresh.id).status} == {:unknown, :unknown}
    end

    test "every origin but proof, including a pre-R0 NULL origin with a generation-1 row",
         ctx do
      legacy = run!(ctx)
      old = at(@t0, fn -> sent_fake!(legacy, "c-legacy") end)
      {:ok, _} = stop!(ctx, legacy, :succeeded)
      set_origin!(legacy, nil)
      set_generation!(old, 1)
      drop_reservation_event!(old)

      assignment = run!(ctx)
      fake = at(@t0, fn -> sent_fake!(assignment, "c-fake2") end)
      claude = at(@t0, fn -> sent_claude!(assignment, "c-claude2") end)
      {:ok, _} = stop!(ctx, assignment, :succeeded)

      sweep_at(ctx, past_cutoff(claude.sent_at))

      assert stored(old.id).status == :unknown,
             "E1: a NULL-origin run's generation-1 row (no reservation event) is unknown"

      assert stored_run(legacy).usage_origin == nil
      assert {stored(fake.id).status, stored(claude.id).status} == {:unknown, :unknown}
    end

    test "a generation-1 row with one tupleless reservation event is eligible", ctx do
      run = run!(ctx)
      old = at(@t0, fn -> sent_fake!(run, "c-g1-event") end)
      {:ok, _} = stop!(ctx, run, :succeeded)
      set_generation!(old, 1)

      sweep_at(ctx, past_cutoff(old.sent_at))
      assert stored(old.id).status == :unknown, "E1: generation 1, :no_tuple, is eligible"
    end
  end

  ## Refused or untouched

  describe "rows and runs E1 never normalizes" do
    test "a terminal proof run's sent row: no transition, release, latch or attestation", ctx do
      proof = run!(ctx, usage_origin: :proof)
      cal = at(@t0, fn -> sent_calibration!(proof, "c-proof") end)
      {:ok, _} = stop!(ctx, proof, :cancelled)
      count = length(events(ctx.tenant))

      sweep_at(ctx, past_cutoff(cal.sent_at))

      assert stored(cal.id).status == :sent
      assert length(events(ctx.tenant)) == count
      refute released?(cal)
      assert events_of_type(ctx.tenant, "calibration.owner_attested") == []
      assert e1(proof.run.id, stale(), ctx.agent) == {:error, :proof_run}
      assert stored(cal.id).status == :sent
    end

    test "recorded calibration authority on a non-proof run refuses the whole run", ctx do
      run = run!(ctx, usage_origin: :proof)
      cal = at(@t0, fn -> sent_calibration!(run, "c-auth") end)
      other = at(@t0, fn -> sent_fake!(run, "c-auth-other") end)
      {:ok, _} = stop!(ctx, run, :cancelled)
      set_origin!(run, "assignment")
      Clock.freeze(past_cutoff(cal.sent_at))

      assert e1(run.run.id, stale(), ctx.agent) == {:error, :calibration_authority}
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      assert {stored(cal.id).status, stored(other.id).status} == {:sent, :sent}
      assert unknown_events(ctx, other) == []
    end

    # Calibration admits one unlatched calibration per tenant at a time, so
    # each mixed run is its own test.
    test "a fresh invocation's recorded authority keeps the run's old row sent", ctx do
      run = run!(ctx, usage_origin: :proof)
      old = at(@t0, fn -> sent_fake!(run, "c-mixed-old") end)

      at(DateTime.add(@t0, stale() * 2, :second), fn ->
        sent_calibration!(run, "c-mixed-fresh")
      end)

      assert_mixed_refused(ctx, run, old)
    end

    test "a terminal invocation's recorded authority keeps the run's old row sent", ctx do
      run = run!(ctx, usage_origin: :proof)
      old = at(@t0, fn -> sent_fake!(run, "c-mixed-old2") end)
      cal = at(@t0, fn -> sent_calibration!(run, "c-mixed-failed") end)

      {:ok, _} =
        Agents.fail_model_invocation(cal, %{error: %{"kind" => "provider_error"}},
          actor: run.agent
        )

      assert_mixed_refused(ctx, run, old)
    end

    defp assert_mixed_refused(ctx, run, old) do
      {:ok, _} = stop!(ctx, run, :cancelled)
      set_origin!(run, "assignment")
      Clock.freeze(past_cutoff(old.sent_at))
      assert e1(run.run.id, stale(), ctx.agent) == {:error, :calibration_authority}
      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      assert stored(old.id).status == :sent
      assert unknown_events(ctx, old) == []
    end

    test "generation 2 with missing, duplicated or malformed evidence fails closed", ctx do
      for {label, break} <- [
            missing: &drop_reservation_event!/1,
            duplicated: &duplicate_reservation_event!(ctx.kernel, &1),
            malformed: &malform_tuple!/1,
            unreadable: &set_arguments!(&1, ~s("not-a-map"))
          ] do
        run = run!(ctx)
        row = at(@t0, fn -> sent_claude!(run, "c-g2-#{label}") end)
        {:ok, _} = stop!(ctx, run, :succeeded)
        break.(row)
        Clock.freeze(past_cutoff(row.sent_at))

        assert e1(run.run.id, stale(), ctx.agent) == {:error, :authority_unbindable},
               "E1 (generation 2, #{label}): unbindable evidence refuses"

        assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
        assert stored(row.id).status == :sent
      end
    end

    test "generation 1: a valid tuple refuses; broken evidence fails closed", ctx do
      cal_run = run!(ctx, usage_origin: :proof)
      cal = at(@t0, fn -> sent_calibration!(cal_run, "c-g1-tuple") end)
      {:ok, _} = stop!(ctx, cal_run, :cancelled)
      set_origin!(cal_run, "assignment")
      set_generation!(cal, 1)
      Clock.freeze(past_cutoff(cal.sent_at))
      assert e1(cal_run.run.id, stale(), ctx.agent) == {:error, :calibration_authority}

      for {label, break} <- [
            duplicated: &duplicate_reservation_event!(ctx.kernel, &1),
            malformed: &malform_tuple!/1,
            unreadable: &set_arguments!(&1, ~s("not-a-map"))
          ] do
        run = run!(ctx)
        row = at(@t0, fn -> sent_fake!(run, "c-g1-#{label}") end)
        {:ok, _} = stop!(ctx, run, :succeeded)
        set_generation!(row, 1)
        break.(row)
        Clock.freeze(past_cutoff(row.sent_at))

        assert e1(run.run.id, stale(), ctx.agent) == {:error, :authority_unbindable},
               "E1 (generation 1, #{label}): broken evidence fails closed"

        assert stored(row.id).status == :sent
      end

      assert :ok = StaleRunSweeper.sweep(ctx.tenant.id)
      assert stored(cal.id).status == :sent
    end

    test "queued and running runs are never in case (c)", ctx do
      running = run!(ctx)
      row = at(@t0, fn -> sent_claude!(running, "c-running") end)

      %Oban.Job{} =
        %{"run_id" => running.run.id}
        |> Oban.Job.new(worker: "SdrAgent.SDR.ReplyWorker", queue: :agent)
        |> Repo.insert!()

      sweep_at(ctx, past_cutoff(row.sent_at))
      assert {stored(row.id).status, stored_run(running).status} == {:sent, :running}
      assert e1(running.run.id, stale(), ctx.agent) == {:error, :not_terminal}

      definition = AgentsFixtures.definition!(ctx.tenant)
      {:ok, queued} = Agents.create_run(AgentsFixtures.run_attrs(definition), actor: ctx.agent)
      assert e1(queued.id, stale(), ctx.agent) == {:error, :not_terminal}
    end
  end

  ## Gate.reservation_authority/1

  describe "reservation evidence classes" do
    test "each class, and a failed read is :invalid, not a raise", ctx do
      run = run!(ctx)
      plain = sent_claude!(run, "a-plain")
      assert authority(plain) == :no_tuple

      gone = sent_claude!(run, "a-gone")
      drop_reservation_event!(gone)
      assert authority(gone) == :no_event

      proof = run!(ctx, usage_origin: :proof)
      cal = sent_calibration!(proof, "a-cal")
      assert {:recorded, %{profile_id: :claude_cli_opus}} = authority(cal)

      dup = sent_claude!(run, "a-dup")
      duplicate_reservation_event!(ctx.kernel, dup)
      assert authority(dup) == :invalid

      bad = sent_claude!(run, "a-bad")
      malform_tuple!(bad)
      assert authority(bad) == :invalid

      args = sent_claude!(run, "a-args")
      set_arguments!(args, ~s("not-a-map"))
      assert authority(args) == :invalid

      assert authority(%{plain | tenant_id: "not-a-uuid"}) == :invalid
    end
  end

  ## The domain function's boundary

  describe "Agents.mark_terminal_run_sent_unknown/3" do
    setup ctx do
      run = run!(ctx)
      row = at(@t0, fn -> sent_claude!(run, "b-row") end)
      {:ok, _} = stop!(ctx, run, :succeeded)
      Clock.freeze(past_cutoff(row.sent_at))
      Map.merge(ctx, %{target: run, row: row})
    end

    test "only the tenant's agent runtime; others are refused and write nothing", ctx do
      tenantless = struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: nil)
      other_system = system_actor(:reconciler, ctx.tenant)

      for actor <- [ctx.admin, tenantless, other_system],
          id <- [ctx.target.run.id, Ecto.UUID.generate()] do
        assert {:error, %Ash.Error.Forbidden{}} = e1(id, stale(), actor)
      end

      denied = length(events_of_type(ctx.tenant, "authz.denied"))

      assert {:error, %Ash.Error.Forbidden{}} =
               e1(ctx.target.run.id, stale(), human(:auditor, ctx.tenant))

      assert length(events_of_type(ctx.tenant, "authz.denied")) == denied + 1

      foreign = struct(SdrAgent.Actor, type: :agent_runtime, tenant_id: Ecto.UUID.generate())
      assert e1(ctx.target.run.id, stale(), foreign) == {:error, :run_not_found}
      assert e1("not-a-uuid", stale(), ctx.agent) == {:error, :run_not_found}

      for grace <- [0, -1, "1800", 1.5],
          do: assert(e1(ctx.target.run.id, grace, ctx.agent) == {:error, :invalid_stale_after})

      assert stored(ctx.row.id).status == :sent
      assert unknown_events(ctx, ctx.row) == []

      assert e1(ctx.target.run.id, stale(), ctx.agent) == {:ok, 1}
      assert e1(ctx.target.run.id, stale(), ctx.agent) == {:ok, 0}
      assert stored(ctx.row.id).status == :unknown
    end

    test "a failure on a later row rolls back the whole run", ctx do
      run = run!(ctx)
      a = at(@t0, fn -> sent_claude!(run, "r-a") end)
      b = at(DateTime.add(@t0, 1, :second), fn -> sent_fake!(run, "r-b") end)
      {:ok, _} = stop!(ctx, run, :cancelled)

      Repo.query!("""
      CREATE FUNCTION e1_refuse_b() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'e1 injected failure'; END; $$
      """)

      Repo.query!("""
      CREATE TRIGGER e1_refuse_b BEFORE UPDATE ON model_invocations FOR EACH ROW
      WHEN (OLD.id = '#{b.id}' AND NEW.status = 'unknown') EXECUTE FUNCTION e1_refuse_b()
      """)

      Clock.freeze(past_cutoff(b.sent_at))
      assert {:error, _} = e1(run.run.id, stale(), ctx.agent)
      assert {stored(a.id).status, stored(b.id).status} == {:sent, :sent}
      assert unknown_events(ctx, a) == []
    end
  end

  ## The grace setting

  describe "an invalid stale_after_seconds" do
    defp with_setting(value, fun) do
      previous = Application.fetch_env(:sdr_agent, StaleRunSweeper)
      Application.put_env(:sdr_agent, StaleRunSweeper, value)

      try do
        fun.()
      after
        case previous do
          {:ok, config} -> Application.put_env(:sdr_agent, StaleRunSweeper, config)
          :error -> Application.delete_env(:sdr_agent, StaleRunSweeper)
        end
      end
    end

    test "makes the whole sweep write nothing, with a fixed content-free warning", ctx do
      abandoned = run!(ctx)
      abandoned_row = at(@t0, fn -> sent_claude!(abandoned, "s-abandoned") end)
      stopped = run!(ctx)
      stopped_row = at(@t0, fn -> sent_claude!(stopped, "s-stopped") end)
      {:ok, _} = stop!(ctx, stopped, :succeeded)
      Clock.freeze(DateTime.add(@t0, 30 * 86_400, :second))

      for {value, canary} <- [
            {[stale_after_seconds: 0], nil},
            {[stale_after_seconds: -1], nil},
            {[stale_after_seconds: "canary-7f3a"], "canary-7f3a"},
            {[stale_after_seconds: 1_234_567.25], "1234567.25"},
            {"canary-container", "canary-container"},
            {%{stale_after_seconds: 1800}, nil}
          ] do
        count = length(events(ctx.tenant))

        {result, log} =
          with_log(fn ->
            with_setting(value, fn ->
              try do
                StaleRunSweeper.sweep(ctx.tenant.id)
              rescue
                error -> {:raised, error.__struct__}
              end
            end)
          end)

        assert result == :ok,
               "E1: an invalid setting (#{inspect(value)}) makes the sweep return :ok, " <>
                 "got #{inspect(result)}"

        assert log =~ @warning
        if canary, do: refute(log =~ canary, "the warning names no value")
        assert length(events(ctx.tenant)) == count
        assert stored_run(abandoned).status == :running
        assert {stored(abandoned_row.id).status, stored(stopped_row.id).status} == {:sent, :sent}
      end
    end
  end

  ## Late settlement (sequential orders; the lock-wait order is in the race file)

  describe "a late facade settlement" do
    setup do
      dump = Path.join(System.tmp_dir!(), "sdr-e1-#{System.unique_integer([:positive])}")
      on_exit(fn -> (dump <> ".*") |> Path.wildcard() |> Enum.each(&File.rm/1) end)
      %{dump: dump}
    end

    defp server!(dump, delay_ms) do
      {:ok, server} =
        ClaudeCLI.start_link(
          command: System.find_executable("elixir"),
          test_launcher: true,
          command_args: [@fake, "env_dump", dump, Integer.to_string(delay_ms)],
          timeout: 30_000
        )

      server
    end

    test "control: a running run's call completes normally", ctx do
      run = run!(ctx)
      assert {:ok, _} = complete(run, "l-control", server!(ctx.dump, 0))
      assert by_key(ctx, "l-control").status == :completed
    end

    test "ClaudeCLI, recovery first: exactly :invocation_already_settled", ctx do
      run = run!(ctx)
      server = server!(ctx.dump, 4_000)
      call = Task.async(fn -> complete(run, "l-first", server) end)
      assert eventually(fn -> match?(%{status: :sent}, by_key(ctx, "l-first")) end)
      {:ok, _} = stop!(ctx, run, :cancelled)
      row = by_key(ctx, "l-first")

      sweep_at(ctx, past_cutoff(row.sent_at))
      assert stored(row.id).status == :unknown, "E1: the cancelled run's sent row is unknown"

      assert Task.await(call, 30_000) == {:error, :invocation_already_settled}
      after_settle = stored(row.id)
      assert after_settle.status == :unknown
      assert after_settle.response_sha256 == nil
      refute released?(row)
      assert by_key(ctx, "l-first-retry") == nil
    end

    test "a provider-error outcome keeps its own refusal", ctx do
      run = run!(ctx)
      sent = at(@t0, fn -> sent_claude!(run, "l-error") end)
      {:ok, _} = stop!(ctx, run, :cancelled)
      sweep_at(ctx, past_cutoff(sent.sent_at))
      assert stored(sent.id).status == :unknown, "E1: the row is unknown"

      assert_status_refused(
        Agents.fail_model_invocation(sent, %{error: %{"kind" => "provider_error"}},
          actor: run.agent
        ),
        "invalid transition to failed"
      )

      assert stored(sent.id).status == :unknown
    end

    test "the Fake's stale settle is refused by the status transition", ctx do
      run = run!(ctx)
      sent = at(@t0, fn -> sent_fake!(run, "l-fake") end)
      {:ok, _} = stop!(ctx, run, :cancelled)
      sweep_at(ctx, past_cutoff(sent.sent_at))
      assert stored(sent.id).status == :unknown, "E1: the Fake row is unknown"
      charged = usage(ctx)

      assert_status_refused(
        Agents.complete_model_invocation(sent, AgentsFixtures.completion(), actor: run.agent),
        "invalid transition to completed"
      )

      assert stored(sent.id).status == :unknown
      assert usage(ctx) == charged
      refute released?(sent)
    end

    test "a completion refused on the terminal run first; a later pass marks it", ctx do
      run = run!(ctx)
      sent = at(@t0, fn -> sent_fake!(run, "l-terminal-first") end)
      {:ok, _} = stop!(ctx, run, :cancelled)
      before = frozen_run(stored_run(run))

      assert_status_refused(
        Agents.complete_model_invocation(sent, AgentsFixtures.completion(), actor: run.agent),
        "run is not running"
      )

      assert stored(sent.id).status == :sent
      sweep_at(ctx, past_cutoff(sent.sent_at))
      assert stored(sent.id).status == :unknown, "E1: the later pass marks it unknown"
      assert frozen_run(stored_run(run)) == before
    end
  end

  # The existing refusals (probed on main's behavior, pinned exactly).
  defp assert_status_refused(result, message) do
    assert {:error, %Ash.Error.Invalid{errors: errors}} = result

    assert Enum.any?(
             errors,
             &match?(%Ash.Error.Changes.InvalidAttribute{field: :status, message: ^message}, &1)
           ),
           "expected the status refusal #{inspect(message)}, got #{inspect(errors)}"
  end

  ## Lock order

  describe "lock order" do
    test "the run, then all its sent rows, before the first append", ctx do
      run = run!(ctx)
      at(@t0, fn -> sent_claude!(run, "o-a") end)
      at(@t0, fn -> sent_fake!(run, "o-b") end)
      {:ok, _} = stop!(ctx, run, :succeeded)
      Clock.freeze(DateTime.add(@t0, stale() + 1, :second))

      queries = capture_queries(fn -> e1(run.run.id, stale(), ctx.agent) end)
      appends = for {q, i} <- Enum.with_index(queries), q =~ ~s("audit_chain_heads"), do: i
      [run_lock | _] = lock_indexes(queries, "agent_runs")
      invocation_locks = lock_indexes(queries, "model_invocations")

      assert appends != [], "E1: the normalization appends its events"
      assert invocation_locks != []
      first_append = Enum.min(appends)
      assert run_lock < Enum.min(invocation_locks)
      assert Enum.max(invocation_locks) < first_append
    end
  end

  defp complete(run, id, server) do
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

    ModelProvider.complete(
      %{
        id: id,
        run: run.run,
        actor: run.agent,
        operation: "model.complete",
        prompt: "Qualify the fixture lead",
        schema: @schema,
        audit: audit
      },
      provider: ClaudeCLI,
      provider_options: [server: server]
    )
  end

  defp by_key(ctx, key) do
    ModelInvocation
    |> Ash.Query.filter(idempotency_key == ^key and tenant_id == ^ctx.tenant.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp capture_queries(fun) do
    parent = self()
    handler = "e1-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sdr_agent, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:query, IO.iodata_to_binary(metadata.query)})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    collect_queries([])
  end

  defp collect_queries(acc) do
    receive do
      {:query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp lock_indexes(queries, table) do
    for {query, index} <- Enum.with_index(queries),
        String.starts_with?(query, "SELECT"),
        String.contains?(query, ~s(FROM "#{table}")),
        String.contains?(query, "FOR UPDATE"),
        do: index
  end

  defp eventually(fun, attempts \\ 500)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
