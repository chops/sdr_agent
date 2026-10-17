# R0-06 profile proof: evidence record and owner runbook

**Status:** draft 5, 2026-10-17: the promotion and every prerequisite
merged (section 1); the tuples evaluated and promoted (section 3); the
owner-run in-app trial recorded, with Codex qualified technical PASS
`9f2ed2b2` (section 4). Owner dispositions: D-145 (attempt 2's missed
stop), D-152 (the trial's omitted helper-hash check) and D-153 (the owner
accepts R0-06 and closes layer 1, given before this record's review).
This exact record still needs Codex's review, exact-head CI and the
owner's merge decision. Ordinary real calls remain staged. Draft 4,
2026-10-16: the owner's OQ-R6-1 amendment (D-142) in sections 0, 2 and 5. Draft 3 had **Codex PASS** for the record and
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
| R0-04, the provider outcome contract | #158 | `83a5b74` | `84025c35` |
| C2-02b2β, the attended resolver | #167 | `ac95b9f` | `8cb5410a` |
| C2-02c, restart and status | #168 | `6de84ff` | `6d30e5e6` |
| C9-04, evidence | #157 | `8df6b0a` | `b7195c31` |
| C1-02, Home inbox reads (C9-06's dependency) | #169 | `6b17072` | `b0af5f56` |
| C9-06, evidence | #170 | `d95457f` | `aea57294` |
| R0-05, the admin card, switch and resolver UI | #173 | `3d27aad` (draft 5; browser acceptance D-150) | `6f271abe` |
| R0-06, the tuple promotion (section 3) | #172 | `82c005b` | `527c3156` (D-146) |

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
| 2 | `claude_cli_sonnet` | Oct 15 | completed / valid; console outcome `match` | `689a0514c7cc221b6e4525f57ada49671358d3ffa5fc746a26d8bc53ba9c40cb` | `:calibration` | **Retrospective PASS, Oct 16** (53/53 read-only checks; reviewer report in the private evidence index). **Deviation kept:** charged about 24 minutes after attempt 1, before attempt 1's evidence review, so the review-before-next stop was not kept; it was missing from this ledger until Codex's ledger snapshot found it (Oct 16). The later review cannot supply historical authorization or waive the stop; the owner accepted the deviation (D-145, Oct 16). |
| 3 | `claude_cli_sonnet` | Oct 16 | completed / valid; console outcome `match` | `a2e8a0b2ffbb84ff739f193a9bb91fb9b95baf36affb4f92dde5b148e4854525` | `:calibration` | PASS, attempt only, not promotion (53/53 read-only checks; reviewer report in the private evidence index) |

**G-R0 usage** (Codex's read-only snapshot, 2026-10-16 19:40:51 UTC): Opus
1 of 2, Sonnet 2 of 2, total 3 of 4. Sonnet's allocation is exhausted;
the one remaining unit is Opus-only and is not required (D-142). The
ledger counts come from that snapshot, never from conversation.

**Still required (no order; the owner chooses each next attempt):**

| Profile | Required | Done | Remaining |
|---|---|---|---|
| `claude_cli_opus` | 1 PASS | 1 PASS | 0 |
| `claude_cli_sonnet` | 1 PASS | 1 PASS (attempt 3) | 0 |

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
| cli_version | `2.1.294` | `2.1.294` |
| profile_id | `claude_cli_opus` | `claude_cli_sonnet` |
| model_id | `claude-opus-5-5` | `claude-sonnet-5-5` |
| projection_version | `claude-message-json/3+prompt-builder/1` | `claude-message-json/3+prompt-builder/1` |
| method | `propagated_id` | `propagated_id` |

**Evaluated and promoted.** Each column is the exact tuple evaluated in its own reviewed attempt:
- **Opus:** attempt 1, evidence `0c2e3735…80c648b4`.
- **Sonnet:** attempt 3, evidence `a2e8a0b2…4e854525`.

Neither rides on the other's PASS. Both tuples were promoted by #172: config-only, Codex-approved (`337e2807`) at reviewed head `82c005b3230a92dfd2817877f8733c6e0c638ea2`, and merged as `527c31562e362ab9f1246dabac19c7fba1bc9e19` (D-146). The trial build `6f271ab`'s `config/config.exs` Witness `reconciled_methods` holds exactly these two generation-2 entries, beside the gen-1 entry.

Promotion admits these tuples to witness reconciliation only. It does not lift `:real_model_staged`; ordinary real calls remain staged.

**Historical: Sonnet pre-attempt candidate (reviewed, 2026-10-16),** before attempt 3's evidence and the promotion: `(claude_cli,
2.1.294, claude_cli_sonnet, claude-sonnet-5-5,
claude-message-json/3+prompt-builder/1, propagated_id)`. Codex confirmed
the held calibration code (`3b2caaa`) builds exactly this candidate,
within the previously hermetically reviewed projection, prompt and
outcome scope; an independent no-start pure check passed 46/46, including
a Sonnet v3 match and a wrong-model refusal (consultation `f61b754d`,
report sha256 `5a365cb8…`). This is the candidate only: not an observed
init, an evaluated result, evidence PASS or promotion.

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

**The trial, 2026-10-17 (owner-run).**
- **Build and instance:** main `6f271abef7b3cfefa2c7eb6defcb07602c003181`; dev, `claude_cli` with the pinned CLI, port 4120, database `sdr_agent_dev`. The BEAM was pid 12403, started 21:34:09 UTC, and was the same at all six probes.
- **Capture root:** `/Users/charles/.local/share/llm-otel-proxy/blobs`.
- **Readings:** the baseline was read with the reviewed snapshot helper v3 (Codex 2b47b3f4) at three checkpoints, each `result complete` with an outer `exit=0`.
- **Evidence (private, in the handoff state dir; bound by hash):**
  - `claude-r006-trial-evidence.md`, sha256 `8deb05d2aebfef1bb1e8f94a1af2aaeaaaa2232abcc1351a39e0ec1d7fecc5b4`;
  - `owner-r006-snapshots.log`, sha256 `e0cea158b4485d8bab87d2f4aefa390bb809ef517738c2656e326eaec7decac6`.

  If either file changes, this binding is updated, never kept for new content.
- **Helper:** the expected, reviewed v3 mechanism. Its files hashed to the approved values before and after the trial; the bytes that ran at execution time are not proven (see the deviation).

| Leg | Time (UTC) | Switch id | Desired / running / revision | Server generation | No-call check | Notes |
|---|---|---|---|---|---|---|
| Opus → Sonnet | 21:50:08 | `01a14bd7-fbd0-79be-98f2-25b699b69406` (completed) | Sonnet / Sonnet / 2 | 1 → 2 (sonnet, ready, activation) | Unchanged: model_invocations 19 (pre-existing, last reserved 2026-10-07), grants 0, witness links 0, result releases 0, capture-store aggregates 19/19/19/0 | Owner card gate passed |
| Sonnet → Opus | 21:52:56 | `01a14bda-8b59-75e0-a954-df7c57e19451` (completed) | Opus / Opus / 3 | 2 → 3 (opus, ready, activation) | Unchanged, as above | Owner card gate passed |

**Verdict:** Codex qualified technical PASS (`9f2ed2b2`) for the owner-run in-app Opus → Sonnet → Opus no-call trial, based on the three checkpoint blocks and the retrospective owner attestation.

**Deviation, accepted by the owner (D-152, 2026-10-17):** the approved pre-execution helper-hash check was omitted from the relayed instructions and not performed. Matching before/after file hashes do not prove the bytes that ran at execution time. The acceptance disposes of the deviation; it is not new proof.

**Owner acceptance:** D-153 (2026-10-17): the owner accepts R0-06 and closes layer 1. It was given before this exact record's review, which still governs the merge of #171.

**Recorded qualifications:**
- **Owner attestation:** the build SHA, the baseline card gate, the outer exits and the quiet conditions are owner attestations (retrospective, "1–4 yes"), not captured output.
- **Not captured:** the audit event ids.
- **Capture entries:** the 19 were present at the baseline with unchanged aggregate counts; their individual ages were not inspected.
- **Method limits:** the checkpoints are not atomic snapshots or continuous observation. No overlap of the two servers rests on the coordinator's tests, as above.
- **Staging:** ordinary calls remain staged.

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
  profile recorded, with every actual attempt listed (the evidence
  subcriterion is met by attempts 1 and 3; the missed review-before-next
  stop before attempt 2 is disclosed and accepted, D-145); the promotion merged through its
  reviewed process; the owner's UI and no-call trial recorded; exact-head
  CI and Codex's approving review of this record; the owner's acceptance.
  The record then states that ordinary calls remain staged.

## Open questions

- **OQ-R6-1 (owner): decided** (D-142, 2026-10-16): one reviewed PASS per
  profile, the second slot reserved for failures.
- **OQ-E1 (owner, existing):** publication of raw evidence. Until then this
  record carries hashes and verdict references only.
