# C9-06 (#46) acceptance evidence map (draft)

- **Main:** `3b0918384e348fb5e530a9234893d00ee5e1ecbd`.
- **The Home producer:** C1-02's reviewed branch
  (`c1-02-inbox-reads` at `ede9f2b`, approved, not merged).
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

To fill. B1 and B2 run at main when the map is finalized. B3 waits for
C1-02's merge and exact-head checks.
