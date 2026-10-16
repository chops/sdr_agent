defmodule SdrAgentWeb.AdminLiveSwitchGreenTest do
  @moduledoc """
  R0-05 GREEN review regressions (Codex `codex-r005-8de4fca-green-review.md`,
  CHANGES REQUESTED at `8de4fca`), beyond the permanent probes in
  `SdrAgentWeb.AdminLiveSwitchProbeTest`:

    * **MF1** — an async completion (a resolution, or a facts re-check)
      re-validates the connected operator first: demoted, disabled or
      revoked while the completion is in flight, the operator gets the
      existing redirect and the page reads nothing more — also when the
      dispatched resolution was in fact recorded;
    * **MF2** — the stored line is the reviewed switch's own row: a failed
      read (or a missing target) is unknown, never another row;
    * **MF3** — the frozen confirmation is opaque in the view's state and
      absent from the debug crash path of a crashed attempt task;
    * the hardening: a success for another switch is not "recorded".

  The view process is suspended (`:erlang.suspend_process/1`) to hold a
  completion until the operator has changed; the coordinator is blocked to
  hold the attempt itself. Real coordinator fixtures, the fake CLI, no
  model call.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.Test.AdminSwitchHarness

  alias SdrAgent.Accounts
  alias SdrAgent.Agents
  alias SdrAgent.AI.ModelProvider.ClaudeCLI
  alias SdrAgent.AI.ModelProvider.ClaudeCLI.Reaper
  alias SdrAgent.AuditCase
  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH
  alias SdrAgentWeb.AdminLive.Confirmation
  alias SdrAgentWeb.AdminLive.ModelComponents
  alias SdrAgentWeb.AdminLive.Resolution

  @moduletag :r0_05
  @moduletag :capture_log
  @moduletag timeout: 180_000

  @resolve {Agents, :resolve_blocked_switch, 3}
  @facts {Agents, :blocked_switch_facts, 2}
  @reads [{Accounts, :list_users, 1}, {Agents, :list_profile_switches, 1}]

  setup do
    RH.lease_cleanup!()
    SH.select_claude_cli!()
    :ok
  end

  defp admin_view(conn) do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    view
  end

  defp open_review!(view, label) do
    click!(view, "#resolve-blocked", label)

    await_element!(
      view,
      "#resolution-review[data-state='editing']",
      nil,
      10_000,
      "#{label}: the review never reached :editing"
    )
  end

  defp submit!(view, text, label) do
    change_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)
    submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)
  end

  defp suspend!(pid) do
    true = :erlang.suspend_process(pid)
    on_exit(fn -> resume(pid) end)
  end

  defp returned?(tracer, mfa),
    do: Enum.any?(page_calls(tracer, mfa), &(&1.result != :no_return))

  defp page_reads(tracer), do: Enum.flat_map(@reads, &page_calls(tracer, &1))

  defp other_admin!(ctx), do: AuditCase.new_human(:admin, ctx.tenant)

  @password String.duplicate("r", 12) <> "-reset-0"

  defp auth_loss(:demoted, user, by), do: Accounts.change_role(user, :reviewer, actor: by)
  defp auth_loss(:disabled, user, by), do: Accounts.change_status(user, :disabled, actor: by)

  defp auth_loss(:revoked, user, by),
    do:
      Accounts.set_password(user, %{password: @password, password_confirmation: @password},
        actor: by
      )

  ## MF1

  describe "MF1: an async completion re-validates the operator before applying or reading" do
    for {loss, to} <- [demoted: "/", disabled: "/sign-in", revoked: "/sign-in"] do
      test "a recorded resolution's completion after the operator is #{loss}: redirected, nothing read",
           ctx do
        blocked = RH.none!(ctx)
        other = other_admin!(ctx)
        tracer = trace_calls!([@resolve | @reads])
        view = admin_view(ctx.conn)
        open_review!(view, "MF1 #{unquote(loss)}")

        blocker = RH.block_coordinator!()
        submit!(view, confirmation(blocked), "MF1 #{unquote(loss)}")
        # Hold the completion in the view's mailbox; let the attempt run.
        suspend!(view.pid)
        RH.release_coordinator!(blocker)

        assert wait_until(fn -> returned?(tracer, @resolve) end, 20_000),
               "fixture: the attempt returned"

        assert [%{result: {:ok, %{switch: %{status: :failed}}}}] = page_calls(tracer, @resolve),
               "fixture: an otherwise valid, recorded result"

        assert RH.raw_status(blocked.id) == "failed"
        assert {:ok, _} = auth_loss(unquote(loss), ctx.admin, other)
        reads = length(page_reads(tracer))

        resume(view.pid)
        assert_redirect(view, unquote(to), 5_000)

        assert length(page_reads(tracer)) == reads,
               "MF1: no read after the completion of a #{unquote(loss)} operator"
      end
    end

    test "a facts re-check's completion after demotion: redirected, nothing applied or read",
         ctx do
      RH.none!(ctx)
      other = other_admin!(ctx)
      tracer = trace_calls!([@facts | @reads])
      view = admin_view(ctx.conn)
      open_review!(view, "MF1 facts")
      checks = length(page_calls(tracer, @facts))

      blocker = RH.block_coordinator!()
      click!(view, "#refresh-status", "MF1 facts re-check")
      suspend!(view.pid)
      RH.release_coordinator!(blocker)

      assert wait_until(
               fn ->
                 tracer
                 |> page_calls(@facts)
                 |> Enum.drop(checks)
                 |> Enum.any?(&(&1.result != :no_return))
               end,
               15_000
             ),
             "fixture: the re-check returned"

      {:ok, _} = auth_loss(:demoted, ctx.admin, other)
      reads = length(page_reads(tracer))

      resume(view.pid)
      assert_redirect(view, "/", 5_000)
      assert length(page_reads(tracer)) == reads
    end
  end

  ## MF2

  describe "MF2: the stored line is the reviewed switch's own row" do
    test "a failed stored read shows the reviewed switch as unknown, never another row", ctx do
      blocked = RH.dead_holder!(ctx)
      view = admin_view(ctx.conn)
      open_review!(view, "MF2 read failure")
      # Draft 4 (D-141; Codex d0c80ff, permitted amendment 3): a wrong text
      # no longer reaches the domain, so the terminal refusal is b2β's
      # :stale_attestation of the exact text (the dead lease is released
      # under the review).
      assert :ok = Reaper.release(ClaudeCLI.server())
      submit!(view, confirmation(blocked), "MF2 read failure")

      await_element!(
        view,
        "#resolution-result[data-outcome='stale_attestation']",
        nil,
        20_000,
        "MF2: a terminal refusal"
      )

      assert has_element?(
               view,
               "#stored-switch[data-status='blocked'][data-switch-id='#{blocked.id}']"
             )

      SH.break_table!("model_profile_switches")

      try do
        click!(view, "#refresh-status", "MF2 refresh on a failed read")
      after
        SH.restore_table!("model_profile_switches")
      end

      assert has_element?(
               view,
               "#stored-switch[data-status='unknown'][data-switch-id='#{blocked.id}']"
             ),
             "MF2: a failed read is unknown, with the reviewed switch's identity"

      refute has_element?(view, "#latest-switch"), "MF2: no other row is shown instead"
    end

    test "recorded_switch/2: exactly the target's row; a missing target or a failed read is unknown" do
      a = %{id: Ecto.UUID.generate(), status: :failed}
      b = %{id: Ecto.UUID.generate(), status: :completed}

      assert ModelComponents.recorded_switch({:ok, [b, a]}, a.id) == {:ok, a}
      assert ModelComponents.recorded_switch({:ok, [b]}, a.id) == :unknown
      assert ModelComponents.recorded_switch({:ok, []}, a.id) == :unknown
      assert ModelComponents.recorded_switch(:unknown, a.id) == :unknown
      assert ModelComponents.recorded_switch({:ok, [b, a]}, nil) == {:ok, b}
      assert ModelComponents.recorded_switch({:ok, []}, nil) == {:ok, nil}
      assert ModelComponents.recorded_switch(:unknown, nil) == :unknown
    end
  end

  ## MF3

  describe "MF3: the frozen confirmation is opaque" do
    test "in the view's state while :submitting; a killed attempt task takes the view down with nothing captured",
         ctx do
      blocked = RH.none!(ctx)
      text = confirmation(blocked)
      tracer = trace_calls!([@resolve])
      view = admin_view(ctx.conn)
      open_review!(view, "MF3 task")
      blocker = RH.block_coordinator!()
      submit!(view, text, "MF3 task")
      await_element!(view, "#resolution-review[data-state='submitting']", nil, 5_000, "MF3")

      state = :sys.get_state(view.pid)
      refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ text

      assert %{confirmation: %Confirmation{text: ^text}} =
               state.socket.assigns.resolution.attestation,
             "the exact frozen text is kept, opaquely"

      assert wait_until(fn -> page_calls(tracer, @resolve) != [] end, 5_000)
      [%{pid: task}] = page_calls(tracer, @resolve)

      Process.unlink(view.pid)
      previous = Process.flag(:trap_exit, true)

      log =
        try do
          {_result, captured} =
            debug_logs(fn ->
              Process.exit(task, :r005_task_crash)

              # The view is linked to its attempt task: it goes down with it.
              assert wait_until(fn -> not Process.alive?(view.pid) end, 5_000)

              Process.sleep(100)
            end)

          captured
        after
          Process.flag(:trap_exit, previous)
        end

      RH.release_coordinator!(blocker)

      # A signal death writes no crash report (the task's own raise path is
      # the reported residual): the check is that nothing captured carries
      # the text, and that the view went down with its task.
      refute Process.alive?(view.pid)
      refute log =~ text, "MF3: a crashed attempt's diagnostics disclosed the confirmation"
    end

    test "Confirmation renders redacted and is unwrapped only for the domain call" do
      text = "STOPPED " <> Ecto.UUID.generate()
      wrapped = Confirmation.wrap(text)

      assert inspect(wrapped) == "#Confirmation<redacted>"
      refute inspect(%{attestation: %{confirmation: wrapped}}, structs: true) =~ text

      assert %{confirmation: ^text, outcome: :failed} =
               Confirmation.reveal_attestation(%{confirmation: wrapped, outcome: :failed})
    end
  end

  ## The hardening

  test "a success for another switch, or not failed, is an unknown outcome, never recorded" do
    id = Ecto.UUID.generate()

    review = %{
      state: :submitting,
      switch_id: id,
      facts: %{},
      attestation_id: Ecto.UUID.generate(),
      attestation: %{},
      exact?: true,
      retry?: false,
      dispatch: make_ref(),
      result: nil,
      error: nil,
      facts_changed?: false
    }

    for value <- [
          %{switch: %{id: Ecto.UUID.generate(), status: :failed}},
          %{switch: %{id: id, status: :blocked}},
          %{switch: nil}
        ] do
      assert {%{state: :uncertain, result: %{outcome: "uncertain"}}, false} =
               Resolution.settle(review, {:ok, {:ok, value}})
    end

    assert {%{state: :terminal, result: %{outcome: "recorded"}}, true} =
             Resolution.settle(review, {:ok, {:ok, %{switch: %{id: id, status: :failed}}}})
  end
end
