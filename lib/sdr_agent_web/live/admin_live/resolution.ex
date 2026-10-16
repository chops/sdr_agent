defmodule SdrAgentWeb.AdminLive.Resolution do
  @moduledoc """
  The admin page's socket-local review of one blocked-switch resolution
  (R0-05, `docs/product/r0/r0-05-interface.md` section 3): pure functions
  over the review map `SdrAgentWeb.AdminLive` holds. No domain call is made
  here; the view reads the facts and dispatches the attempt.

  States: `:facts` (a failed facts read, facts with no attestable lease
  kind, or facts that changed under an open review), `:editing` (the
  facts, the b2β statement and the input; the `attestation_id` is
  generated once, here), `:submitting` and `:uncertain` (both **frozen**:
  the id, the facts and the attestation can't be replaced, and nothing but
  "Check again" from `:uncertain` acts) and `:terminal` (the review is
  discarded; a new resolution needs a new review, id and confirmation).

  `settle/2` maps an attempt's result to the next state. A first attempt's
  results follow section 3's table; a retry after an unknown outcome
  (`retry?`) settles the earlier attempt only on an exact success or
  replay, `:switch_not_blocked` or `:attestation_conflict`, and otherwise
  returns to `:uncertain` with the same frozen identity. An authorization
  loss (Forbidden or NotFound) ends any review without claiming what
  happened. A result of no known shape, and a task exit, are an unknown
  outcome (dispatch may have happened): never a rollback, never "Not
  recorded". Every message is operator-safe words, never a raw term.
  """

  alias SdrAgentWeb.AdminLive.Confirmation
  alias SdrAgentWeb.AuditedView

  @attestable [:none, :survivor, :dead_holder]

  @statement "No Claude CLI process started by any server in this range is still running, " <>
               "except work owned by the current held server's own live reaper. " <>
               "I checked this myself."

  @recorded "The resolution was recorded: the switch is failed. Readiness is checked " <>
              "separately; calls stay paused until the status shows the server accepting " <>
              "calls. A dead lease may still need an operator."

  @first_unknown "The result isn't known yet. Check again resends exactly this review " <>
                   "(the same id and facts); it never starts a new one."

  @still_unknown "The result still isn't known. A refused retry says nothing about the " <>
                   "earlier attempt; Check again resends exactly this review."

  # Typed refusals of a first attempt, in words (b2β section 2).
  @refusals %{
    stale_attestation:
      "Refused: the server's starts or lease changed since these facts were read. " <>
        "Start a new review.",
    live_work_observed:
      "Refused: live Claude CLI work is observed on the server, so this switch can't be " <>
        "attested as stopped now.",
    observation_unknown:
      "Refused: the server's state can't be read right now. Start a new review to try again.",
    coordinator_busy:
      "Refused: the model server coordinator is busy with other work. Start a new review shortly.",
    attestation_invalid:
      "Refused: the confirmation must be exactly the word STOPPED, one space and the switch id.",
    attestation_conflict:
      "Refused: this review's id is already recorded with other facts. Start a new review.",
    switch_not_blocked:
      "Refused: this switch is no longer blocked. The recorded switch is shown on the card.",
    switch_open: "Refused: another switch is open. The recorded switch is shown on the card."
  }

  # A retry's settling refusals (the earlier attempt's outcome is then shown
  # only from the stored switch, re-read as the actor).
  @settling %{
    attestation_conflict:
      "This review's id is recorded with other facts, or for another switch. That doesn't " <>
        "show whether this switch is still blocked; the recorded switch is shown on the card.",
    switch_not_blocked:
      "The switch is no longer blocked. The recorded switch on the card shows what is stored."
  }

  @doc "The b2β section 3 statement the admin confirms, word for word."
  def statement, do: @statement

  @doc "The section 3 message of a recorded resolution (never \"ready\")."
  def recorded_message, do: @recorded

  @doc """
  A review opened on a facts read (`Agents.blocked_switch_facts/2`'s
  result) for `switch_id`; `requester` names who requested the switch.
  Attestable facts enter `:editing` with a fresh attestation id; anything
  else is `:facts` with an error in words and no input.
  """
  def open(switch_id, {:ok, facts}, requester) do
    shown = shown(facts, requester)

    if facts.lease_kind in @attestable do
      %{base(switch_id) | state: :editing, facts: shown, attestation_id: Ecto.UUID.generate()}
    else
      %{
        base(switch_id)
        | facts: shown,
          error:
            "Live Claude CLI work is observed on the server, so this switch can't be " <>
              "attested as stopped now. Refresh, then review again."
      }
    end
  end

  def open(switch_id, {:error, reason}, _requester),
    do: %{base(switch_id) | error: facts_error(reason)}

  defp base(switch_id) do
    %{
      state: :facts,
      switch_id: switch_id,
      facts: nil,
      attestation_id: nil,
      attestation: nil,
      exact?: false,
      retry?: false,
      dispatch: nil,
      result: nil,
      error: nil,
      facts_changed?: false
    }
  end

  defp facts_error(:observation_unknown),
    do: "The server's state can't be read right now; try again"

  defp facts_error(:switch_not_blocked),
    do: "This switch is no longer blocked; refresh the status."

  defp facts_error(reason), do: AuditedView.error_message(reason)

  # What the review shows (and what is attested): frozen with the review.
  defp shown(facts, requester) do
    switch = facts.switch

    %{
      switch: %{
        id: switch.id,
        from: switch.from_profile_id,
        to: switch.to_profile_id,
        reason: switch.failure_reason,
        requested_at: switch.requested_at,
        requested_by: requester
      },
      starts:
        Enum.map(facts.covered_starts, fn start ->
          Map.take(start, [
            :id,
            :generation,
            :reason,
            :profile_id,
            :status,
            :pid,
            :node,
            :reaper_pid
          ])
        end),
      latest_start_id: facts.latest_start.id,
      latest_generation: facts.latest_start.generation,
      lease_kind: facts.lease_kind
    }
  end

  @doc """
  Whether a re-read of the facts (while `:editing`) differs from the facts
  the review shows: another latest start, another lease kind, or other
  covered starts.
  """
  def changed?(%{facts: shown}, {:ok, facts}),
    do: fingerprint(shown(facts, nil)) != fingerprint(shown)

  def changed?(_review, {:error, :switch_not_blocked}), do: true
  # An unreadable re-read proves no change; the coordinator re-checks the
  # binding and the lease kind at submission.
  def changed?(_review, {:error, _unknown}), do: false

  defp fingerprint(shown),
    do: {shown.latest_start_id, shown.latest_generation, shown.lease_kind, shown.starts}

  @doc """
  The review after its facts changed: `:facts`, showing the re-read facts
  (when there are any), with no input, id or typed confirmation kept.
  """
  def facts_changed(review, read, requester) do
    facts =
      case read do
        {:ok, facts} -> shown(facts, requester)
        _gone -> nil
      end

    %{base(review.switch_id) | facts: facts, facts_changed?: true}
  end

  @doc "Records whether the typed text is exactly `STOPPED <switch id>` (the button's state only)."
  def typed(%{state: :editing} = review, text),
    do: %{review | exact?: text == "STOPPED " <> review.switch_id}

  def typed(review, _text), do: review

  @doc """
  The frozen attestation of an `:editing` review, carrying the operator's
  own `text` (never synthesized from the id; held as an opaque
  `SdrAgentWeb.AdminLive.Confirmation`, unwrapped only for the domain call)
  and the facts shown.
  """
  def attest(%{state: :editing, facts: facts} = review, text) do
    %{
      review
      | attestation: %{
          attestation_id: review.attestation_id,
          switch_id: review.switch_id,
          attested_start_id: facts.latest_start_id,
          attested_generation: facts.latest_generation,
          attested_lease_kind: facts.lease_kind,
          outcome: :failed,
          confirmation: Confirmation.wrap(text)
        }
    }
  end

  @doc "The review while attempt `ref` is in flight (frozen)."
  def submitting(review, ref), do: %{review | state: :submitting, dispatch: ref}

  @doc """
  The review after its attempt's `result` (`{:ok, value}` from the task, or
  `{:exit, reason}`). Returns `{review, reread?}`: `reread?` asks the view
  to re-read the stored switch and the status.
  """
  # Recorded only when the result is the reviewed switch, failed (a commit
  # or the exact replay); any other success shape is an unknown outcome.
  def settle(%{switch_id: id} = review, {:ok, {:ok, %{switch: %{id: id, status: :failed}}}}),
    do: {terminal(review, "recorded", @recorded), true}

  def settle(review, {:ok, {:error, reason}}), do: settle_error(review, reason)
  def settle(review, {:ok, _unknown_shape}), do: {unknown(review), false}
  def settle(review, {:exit, _reason}), do: {unknown(review), false}

  defp settle_error(%{retry?: false} = review, :resolve_timeout),
    do: {terminal(review, "not_recorded", "Not recorded. Start a new review."), true}

  defp settle_error(%{retry?: true} = review, reason)
       when reason in [:attestation_conflict, :switch_not_blocked],
       do: {terminal(review, to_string(reason), Map.fetch!(@settling, reason)), true}

  defp settle_error(review, reason) when is_atom(reason) and is_map_key(@refusals, reason) do
    if review.retry?,
      do: {unknown(review), false},
      else: {terminal(review, to_string(reason), Map.fetch!(@refusals, reason)), true}
  end

  defp settle_error(review, %Ash.Error.Forbidden{}),
    do: {terminal(review, "forbidden", authorization_loss(:forbidden)), true}

  defp settle_error(review, %Ash.Error.Query.NotFound{}),
    do: {terminal(review, "not_found", authorization_loss(:not_found)), true}

  # `:resolve_uncertain`, a retry's `:resolve_timeout`, or any other shape:
  # the outcome is unknown.
  defp settle_error(review, _reason), do: {unknown(review), false}

  # An authorization loss ends the review and never proves a rollback, even
  # on a first attempt: the caller's own settlement of an unknown dispatch
  # can be refused too (b2β `settle_resolution/2`). So not AuditedView's
  # "refused and recorded".
  defp authorization_loss(:forbidden),
    do:
      "Not permitted for your role; the review has ended. This doesn't show whether the " <>
        "resolution was recorded: the recorded switch is shown on the card."

  defp authorization_loss(:not_found),
    do:
      "The switch was not found for your account; the review has ended. This doesn't show " <>
        "whether the resolution was recorded: the recorded switch is shown on the card."

  defp terminal(review, outcome, message),
    do: %{
      review
      | state: :terminal,
        dispatch: nil,
        facts: nil,
        attestation_id: nil,
        attestation: nil,
        exact?: false,
        result: %{outcome: outcome, message: message}
    }

  # Frozen: the same id, facts and attestation; only Check again acts.
  defp unknown(review) do
    message = if review.retry?, do: @still_unknown, else: @first_unknown

    %{
      review
      | state: :uncertain,
        dispatch: nil,
        retry?: true,
        result: %{outcome: "uncertain", message: message}
    }
  end

  @doc "The lease kind in words."
  def lease_kind_words(:survivor),
    do: "survivor: the held server's own live reaper holds the lease"

  def lease_kind_words(:none), do: "none: no server runs and no lease is held"

  def lease_kind_words(:dead_holder),
    do: "dead holder: no server runs, and a process that is no longer alive holds the lease"

  def lease_kind_words(:live_work_observed),
    do: "live work observed: no attestation can name this state"

  def lease_kind_words(_other), do: "unknown"
end
