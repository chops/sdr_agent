# Slice A build plan (gate G5 packet)

- **Status:** proposed, **pending the owner's G1 approval and slice choice**
  (OQ-1), the G2 to G4 records for slice A, and the owner's explicit build
  authorization at G5. Nothing here lifts the feature freeze. Drafted
  2026-10-08.
- **Inputs:** [requirements.md](requirements.md),
  [screen-matrix.md](screen-matrix.md), [baseline-delta.md](baseline-delta.md),
  [tech-fit.md](tech-fit.md) (design, threat model, tests T-A-1 to T-A-37),
  and the process rules in `docs/sdlc/` (gate records, change control,
  schedule controls).
- **Named scope:** "slice A: operator shell and home", meaning REQ-A-1 to
  REQ-A-18 with the ranking the owner confirms (OQ-7). Nothing else.

## 1. Slices

Each slice is one pull request: small, mergeable on its own, written test
first. Tests are listed red-first (Phase 4a, verified with `tdd-verify`)
before any implementation (Phase 4b). Estimates are ranges of agent working
time **plus** review rounds, which is where the time actually goes.

The must slices come first, so cutting a should slice leaves a complete
must scope.

### SL-A-1 Delivery buckets and run window (must)
- **REQ:** REQ-A-7 (bucketing), REQ-A-6 window function, REQ-A-17 clock rules.
- **Red tests:** T-A-9, T-A-10, T-A-11.
- **Files:** new `lib/sdr_agent_web/home_data.ex` (pure `buckets/2`,
  `stopped_runs/2`); new `test/sdr_agent_web/home_data_test.exs`.
- **Estimate:** 0.5 day; 1 to 2 review rounds. **Reviewer:** Codex.
- **Risk:** low. Pure functions, no IO.

### SL-A-2 Home composition, states and audit (must)
- **REQ:** REQ-A-2, 3, 4, 5, 7 (rendering), 9 (keep existing pipeline),
  10, 11, 12, 13, 15, 16, 18.
- **Red tests:** T-A-3 to T-A-8, T-A-12, T-A-19 to T-A-27 (including T-A-23 live refresh), T-A-31, T-A-36.
- **Files:**
  - `home_data.ex`: add `load/3`, the per-list caps, filtered contacts,
    subject-path reuse and the auditor `target_ref`;
  - `lib/sdr_agent_web/live/dashboard_live.ex`: load through `HomeData`,
    render the new sections;
  - `test/sdr_agent_web/live/dashboard_live_test.exs` (extended);
  - new `test/sdr_agent_web/live/home_read_budget_test.exs`;
  - test fixtures as needed in `test/support/`.
- **Estimate:** 1 to 1.5 days; 2 to 3 review rounds, because it touches
  audit and authorization paths. **Reviewer:** Codex.
- **Risk:** medium.
  - Measuring the read budget may show that Ash adds per-row queries. If the
    query count grows with rows, stop: a fix with a count or batch read is
    **trigger: yes** (tech-fit §4).
  - Auditor `target_ref` lengths grow with the queue and attention lists.

### SL-A-3 Freshness: minute tick and UTC rollover (must)
- **REQ:** REQ-A-17, REQ-A-10 (stale banner).
- **Red tests:** T-A-28, T-A-29, T-A-30, T-A-35.
- **Files:**
  - `dashboard_live.ex`: `:home_tick`, `data_as_of`, `checked_at`,
    `loaded_utc_date`;
  - `lib/sdr_agent_web/live_refresh.ex`: new `request/1`;
  - `test/sdr_agent_web/live/live_refresh_test.exs` (extended);
  - `dashboard_live_test.exs`.
- **Estimate:** 0.5 to 1 day; 2 review rounds, because it changes a module
  every console view shares. **Reviewer:** Codex.
- **Risk:** medium. A coalescing bug could double-record auditor accesses.
  T-A-29 guards this.

### SL-A-4 Shell, accessibility and labels (must)
- **REQ:** REQ-A-1, REQ-A-14, REQ-A-16, and the wording choices OQ-5
  (Home) and OQ-9 (Captured emails (outbox)).
- **Red tests:** T-A-1, T-A-2, T-A-33; T-A-20 and T-A-22 re-run against the final wording.
- **Files:**
  - `lib/sdr_agent_web/components/layouts.ex`: skip link, current page,
    focus ring, nav label;
  - `dashboard_live.ex` (headings, accessible names);
  - `assets/css/app.css` (focus ring, reduced motion, provisional tokens if
    OQ-6 is yes);
  - `test/sdr_agent_web/live/navigation_test.exs` (extended).
- **Estimate:** 0.5 to 1 day; 1 to 2 review rounds. **Reviewer:** Codex.
- **Risk:** low. Shared layout changes are visible on every page, so the
  navigation tests run for all routes.

### SL-A-5 Admin model card (should, REQ-A-8)
- **Red tests:** T-A-13 to T-A-18.
- **Files:**
  - `home_data.ex`: `admin_card/2`;
  - new `lib/sdr_agent_web/home_data/status_reader.ex`;
  - `dashboard_live.ex`;
  - a test-only recording reader in `test/support/`.
- **Estimate:** 0.5 to 1 day; 2 to 3 review rounds, because it is the one
  slice that calls actorless reads. **Reviewer:** Codex.
- **Risk:** medium. Cut first if the musts run late: removing it removes
  both actorless calls from home entirely.

### SL-A-6 Agent activity (should, REQ-A-6)
- **Red tests:** T-A-9 (already green from SL-A-1), plus a LiveView test
  for the section (part of T-A-20's empty states and T-A-24's auditor run
  ids).
- **Files:** `home_data.ex` (runs read and caps), `dashboard_live.ex`,
  tests.
- **Estimate:** 0.5 day; 1 review round. **Reviewer:** Codex.
- **Risk:** low. Adds one unbounded read (runs) to the load budget; T-A-31
  is re-run.

### SL-A-7 Evidence and completion (must, no product code)
- **Covers:** T-A-32 (perf measurement), T-A-34 (scripted browser check of
  contrast, focus and reduced motion), a browser smoke of every state, and
  T-A-37 (Codex's confirmation of the entity trigger).
- **Files:**
  - new `test/sdr_agent_web/live/home_perf_test.exs` (`@tag :perf`);
  - `test/test_helper.exs` (exclude `:perf`);
  - `docs/product/slice-a/evidence.md` (measurements, screenshots list, run
    links).
- **Estimate:** 0.5 day; 1 review round. **Reviewer:** Codex.

## 2. Order and critical path

```
SL-A-1 ──> SL-A-2 ──> SL-A-3 ──> SL-A-4 ──> SL-A-7 (musts complete)
                         └──────> SL-A-5 (should) ──> SL-A-6 (should) ──> SL-A-7 update
```

One deep Codex review at a time (WIP 1), at most two slices in flight
(one in review, one being written). Calendar days, seven days a week:

| Date | Planned | Merge target |
|---|---|---|
| Sat Oct 10 | SL-A-1 written and reviewed; SL-A-2 tests red | SL-A-1 |
| Sun Oct 11 | SL-A-2 written; first review round | |
| Mon Oct 12 | SL-A-2 rework and re-review; SL-A-3 tests red | SL-A-2 |
| Tue Oct 13 | SL-A-3 written and reviewed | SL-A-3 |
| Wed Oct 14 | SL-A-4 written and reviewed; **musts complete** | SL-A-4 |
| Thu Oct 15 | SL-A-7 evidence for the musts; owner live demo of slice A | SL-A-7 |
| Fri Oct 16 | SL-A-5 (should) | SL-A-5 |
| Sat Oct 17 | SL-A-6 (should); SL-A-7 evidence updated | SL-A-6 |

**Range:** the musts complete between Oct 14 and Oct 16, depending on review
rounds. The shoulds complete by Oct 17, or are cut. Slice A shares Codex's
review queue with planning for later slices, so a planning review in the
same window moves these dates. Claude reports the queue order in the daily
status, and the owner decides priority when they conflict.

## 3. Definition of ready (each slice)

- Slice A has passed G1 to G5 with a committed gate record naming it.
- The slice's REQs and tests are listed in this plan, and its files are
  known.
- The entity trigger is still "no" for what the slice touches. If it isn't,
  stop for an inline delta and an independent PASS.
- The worktree is clean on a branch from current `main`.

## 4. Definition of done (each slice)

- The red tests were verified failing for the intended reason
  (`tdd-verify`), then pass.
- `bin/verify` passes locally: workflow receipt, format, compile with
  warnings as errors, and the full ExUnit suite. The configured Credo check
  passes too.
- Codex's verdict is APPROVED on the **exact head**, and CI is green on that
  exact head. A context-only range-diff can carry the review forward, never
  the CI result.
- No new warning, no `raw/1`, no domain write reachable from home.
- Moduledocs updated for every touched public module (AGENTS.md style).
- Merged with explicit paths staged and pushed; the slice row in the release
  board is updated.

## 5. Release evidence for slice A

At SL-A-7, recorded in `docs/product/slice-a/evidence.md`:

1. Exact-head CI runs and Codex verdicts for every merged slice.
2. `bin/verify` output on the final `main` commit containing slice A.
3. The T-A-31 query counts (one row and worst case) and the T-A-32
   measured load time against the under-1-second target.
4. A browser smoke of every state:
   - for each role (admin, reviewer, auditor): loading, normal, empty,
     withheld, refused on refresh, stale (disconnected), degraded model
     card (admin), an unknown delivery with its Inspect link, and an
     expired deferral after a tick;
   - screenshots listed, with synthetic data only.
5. T-A-34's measured contrast pairs, light and dark.
6. Codex's confirmation that D-A-1 is still trigger: no (T-A-37).
7. The owner's live demo notes (iteration demo, Oct 15).

## 6. Risks

| Risk | Trigger | Response |
|---|---|---|
| Query count grows with rows (Ash adds per-row queries) | T-A-31 fails | Stop. Write a D-A-2 inline delta for a count or batch read and get an independent PASS, or ask the owner to accept the measured cost. Never an unreviewed new read. |
| Load slower than 1 second at worst case | T-A-32 above target | Record it; trim displayed sections or accept for workshop scale (owner decision); a count read is trigger: yes. |
| Review rounds exceed plan on SL-A-2, 3 or 5 | Third round still has findings | Narrow the slice or cut a should; tell the owner the same day. |
| Shared `LiveRefresh` change breaks another view | Any existing live refresh test fails | Fix within SL-A-3 before merge; no merge on red. |
| Owner decision missing (OQ-2, 4 to 9) | Slice reaches its tests with an open wording or policy question | Use the documented default (tech-fit §3.3, requirements' provisional wording), and record it as provisional in the gate record. |
| Review queue contention with later-slice planning | Two review requests ready at once | Owner picks the order; WIP stays 1. |

## 7. Scope cut and rollback

- **Cut order:** SL-A-6, then SL-A-5. The musts (SL-A-1 to 4 and 7) are a
  complete slice on their own.
- **Cut trigger:** if SL-A-4 is not merged by **Fri Oct 16**, the shoulds
  move to a later slice, and the owner is told. The project-wide Oct 22
  checkpoint still applies.
- **Rollback:** each slice is one merge commit with no migration, no
  resource or policy change, and no data change. Reverting the merge
  restores the previous dashboard. A revert goes through the same exact-head
  CI.

## 8. What stays frozen while slice A is built

- Every domain resource, action, policy, calculation, migration and
  integration (baseline-delta, "Frozen").
- Approval binding, suppression, idempotency, the audit trail and its event
  contracts.
- Real model calls (budget zero), HubSpot, live research, alerts.
- Every route except `/` and the shared layout.
- D-A-2 to D-A-5 and G-A-1, unless separately gated.

## 9. Readiness checks that apply to slice A

The workshop-level G5 checks (`docs/sdlc`) mostly concern later slices.
For slice A:

| Check | Slice A |
|---|---|
| Supported versions | Same as `main`: Elixir 1.20.4, OTP 29, Postgres 18 (devenv, port 5520), macOS. No new dependency. |
| Fake-model-first install | Unchanged; slice A adds no setup step. |
| Synthetic data only | All tests and the browser smoke use fixtures and the demo seed. |
| No-send negative tests | Slice A has no write path; T-A-21 proves home has no domain write. |
| Credential, proxy and tool isolation | Unchanged; `Runtime.status/0` exposes no secrets (TM-7). |
| Backup and restore | Not affected: no migration and no data change. |
| Unknown-outcome recovery | Navigation only (REQ-A-18); the background reconciler is unchanged. |
| Cost and budget | Zero real model calls. |
| Workshop fallback | Unchanged; defined at the workshop-level G5. |

## 10. What the G5 gate record must contain

Path `docs/sdlc/gates/G5-slice-a.md`, from the template:

- **Named scope:** "slice A: operator shell and home", REQ-A-1 to 18 at the
  ranking the owner confirms, built as SL-A-1 to SL-A-7 in this plan.
- **Reviewed revisions:** the exact `slice-a-plan` and `p1-discovery`
  commits, and the G1 to G4 records for slice A.
- **Evidence:** Codex's verdicts on this packet and on tech-fit, including
  T-A-37's entity confirmation and answers to Q-T-1 and Q-T-2.
- **Thresholds bound:**
  - the read budget (tech-fit §3.5);
  - the under-1-second target (measured and recorded, not a CI gate);
  - REQ-A-14's six accessibility checks;
  - bug severities P0 to P3 from `docs/sdlc`;
  - real-model budget zero.
- **Owner decisions:** OQ-1 to OQ-10 answers, provisional design tokens if
  OQ-6 is yes.
- **The owner's build authorization, in their words,** with the time and
  zone and where it was given. For example: "I authorize building slice A
  as planned."
- **Exceptions:** none expected.
- **Next authorized scope:** implement SL-A-1 to SL-A-7 only; later slices
  pass their own gates.
