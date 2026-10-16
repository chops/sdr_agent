defmodule SdrAgentWeb.AdminLiveSwitchOptionBTest do
  @moduledoc """
  R0-05 option B (D-141; ADR-0005 R0-05 amendment) GREEN obligations from
  Codex's verified RED at `1ddd1a2`
  (`codex-r005b-1ddd1a2-red-verification.md`), added alongside the verified
  RED files, whose assertions are unchanged:

    * **Ruling 4, the browser-visible reset signal.** The pinned LiveView
      client (1.2.12) keeps a focused input's value when it patches it
      (`DOMPatch` `onBeforeElUpdated`: `DOM.mergeFocusedInput/2`, which
      excludes `value`) unless the rendered input carries the
      `phx-patch-focused` opt-in; and a function component whose dynamics
      did not change is not patched at all (the `data-phx-skip` root
      optimization). So the server renders the confirmation input with
      `phx-patch-focused` (and no value) only while a local mismatch is
      shown: the attribute appears on the mismatch render (the input is
      then patched, focused or not, and morphdom's `INPUT` handler sets its
      value to the rendered empty value) and is gone on the next edit, so
      typing is never reset. These tests pin that server-side signal; the
      client behaviour itself is cited from source, not executed here, and
      the owner's browser check remains outstanding.
    * **Ruling 10.** `#resolution-mismatch` clears on the next edit; the
      review identity, the absence of the text and the button state stay
      truthful.
    * **Ruling 6.** A disconnected render runs `mount/3` in the HTTP (here
      the test) process: it must leave that process's logger metadata
      unchanged (no tag; pre-existing entries kept; only the request's own
      `request_id` and OTel span ids differ), while the connected
      channel's own reports carry the tag.
    * **Ruling 8.** An error-or-higher level other than `:error` keeps its
      level through the tagged path; a tagged OTP report below `:error`
      keeps its level too; untagged events are unchanged.

  Synthetic data only; the fake CLI; zero model calls.
  """
  use SdrAgentWeb.OperatorCase, async: false

  import SdrAgent.Test.AdminSwitchHarness

  require Logger

  alias SdrAgent.Test.ResolveHarness, as: RH
  alias SdrAgent.Test.StatusHarness, as: SH

  @moduletag :r0_05
  @moduletag :capture_log
  @moduletag timeout: 120_000

  # The request pipeline's own identifiers (Plug.RequestId and the OTel span
  # context of the request), which any HTTP request changes; ruling 6 is about
  # the tag, so they are excluded from "unchanged".
  @request_meta [:request_id, :otel_trace_id, :otel_span_id, :otel_trace_flags]
  @input "#resolution-confirmation"
  @reset "#resolution-confirmation[phx-patch-focused]"

  setup do
    RH.lease_cleanup!()
    SH.select_claude_cli!()
    :ok
  end

  defp open_resolution!(view, label) do
    click!(view, "#resolve-blocked", label)

    await_element!(
      view,
      "#resolution-review[data-state='editing']",
      nil,
      10_000,
      "#{label}: opening the resolver never reached :editing"
    )

    attr_of(view, "#resolution-review", "data-attestation-id")
  end

  defp type!(view, text, label),
    do: change_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)

  defp submit!(view, text, label),
    do: submit_form!(view, "#resolution-form", %{"resolution_confirmation" => text}, label)

  defp editing!(view, id, label) do
    assert attr_of(view, "#resolution-review", "data-state") == "editing" and
             attr_of(view, "#resolution-review", "data-attestation-id") == id,
           "R0-05 #{label}: the review stays :editing with the same attestation id"
  end

  ## Ruling 4 (the reset signal) and ruling 10 (the message clears on the next edit)

  test "ruling 4: only a local mismatch renders the input with phx-patch-focused and no value; the next edit removes it",
       ctx do
    blocked = RH.none!(ctx)
    exact = confirmation(blocked)
    view = admin_view(ctx.conn)
    id = open_resolution!(view, "reset")

    assert has_element?(view, @input), "R0-05 reset: the confirmation input is shown"
    refute has_element?(view, @reset), "R0-05 reset: no reset signal before any mismatch"

    # Keystrokes never carry the signal (a reset on every edit would erase typing).
    for text <- ["S", "STOPPED", "stopped " <> blocked.id, exact] do
      type!(view, text, "reset typing")

      refute has_element?(view, @reset),
             "R0-05 reset: a change_resolution render never carries phx-patch-focused " <>
               "(#{inspect(String.slice(text, 0, 7))})"
    end

    refute has_element?(view, "#confirm-resolution[disabled]"), "fixture: the exact text"

    # The local mismatch: the one render that resets the browser's input.
    submit!(view, "stopped " <> blocked.id, "reset mismatch")

    assert has_element?(view, "#resolution-mismatch"), "fixture: the page's local refusal"

    assert has_element?(view, @reset),
           "R0-05 reset: the mismatch render opts the input into a focused patch " <>
             "(phx-patch-focused), so the client replaces a focused input's value"

    assert attr_of(view, @input, "value") == nil,
           "R0-05 reset: the patched input carries no value (morphdom sets it to empty)"

    assert has_element?(view, "#confirm-resolution[disabled]"),
           "R0-05 reset: the button matches the emptied input"

    editing!(view, id, "reset mismatch")

    # Ruling 10: the next edit clears the message and the signal.
    type!(view, "S", "reset next edit")

    refute has_element?(view, @reset),
           "R0-05 reset: the next edit removes phx-patch-focused (one-shot), so typing is kept"

    refute has_element?(view, "#resolution-mismatch"),
           "R0-05 ruling 10: #resolution-mismatch clears on the next edit"

    assert has_element?(view, "#confirm-resolution[disabled]"),
           "R0-05 ruling 10: the button stays truthful (not the exact text)"

    editing!(view, id, "reset next edit")

    # A second mismatch signals again (one-shot per mismatch, not per review).
    type!(view, exact, "reset exact again")
    refute has_element?(view, @reset)
    submit!(view, exact <> " ", "reset second mismatch")
    assert has_element?(view, @reset), "R0-05 reset: a later mismatch signals again"
    editing!(view, id, "reset second mismatch")

    # The exact text after a mismatch (no edit in between) is sent; the
    # message and the signal do not follow it into :submitting (the form is
    # still shown there, with the input disabled), held by a blocked
    # coordinator.
    blocker = RH.block_coordinator!()

    try do
      submit!(view, exact, "reset exact")
      await_element!(view, "#resolution-review[data-state='submitting']", nil, 5_000, "reset")
      assert has_element?(view, "#{@input}[disabled]"), "fixture: the frozen form is shown"

      refute has_element?(view, "#resolution-mismatch"),
             "R0-05 reset: the refusal message does not follow the exact text into :submitting"

      refute has_element?(view, @reset),
             "R0-05 reset: the reset signal does not follow the exact text into :submitting"
    after
      RH.release_coordinator!(blocker)
    end

    await_element!(
      view,
      "#resolution-result[data-outcome='recorded']",
      nil,
      20_000,
      "reset: the exact text after a mismatch is recorded"
    )

    refute has_element?(view, "#resolution-mismatch")
    refute has_element?(view, @reset)
  end

  ## Ruling 6: the disconnected render

  test "ruling 6: a disconnected render leaves the caller's logger metadata unchanged; the connected channel's reports carry the tag",
       ctx do
    :logger.update_process_metadata(%{r005_caller: :kept})
    before = :logger.get_process_metadata()
    conn = sign_in(ctx.conn, :admin)

    # The disconnected (HTTP) render runs mount/3 in this process.
    assert conn |> get(~p"/admin") |> html_response(200) =~ "Providers, budgets"
    after_dead = :logger.get_process_metadata()

    refute Map.has_key?(after_dead, :sdr_sensitive_input),
           "R0-05 ruling 6: a disconnected render must not tag the HTTP process"

    assert Map.drop(after_dead, @request_meta) == Map.drop(before, @request_meta),
           "R0-05 ruling 6: the caller's metadata is unchanged (apart from the request's " <>
             "own trace and request ids); got #{inspect(Map.keys(after_dead))}"

    # live/2 renders disconnected in this process, then connects the channel.
    {:ok, view, _html} = live(conn, ~p"/admin")
    after_live = :logger.get_process_metadata()

    refute Map.has_key?(after_live, :sdr_sensitive_input),
           "R0-05 ruling 6: the connecting test process is not tagged"

    assert Map.drop(after_live, @request_meta) == Map.drop(before, @request_meta)

    {_reason, text, events} =
      log_events(:debug, fn ->
        crash!(view, fn -> :sys.terminate(view.pid, :r005_ruling6) end)
      end)

    assert_withheld!(events, view.pid, "ruling 6 the connected channel's report")
    assert text =~ withheld()

    refute Enum.any?(events_of(events, self()), &(&1.meta[:sdr_sensitive_input] == true)),
           "R0-05 ruling 6: no event of the test process carries the tag"

    assert exception_filter!("ruling 6")
  end

  ## Ruling 8: level preservation

  test "ruling 8: a tagged error-or-higher event keeps its level (not only :error); a tagged OTP report below :error keeps its level",
       _ctx do
    canary = mismatch_canary()

    {pid, text, events} =
      log_events(:debug, fn ->
        run_task!(fn ->
          tag_process!()
          Logger.critical("r005 tagged critical " <> canary)
        end)
      end)

    [critical] =
      events
      |> events_of(pid)
      |> Enum.filter(&(:logger.compare_levels(&1.level, :error) != :lt))

    assert critical.level == :critical, "R0-05 ruling 8: :critical stays :critical"
    assert critical.msg == {:string, withheld()}
    assert critical.meta[:sdr_sensitive_input] == true
    refute_canary!(events, text, canary, "ruling 8 critical")

    {fun, opts} = exception_filter!("ruling 8")
    meta = %{sdr_sensitive_input: true, pid: self(), note: canary}

    for level <- [:emergency, :alert, :critical, :error] do
      result = fun.(%{level: level, msg: {:string, "r005 " <> canary}, meta: meta}, opts)

      assert result.level == level and result.msg == {:string, withheld()},
             "R0-05 ruling 8: a tagged #{level} event keeps its level; got #{inspect(result.level)}"

      refute holds?(result, canary)
    end

    # A tagged OTP (crash or termination) report is replaced at any level,
    # keeping that level.
    report = %{
      level: :notice,
      msg: {:report, %{label: {:r005, :report}, data: canary}},
      meta: Map.put(meta, :domain, [:otp])
    }

    result = fun.(report, opts)

    assert result.level == :notice and result.msg == {:string, withheld()},
           "R0-05 ruling 8: a tagged OTP report keeps its level and is replaced"

    assert result.meta == %{sdr_sensitive_input: true, pid: self(), domain: [:otp]}

    # Controls: untagged events are returned unchanged at every level.
    for level <- [:critical, :error, :notice] do
      untagged = %{level: level, msg: {:string, "r005 untagged"}, meta: %{pid: self()}}
      assert fun.(untagged, opts) == untagged
    end

    assert exception_filter!("ruling 8")
  end

  defp admin_view(conn) do
    {:ok, view, _html} = conn |> sign_in(:admin) |> live(~p"/admin")
    view
  end
end
