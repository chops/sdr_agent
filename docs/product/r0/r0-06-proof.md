# R0-06 profile proof: evidence record and owner runbook

**Status:** draft 1, 2026-10-16. Shaped by Codex's pre-read rulings
(`codex-r006-preread-4b41d10e.md`, consultation `4b41d10e`); needs Codex
review. Issue #54. Not a completion claim: every row below is open until
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

1. **Two synthetic calibration attempts per profile** under G-R0, four in
   all. Each is an actual, separately attended attempt run by the owner,
   with Codex's evidence review before the next attempt. One PASS plus an
   unused slot is **not** equivalent (Codex ruling c). Changing this needs
   an explicit owner amendment to #54, the readiness packet and this
   record.
2. **Witness reconciled:** Codex reviews each captured exchange against
   its hermetically built candidate; then each exact tuple is promoted by
   a reviewed config PR.
3. **The owner switches Opus → Sonnet → Opus in the app**, on a specified
   merged main build, with no model call.

**Expiry.** G-R0 and the calibration exception expire **2026-10-19 05:59
UTC (Sat Oct 18, 23:59 MDT)**. Valid evidence captured before then still
supports the later promotion and the UI trial. A call needed after expiry
needs a new owner grant and exception first. Nothing is retried or batched
automatically, and finishing R0-06 later does not extend the window.

**What R0-06 does not do: enable ordinary real calls.** On main `397dcda`,
`Runtime` and `ClaudeCLI` refuse every ordinary real call with
`:real_model_staged`, and adding allowlist entries does not lift that.
R0-06 leaves ordinary calls staged. Enablement is a separate, reviewed
scope that is not planned yet; no promotion PR may contain a staging
bypass.

## 1. Prerequisites (merged, not just approved)

An approved but unmerged branch does not satisfy a dependency. Fill the
merge SHA when each lands.

| Prerequisite | PR | Approved head | Merged at |
|---|---|---|---|
| R0-02, R0-03 | to confirm | — | to confirm |
| R0-04, provider outcome contract | #158 | `83a5b74` | open |
| C2-02a, b1, b2α | #159, #160, #163 | — | on main |
| C2-02b2β, attended resolver | #167 | `ac95b9f` | open |
| C2-02c, restart and status | #168 | `6de84ff` | open |
| R0-05, admin card, switch and resolver UI | not yet | — | GREEN waits on the ADR-0005 R0-05 amendment |
| C9-05 | to confirm | — | to confirm |
| R0-07 calibration console (R0-07f) | #162 | — | on main (`3b2caaa`) |

The UI trial's build is the main SHA after every row above has merged.
It is recorded in section 4.

## 2. Calibration attempts

One row per charged attempt, in order. Failed, invalid or unknown
attempts stay listed and charged; they are not proof. An outstanding lock,
ticket or unlatched predecessor is a stop.

| # | Profile | Date (MDT) | Outcome | Evidence SHA-256 | Latch | Codex attempt verdict | Grant usage after |
|---|---|---|---|---|---|---|---|
| 1 | `claude_cli_opus` | Oct 15 | completed / valid | `0c2e3735582d0bde76a7eb8eb2e59dec88852f683d8f5cd18834189a80c648b4` | `:calibration` | PASS (`1a6db933`), attempt only, not promotion | Opus 1/2, Sonnet 0/2 |
| 2 | `claude_cli_opus` | — | — | — | — | — | — |
| 3 | `claude_cli_sonnet` | — | — | — | — | — | — |
| 4 | `claude_cli_sonnet` | — | — | — | — | — | — |

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
| cli_version | `2.1.294` | `2.1.294` (to confirm from its attempts) |
| profile_id | `claude_cli_opus` | `claude_cli_sonnet` |
| model_id | `claude-opus-5-5` | `claude-sonnet-5-5` (to confirm) |
| projection_version | `claude-message-json/3+prompt-builder/1` | to confirm |
| method | `propagated_id` | `propagated_id` |

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
- **Baseline, read-only:** the app database's invocation reservations,
  `sent` rows and charges, and the witness store's exchange count, for
  this application instance.
- The admin card shows the desired profile Opus, the running profile
  Opus, accepting calls, no open switch and the pinned CLI version.

**Each leg (Opus → Sonnet, then Sonnet → Opus):**
1. Request the switch on the admin page and confirm it.
2. Record: the time, the switch id and its audit events, the desired and
   running profiles and the setting revision, the server start
   generation and outcome, and any pending, blocked or uncertain state.
3. Check: the app did not restart (same BEAM), only the model server
   changed, and no two model servers overlapped.
4. **No model call:** repeat the baseline reads. There are no new
   invocation reservations, `sent` rows, charges or witness exchanges.
   The new server's `--version` preflight is not a model call. An
   unchanged counter on the page, or a successful click, is not this
   proof.

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
- **Done when** all of: the prerequisites merged; the four attempts
  recorded with reviewed evidence; the promotion merged through its
  reviewed process; the owner's UI and no-call trial recorded; exact-head
  CI and Codex's approving review of this record; the owner's acceptance.
  The record then states that ordinary calls remain staged.

## Open questions

- **OQ-R6-1 (owner):** keep the two-attempts-per-profile acceptance, or
  amend it to one reviewed PASS per profile with the second slot reserved
  for failures? The current text requires two actual attempts each.
- **OQ-E1 (owner, existing):** publication of raw evidence. Until then this
  record carries hashes and verdict references only.
