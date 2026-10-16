# C9-06 (#46) acceptance evidence map (draft)

- **Main:** `397dcda7efc1b3320eb8bcb02b0b66d595cf458a`.
- **The Home producer:** C1-02 on `c1-02-integration` at `6b17072`
  (PR #169, not merged yet). This branch stacks on it.
- **Entity Model trigger:** no. This change maps and tests merged behavior
  only (Codex 4ca892eb). A gap in production behavior would stop this
  work and get its own entity check and a real RED first.
- **Characterization tests** that pass on merged code are reported as
  that, never as RED.

## Acceptance

The issue (#46) reads:

> Exhausted/ineligible → Failure (inbox row once C1 lands) + metadata-only
> Telegram

**Adjusted by the owner:** the Failure item only, with no Telegram from
the app.
- **Where that is recorded:** D-107 and the R0 packet section 8 (OQ-4).
- **How the owner hears of it:** the build-time owner alerts
  (`bin/notify-telegram`, run by the agents) are separate and unchanged.
- **This PR adds no notifier.**

## Map

| Part | Merged behavior | Existing tests (main) | Gap |
|---|---|---|---|
| **B1. A reservation refusal opens a Failure.** Exhausted (grant, day or allocation cap) and ineligible (no eligible grant, no allocation, ambiguous, no usage origin). | The Failure is committed in its own transaction after the reservation rolls back. It is deduplicated under the chain-head lock, with class `budget_exhausted` and subject the run. | **`model_call_admission_test.exs`:**<br>• "a refused reservation writes no payload, invocation or counter, and one Failure and event";<br>• "a repeated refusal adds no second Failure";<br>• "a different reason, grant or run opens its own Failure";<br>• "a resolved refusal Failure is not reused".<br>**`grant_refusal_worker_test.exs`:**<br>• "without a grant the run fails :grant_unavailable before any provider call";<br>• "an exhausted grant stops the run :grant_exhausted before any provider call".<br>Both assert `Failure.class == :budget_exhausted`, linked from the run and its Operation, with no second `run_stopped` item. | **None expected.** |
| **B2. A launch refusal opens a Failure.** | The Failure is opened in the same transaction that fails the invocation: class `provider_error`, `grant_ineligible_at_launch`, critical and open. | **`launch_admission_test.exs`:** the `grant_ineligible_at_launch` cases (expiry, revocation, profile removal, window close and others), through `assert_refused_at_launch/3`. **`launch_admission_race_test.exs`:** the held revocation race. | **None expected.** The final map lists each branch against its test. |
| **B3. The Failure shows as a Home inbox row.** | C1-02's `operations_failures` producer, read through `Inbox.refresh/2`. | **None on main**, because C1-02 is not merged. C1-02's own tests cover its generic Failure rows and authorization. | **Add after C1-02 merges:** an integration test (below). |
| **B4. No Telegram from the app.** | No app-side notifier exists. | Not applicable. | Recorded here as the owner's adjustment. No test asserts the absence of a feature that was never built. |

## The B3 integration test (after C1-02 merges)

1. **Make real refusals.** Through the existing domain paths, create:
   - an unavailable refusal: no eligible grant;
   - an exhausted refusal: an allocation cap.
2. **Read Home.** Call the token-authenticated `Inbox.refresh/2` as an
   operator with Home access.
3. **Assert each row:**
   - `producer: :operations_failures`;
   - `kind: :failure_attention`;
   - a `subject_ref` bound to that exact Failure, not to a hand-seeded
     one.
4. **Dedupe:** a repeated refusal adds no second row, and the live count
   matches.
5. **Resolution:** after an admin resolves the refusal, its row is gone.
6. **Launch refusal:** cover it as well only if no C1-02 test already
   covers a `provider_error` Failure row.

**Out of scope:**
- authorization: C1-02's generic coverage is reused, not duplicated;
- retry actions (C1-03);
- any Home LiveView work.

## Results

Run on this branch with main `397dcda` and C1-02 `6b17072` merged in
(local merge head `a0edf9c`). Test partition `_c906`.

- **B1:** `model_call_admission_test.exs` and
  `grant_refusal_worker_test.exs`.
  - Seed 570129. `Result: 42 passed`.
- **B2:** `launch_admission_test.exs` and `launch_admission_race_test.exs`.
  - Seed 615734. `Result: 29 passed`.
- **B3:** `test/sdr_agent/inbox/c9_06_refusal_rows_test.exs`, new.
  - Characterization tests: they pass on merged code. Not RED.
  - Seed 290267. `Result: 5 passed`.
  - The refusals come from `Agents.reserve_model_invocation/3`: no grant
    (`no_eligible_grant`) and an allocation cap (`allocation_exhausted`).
    No Failure is seeded by hand.
  - Home is read with `Inbox.refresh/2` and an admin's stored session
    token.
  - Each row: `producer: :operations_failures`,
    `kind: :failure_attention`, and a `subject_ref` equal to the Failure
    in the refusal receipt. That Failure is also the one in the
    `model.reservation.refused` event.
  - A repeated refusal keeps one row with the same row id, and the live
    count stays 1.
  - After an admin resolves the Failure, its row is gone and the live
    count is 0.
- **B3 step 6 (launch refusal):** not added. C1-02's tests already show
  `provider_error` Failure rows (the `failure!/2` default class), for
  example in `page_test.exs`. The producer filters on status only, not
  class, so a launch refusal takes the same path.
- **Sensitivity:** each key B3 assertion was shown to fail under a
  temporary change, then reverted.
  - Producer drops `budget_exhausted` Failures: row missing, 0/5 passed.
  - Row `producer` or `kind` changed: that assertion fails, 0/5 passed.
  - `subject_ref` points at the run, not the Failure: row missing,
    0/5 passed.
  - The test looks up a hand-seeded lookalike Failure instead of the
    receipt's: the event binding fails, 0/5 passed.
  - Refusal dedupe turned off: the dedupe test fails on the receipt, then
    (with those checks removed) on the row count, then on the live count.
    4/5 passed each time.
  - The attention read keeps resolved Failures, or the test skips the
    resolve: the resolution test fails, 4/5 passed.
- **Checks:** `mix format --check-formatted`,
  `MIX_ENV=test mix compile --warnings-as-errors` and `mix credo` on the
  new file all pass. The full gate was not run.
