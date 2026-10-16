# R0-06 profile proof: evidence record and owner runbook

**Status:** draft 4, 2026-10-16: the owner's OQ-R6-1 amendment (D-142) in
sections 0, 2 and 5; needs Codex review. Draft 3 had **Codex PASS** for the record and
runbook template (`82c07ef7`, exact `3fbabaf`); not a completed proof
or any execution authority. Shaped by Codex's pre-read rulings
(`codex-r006-preread-4b41d10e.md`, consultation `4b41d10e`). Draft 1
(`7027700`) was NEEDS-REVIEW (Codex `e87584b5`, five corrections, made
here). Draft 2 (`5ac7106`) was NEEDS-REVIEW (Codex `808cd478`, two
evidence sources, fixed here); needs Codex review. Issue #54. Not a completion claim: every row below is open until
its evidence is recorded and reviewed.

**Entity Model trigger: no.** Reason: this is an evidence record and a
runbook for accepted, already reviewed behavior. It adds or changes no
persisted model, attribute, action, policy, lifecycle, recovery authority
or enabling behavior (Codex ruling d). Any enablement change is evaluated
separately.

**ADR evaluation:** none. Promotion uses ADR-0005's reviewed config
mechanism (`r0-07-witness.md` REQ-07-1); batching entries is a process
choice.

## 0. Acceptance (issue #54, REQ-R0-11)

1. **One reviewed PASS per profile** under G-R0 (amended by the owner,
   D-142, OQ-R6-1 = B; the earlier text required two actual attempts per
   profile, four in all). Each is an actual, separately attended attempt
   run by the owner, with Codex's evidence review before the next attempt.
   G-R0's terms are unchanged: the second slot per profile is reserved for
   a failed, invalid or unknown attempt and is not required. A failed
   attempt stays charged and is not proof. #54 and the readiness packet
   carry the same amendment.
2. **Witness reconciled:** Codex reviews each captured exchange against
   its hermetically built candidate; then each exact tuple is promoted by
   a reviewed config PR.
3. **The owner switches Opus → Sonnet → Opus in the app**, on a specified
   merged main build, with no model call.

**Expiry.** G-R0 and the calibration exception expire **2026-10-19 05:59
UTC (Sun Oct 18, 23:59 MDT)**. Valid evidence captured before then still
supports the later promotion and the UI trial, but only while its exact
tuple, prompt builder and projection, and pin and provenance stay
applicable and reviewed. A later change to the code or the runtime
identity is not grandfathered. A call needed after expiry
needs a new owner grant and exception first. Nothing is retried or batched
automatically, and finishing R0-06 later does not extend the window.

**What R0-06 does not do: enable ordinary real calls.** On main `397dcda`,
`Runtime` and `ClaudeCLI` refuse every ordinary real call with
`:real_model_staged`, and adding allowlist entries does not lift that.
R0-06 leaves ordinary calls staged. Enablement is a separate, reviewed
scope that is not planned yet; no promotion PR may contain a staging
bypass.

## 1. Prerequisites

**Two different sets.** The calibration attempts ran, and run, under
their own separately approved prerequisites (G-R0, R0-07f #162, the
isolated calibration database); nothing below makes an earlier attempt
unauthorized. The table below is the **final R0-06 exit**: the merged
build for the UI trial and for closing #54. An approved but unmerged
branch does not satisfy a row.

| Prerequisite | PR | Reviewed head | Merged at |
|---|---|---|---|
| R0-02, the app-owned pin | #131 | `d98b997` | `1096b135` |
| R0-03, the registry | #135 | `301c90b` | `f3fffdb6` |
| R0-08, CLI and registry aligned to 2.1.294 | #147 | `261b15d` | `779bfbf4` |
| C9-05, the grant form | #134 | `c9d640e` | `22c02bc4` |
| R0-07f, the calibration console | #162 | — | `3b2caaa` |
| C2-02a, b1, b2α | #159, #160, #163 | — | `3c54fa56`, `35279848`, `22db5c06` |
| R0-04, the provider outcome contract | #158 | `83a5b74` | open |
| C2-02b2β, the attended resolver | #167 | `ac95b9f` | open |
| C2-02c, restart and status | #168 | `6de84ff` | open |
| C9-04, evidence | #157 | `8df6b0a` | open |
| C1-02, Home inbox reads (C9-06's dependency) | #169 | `6b17072` | open |
| C9-06, evidence | #170 | `d95457f` | open |
| R0-05, the admin card, switch and resolver UI | not yet | — | GREEN waits on the ADR-0005 R0-05 amendment |

Where a branch was updated from main only to satisfy branch protection,
the record keeps both: the exact head Codex approved, and the
updated-identical tree or Codex's integration check.

The UI trial's build is the main SHA after every row has merged. It is
recorded in section 4.

## 2. Calibration attempts

**The ledger: actual attempts only, in the order they happened.** Failed,
invalid or unknown attempts stay listed and charged; they are not proof.
An outstanding lock, ticket or unlatched predecessor is a stop.

| Order | Profile | Date (MDT) | Outcome | Evidence SHA-256 | Latch | Codex attempt verdict |
|---|---|---|---|---|---|---|
| 1 | `claude_cli_opus` | Oct 15 | completed / valid | `0c2e3735582d0bde76a7eb8eb2e59dec88852f683d8f5cd18834189a80c648b4` | `:calibration` | PASS, attempt only, not promotion (reviewer report in the private evidence index) |

**Still required (no order; the owner chooses each next attempt):**

| Profile | Required | Done | Remaining |
|---|---|---|---|
| `claude_cli_opus` | 1 PASS | 1 PASS | 0 |
| `claude_cli_sonnet` | 1 PASS | 0 | 1 |

These counts follow the amended acceptance (section 0, item 1; D-142).
A failed, invalid or unknown attempt uses that profile's reserved slot
and the PASS is still required. Grant usage after each attempt
is recorded in the private evidence index.

The run, invocation, grant, allocation and witness-link ids, and the
raw exchanges, stay in the private evidence store. This public record
carries only the tuple, hashes and verdict references until the owner
decides OQ-E1.

## 3. Tuples

All six keys are exact. No wildcard, alias, or inference from one profile
to the other.

| Key | Opus | Sonnet |
|---|---|---|
| provider | `claude_cli` | `claude_cli` |
| cli_version | `2.1.294` | candidate: `2.1.294` |
| profile_id | `claude_cli_opus` | candidate: `claude_cli_sonnet` |
| model_id | `claude-opus-5-5` | candidate: `claude-sonnet-5-5` |
| projection_version | `claude-message-json/3+prompt-builder/1` | candidate: not yet known |
| method | `propagated_id` | candidate: `propagated_id` |

The Opus column is the tuple evaluated in attempt 1 (reviewed). For
Sonnet, the profile id, CLI version and model id are the registry's
configuration, candidates only, until its captured identities are
independently reviewed. The projection and method don't come from the
registry: the candidate projection is fixed and hermetically reviewed
before the attempt, and the evaluated result is unknown until the
attempt is reviewed. Record the exact pre-reviewed Sonnet candidate
here before its first attempt.

For each tuple, record: the prompt-builder version and commitments, the
hermetically reviewed candidate, the pin and code provenance, the
attempts it rests on, Codex's tuple-level promotion verdict, and the
promotion PR and its merge SHA.

**Promotion PR:** one combined, config-only PR after both profiles have
their reviewed evidence, with a separate evidence binding per tuple
(Codex ruling b). A profile that fails cannot ride on the other's PASS.
The PR needs its own exact-head gate, CI, Codex review and the owner's
merge decision.

## 4. Owner runbook: the in-app switch

The owner runs this on their own checkout, at a time they choose. The
agents never run it.

**Before starting:**
- The owner picks the build: the main SHA from section 1, and the
  environment.
- No active or uncertain work: no run in progress, and no switch pending
  or blocked.
- **Baseline, read-only,** for this application instance and its own
  database (not the calibration database):
  - `model_invocations`: the row count, and the counts by status
    (reserved, `sent` and the terminal states);
  - grant usage: `Agents.grant_usage/2` for the app's grants (the
    attempts consumed, derived from charged `model_invocations` of every
    outcome; the grant tables hold terms and revisions, not usage
    counters), read as the owner. A failed read is unknown, never zero;
  - `wire_witness_links`: the row count, and the witness store's exchange
    count;
  - `model_server_starts`: the latest generation and its status;
  - the app's BEAM identity: its OS process id **and** start time
    (`LC_ALL=C TZ=UTC ps -o pid,lstart -p <pid>`, for the process serving
    this app's port; the fixed locale and UTC keep readings comparable). A
    reused pid with a different start time is a restart. This shows only
    that the BEAM itself kept running, within what `ps` can show; it says
    nothing about every child process. An unknown read stops the trial.
- **The admin card shows:** desired profile Opus; running profile Opus,
  with its own server; server admission open; no open, pending, blocked or
  uncertain switch; the pinned CLI version. Ordinary model calls are still
  refused as staged (`:real_model_staged`). That is expected: R0-06 does
  not lift staging, and "admission open" is not model-call readiness. A
  failed or unknown read is not any of these states.

**Each leg (Opus → Sonnet, then Sonnet → Opus):**
1. Request the switch on the admin page and confirm it.
2. Record: the time, the switch id and its audit events, the desired and
   running profiles and the setting revision, the server start
   generation and outcome, and any pending, blocked or uncertain state.
3. Check what you can observe: the app's BEAM pid and start time are
   unchanged (no app restart); `model_server_starts` has one new generation for this
   leg, and its status; the running profile is the target.
   **Not observed by the trial:** that two model servers never
   overlapped. Before-and-after reads can't show that across the
   interval. It is a tested invariant of the coordinator: a candidate
   starts only after the old server's reaper cleanup is confirmed
   (`profile_coordinator_test.exs`, "a switch" and "the cleanup receipt,
   as the coordinator validates it"; `profile_coordinator_race_test.exs`).
   The record cites those tests, not the trial, for it.
4. **No model call:** repeat the baseline reads. There are no new
   `model_invocations` rows of any status, no change in
   `Agents.grant_usage/2`, and no new witness links or exchanges. The new
   server's `--version` preflight is not a model call. An unchanged
   counter on the page, or a successful click, is not this proof. Keep
   other work quiet during the trial, so an unrelated call can't be
   mistaken for one, or hide one.

**Reading the card.** The desired profile, the running server and
eligibility are separate facts. A completed switch promises neither
readiness nor a model attestation, and the last attestation shown is
historical: it does not attest the newly selected model.

**Stop and keep the evidence** on any of these: a pin, version or store
mismatch; an unexpected charge or exchange; mixed or stale facts; an
uncertain outcome; a blocked or held provider; unresolved history. Never
retry automatically, force a rollback, delete locks or tickets, release a
Reaper lease, or try to clear a hard conflict. Use only the reviewed
attended resolver where it applies; otherwise escalate.

**After the return leg:** desired and running are Opus again. The switch
history stays.

| Leg | Time | Switch id | Desired / running / revision | Server generation | No-call check | Notes |
|---|---|---|---|---|---|---|
| Opus → Sonnet | — | — | — | — | — | — |
| Sonnet → Opus | — | — | — | — | — | — |

## 5. Who signs what (Codex ruling e)

- **Codex:** each attempt's evidence verdict; tuple and prompt-builder
  applicability, and the promotion review; the code, config and
  evidence-map review; whether the no-call, runtime and audit observations
  support the technical claim. A projection match is not whole-wire
  equality, factual correctness or a promise about future calls.
- **The owner:** attending and authorizing every real call; grant,
  billing and expiry exceptions; any change to the acceptance; OQ-E1
  publication; outstanding ADR acceptances; the UI trial and product
  acceptance; every merge and any enablement.
- **Done when** all of: the prerequisites merged; one reviewed PASS per
  profile recorded, with every actual attempt listed; the promotion merged through its
  reviewed process; the owner's UI and no-call trial recorded; exact-head
  CI and Codex's approving review of this record; the owner's acceptance.
  The record then states that ordinary calls remain staged.

## Open questions

- **OQ-R6-1 (owner): decided** (D-142, 2026-10-16): one reviewed PASS per
  profile, the second slot reserved for failures.
- **OQ-E1 (owner, existing):** publication of raw evidence. Until then this
  record carries hashes and verdict references only.
