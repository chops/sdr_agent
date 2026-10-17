# Layer 2: ordinary-call enablement (E1 + E3)

**Status:** draft 1, 2026-10-17, for Codex's entity/action soft-stop. There is no implementation and there are no RED tests yet.
- **Base:** main `6f271ab`.
- **Owner:** D-154 starts layer 2, with the E1 and E3 contracts drafted together. D-153 closed layer 1; it is not enablement authority.
- **Exit:** synthetic-only ordinary model calls. Real-data activation (C5-04) and B1/H1 product acceptance are separate exits.

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
| ModelInvocation | Existing (E1 recovery-path delta) | The charged ledger row of one model attempt | Unchanged. Reads `status`, `sent_at`, `sequence_in_run`, `agent_run_id` | Belongs to AgentRun; grant and allocation unchanged | **New path (E1):** a `sent` row of a terminal run (`succeeded`, `failed`, `budget_exhausted`, `cancelled`) whose `sent_at` is older than the grace window becomes `unknown` through the existing `:mark_unknown` action and its `model.invocation.unknown` event. It is never `failed`, never re-sent, never released, and never adopted as a result. The charge stays: grant, allocation and day consumption count rows. A recent `sent` row is untouched. Re-sweeping is idempotent: a terminal row is skipped, and the terminal-row trigger is unchanged. | `agent_runtime` only, through the sweeper's domain function, exactly as today's `:mark_unknown` policy | OQ-E1-1 settlement: (i) mark unknown without `:settle_model_call`, so the terminal run's `model_calls_used` is not incremented while the ledger charge stays; or (ii) a reviewed terminal-tolerant settle. Pick: (i). OQ-E1-2: an unknown-outcome Failure for the stopped run? Pick: none, as in case (b), because the stop is the cause. |
| AgentRun | Existing dependency | | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. E1 reads and locks the run (`FOR UPDATE`, run first, as admission does) and never writes it or changes its status | unchanged | none |
| StaleRunSweeper (case c) | Existing worker, new pass | Find and recover E1 rows | Grace: `sent_at < now − max(stale_after_seconds, ClaudeCLI timeout + margin)` | Per run: lock the run `FOR UPDATE`, re-check that it is terminal, then lock its `sent` rows `FOR UPDATE` in sequence order and re-read their status and age | One transaction per run. Skip (no write) on: the run not terminal; the row no longer `sent`; the row inside the grace window. A late facade `complete` after the recovery gets `:invocation_already_settled` and releases nothing. Lock order is the same as admission and case (b) (the run before its invocations, then the audit head) | `agent_runtime` system actor | OQ-E1-3: the grace window value. Pick: the same `stale_after_seconds` (1800 s), which already exceeds the 240 s CLI timeout. |
| Ordinary-call admission (Runtime eligibility + ClaudeCLI staged) | Existing (E3 contract delta) | Decide whether an ordinary call may reserve and launch | No new fields. Inputs: the runtime attestation, the promoted-tuple check, the store binding, the result gate, the grant | Unchanged callers: `SDR.Model` via `ModelProvider.complete/2`, `AgentWorker`, `ReplyWorker`. No other caller gains a path | **E3:** an ordinary call is admitted only when **all** of these hold, re-checked at reservation and at launch:<br>(1) provider `claude_cli` in dev with the verified pinned executable;<br>(2) the observed init or version is an exact promoted gen-2 tuple (`Witness.promoted?`);<br>(3) the witness store root is configured, trusted and bound, so reconciliation is live (unset → refuse; a new refusal tag, see OQ-E3-2);<br>(4) `ResultGate` is enforced;<br>(5) an eligible owner grant and allocation exist at reservation and are re-checked at launch;<br>(6) E1 is merged.<br>Otherwise it refuses with today's typed reasons. Every ordinary result stays unusable until its own invocation is reconciled and released. Missing, mismatched or timed-out capture stays charged and withheld. Calibration's test-seam exemption is unchanged. No env, caller, job or request flag admits a call | Owner is the authority: creating, revoking or exhausting the grant enables or disables calls. Agents never create, edit or use grants | OQ-E3-1: how enablement is controlled. (a) Code-only lift, where the owner's grant is the switch and revoking it, or unsetting the provider, disables calls. (b) A new durable owner enable setting. Pick: (a). OQ-E3-2: the refusal tag for an unset store root. Pick: reuse `witness_store_untrusted`. |
| SDR prompts and schemas | Existing dependency, applicability check | The server-owned ordinary prompt and schema | `SDR.Prompts` `sdr.<purpose>` v1, and `SDR.Schemas` | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. E3 adds tests only: every ordinary purpose renders through `prompt-builder/1` and reconciles under the fake proxy at the promoted projection version; a purpose that cannot is refused | unchanged | OQ-E3-3: is a separate review of each ordinary prompt needed before enablement? Pick: yes, in the E3 code review |
| ModelCallGrant / allocation (G-DEMO) | Existing dependency | Owner spend authority | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. The owner creates G-DEMO (D-099: 200 total, 30 per day, 30 held for the workshop, expiry 2026-11-07 06:59 UTC) in the reviewed UI after E3 is accepted | Owner only | Billing posture (included subscription or extra usage) is confirmed by the owner at creation |

Reviewer precedence: ai-pair; reviewer **Codex**. Verdict: **UNREVIEWED**. No affected-module design or RED work starts before PASS.

## Owner prerequisites before the E3 merge (r0-07-witness.md)

1. The B5' residual is acknowledged.
2. G3 (284-288): an owner metadata inventory of the existing gen-2 rows, and the decision on plaintext audit copies. Status still needs checking; see OQ-E3-4.
3. The owner reviews and merges E1, then E3.
4. The owner creates G-DEMO, and only after E3 is accepted.
5. The first ordinary real call is owner-run: a synthetic lead, attended, with the result gate observed.

## Required RED evidence

- **E1:**
  - a recent terminal-run `sent` row is untouched; an old one becomes `unknown`, with an event and no run write;
  - re-sweeping is idempotent;
  - such a row is never `failed`, `released` or re-sent;
  - a late facade `complete` gets `:invocation_already_settled`;
  - a concurrent cancel is serialized by the run lock;
  - the ledger charge stays in `grant_usage`;
  - real-connection race tests follow the case (b) precedent.
- **E3:**
  - the full ordinary path on the fake proxy and fake CLI with a non-test-launcher attestation in dev (no test seam): facade → reservation → launch → validated witness → release → the downstream read;
  - each failed condition among (1)–(6) refuses with its typed reason and no launch;
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

OQ-E1-1, OQ-E1-2 and OQ-E1-3; OQ-E3-1, OQ-E3-2 and OQ-E3-3; and OQ-E3-4: is G3 (the owner gen-2 inventory and the plaintext audit-copy decision) already closed, and where?
