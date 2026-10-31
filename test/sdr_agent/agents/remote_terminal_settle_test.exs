defmodule SdrAgent.Agents.RemoteTerminalSettleTest do
  @moduledoc """
  S-B4 terminal-run remote settlement RED (addendum r2 77284f60, Codex
  entity/design PASS f25f89c8): a remote call whose run is already terminal
  (failed, e.g. after the caller's bounded wait timed out) is finished by
  `SdrAgent.Agents.RemoteCalls.settle_due/1` ledger-only.

  - A late valid result: the invocation is completed once; the run row,
    its Operation and every budget counter are unchanged; the charge stays
    one; no release; a second pass writes nothing.
  - A claimed call past its result deadline: unknown once, with the same
    guarantees.
  - A late schema-invalid result: failed (validation invalid); a late
    drift transcript: failed with one critical attention Failure. The run
    is never resumed.
  - The settler's private capability is restored after the pass.
  - Test-seam build: the capability's previous value is restored after
    an error and a raise; under a valid scope, a capability naming another
    invocation, tenant or call, or a call not yet settled, is refused.
  - Controls (pass before GREEN): a local invocation of a terminal run is
    still refused and rolled back; a genuine remote invocation finished
    through the public `Agents` wrappers (also with a forged
    `remote_terminal: true` option, an unscoped or nil-ref capability, or
    a capability bound to another invocation or tenant) is refused with no
    write; a running run's remote settlement still counts its call.

  Synthetic transcripts only; no model, no CLI, no network.
  """
  use SdrAgent.PrototypeCase, async: false

  alias SdrAgent.Agents
  alias SdrAgent.Agents.RemoteCalls
  alias SdrAgent.Clock
  alias SdrAgent.Operations.Failure
  alias SdrAgent.Operations.Operation
  alias SdrAgent.RemoteCallFixtures, as: F
  alias SdrAgent.RemoteSettlerFixtures, as: S

  require Ash.Query

  # The private capability key named in addendum r2 (process-scoped).
  @capability {SdrAgent.Agents.RemoteCalls, :terminal_settlement}

  setup do
    fx = F.world!()
    F.remote!()
    %{fx: fx}
  end

  ## Helpers

  defp charged(fx) do
    SdrAgent.Agents.ModelInvocation
    |> Ash.Query.filter(grant_id == ^fx.grant.id)
    |> Ash.count!(SdrAgent.Audit.Kernel.opts(fx.tenant.id))
  end

  defp fail_run!(fx) do
    run = Ash.get!(SdrAgent.Agents.AgentRun, fx.run.id, authorize?: false)

    assert {:ok, failed} =
             Agents.fail_run(
               run,
               %{status_reason: :provider_error, failure_reason: "sb4 synthetic terminal"},
               actor: fx.agent
             )

    assert failed.status == :failed
    failed
  end

  defp operation_row(fx) do
    case fx.run.operation_id do
      nil -> nil
      id -> F.rows(Operation, "id = $1", [F.dump(id)])
    end
  end

  # The terminal run, its Operation and the charge, as one snapshot.
  defp terminal_snapshot(fx), do: {S.run_row(fx.run.id), operation_row(fx), charged(fx)}

  defp failures_of(id), do: length(F.rows(Failure, "subject_id = $1", [F.dump(id)]))

  defp assert_ledger_only!(fx, id, before) do
    assert terminal_snapshot(fx) == before,
           "the terminal run, its Operation or the charge changed"

    assert charged(fx) == 1
    assert S.release_count(id) == 0
    assert S.run_row(fx.run.id)["status"] == "failed"

    # A second pass writes nothing more.
    events = F.event_count(fx)
    row = S.invocation_row(id)
    S.settle!(fx)
    assert F.event_count(fx) == events, "a second pass appended events"
    assert S.invocation_row(id) == row
    assert terminal_snapshot(fx) == before
  end

  defp refused?({:ok, _}), do: false
  defp refused?(_other), do: true

  ## Ledger-only finish (RED: "run is not running" today)

  test "a late valid result on a terminal run completes the invocation ledger-only", %{fx: fx} do
    c = S.completed!(fx, S.valid_transcript())
    fail_run!(fx)
    before = terminal_snapshot(fx)

    S.settle!(fx)

    assert S.invocation_row(c.invocation.id)["status"] == "completed"
    assert F.call_row(c.call_id)["state"] == "completed"
    assert Process.get(@capability) == nil, "the settler capability was not restored"
    assert_ledger_only!(fx, c.invocation.id, before)
  end

  test "a terminal run's claimed call past its result deadline becomes unknown once", %{fx: fx} do
    c = S.claimed!(fx)
    fail_run!(fx)
    before = terminal_snapshot(fx)

    Clock.freeze(F.ts(F.call_row(c.call_id)["result_deadline"]))
    S.settle!(fx)

    assert F.call_row(c.call_id)["state"] == "expired_unknown"
    assert S.invocation_row(c.invocation.id)["status"] == "unknown"
    assert Process.get(@capability) == nil
    assert_ledger_only!(fx, c.invocation.id, before)
  end

  test "a late schema-invalid result on a terminal run fails validation invalid", %{fx: fx} do
    c = S.completed!(fx, S.valid_transcript(%{"qualified" => "yes", "score" => 900}))
    fail_run!(fx)
    before = terminal_snapshot(fx)

    S.settle!(fx)

    row = S.invocation_row(c.invocation.id)
    assert row["status"] == "failed"
    assert row["validation_status"] == "invalid"
    assert_ledger_only!(fx, c.invocation.id, before)
  end

  test "a late drift transcript on a terminal run fails with one critical Failure", %{fx: fx} do
    transcript =
      S.stream([S.init_event(%{"model" => "claude-sb4-drift-model"}), S.result_event()])

    c = S.completed!(fx, transcript)
    fail_run!(fx)
    before = terminal_snapshot(fx)

    S.settle!(fx)

    row = S.invocation_row(c.invocation.id)
    assert row["status"] == "failed"
    assert S.error_code?(row, "model_attestation_drift"), "error: #{inspect(row["error"])}"
    assert failures_of(c.invocation.id) == 1
    assert_ledger_only!(fx, c.invocation.id, before)
  end

  ## Controls (pass today; must keep passing)

  test "a local invocation of a terminal run is still refused and rolled back", %{fx: fx} do
    F.remote!(:local)
    reserved = F.reserve!(fx)
    assert F.call_of(reserved.id) == nil, "prerequisite: a local reservation has no remote call"
    {:ok, sent} = Agents.mark_model_invocation_sent(reserved, actor: fx.agent)
    fail_run!(fx)
    events = F.event_count(fx)

    result =
      Agents.complete_model_invocation(sent, SdrAgent.AgentsFixtures.completion(),
        actor: fx.agent
      )

    assert refused?(result), "a local terminal settle was accepted: #{inspect(result)}"
    assert S.invocation_row(sent.id)["status"] == "sent"
    assert F.event_count(fx) == events
  end

  describe "a genuine remote invocation outside the settler" do
    setup %{fx: fx} do
      c = S.completed!(fx, S.valid_transcript())
      sent = F.invocation(c.invocation.id)
      fail_run!(fx)
      on_exit(fn -> Process.delete(@capability) end)
      %{c: c, sent: sent}
    end

    defp finish(fx, sent, opts \\ []) do
      F.safely(fn ->
        Agents.complete_model_invocation(
          sent,
          SdrAgent.AgentsFixtures.completion(),
          Keyword.merge([actor: fx.agent], opts)
        )
      end)
    end

    defp assert_untouched!(fx, sent, events) do
      assert S.invocation_row(sent.id)["status"] == "sent"
      assert F.event_count(fx) == events
    end

    test "the public wrapper, also with a forged remote_terminal option", %{fx: fx, sent: sent} do
      events = F.event_count(fx)

      for opts <- [[], [remote_terminal: true]] do
        result = finish(fx, sent, opts)
        assert refused?(result), "accepted with #{inspect(opts)}: #{inspect(result)}"
        assert_untouched!(fx, sent, events)
      end

      for unknown <- [
            fn -> Agents.mark_model_invocation_unknown(sent, actor: fx.agent) end,
            fn ->
              Agents.fail_model_invocation(
                sent,
                %{error: %{"kind" => "provider_error", "reason" => "sb4_synthetic"}},
                actor: fx.agent
              )
            end
          ] do
        assert refused?(F.safely(unknown))
        assert_untouched!(fx, sent, events)
      end
    end

    test "an unscoped, nil-ref, wrong-scope, other-invocation or other-tenant capability",
         %{fx: fx, c: c, sent: sent} do
      events = F.event_count(fx)
      other = Ecto.UUID.generate()

      for forged <- [
            {nil, fx.tenant.id, sent.id, c.call_id},
            {make_ref(), fx.tenant.id, sent.id, c.call_id},
            {make_ref(), fx.tenant.id, other, c.call_id},
            {make_ref(), other, sent.id, c.call_id}
          ] do
        Process.put(@capability, forged)
        result = finish(fx, sent)
        Process.delete(@capability)
        assert refused?(result), "accepted with #{inspect(forged)}: #{inspect(result)}"
        assert_untouched!(fx, sent, events)
      end
    end
  end

  ## Cleanup and identity under a valid scope (Codex e59e7c47; test-seam build)

  describe "the capability under a valid RemoteCalls scope" do
    setup do
      on_exit(fn -> Process.delete(@capability) end)
      :ok
    end

    defp scope_ref(scope), do: Map.fetch!(scope, :sdr_agent_remote_calls_scope)

    # Runs `fun.(scope)` in the test-seam scope; the refusal of a nested
    # finish may abort the scope's transaction, so the value is sent back.
    defp in_scope(fun) do
      _ =
        F.safely(fn ->
          RemoteCalls.__with_scope_for_test__(&send(self(), {:in_scope, fun.(&1)}))
        end)

      assert_received {:in_scope, value}
      value
    end

    test "the previous value is restored after an error and after a raise", %{fx: fx} do
      c = S.completed!(fx, S.valid_transcript())
      sent = F.invocation(c.invocation.id)
      Process.put(@capability, :previous)

      assert {:ok, {:error, :synthetic}} =
               RemoteCalls.__with_terminal_for_test__(c.call_id, sent, fn ->
                 assert {_ref, _tenant, _id, _call} = Process.get(@capability)
                 {:error, :synthetic}
               end)

      assert Process.get(@capability) == :previous

      assert_raise RuntimeError, "synthetic raise", fn ->
        RemoteCalls.__with_terminal_for_test__(c.call_id, sent, fn -> raise "synthetic raise" end)
      end

      assert Process.get(@capability) == :previous

      Process.delete(@capability)
      RemoteCalls.__with_terminal_for_test__(c.call_id, sent, fn -> :ok end)
      assert Process.get(@capability) == nil
    end

    test "another invocation, tenant or call, or an unsettled call, is refused", %{fx: fx} do
      c = S.completed!(fx, S.valid_transcript())
      sent = F.invocation(c.invocation.id)
      claimed = S.claimed!(fx)
      claimed_sent = F.invocation(claimed.invocation.id)
      fail_run!(fx)
      events = F.event_count(fx)
      other = Ecto.UUID.generate()

      cases = [
        {sent, fn ref -> {ref, fx.tenant.id, other, c.call_id} end},
        {sent, fn ref -> {ref, other, sent.id, c.call_id} end},
        {sent, fn ref -> {ref, fx.tenant.id, sent.id, other} end},
        {sent, fn ref -> {ref, fx.tenant.id, sent.id, claimed.call_id} end},
        {claimed_sent, fn ref -> {ref, fx.tenant.id, claimed_sent.id, claimed.call_id} end}
      ]

      for {invocation, tuple} <- cases do
        result =
          in_scope(fn scope ->
            Process.put(@capability, tuple.(scope_ref(scope)))

            F.safely(fn ->
              Agents.complete_model_invocation(
                invocation,
                SdrAgent.AgentsFixtures.completion(),
                actor: fx.agent
              )
            end)
          end)

        Process.delete(@capability)
        assert refused?(result), "accepted: #{inspect(result, limit: 6)}"
        assert S.invocation_row(invocation.id)["status"] == "sent"
        assert F.event_count(fx) == events
      end
    end
  end

  test "a running run's remote settlement still counts its call", %{fx: fx} do
    c = S.completed!(fx, S.valid_transcript())
    before = S.run_row(fx.run.id)["budget"]

    S.settle!(fx)

    assert S.invocation_row(c.invocation.id)["status"] == "completed"
    after_settle = S.run_row(fx.run.id)["budget"]
    assert after_settle["model_calls_used"] == before["model_calls_used"] + 1
    assert S.run_row(fx.run.id)["status"] == "running"
  end
end
