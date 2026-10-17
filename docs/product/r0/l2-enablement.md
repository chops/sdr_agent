# Layer 2: ordinary-call enablement (E1 + E3)

**Status:** draft 2, 2026-10-17. It answers Codex's NEEDS-REVIEW on draft 1 (`1a6b6361`, `codex-l2-bcd4faf-1a6b6361-entity-review.md`): four must-fixes and all of the open-question rulings. Needs a recheck. There is no implementation and there are no RED tests yet.
- **Base:** main `6f271ab`.
- **Owner:** D-154 starts layer 2, with the E1 and E3 contracts drafted together. D-153 closed layer 1; it is not enablement authority.
- **Exit:** synthetic-only ordinary model calls. E1 merged is a **release dependency** of E3 (E3 doesn't merge first); it is not a runtime predicate or a request flag. Real-data activation (C5-04) and B1/H1 product acceptance are separate exits.

## Scope

1. **E1. Settle the `sent` rows of terminal runs** (readiness.md:323, open). This is a recovery delta. It must merge before E3 can merge.
2. **E3. Lift `:real_model_staged` for ordinary calls.** Ordinary calls are those made through the `SDR.Model` facade by `AgentWorker` and `ReplyWorker`, on synthetic data only, under the owner's G-DEMO grant. Calibration authority is untouched.
3. **B5' disclosure.** The owner is shown the observation-time store-trust residual (readiness.md:322) before the E3 merge. Its plain-words text was shown to the owner on 2026-10-17; their formal acknowledgement is requested with E3's acceptance.

**Not in scope:**
- real prospect data: the C5-04 guard stays reserved-domains only;
- new providers, concurrency (D-069), automatic retries or refunds;
- Reaper cleanup authority;
- grant creation by agents: the owner creates G-DEMO in the reviewed budgets UI;
- any model call by an agent. The first real ordinary call is owner-run and owner-authorized, separately from the merge.

## Current facts (main `6f271ab`)

- **Refusals:**
  - `Runtime.eligibility/1` refuses every non-test-launcher attestation with `:real_model_staged` (`runtime.ex:193-203`).
  - `ClaudeCLI.staged/3` refuses everything except the test launcher and the test-seam calibration exemption (`claude_cli.ex:818-833`).
  - The moduledoc says nothing configurable lifts this.
- **Already built, and it stays:**
  - the facade, reservation, launch admission (`Admission.Gate`, `launch_check/6`), the result gate (enforced at compile time), and `ModelResultRelease`, with `ReleasedOutput.fetch/2` as the only business read;
  - the sweeper's R1–R3 recovery;
  - the promoted gen-2 tuples for Opus and Sonnet 2.1.294 (`config/config.exs` Witness `reconciled_methods`, #172).
- **E1 gap:**
  - `StaleRunSweeper` recovers `sent` rows only for running, abandoned runs (`stale_run_sweeper.ex:148`, 306-332). Case (b) fails only old `reserved` rows of terminal runs (516-554).
  - Every finish of a `sent` row goes through `finish_model_invocation` → `settle/2` → `AgentRun :settle_model_call`, whose `BudgetCounter` refuses a non-running run (`budget_counter.ex:38-39`). So a terminal run's `sent` row can never become `unknown`.
  - Runs reach terminal status while a row is `sent` by: an operator cancel during a call; the worker's crash terminalization; `SDR.Model.halt_fail` after a failed `mark_unknown`; and a dead caller after admission committed.

## Entity Model

Entity Model trigger: **yes**. Reason: E1 adds a recovery transition path for an existing lifecycle (ModelInvocation `sent` → `unknown` on a terminal run). E3 changes the admission contract (which calls the staged predicate admits). No new persisted entity, attribute or relationship is added.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| ModelInvocation | Existing (E1 recovery-path delta) | The charged ledger row of one model attempt | Unchanged. Reads `status`, `sent_at`, `sequence_in_run`, `agent_run_id` | Belongs to AgentRun; grant and allocation unchanged | **New path (E1), a ledger-only normalization.** A `sent` row of a terminal run (`succeeded`, `failed`, `budget_exhausted`, `cancelled`) whose run is **not** `usage_origin: :proof` and has no recorded calibration authority (both re-checked under the run lock), and whose `sent_at` is strictly before the cutoff, becomes `unknown` through the existing `:mark_unknown` action and its `model.invocation.unknown` event. Coverage is every non-proof run whatever its provider or generation (Fake, legacy gen-1, ordinary gen-2), because the normalization doesn't depend on the provider.<br>The row is never `failed`, never re-sent, never released, and never adopted as a result. **Accounting (OQ-E1-1 (i), ruled):** the run is not settled and its counters stay as they are, so the terminal run's `model_calls_used` and token counters are not backfilled and are not authoritative charged-attempt totals. The ledger row stays charged in `grant_usage` for its grant, allocation and UTC day: no refund and no synthetic completion. Running-run settlement is unchanged, and the generic finish path gains no terminal-run bypass or flag.<br>The new `unknown` is not cleanup proof, not a release of the Reaper lease, and not retry permission (C1-03 keeps retry blocked). A later complete or mark-unknown attempt can't overwrite a terminal invocation: the existing trigger and transitions hold. Re-sweeping is idempotent. | `agent_runtime` only, through a new sweeper domain function that calls `:mark_unknown` directly (as `CalibrationRecovery` does), skipping `settle/2` | Resolved: OQ-E1-1 (i). OQ-E1-2, no new Failure (ruled): see below. |
| AgentRun | Existing dependency | | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. E1 reads and locks the run (`FOR UPDATE`, run first, as admission does) and never writes it or changes its status | unchanged | none |
| StaleRunSweeper (case c) | Existing worker, new pass | Find and recover E1 rows | **Grace (OQ-E1-3, ruled):** exactly the sweeper's existing `stale_after_seconds`, as a ledger-uncertainty grace only, never as evidence that the job, caller or CLI tree is gone. Cutoff = the transaction's `now` minus `stale_after_seconds`. Eligible only when `sent_at < cutoff`; equal is not eligible. A non-positive, non-integer or unreadable setting makes the pass write nothing and log a fixed warning code | Per run: lock the run `FOR UPDATE`; re-check it is terminal, not `:proof`, and has no calibration authority; then lock its `sent` rows `FOR UPDATE` in `sequence_in_run` order, re-reading status and `sent_at`. All dependent rows are locked before the first audit-head acquisition | One transaction per run. Skip with no write when: the run is not terminal; it is proof or calibration; the row is no longer `sent`; the row is not before the cutoff; or a read fails. A late facade `complete` after recovery gets `:invocation_already_settled` and releases nothing. Same lock order as admission and case (b) | `agent_runtime` system actor. The role is unchanged, but this new selection scope is the delta under review | **OQ-E1-2 (ruled): no new Failure.** It is a ledger-only normalization: it creates no Home attention item, and changes or resurrects no old cause, Failure or terminal Operation. A succeeded run has no attention, a cancel's attention is conditional, and an old cause may already be resolved, so the stop is not claimed to supply attention. The `model.invocation.unknown` event is durable history. Attention for this state would need its own Failure delta. |
| Ordinary-call admission (Runtime eligibility + ClaudeCLI staged) | Existing (E3 contract delta) | Decide whether an ordinary call may reserve and launch | No new fields. Inputs: the runtime attestation, the promoted-tuple check, the store binding, the result gate, the grant | Unchanged callers: `SDR.Model` via `ModelProvider.complete/2`, `AgentWorker`, `ReplyWorker`. No other caller gains a path | **E3, in order:**<br>**Before launch (reservation, then the launch re-check):**<br>(1) provider `claude_cli` in dev, with the verified pinned executable and a fresh pin and version preflight;<br>(2) the *expected* identity, built by `Admission.Gate.admit_reservation/4` from the reviewed profile and frozen on the invocation, is an exact promoted gen-2 tuple (`Witness.promoted?/2`, which establishes eligible expected identity, not the evaluated projection);<br>(3) the witness store root is configured, trusted and bound; nil or untrusted refuses with the existing `:witness_store_untrusted`;<br>(4) `ResultGate` is enforced;<br>(5) an eligible owner grant and allocation, by the existing C9 selector, at reservation, re-checked at launch.<br>**After launch:** the CLI's actual init is checked for that call by the existing per-call init check. Drift found there may already have spent the charged attempt: no output, no automatic retry, no "no launch" claim. The result gate then validates the exact evaluated projection and method for this invocation before any release. A prior init or card attestation never authorizes the next call.<br>Otherwise each step refuses with today's typed reasons. Every ordinary result stays unusable until its own invocation is reconciled and released. Missing, mismatched or timed-out capture stays charged and withheld. Calibration's test-seam exemption is unchanged. No env, caller, job or request flag admits a call | The owner is the authority. Agents never create, edit or use grants | **OQ-E3-1 (ruled): (a) code-only lift**, under the activation and cutover protocol below. The default stays Fake. A missing grant or store fails closed. **OQ-E3-2 (ruled):** reuse `:witness_store_untrusted`. |
| SDR prompts and schemas | Existing dependency, applicability check | The server-owned ordinary prompt and schema | `SDR.Prompts` `sdr.<purpose>` v1, and `SDR.Schemas` | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. E3 adds tests only: every ordinary purpose renders through `prompt-builder/1` and reconciles under the fake proxy at the promoted projection version; a purpose that cannot is refused | unchanged | **OQ-E3-3 (ruled): yes.** Each ordinary purpose's builder and schema needs an applicability review and hermetic positive and negative evidence. The fixed calibration proof prompt is never treated as an ordinary prompt. Any tuple, projection or builder change needs its own evidence and promotion scope. |
| ModelCallGrant / allocation (G-DEMO) | Existing dependency | Owner spend authority | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. The owner creates G-DEMO (D-099: 200 total, 30 per day, 30 held for the workshop, expiry 2026-11-07 06:59 UTC) in the reviewed UI after E3 is accepted | Owner only | Billing posture (included subscription or extra usage) is confirmed by the owner at creation |

Reviewer precedence: ai-pair; reviewer **Codex**. Verdict: **UNREVIEWED**. No affected-module design or RED work starts before PASS.

## Stages, activation and cutover (must-fix 3)

**Stage 1. Contract acceptance.** This contract gets PASS. The owner accepts E1 and E3 scope, and acknowledges the B5' residual.

**Stage 2. Reviewed merges.**
- E1 merges, then E3, each through contract, RED, GREEN, review, gate, CI and the owner's merge decision.
- **G3 must be closed before the E3 merge** (OQ-E3-4, ruled open). The owner runs a metadata-only inventory of existing gen-2, provider and plaintext audit-copy rows and gives an explicit disposition. Claude supplies a reviewed read-only query, and agents never access the owner's database. Missing evidence is never a nil inventory, and append-only history is never rewritten.
- **After E3 merges and before any grant exists,** every ordinary call refuses with `:no_eligible_grant`. Lifting staging alone activates nothing.

**Stage 3. Owner grant creation (G-DEMO), attended.**
- **G-DEMO is an operational restriction, not a new runtime one.** It is the only ordinary grant the owner creates. Runtime selection is the existing C9 selector (purpose, profile, window and allocation `applies_to`). No named budget is enforced, and no display name is authority.
- **Before creating it,** the owner runs a reviewed metadata-only read showing zero `agent_runs` queued or running and zero Oban jobs in the agent and reply queues that are available, scheduled or retryable. No cron enqueues agent runs: work enters only through `SDR` assignment, `ReplyIntake` and `Retry`. Any non-zero count stops the stage, so pre-existing work can't become an unrequested first call.
- **The grant itself:**
  - `starts_at` is set to the attended start;
  - the first allocation's `applies_to` is the one bucket of the planned first run;
  - the per-day limit follows D-099;
  - the 30-attempt workshop reserve is held as a separate allocation that no bucket can spend until the owner releases it.
- **Billing posture:** the owner confirms whether calls use the included subscription or extra usage.

**Stage 4. Separately authorized owner execution.**
- The owner starts the first ordinary run on a synthetic lead, attended. Synthetic data is guaranteed by the existing `Sales.Synthetic` guard (C5-04 unchanged: reserved domains only).
- The owner observes the reservation, the launch, the reconciliation and the release (or the withholding).
- Revoking the grant, or unsetting `SDR_MODEL_PROVIDER`, disables calls again.

**Entry points.**
- Ordinary calls enter only through `SDR.Model.call/4` → `ModelProvider.complete/2`, from `AgentWorker` and `ReplyWorker`.
- The implementation plan proves there are no other callers of `ModelProvider.complete/2`, `run/3` or the ClaudeCLI server outside these and calibration, and adds a guard test that fails on a new caller.
- Direct and alternate entry points refuse.

## Required RED evidence

- **E1:**
  - negative control: a terminal **proof or calibration** run's `sent` row gets no transition, release, latch, attestation or cleanup inference;
  - cases for succeeded, cancelled, failed and budget-exhausted runs, and a run whose cause is already resolved: no Failure or Operation change;
  - cutoff boundaries: equal is not eligible, and an invalid or unreadable setting writes nothing;
  - a recent terminal-run `sent` row is untouched; an old one becomes `unknown`, with an event and no run write;
  - re-sweeping is idempotent;
  - such a row is never `failed`, `released` or re-sent;
  - a late facade `complete` gets `:invocation_already_settled`;
  - a concurrent cancel is serialized by the run lock;
  - the ledger charge stays in `grant_usage`;
  - real-connection race tests follow the case (b) precedent.
- **E3:**
  - the full ordinary path on the fake proxy and fake CLI with a non-test-launcher attestation in dev (no test seam): facade → reservation → launch → validated witness → release → the downstream read;
  - each pre-launch condition (1)–(5) refuses with its typed reason and no launch;
  - post-launch init drift: charged, withheld, no automatic retry;
  - after merge with no grant: `:no_eligible_grant`, with no launch;
  - an unset store root refuses;
  - an alternate or direct caller cannot bypass;
  - grant races: exhausted, expired, revoked, wrong profile, day rollover, held reserve;
  - every withholding boundary (mismatch, timeout, crash) stays charged and withheld;
  - calibration still requires its exemption;
  - no agent test makes a real model call.

## ADR

E1 evaluates ADR-0004/0005. It adds no new recovery authority beyond the sweeper's existing system role. It settles no cleanup and releases no lease. So no ADR amendment is expected. Codex to confirm.

E3 lifts a staging stop once already-accepted guarantees are met, which by itself needs no new ADR. If OQ-E3-1 chooses (b), a durable enable policy, that is an ADR-0004 amendment.

## Questions for Codex

All the open questions are ruled (`1a6b6361`) and recorded above. G3 is open: it is an owner prerequisite in stage 2. Recheck asked for must-fixes 1–4.
