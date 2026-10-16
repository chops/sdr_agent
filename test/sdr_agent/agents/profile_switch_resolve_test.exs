defmodule SdrAgent.Agents.ProfileSwitchResolveTest do
  @moduledoc """
  C2-02b2β RED (`docs/product/r0/c2-02b2b-interface.md` draft 4, interface
  and entity PASS at `e60943c`), section 8 "Domain and policy", tests 1–7,
  10 (first case) and 11, and the binding obligations on replay, authority
  and event metadata (`codex-c202b2beta-e60943c-interface-pass.md`).

  Every switch is blocked by the real b2α coordinator
  (`SdrAgent.Test.ResolveHarness`): `:survivor` (adopted after a restart),
  `:dead_holder` (the old reaper killed before its receipt) and `:none` (that,
  then a test-side operator release). The resolver is called through
  presence-guarded helpers, so a missing b2β function fails as an assertion
  after the fixture. Shared SQL sandbox; the fake CLI; no model call.

  Passes by design (b2α behavior the contract keeps): in test 6, `complete`
  and `fail` on a blocked switch are refused as blocked, the current owner's
  `block` on it is a no-write replay, and the unphased α actions are
  refused.
  """
  use SdrAgent.AuditCase, async: false

  import SdrAgent.Test.ResolveHarness

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.Agents.ModelProfileSwitch
  alias SdrAgent.Agents.ProfileSwitches
  alias SdrAgent.AI.ModelProvider.Coordinator
  alias SdrAgent.Test.CoordinatorHarness

  @moduletag :c2_02b2b
  @moduletag timeout: 120_000

  @kinds [:none, :survivor, :dead_holder]
  # The resolution's persisted fields (section 4 and the entity table).
  @resolution_fields [
    :resolution,
    :resolved_by_id,
    :resolved_at,
    :attestation_id,
    :attested_start_id,
    :attested_generation,
    :attested_lease_kind
  ]
  @kept [:from_profile_id, :to_profile_id, :server_generation, :requested_by_id, :requested_at]
  # The event's closed metadata (section 4); the switch and tenant may also
  # be named, besides the flat keys every switch event carries.
  @required_payload ~w(attestation_id covered_generations attested_lease_kind outcome
                       resolution failure_reason setting_revision)
  @allowed_payload @required_payload ++
                     ~w(switch_id tenant_id action from_profile_id to_profile_id
                        server_generation record_sha256)

  setup do
    tenant = bootstrap!()
    lease_cleanup!()

    %{
      tenant: tenant,
      admin: human(:admin, tenant),
      runtime: system_actor(:model_runtime, tenant)
    }
  end

  ## 1. The happy path, for each lease kind

  describe "1. the happy path" do
    for kind <- @kinds do
      test "#{kind}: blocked → failed, provenance kept, one clock value, switch_resolved", ctx do
        blocked = blocked!(ctx, unquote(kind))
        latest = latest_start!(ctx)
        {:ok, setting} = Agents.get_profile_setting(actor: ctx.admin)
        attestation = attestation(blocked, latest, unquote(kind))

        result = resolve(blocked, attestation, ctx.admin)

        assert match?({:ok, %{switch: %ModelProfileSwitch{}}}, result),
               "C2-02b2β: resolving a blocked switch (#{unquote(kind)}) must return " <>
                 "{:ok, %{switch: s}}; got #{inspect(result)}"

        {:ok, reply} = result
        refute Map.get(reply, :replay), "a first resolution is not a replay"

        stored = switch!(ctx, blocked.id)
        assert stored.status == :failed
        assert stored.failure_reason == blocked.failure_reason, "the block's reason is kept"

        for key <- @kept,
            do: assert(Map.get(stored, key) == Map.get(blocked, key), "#{key} is kept")

        assert field(stored, :resolution) == :owner_attested
        assert field(stored, :resolved_by_id) == ctx.admin.id
        assert field(stored, :attestation_id) == attestation.attestation_id
        assert field(stored, :attested_start_id) == latest.id
        assert field(stored, :attested_generation) == latest.generation
        assert field(stored, :attested_lease_kind) == unquote(kind)

        assert stored.finished_at != nil and field(stored, :resolved_at) == stored.finished_at,
               "finished_at and resolved_at come from one clock value"

        assert Map.take(reply.switch, @resolution_fields) == Map.take(stored, @resolution_fields)

        assert Agents.get_profile_setting(actor: ctx.admin) == {:ok, setting},
               "the setting row and revision are not written"

        assert_resolved_event!(ctx, blocked, attestation, unquote(kind), latest, setting)
        quiet!()
      end
    end

    for kind <- @kinds do
      test "#{kind}: the facts are read-only, admin-only and name the covered starts", ctx do
        blocked = blocked!(ctx, unquote(kind))
        latest = latest_start!(ctx)
        before = effects(ctx)

        result = facts(blocked, ctx.admin)

        assert match?({:ok, %{}}, result),
               "C2-02b2β: facts must be {:ok, map}; got #{inspect(result)}"

        {:ok, facts} = result

        assert facts.switch.id == blocked.id
        assert facts.boot_id == status().boot_id
        assert facts_latest(facts).id == latest.id
        assert facts.hold == :held
        assert facts_kind(facts) == unquote(kind), "the observed lease kind"

        covered =
          ctx
          |> starts!()
          |> Enum.filter(&(&1.generation in blocked.server_generation..latest.generation//1))

        assert Enum.map(facts.covered_starts, & &1.id) == Enum.map(covered, & &1.id)

        for start <- facts.covered_starts,
            do: assert(start.pid && start.node && start.reaper_pid, "recorded identity")

        assert effects(ctx) == before, "the facts read makes no write and no runtime change"

        for actor <- [human(:reviewer, ctx.tenant), human(:auditor, ctx.tenant), ctx.runtime] do
          assert match?({:error, %Ash.Error.Forbidden{}}, facts(blocked, actor)),
                 "blocked_switch_facts is admin-only"
        end
      end
    end
  end

  ## 2. The shape

  test "2. a malformed attestation is :attestation_invalid and writes nothing", ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)
    valid = attestation(blocked, latest, :dead_holder)
    id = blocked.id
    before = effects(ctx)

    variants = [
      {"a wrong confirmation", %{valid | confirmation: "STOPPED"}},
      {"another switch's id", %{valid | confirmation: "STOPPED " <> Ecto.UUID.generate()}},
      {"a mis-cased confirmation", %{valid | confirmation: "stopped " <> id}},
      {"a mis-cased confirmation (title)", %{valid | confirmation: "Stopped " <> id}},
      {"a leading pad", %{valid | confirmation: " STOPPED " <> id}},
      {"a trailing pad", %{valid | confirmation: "STOPPED " <> id <> " "}},
      {"a doubled space", %{valid | confirmation: "STOPPED  " <> id}},
      {"an upcased id", %{valid | confirmation: "STOPPED " <> String.upcase(id)}},
      {"a missing confirmation", Map.delete(valid, :confirmation)},
      {"a nil confirmation", %{valid | confirmation: nil}},
      {"outcome completed", %{valid | outcome: :completed}},
      {"outcome as a string", %{valid | outcome: "failed"}},
      {"an extra field", Map.put(valid, :note, "checked")},
      {"an unknown lease kind", %{valid | attested_lease_kind: :gone}},
      {"a lease kind as a string", %{valid | attested_lease_kind: "none"}},
      {"a missing attestation_id", Map.delete(valid, :attestation_id)},
      {"a non-uuid attestation_id", %{valid | attestation_id: "attestation-1"}},
      {"another switch_id", %{valid | switch_id: Ecto.UUID.generate()}},
      {"a zero generation", %{valid | attested_generation: 0}},
      {"a missing start", Map.delete(valid, :attested_start_id)},
      {"a keyword list", Map.to_list(valid)}
    ]

    for {label, attestation} <- variants do
      result = resolve(blocked, attestation, ctx.admin)

      assert result == {:error, :attestation_invalid},
             "C2-02b2β: #{label} must be {:error, :attestation_invalid}; got #{inspect(result)}"
    end

    assert switch!(ctx, blocked.id) == blocked
    assert effects(ctx) == before
    assert resolved_events(ctx) == []

    # The allow side: the valid attestation resolves.
    assert match?({:ok, %{switch: %{status: :failed}}}, resolve(blocked, valid, ctx.admin))
  end

  ## 3. Actors

  test "3. every non-admin actor, and a demoted or disabled admin, is refused", ctx do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)

    demoted = new_human(:admin, ctx.tenant)
    {:ok, _} = Accounts.change_role(demoted, :reviewer, actor: ctx.admin)
    disabled = new_human(:admin, ctx.tenant)
    {:ok, _} = Accounts.change_status(disabled, :disabled, actor: ctx.admin)

    refused =
      [
        {"a reviewer", human(:reviewer, ctx.tenant)},
        {"an auditor", human(:auditor, ctx.tenant)},
        {"an admin demoted before the call (stale struct)", demoted},
        {"an admin disabled before the call (stale struct)", disabled},
        {"another tenant's admin", %{ctx.admin | tenant_id: Ash.UUIDv7.generate()}}
      ] ++ Enum.map(SdrAgent.Actor.types(), &{"system actor #{&1}", system_actor(&1, ctx.tenant)})

    for {label, actor} <- refused do
      result = resolve(blocked, attestation, actor)

      assert match?({:error, %Ash.Error.Forbidden{}}, result),
             "C2-02b2β: #{label} must be refused (Forbidden); got #{inspect(result)}"
    end

    assert match?({:error, _}, resolve(blocked, attestation, nil)), "no actor is refused"
    assert switch!(ctx, blocked.id) == blocked
    assert resolved_events(ctx) == []

    # The allow side: any other active human admin resolves, named as resolver.
    other = new_human(:admin, ctx.tenant)
    assert match?({:ok, %{switch: _}}, resolve(blocked, attestation, other))
    assert field(switch!(ctx, blocked.id), :resolved_by_id) == other.id
    assert field(switch!(ctx, blocked.id), :resolved_by_id) != blocked.requested_by_id
  end

  ## 4. The process

  test "4. resolve_blocked runs only in the coordinator's :resolve phase, as a human admin",
       ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)

    assert Ash.Resource.Info.action(ModelProfileSwitch, :resolve_blocked),
           "C2-02b2β: the action ModelProfileSwitch.resolve_blocked is not implemented"

    assert Code.ensure_loaded?(SdrAgent.Agents.Checks.ResolveContext),
           "C2-02b2β: SdrAgent.Agents.Checks.ResolveContext is not implemented"

    for {name, arity} <- [resolution_facts: 2, resolve_blocked: 2] do
      assert function_exported?(Coordinator, name, arity),
             "C2-02b2β: Coordinator.#{name}/#{arity} is not implemented"
    end

    inputs = %{
      attestation_id: Ecto.UUID.generate(),
      attested_start_id: latest.id,
      attested_generation: latest.generation,
      attested_lease_kind: :dead_holder
    }

    forged = %{
      profile_switch: %{phase: :resolve, action: :resolve_blocked, switch_id: blocked.id}
    }

    # Outside the coordinator: forbidden, even for an admin, and with a
    # forged or a genuine (test-seam) :resolve phase.
    for actor <- [ctx.admin, ctx.runtime], context <- [%{}, forged] do
      assert_forbidden!(direct(blocked, inputs, actor, context), "outside the coordinator")
    end

    assert_forbidden!(
      in_test_phase(:resolve, ctx.admin, blocked, &direct(blocked, inputs, ctx.admin, &1)),
      "a :resolve phase outside the coordinator process"
    )

    # In the coordinator: no phase, or the phase bound to model_runtime
    # (model_runtime gains no write), or the read-only :settle phase.
    for actor <- [ctx.admin, ctx.runtime] do
      assert_forbidden!(
        in_coordinator(fn -> direct(blocked, inputs, actor, %{}) end),
        "in the coordinator without a phase"
      )
    end

    assert_forbidden!(
      in_coordinator(fn ->
        in_test_phase(:resolve, ctx.runtime, blocked, &direct(blocked, inputs, ctx.runtime, &1))
      end),
      "a :resolve phase bound to model_runtime"
    )

    foreign_admin = %{ctx.admin | tenant_id: Ash.UUIDv7.generate()}

    assert_forbidden!(
      in_coordinator(fn ->
        in_test_phase(
          :resolve,
          foreign_admin,
          blocked,
          &direct(blocked, inputs, foreign_admin, &1)
        )
      end),
      "a :resolve phase bound to another tenant's admin"
    )

    for action <- [:resolve_blocked, :fail, :block] do
      assert_forbidden!(
        in_coordinator(fn ->
          in_test_phase(:settle, ctx.admin, blocked, fn context ->
            write(blocked, action, inputs, ctx.admin, context)
          end)
        end),
        "#{action} in the read-only :settle phase"
      )
    end

    # The b2α check's model_runtime rule is unchanged: an admin never matches it.
    refute in_coordinator(fn ->
             SdrAgent.Agents.Checks.CoordinatorProcess.match?(ctx.admin, %{}, [])
           end)

    assert switch!(ctx, blocked.id) == blocked
    assert resolved_events(ctx) == []
  end

  ## 5. The state

  test "5. a pending or completed switch is :switch_not_blocked; history unchanged", ctx do
    tree!()
    await_status!(&(&1.hold == :released))
    pause = pause_stage!(:drained)
    switch = request_switch!(ctx)
    assert_receive {:stage_paused, :drained, worker}, 20_000

    pending = switch!(ctx, switch.id)
    result = resolve(pending, attestation(pending, latest_start!(ctx), :survivor), ctx.admin)
    :telemetry.detach(pause)
    send(worker, :continue)

    assert result == {:error, :switch_not_blocked},
           "C2-02b2β: a pending switch must be :switch_not_blocked; got #{inspect(result)}"

    completed = await_switch!(ctx, switch.id, :completed)
    await_status!(&(&1.hold == :released))
    before = effects(ctx)

    result = resolve(completed, attestation(completed, latest_start!(ctx), :survivor), ctx.admin)
    assert result == {:error, :switch_not_blocked}
    assert switch!(ctx, switch.id) == completed
    assert effects(ctx) == before
    assert resolved_events(ctx) == []
  end

  test "5. a failed (rolled-back) switch is :switch_not_blocked; history unchanged", ctx do
    tree!(failing_preflight: :claude_cli_sonnet)
    await_status!(&(&1.hold == :released))
    switch = request_switch!(ctx)
    failed = await_switch!(ctx, switch.id, :failed)
    await_status!(&(&1.hold == :released))
    before = effects(ctx)

    result = resolve(failed, attestation(failed, latest_start!(ctx), :survivor), ctx.admin)

    assert result == {:error, :switch_not_blocked},
           "C2-02b2β: a failed switch must be :switch_not_blocked; got #{inspect(result)}"

    assert switch!(ctx, switch.id) == failed
    assert effects(ctx) == before
    assert resolved_events(ctx) == []
  end

  ## 6. The α finalizers

  test "6. complete and fail on a blocked switch are refused as blocked (passes by design)",
       ctx do
    blocked = dead_holder!(ctx)
    attrs = %{server_generation: blocked.server_generation, failure_reason: "test"}

    assert CoordinatorHarness.finalize(:complete_profile_switch, blocked, attrs,
             actor: ctx.runtime
           ) == {:error, :switch_blocked}

    assert CoordinatorHarness.finalize(:fail_profile_switch, blocked, attrs, actor: ctx.runtime) ==
             {:error, :switch_blocked}

    assert switch!(ctx, blocked.id) == blocked
  end

  test "6. the current owner's block on a blocked switch is a no-write replay (passes by design)",
       ctx do
    blocked = dead_holder!(ctx)
    before = effects(ctx)

    assert {:ok, %{status: :blocked}} =
             CoordinatorHarness.finalize(
               :block_profile_switch,
               blocked,
               %{server_generation: blocked.server_generation, failure_reason: "again"},
               actor: ctx.runtime
             )

    assert switch!(ctx, blocked.id) == blocked
    assert effects(ctx) == before
  end

  test "6. the unphased α actions are refused (passes by design)", ctx do
    blocked = dead_holder!(ctx)

    for {action, inputs} <- [
          complete: %{},
          fail: %{failure_reason: "x"},
          block: %{failure_reason: "x"}
        ],
        actor <- [ctx.runtime, ctx.admin] do
      assert_forbidden!(write(blocked, action, inputs, actor, %{}), "an unphased #{action}")
    end

    assert switch!(ctx, blocked.id) == blocked
  end

  test "6. fail on a resolved switch is :switch_already_finished, after α's guards", ctx do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    assert match?({:ok, %{switch: _}}, resolve(blocked, attestation, ctx.admin))
    resolved = switch!(ctx, blocked.id)
    settled!(:dead_holder)
    before = length(events(ctx.tenant))

    # α's stale-generation guard still runs first.
    stale =
      CoordinatorHarness.finalize(
        :fail_profile_switch,
        resolved,
        %{server_generation: resolved.server_generation + 1, failure_reason: "late"},
        actor: ctx.runtime
      )

    assert match?({:error, %Ash.Error.Invalid{}}, stale),
           "a stale-generation fail gets α's stale error first; got #{inspect(stale)}"

    result =
      CoordinatorHarness.finalize(
        :fail_profile_switch,
        resolved,
        %{server_generation: resolved.server_generation, failure_reason: "late"},
        actor: ctx.runtime
      )

    assert result == {:error, :switch_already_finished},
           "C2-02b2β: fail on a resolved switch is never a fail replay; got #{inspect(result)}"

    assert CoordinatorHarness.finalize(
             :complete_profile_switch,
             resolved,
             %{server_generation: resolved.server_generation},
             actor: ctx.runtime
           ) == {:error, :switch_already_finished}

    assert Map.take(switch!(ctx, blocked.id), [:status, :finished_at | @resolution_fields]) ==
             Map.take(resolved, [:status, :finished_at | @resolution_fields])

    assert length(events(ctx.tenant)) == before, "no fail event on a resolved switch"
  end

  ## 7. Replay precedence

  test "7. an exact replay right after the resolution has no effect", ctx do
    blocked = dead_holder!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :dead_holder)
    first = resolve(blocked, attestation, ctx.admin)

    assert match?({:ok, %{switch: _}}, first),
           "C2-02b2β: the first resolution; got #{inspect(first)}"

    settled!(:dead_holder)
    before = effects(ctx)

    replay = resolve(blocked, attestation, ctx.admin)
    assert_replay!(replay, blocked, ctx)
    assert effects(ctx) == before, "a replay writes nothing and has no runtime effect"
    assert length(resolved_events(ctx)) == 1
  end

  test "7. still an exact no-effect replay after a later start, a later boot and a new switch",
       ctx do
    blocked = none!(ctx)
    attestation = attestation(blocked, latest_start!(ctx), :none)
    first = resolve(blocked, attestation, ctx.admin)

    assert match?({:ok, %{switch: _}}, first),
           "C2-02b2β: the first resolution; got #{inspect(first)}"

    # A later start: the post-commit reconciliation's fresh start.
    released =
      await_status!(&(&1.hold == :released and &1.generation > attestation.attested_generation))

    # A later boot (killed once idle), then a new, completed switch.
    sync()
    kill_coordinator!()
    await_status!(&(&1.boot_id != released.boot_id and &1.hold == :released))
    switch = request_switch!(ctx)
    await_switch!(ctx, switch.id, :completed)
    await_status!(&(&1.hold == :released))
    quiet!()
    before = effects(ctx)

    replay = resolve(blocked, attestation, ctx.admin)
    assert_replay!(replay, blocked, ctx)
    assert effects(ctx) == before
    assert length(resolved_events(ctx)) == 1
  end

  for {resolved_kind, attempt_kind} <- [none: :survivor, survivor: :none, dead_holder: :none] do
    test "7. the same id with another resolver, switch, start, generation or kind " <>
           "(#{resolved_kind} vs #{attempt_kind}) conflicts",
         ctx do
      blocked = blocked!(ctx, unquote(resolved_kind))
      latest = latest_start!(ctx)
      attestation = attestation(blocked, latest, unquote(resolved_kind))
      first = resolve(blocked, attestation, ctx.admin)

      assert match?({:ok, %{switch: _}}, first),
             "C2-02b2β: the first resolution; got #{inspect(first)}"

      settled!(unquote(resolved_kind))

      # Another switch for the same attestation id: the freed slot's new request.
      {:ok, other} =
        Agents.request_profile_switch(
          %{
            to_profile_id: blocked.to_profile_id,
            expected_revision: 1,
            server_generation: status().generation
          },
          actor: ctx.admin
        )

      before = effects(ctx)

      conflicts = [
        {"another admin", blocked, attestation, new_human(:admin, ctx.tenant)},
        {"another switch", other,
         %{attestation | switch_id: other.id, confirmation: "STOPPED " <> other.id}, ctx.admin},
        {"another start", blocked, %{attestation | attested_start_id: Ecto.UUID.generate()},
         ctx.admin},
        {"another generation", blocked,
         %{attestation | attested_generation: latest.generation + 1}, ctx.admin},
        {"another lease kind only", blocked,
         %{attestation | attested_lease_kind: unquote(attempt_kind)}, ctx.admin}
      ]

      for {label, switch, conflicting, actor} <- conflicts do
        result = resolve(switch, conflicting, actor)

        assert result == {:error, :attestation_conflict},
               "C2-02b2β: #{label} under the same attestation_id must conflict; got #{inspect(result)}"
      end

      assert effects(ctx) == before
      assert length(resolved_events(ctx)) == 1
    end
  end

  test "7. a different attestation id on a resolved switch is :switch_not_blocked", ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)
    first = resolve(blocked, attestation(blocked, latest, :dead_holder), ctx.admin)

    assert match?({:ok, %{switch: _}}, first),
           "C2-02b2β: the first resolution; got #{inspect(first)}"

    settled!(:dead_holder)
    before = effects(ctx)

    result = resolve(blocked, attestation(blocked, latest, :dead_holder), ctx.admin)
    assert result == {:error, :switch_not_blocked}
    assert effects(ctx) == before
  end

  ## 10. Staleness (the facts read, then a later start)

  test "10. a start allocated after the facts read is :stale_attestation", ctx do
    blocked = survivor!(ctx)
    result = facts(blocked, ctx.admin)
    assert match?({:ok, %{}}, result), "C2-02b2β: facts; got #{inspect(result)}"
    {:ok, facts} = result
    stale = attestation(blocked, facts_latest(facts), facts_kind(facts))

    # A later boot adopts the survivor under a new start (killed once idle).
    before = status()
    kill_coordinator!()

    await_status!(
      &(&1.boot_id != before.boot_id and &1.hold == :held and &1.generation > before.generation)
    )

    sync()

    assert resolve(blocked, stale, ctx.admin) == {:error, :stale_attestation}
    assert switch!(ctx, blocked.id) == blocked

    # The allow side: an attestation of the current facts resolves.
    assert match?(
             {:ok, %{switch: _}},
             resolve(blocked, attestation(blocked, latest_start!(ctx), :survivor), ctx.admin)
           )
  end

  ## 11. Tenancy and the slot

  test "11. another tenant's switch is not found; a new request succeeds after the resolution",
       ctx do
    blocked = dead_holder!(ctx)
    latest = latest_start!(ctx)
    foreign = %{blocked | id: Ash.UUIDv7.generate(), tenant_id: Ash.UUIDv7.generate()}

    result =
      resolve(
        foreign,
        attestation(foreign, latest, :dead_holder),
        ctx.admin
      )

    assert not_found?(result),
           "C2-02b2β: another tenant's switch is not found; got #{inspect(result)}"

    request = fn ->
      Agents.request_profile_switch(
        %{
          to_profile_id: blocked.to_profile_id,
          expected_revision: 1,
          server_generation: status().generation
        },
        actor: ctx.admin
      )
    end

    assert match?({:error, _}, request.()), "the slot is occupied while blocked"

    assert match?(
             {:ok, %{switch: _}},
             resolve(blocked, attestation(blocked, latest, :dead_holder), ctx.admin)
           )

    assert match?({:ok, %{status: :pending}}, request.()),
           "C2-02b2β: a new request after the resolution did not open a switch"
  end

  ## Helpers

  # After a commit: :none and :survivor end in b2α's release; :dead_holder
  # stays held (the hard conflict), so it is only left to go quiet.
  defp settled!(kind) when kind in [:none, :survivor] do
    await_status!(&(&1.hold == :released), 20_000)
    quiet!()
  end

  defp settled!(:dead_holder), do: quiet!()

  defp assert_resolved_event!(ctx, blocked, attestation, kind, latest, setting) do
    profile_events =
      ctx.tenant
      |> events()
      |> Enum.filter(&(&1.subject_id == blocked.id))
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(& &1.event_type)

    assert Enum.take(profile_events, -2) == [
             "model.profile.switch_blocked",
             "model.profile.switch_resolved"
           ],
           "the chain shows switch_blocked, then switch_resolved: #{inspect(profile_events)}"

    assert [event] = resolved_events(ctx)
    payload = event.payload

    for key <- @required_payload,
        do: assert(Map.has_key?(payload, key), "switch_resolved metadata names #{key}")

    assert Map.keys(payload) -- @allowed_payload == [], "closed metadata: #{inspect(payload)}"
    assert payload["attestation_id"] == attestation.attestation_id
    assert payload["covered_generations"] == [blocked.server_generation, latest.generation]
    assert payload["attested_lease_kind"] == Atom.to_string(kind)
    assert payload["outcome"] == "failed"
    assert payload["resolution"] == "owner_attested"
    assert payload["failure_reason"] == blocked.failure_reason
    assert payload["setting_revision"] == setting.revision, "the stored revision"

    text = inspect(payload)

    for {label, pattern} <- [
          {"a pid", ~r/<\d+\.\d+\.\d+>|#PID</},
          {"a ref", ~r/#Reference</},
          {"the confirmation text", ~r/STOPPED/}
        ],
        do: refute(Regex.match?(pattern, text), "switch_resolved metadata carries #{label}")
  end

  defp assert_replay!(replay, blocked, ctx) do
    assert match?({:ok, %{switch: %ModelProfileSwitch{}, replay: true}}, replay),
           "C2-02b2β: an exact replay is {:ok, %{switch: stored, replay: true}}; got #{inspect(replay)}"

    {:ok, %{switch: stored}} = replay
    assert stored.id == blocked.id

    assert Map.take(stored, @resolution_fields) ==
             Map.take(switch!(ctx, blocked.id), @resolution_fields)
  end

  defp assert_forbidden!(result, label) do
    assert match?({:error, %Ash.Error.Forbidden{}}, result),
           "C2-02b2β: #{label} must be Forbidden; got #{inspect(result)}"
  end

  defp not_found?({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

  defp not_found?({:error, %Ash.Error.Query.NotFound{}}), do: true
  defp not_found?({:error, :not_found}), do: true
  defp not_found?(_result), do: false

  # A direct `resolve_blocked` (a raise, e.g. an unknown action, is observed).
  defp direct(switch, inputs, actor, context),
    do: write(switch, :resolve_blocked, inputs, actor, context)

  defp write(switch, action, inputs, actor, context) do
    observe(fn ->
      switch
      |> Ash.Changeset.for_update(action, Map.take(inputs, accepted(action)),
        actor: actor,
        context: context
      )
      |> Ash.update()
    end)
  end

  defp accepted(:resolve_blocked),
    do: [:attestation_id, :attested_start_id, :attested_generation, :attested_lease_kind]

  defp accepted(:complete), do: []
  defp accepted(_fail_or_block), do: [:failure_reason]

  defp in_coordinator(fun), do: Coordinator.test_run(fn _binding -> observe(fun) end, 30_000)

  # A genuine phase through the test build's seam (a raise is observed).
  defp in_test_phase(phase, actor, switch, fun) do
    binding = %{
      action: :resolve_blocked,
      tenant_id: switch.tenant_id,
      switch_id: switch.id,
      server_generation: switch.server_generation,
      actor: actor
    }

    observe(fn -> ProfileSwitches.with_test_phase(phase, binding, fun) end)
  end
end
