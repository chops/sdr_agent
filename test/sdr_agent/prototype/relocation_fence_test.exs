defmodule SdrAgent.Prototype.RelocationFenceTest do
  @moduledoc """
  S-B1 RED (ADR-0024 decision 1; plan R2 "Predicates" and "Final fence
  serialization"; r4a C1): the identity-scoped fence on the spending writes
  `SdrAgent.Agents.reserve_model_invocation/3` and
  `SdrAgent.Agents.admit_launch/3`, in prototype runtime with S1's real
  provisioning (`SdrAgent.PrototypeGateFixtures.prototype!/1`).

  Contract specified here:

  - a database holding a `fenced` event whose identity equals its own live
    identity, with no later `aborted` in that relocation, refuses a
    reservation and a launch admission with `{:error, :relocation_fenced}`,
    writing no invocation, no audit event and no status change; the check
    runs after `Kernel.lock_head`, so a reservation made before the fence
    committed is refused at admission;
  - every other audit-appending writer re-checks the same fence after
    `Kernel.lock_head`, refusing with `{:error, :relocation_fenced}` and
    writing no event, run, Operation or job: assign
    (`SdrAgent.SDR.assign_lead/2`), job-start
    (`SdrAgent.Operations.start_operation/2`, `SdrAgent.Agents.start_run/2`),
    settlement (`SdrAgent.Agents.complete_model_invocation/3`) and a stale
    non-model writer that started before the fence
    (`SdrAgent.Agents.set_run_phase/3` on a run started before it);
  - an `aborted` after the fence lifts it on the source;
  - the copied fence names the source identity: the destination (a
    different live identity) with an activation admits a reservation;
  - C1: a restored archive whose identity matches no activated to_identity
    and is not the original admits no reservation.

  The concurrent proof that a writer holding the head lock before the
  `fenced` append commits first and a later writer is refused (plan r1 S-B1
  "a stale pre-fence writer is serialized by the head lock") is
  `SdrAgent.Prototype.RelocationFenceRaceTest`
  (`relocation_fence_race_test.exs`), on independent connections.

  Chain writes are owner-run (the `:relocation` kernel marker) in ordinary
  runtime; the live identity is the test-build seam
  (`PrototypeFixtures.put_live_identity/1`). Synthetic `.test` data only.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Actor
  alias SdrAgent.Agents.ModelInvocation
  alias SdrAgent.Prototype.Checks.KernelMarker
  alias SdrAgent.PrototypeGateFixtures, as: G

  @relocation SdrAgent.Prototype.Relocation
  @event SdrAgent.Prototype.RelocationEvent
  @source_side [:planned, :writers_stopped, :fenced]

  setup do
    fx = G.prototype!()
    run = G.run!(fx)
    original = Map.take(fx.snapshot, [:database, :database_oid, :system_identifier])

    destination = %{
      original
      | database_oid: original.database_oid + 1_000,
        system_identifier: original.system_identifier - 1
    }

    archive = %{
      original
      | database_oid: original.database_oid + 2_000,
        system_identifier: original.system_identifier - 2
    }

    %{fx: fx, run: run, original: original, destination: destination, archive: archive}
  end

  ## Helpers

  defp relocation_context do
    KernelMarker.context(:relocation)
  rescue
    FunctionClauseError -> flunk("KernelMarker has no :relocation marker")
  end

  defp owner(fx), do: [actor: Actor.system(:kernel, fx.tenant.id), context: relocation_context()]

  # Owner-run writes in ordinary runtime at `live`, then back in prototype
  # runtime at `live`.
  defp owner_run!(ctx, live, fun) do
    assert PrototypeFixtures.leave_runtime() == :ok
    assert PrototypeFixtures.put_live_identity(live) == :ok
    result = fun.()
    G.enter!(ctx.fx)
    result
  end

  defp relocation!(ctx) do
    loaded!(@relocation)

    result =
      @relocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          binding_id: ctx.fx.binding.id,
          relocation_seq: 1,
          from_identity: ctx.original,
          to_identity: ctx.destination
        },
        owner(ctx.fx)
      )
      |> Ash.create()

    assert match?({:ok, %{id: _}}, result), "prerequisite: relocation create: #{inspect(result)}"
    {:ok, relocation} = result
    relocation
  end

  defp append!(ctx, relocation, kinds) do
    loaded!(@event)

    for kind <- kinds do
      result =
        @event
        |> Ash.Changeset.for_create(
          :append,
          %{relocation_id: relocation.id, kind: kind},
          owner(ctx.fx)
        )
        |> Ash.create()

      assert match?({:ok, %{id: _}}, result), "prerequisite: append #{kind}: #{inspect(result)}"
    end

    :ok
  end

  # The source fenced at the original identity; returns the relocation.
  defp fenced!(ctx) do
    owner_run!(ctx, ctx.original, fn ->
      relocation = relocation!(ctx)
      append!(ctx, relocation, @source_side)
      relocation
    end)
  end

  # The destination's copy: the source events, then restored and activated
  # at the destination identity.
  defp activated_copy!(ctx) do
    relocation = fenced!(ctx)
    owner_run!(ctx, ctx.destination, fn -> append!(ctx, relocation, [:restored, :activated]) end)
    relocation
  end

  defp effects(ctx), do: {G.invocations(ctx.fx), length(events(ctx.fx.tenant))}

  defp status(invocation),
    do: Ash.get!(ModelInvocation, invocation.id, authorize?: false).status

  ## Tests

  describe "the fence on the source" do
    test "a fenced source refuses a reservation, writing nothing", ctx do
      _relocation = fenced!(ctx)
      before = effects(ctx)
      result = G.reserve(ctx.fx, ctx.run)

      assert result == {:error, :relocation_fenced},
             "reserve on a fenced source: #{inspect(result)}"

      assert effects(ctx) == before, "the refused reservation wrote an invocation or event"
    end

    test "a reservation made before the fence is refused at admission, unchanged", ctx do
      reserved = G.reserve(ctx.fx, ctx.run)

      assert match?({:ok, %ModelInvocation{}}, reserved),
             "prerequisite: pre-fence reserve: #{inspect(reserved)}"

      {:ok, invocation} = reserved
      _relocation = fenced!(ctx)
      before = {status(invocation), length(events(ctx.fx.tenant))}

      result = G.launch(ctx.fx, invocation)

      assert result == {:error, :relocation_fenced},
             "admit on a fenced source: #{inspect(result)}"

      assert {status(invocation), length(events(ctx.fx.tenant))} == before
    end

    test "the source stays fenced after the destination activates", ctx do
      _relocation = activated_copy!(ctx)
      assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
      result = G.reserve(ctx.fx, ctx.run)
      assert result == {:error, :relocation_fenced}, "reserve on the source: #{inspect(result)}"
    end

    # r3b M2 (Codex bbb5c558): interim post-fence abort refusal; fork-safe abort is S-B1b.
    test "aborted after the fence is refused (r3b M2 interim; S-B1b)", ctx do
      relocation = fenced!(ctx)
      before = {abort_rows(relocation), abort_events(ctx, relocation)}

      result =
        owner_run!(ctx, ctx.original, fn ->
          @event
          |> Ash.Changeset.for_create(
            :append,
            %{relocation_id: relocation.id, kind: :aborted},
            owner(ctx.fx)
          )
          |> Ash.create()
        end)

      assert match?({:error, %Ash.Error.Invalid{}}, result),
             "post-fence abort: expected Invalid, got #{inspect(result)}"

      assert {abort_rows(relocation), abort_events(ctx, relocation)} == before,
             "the refused abort wrote a row or ledger event"

      assert PrototypeFixtures.put_live_identity(ctx.original) == :ok
      reserved = G.reserve(ctx.fx, ctx.run)

      assert reserved == {:error, :relocation_fenced},
             "reserve after refusal: #{inspect(reserved)}"
    end

    defp abort_rows(relocation) do
      table = AshPostgres.DataLayer.Info.table(@event)

      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM #{table} WHERE relocation_id = $1 AND kind::text = 'aborted'",
          [Ecto.UUID.dump!(relocation.id)]
        )

      n
    end

    defp abort_events(ctx, relocation) do
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM audit_events WHERE tenant_id = $1 " <>
            "AND event_type = 'prototype.relocation.event_appended' " <>
            "AND payload -> 'changes' ->> 'relocation_id' = $2 " <>
            "AND payload -> 'changes' ->> 'kind' = 'aborted'",
          [Ecto.UUID.dump!(ctx.fx.tenant.id), relocation.id]
        )

      n
    end
  end

  ## Every audit-appending writer (Codex hold review 004447Z must_fix; plan
  ## R2 "Final fence serialization": reserve, admit, assign, settlement and
  ## job-start writes re-check the fence after Kernel.lock_head).

  describe "non-model audit-appending writers on a fenced source" do
    defp tenant_count(table, fx) do
      %{rows: [[n]]} =
        Repo.query!(~s[SELECT count(*) FROM "#{table}" WHERE tenant_id = $1], [
          Ecto.UUID.dump!(fx.tenant.id)
        ])

      n
    end

    defp writes(ctx) do
      %{rows: [[jobs]]} = Repo.query!("SELECT count(*) FROM oban_jobs", [])

      {length(events(ctx.fx.tenant)), tenant_count("agent_runs", ctx.fx),
       tenant_count("operations", ctx.fx), jobs, G.invocations(ctx.fx)}
    end

    defp refused_fenced!(ctx, label, fun) do
      before = writes(ctx)
      result = fun.()

      assert result == {:error, :relocation_fenced},
             "#{label} on a fenced source: #{inspect(result)}"

      assert writes(ctx) == before, "the refused #{label} wrote an event, run, operation or job"
    end

    # A synthetic lead assigned through `SdrAgent.SDR.assign_lead/2` (the
    # bound admin), its run and Operation queued, before any fence.
    defp assigned_queued!(ctx) do
      campaign = SdrAgent.SalesFixtures.active_campaign!(ctx.fx.tenant)
      lead = SdrAgent.SalesFixtures.lead!(ctx.fx.tenant)
      assigned = SdrAgent.SDR.assign_lead(lead, campaign_id: campaign.id, actor: ctx.fx.admin)
      assert match?({:ok, %{run: _, operation: _, job: _}}, assigned), "prerequisite: assign"
      {:ok, queued} = assigned
      queued
    end

    test "assign: SDR.assign_lead/2 is refused", ctx do
      campaign = SdrAgent.SalesFixtures.active_campaign!(ctx.fx.tenant)
      lead = SdrAgent.SalesFixtures.lead!(ctx.fx.tenant)
      _relocation = fenced!(ctx)
      before = lead_row(lead)

      refused_fenced!(ctx, "assign", fn ->
        SdrAgent.SDR.assign_lead(lead, campaign_id: campaign.id, actor: ctx.fx.admin)
      end)

      assert lead_row(lead) == before,
             "the refused assign changed the lead's status/assigned_at"
    end

    defp lead_row(lead) do
      %{rows: [row]} =
        Repo.query!("SELECT status::text, assigned_at FROM leads WHERE id = $1", [
          Ecto.UUID.dump!(lead.id)
        ])

      row
    end

    test "job-start: the assigned Operation's and run's starts are refused", ctx do
      queued = assigned_queued!(ctx)
      _relocation = fenced!(ctx)

      refused_fenced!(ctx, "operation start", fn ->
        SdrAgent.Operations.start_operation(queued.operation, actor: ctx.fx.agent)
      end)

      refused_fenced!(ctx, "run start", fn ->
        SdrAgent.Agents.start_run(queued.run, actor: ctx.fx.agent)
      end)

      assert Ash.get!(SdrAgent.Operations.Operation, queued.operation.id, authorize?: false).status ==
               queued.operation.status

      assert Ash.get!(SdrAgent.Agents.AgentRun, queued.run.id, authorize?: false).status ==
               queued.run.status
    end

    test "settlement: completing a call sent before the fence is refused, still sent", ctx do
      reserved = G.reserve(ctx.fx, ctx.run)
      assert match?({:ok, %ModelInvocation{}}, reserved), "prerequisite: reserve"
      {:ok, reserved} = reserved
      sent = G.launch(ctx.fx, reserved)
      assert match?({:ok, %ModelInvocation{status: :sent}}, sent), "prerequisite: launch"
      {:ok, sent} = sent
      _relocation = fenced!(ctx)

      refused_fenced!(ctx, "settlement", fn ->
        SdrAgent.Agents.complete_model_invocation(
          sent,
          SdrAgent.AgentsFixtures.completion(),
          actor: ctx.fx.agent
        )
      end)

      assert status(sent) == :sent
    end

    test "a stale non-model writer: a run started before the fence cannot change phase", ctx do
      run = ctx.run
      assert run.status == :running, "prerequisite: a running run"
      _relocation = fenced!(ctx)
      next = if run.phase == :qualify, do: :plan, else: :qualify

      refused_fenced!(ctx, "stale set_run_phase", fn ->
        SdrAgent.Agents.set_run_phase(run, next, actor: ctx.fx.agent)
      end)

      assert Ash.get!(SdrAgent.Agents.AgentRun, run.id, authorize?: false).phase == run.phase
    end
  end

  describe "the copied fence on the destination" do
    test "with an activation, the destination's different identity admits a reservation", ctx do
      _relocation = activated_copy!(ctx)
      assert PrototypeFixtures.put_live_identity(ctx.destination) == :ok
      result = G.reserve(ctx.fx, ctx.run)

      assert match?({:ok, %ModelInvocation{}}, result),
             "reserve on the activated destination: #{inspect(result)}"
    end
  end

  describe "read-only recovery (C1)" do
    test "a restored archive matching no activation and not the original admits nothing", ctx do
      _relocation = activated_copy!(ctx)
      assert PrototypeFixtures.put_live_identity(ctx.archive) == :ok
      before = G.invocations(ctx.fx)
      result = G.reserve(ctx.fx, ctx.run)
      refute match?({:ok, _}, result), "the archive admitted a reservation: #{inspect(result)}"
      assert G.invocations(ctx.fx) == before
    end
  end
end
