defmodule SdrAgentWeb.AdminLiveSwitchRaceTest do
  @moduledoc """
  R0-05 RED (`docs/product/r0/r0-05-interface.md` draft 3, interface PASS
  at `fbc3203`, Codex `232bd20d`), the resolver's frozen review states on
  independent connections: Tests 10 and 10a, and section 3's retry rules
  after an unknown outcome. Element ids and events are those listed in
  `SdrAgentWeb.AdminLiveSwitchTest`.

  An unknown outcome needs a settlement barrier that can't be taken, so
  this module runs the SQL sandbox in `:auto` mode for its own duration
  (synchronous; restored to `:manual` after) and truncates only a test
  database before and after each test (`AdminSwitchHarness.auto_sandbox!/0`,
  b2β's race test table list). The caller's call times out against a
  blocked coordinator (`ResolveHarness.block_coordinator!/0`), and its
  settlement barrier waits on an independent lock holder
  (`ResolveHarness.hold!/1`, test 10) or on b2β race test 12's privileged,
  uncommitted original (`AdminSwitchHarness.original!/3`, test 10a: the
  only way attempt A can commit after attempt B's caller replay lookup).
  B is barriered after that lookup with b2β's `query_pause!/2`, matched to
  the page's own process. Return values are traced, so the exact b2β
  results (`:resolve_uncertain`, then B's `:resolve_timeout`, then the
  replay) are evidence of the ordering, not inferred from the page.

  Every lease, holder, original, paused process, blocked coordinator and
  trace is cleaned up on exit by the harnesses. The fake CLI; no model call.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import SdrAgent.Test.AdminSwitchHarness

  alias SdrAgent.Agents
  alias SdrAgent.Audit
  alias SdrAgent.AuditCase
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH

  @endpoint SdrAgentWeb.Endpoint
  @moduletag :r0_05
  @moduletag :capture_log
  @moduletag timeout: 240_000

  @resolve {Agents, :resolve_blocked_switch, 3}
  @switches {Agents, :list_profile_switches, 1}

  setup do
    auto_sandbox!()
    RH.lease_cleanup!()
    SH.select_claude_cli!()
    {:ok, tenant} = Audit.bootstrap(slug: "demo", name: "Demo Tenant")
    %{tenant: tenant, admin: AuditCase.new_human(:admin, tenant)}
  end

  defp admin_view(ctx) do
    {:ok, view, _html} = build_conn() |> sign_in_user(ctx.admin) |> live("/admin")
    view
  end

  defp open_resolution!(view, label) do
    click!(view, "#resolve-blocked", label)

    await_element!(
      view,
      "#resolution-review[data-state='editing']",
      nil,
      10_000,
      "#{label}: opening the resolver never reached :editing with the facts"
    )

    id = attr_of(view, "#resolution-review", "data-attestation-id")

    assert is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id)),
           "R0-05 #{label}: the :editing review carries no attestation id; got #{inspect(id)}"

    id
  end

  defp confirm!(view, text, label) do
    change_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)
    submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)
  end

  defp review_state(view), do: attr_of(view, "#resolution-review", "data-state")

  defp review_id(view), do: attr_of(view, "#resolution-review", "data-attestation-id")

  defp await_state!(view, state, timeout, label) do
    await_element!(
      view,
      "#resolution-review[data-state='#{state}']",
      nil,
      timeout,
      "#{label}: the review never reached :#{state} (now #{inspect(review_state(view))})"
    )
  end

  defp resolve_calls(tracer, ctx),
    do: tracer |> page_calls(@resolve) |> Enum.filter(&(actor_of(&1).id == ctx.admin.id))

  defp snapshot(view) do
    %{
      id: review_id(view),
      facts: text_of(view, "#resolution-facts"),
      statement: text_of(view, "#resolution-statement")
    }
  end

  # Audit refresh, manual refresh, a duplicate confirm, a second review and
  # (when `retry?`) a duplicate Check again: none may change the frozen
  # review or send anything.
  defp poke!(view, ctx, text, retry?) do
    audit_refresh!(ctx.tenant.id)
    click!(view, "#refresh-status", "frozen: manual refresh")
    render_submit(view, "confirm_resolution", %{"resolution_confirmation" => text})
    render_click(view, "open_resolution", %{})
    if retry?, do: render_click(view, "check_again", %{})
    render(view)
  end

  defp assert_frozen!(view, frozen, state, label) do
    assert review_state(view) == state,
           "R0-05 #{label}: the review stays :#{state}; got #{inspect(review_state(view))}"

    assert snapshot(view) == frozen,
           "R0-05 #{label}: frozen means the id, facts and statement can't be replaced; " <>
             "was #{inspect(frozen)}, now #{inspect(snapshot(view))}"
  end

  defp assert_same_identity!(calls, id, text, label) do
    [first | rest] = Enum.map(calls, &attestation_of/1)

    assert first.attestation_id == id and first.confirmation == text,
           "R0-05 #{label}: the review's id and the operator's text; got #{inspect(first)}"

    for other <- rest do
      assert other == first,
             "R0-05 #{label}: Check again resends exactly the frozen identity; " <>
               "#{inspect(other)} != #{inspect(first)}"
    end
  end

  ## 10. Frozen states, and Check again after :resolve_uncertain

  test "10. :submitting and :uncertain are frozen; Check again resends the same identity and settles",
       ctx do
    blocked = RH.dead_holder!(ctx)
    tracer = trace_calls!([@resolve])
    view = admin_view(ctx)
    id = open_resolution!(view, "10")
    text = confirmation(blocked)
    blocker = RH.block_coordinator!()
    # The caller's settlement barrier can't take the setting lock.
    {holder, _backend} = RH.hold!(fn -> RH.lock_setting!(ctx.tenant.id) end)

    confirm!(view, text, "10")
    await_state!(view, "submitting", 5_000, "10 confirm")
    frozen = snapshot(view)

    assert frozen.id == id and is_binary(frozen.facts) and frozen.statement =~ statement(),
           "R0-05 10: :submitting shows the review's id, facts and statement; got #{inspect(frozen)}"

    poke!(view, ctx, text, true)
    assert_frozen!(view, frozen, "submitting", "10 :submitting")

    assert length(resolve_calls(tracer, ctx)) == 1,
           "R0-05 10: a duplicate click while :submitting sends nothing"

    await_state!(view, "uncertain", 30_000, "10 :resolve_uncertain")
    assert has_element?(view, "#resolution-result", "The result isn't known yet.")

    assert match?([%{result: {:error, :resolve_uncertain}}], resolve_calls(tracer, ctx)),
           "fixture: b2β's unknown outcome"

    poke!(view, ctx, text, false)
    assert_frozen!(view, frozen, "uncertain", "10 :uncertain")
    assert length(resolve_calls(tracer, ctx)) == 1, "R0-05 10: only Check again acts"

    RH.release_holder(holder)
    RH.release_coordinator!(blocker)
    RH.drain!()
    assert RH.raw_status(blocked.id) == "blocked", "fixture: the expired attempt wrote nothing"

    click!(view, "#check-again", "10 Check again")
    await_element!(view, "#resolution-result[data-outcome='recorded']", nil, 25_000, "10 settled")
    assert has_element?(view, "#resolution-result", recorded_message())

    calls = resolve_calls(tracer, ctx)
    assert length(calls) == 2, "R0-05 10: one attempt and one Check again"
    assert_same_identity!(calls, id, text, "10")
    assert match?({:ok, %{switch: %{status: :failed}}}, List.last(calls).result)
    assert length(RH.resolved_events(ctx)) == 1
    assert RH.field(RH.switch!(ctx, blocked.id), :attestation_id) == id
  end

  ## 10a. A refused retry after uncertainty

  test "10a. A uncertain, B barriered after its replay lookup, A commits, B times out: still unknown, same id",
       ctx do
    blocked = RH.dead_holder!(ctx)
    latest = RH.latest_start!(ctx)
    tracer = trace_calls!([@resolve])
    view = admin_view(ctx)
    id = open_resolution!(view, "10a")
    text = confirmation(blocked)
    blocker = RH.block_coordinator!()
    attestation = RH.attestation(blocked, latest, :dead_holder, %{attestation_id: id})
    original = original!(blocked, attestation, ctx.admin)

    # A: the caller's call times out; its barrier waits on the open original.
    confirm!(view, text, "10a A")
    await_state!(view, "uncertain", 30_000, "10a A uncertain")
    frozen = snapshot(view)

    assert match?([%{result: {:error, :resolve_uncertain}}], resolve_calls(tracer, ctx)),
           "fixture: A is b2β's unknown outcome"

    # B: barriered just after its caller replay lookup (A not yet visible).
    RH.query_pause!(:b_lookup, view_replay_read(view.pid))
    b_started = System.monotonic_time(:millisecond)
    click!(view, "#check-again", "10a B")
    assert_receive {:b_lookup, b_caller}, 10_000, "R0-05 10a: B's caller replay lookup never ran"
    await_state!(view, "submitting", 5_000, "10a B enters :submitting")

    for _ <- 1..2, do: render_click(view, "check_again", %{})
    render_submit(view, "confirm_resolution", %{"resolution_confirmation" => text})

    assert length(resolve_calls(tracer, ctx)) == 2,
           "R0-05 10a: duplicate Check again clicks while B is in flight send nothing"

    # A commits; then B expires before the coordinator dequeues it.
    commit_original!(original)
    assert RH.raw_status(blocked.id) == "failed", "fixture: A committed"
    Process.sleep(max(15_300 - (System.monotonic_time(:millisecond) - b_started), 0))
    RH.release_coordinator!(blocker)
    RH.drain!()
    RH.resume(b_caller, :b_lookup)

    await_state!(view, "uncertain", 15_000, "10a B refused: back to :uncertain")
    [_a, b] = resolve_calls(tracer, ctx)

    assert b.result == {:error, :resolve_timeout},
           "fixture: B is b2β's retry-local :resolve_timeout; got #{inspect(b.result)}"

    result = text_of(view, "#resolution-result")

    assert result =~ "The result still isn't known",
           "R0-05 10a: a refused retry keeps the unknown-outcome wording; got #{inspect(result)}"

    refute result =~ "Not recorded", "R0-05 10a: a retry refusal is never Not recorded"
    assert_frozen!(view, frozen, "uncertain", "10a after B")
    assert has_element?(view, "#check-again"), "R0-05 10a: Check again is still offered"

    # C: a further Check again shows the recorded result (the replay).
    click!(view, "#check-again", "10a C")
    await_element!(view, "#resolution-result[data-outcome='recorded']", nil, 25_000, "10a replay")

    calls = resolve_calls(tracer, ctx)
    assert length(calls) == 3, "R0-05 10a: A, B and C only; no new review was opened"
    assert_same_identity!(calls, id, text, "10a")

    assert match?({:ok, %{replay: true}}, List.last(calls).result),
           "fixture: C is the exact replay; got #{inspect(List.last(calls).result)}"
  end

  ## Section 3: other retry refusals after uncertainty

  test "13. from :uncertain, a busy retry stays unknown; a conflict ends the review with the stored switch re-read",
       ctx do
    blocked = RH.dead_holder!(ctx)
    latest = RH.latest_start!(ctx)
    tracer = trace_calls!([@resolve, @switches])
    view = admin_view(ctx)
    id = open_resolution!(view, "13 retry")
    text = confirmation(blocked)
    blocker = RH.block_coordinator!()
    {holder, _backend} = RH.hold!(fn -> RH.lock_setting!(ctx.tenant.id) end)
    confirm!(view, text, "13 retry")
    await_state!(view, "uncertain", 30_000, "13 retry: A uncertain")
    frozen = snapshot(view)
    RH.release_holder(holder)
    RH.release_coordinator!(blocker)
    RH.drain!()

    # A busy coordinator refuses the retry: that proves nothing about A.
    :sys.replace_state(SdrAgent.AI.ModelProvider.Coordinator, &%{&1 | reconcile: :boot})
    click!(view, "#check-again", "13 retry busy")
    await_element!(view, "#resolution-result", "The result still isn't known", 15_000, "13 busy")
    :sys.replace_state(SdrAgent.AI.ModelProvider.Coordinator, &%{&1 | reconcile: nil})

    assert match?([_, %{result: {:error, :coordinator_busy}}], resolve_calls(tracer, ctx)),
           "fixture: the retry was refused busy"

    assert_frozen!(view, frozen, "uncertain", "13 retry busy")

    # Another admin resolves under the same attestation id: a conflict.
    other = AuditCase.new_human(:admin, ctx.tenant)
    conflicting = RH.attestation(blocked, latest, :dead_holder, %{attestation_id: id})
    assert match?({:ok, _}, RH.resolve(blocked, conflicting, other))
    reads = length(page_calls(tracer, @switches))

    click!(view, "#check-again", "13 retry conflict")

    await_element!(
      view,
      "#resolution-result[data-outcome='attestation_conflict']",
      nil,
      15_000,
      "13 retry conflict"
    )

    refute has_element?(view, "#check-again"), "R0-05 13: a conflict ends the review"
    result = text_of(view, "#resolution-result")

    refute result =~ recorded_message() or result =~ "Not recorded" or result =~ ~r/rolled back/i,
           "R0-05 13: a conflict is neither the recorded result nor a rollback; got #{inspect(result)}"

    new_reads = tracer |> page_calls(@switches) |> Enum.drop(reads)

    assert Enum.any?(new_reads, &(actor_of(&1).id == ctx.admin.id)),
           "R0-05 13: the page re-reads the stored switch as the actor"

    assert has_element?(view, "#stored-switch[data-status='failed']"),
           "R0-05 13: the page shows only what is recorded"
  end
end
