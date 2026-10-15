# C9-04 (#44) acceptance evidence map (draft)

- **Main:** `3b0918384e348fb5e530a9234893d00ee5e1ecbd`.
- **Entity Model trigger:** no. This change only maps and tests merged
  behavior; no resource, attribute, policy, action or event changes
  (Codex 4ca892eb). If a test exposes missing behavior, work stops and
  that behavior gets its own entity check and a real RED first.
- **Honesty rule:** a new test that passes at once on merged code is a
  characterization test. It is reported as that, never as RED. No
  production code is weakened to make a test fail.

## Acceptance (issue #44)

> Per-use allocations enforced; no agent or system changes to grant terms
> (D-099); reserve usable only on workshop day or after owner release;
> survives restart.

## Map

| Acceptance part | Merged behavior | Existing tests (main) | Gap |
|---|---|---|---|
| **A1. Per-use allocations enforced.** A call is charged to exactly one allocation; there is no borrowing across allocations or grants. | `Admission.admit/5`, `lock_candidates/2`, `allocation_eligible?/4`; `consumed/1` counts charged invocations in the database | `model_call_admission_test.exs`: :102 one eligible allocation; :117 caller cannot choose grant/allocation; :137 b5/b1 buckets; :346 profile-restricted allocation unused; :357 non-funding allocation unused; :413/:426 ambiguous; :457 allocation attempts; :466 grant total caps even with allocation room; :497 UTC day limit; :182 idempotent; :755/:770 allocation belongs to grant/tenant | **None.** :457 and :466 assert the exact reasons. Borrowing can't happen: two allocations that both fund a bucket are refused as ambiguous (:413, :426), never drawn in turn. |
| **A2. No agent or system changes to grant terms.** | `CurrentAdmin` + `GrantContext` policies on grant and allocation actions | `model_call_grant_test.exs`: :59 reviewers, auditors, every system actor refused; :73 disabled admin; :80 demoted admin; :211 non-admins cannot edit; :295 allocation actions not callable directly; :406 events record the current role | **Was a gap:** :59 covered create only, and :211 covered update for one system actor. **Added** a characterization test (`model_call_grant_test.exs`, "no agent or system changes to grant terms"): every non-admin and system actor is refused update, revoke and release, and the stored grant, its allocations and its events are unchanged. |
| **A3. Workshop reserve only on its day or after the owner's release.** | The workshop reserve is an ordinary allocation with `available_from`; `:release` sets `released_at` (`ModelCallAllocation`) | `model_call_admission_test.exs`: :364 unavailable before its time, available after release; :387 window opens and closes; `model_call_grant_test.exs`: :245 early release audited; :415 release refuses unknown/already released; `admin_budgets_live_test.exs`: :441 release with confirmation | **Was a gap.** **Added** a characterization test (`model_call_admission_test.exs`, "a released workshop reserve stays bound by the day limit, grant total and expiry"). |
| **A4. Survives restart.** | No in-memory state: terms, `released_at`, `revision` and consumption are database rows, and `consumed/1` counts them on every admission | **None.** Rereading in the same process is not a restart proof (Codex). | **Add a restart proof** (below). |

## The restart proof (proposed, for Codex's review before writing)

1. **Commit the state.** On an isolated test partition, with the sandbox
   off, commit:
   - a grant with two allocations, one of them released;
   - one consumed attempt on each allocation.
2. **Read it from a fresh BEAM.** Start a separate OS process with
   `mix run` under `MIX_ENV=test` and the same partition, so no process
   state is shared.
3. **What the fresh process asserts:**
   - the terms, `released_at` and the revision read back unchanged;
   - admission charges the next call to the correct allocation;
   - a full allocation is refused with its exact reason;
   - consumed attempts still count and can't be spent again.

   It writes a small result file, which the test reads.
4. **Clean up:** drop the partition's committed rows afterwards (the
   probe-pollution rule).
5. **Tagging:** tagged `:restart_proof`. Whether the full gate includes
   it by default is for Codex to decide; it costs a fresh application
   boot.

Never the owner's database or app; no real calls.

## Results at main (executed)

- **Existing tests at main `3b09183`:** `model_call_admission_test.exs`,
  `model_call_grant_test.exs`, `admin_budgets_live_test.exs` and
  `grant_refusal_worker_test.exs`. **89 passed**, 0 failed (isolated
  test partition 9).
- **With the two added characterization tests:** the admission and grant
  files ran **64 passed**, 0 failed. Both new tests passed on first run,
  as expected for characterization.
- **Not done yet:**
  - **a sensitivity check of the new tests:** a temporary local mutation
    to show they can fail. It is evidence about the tests, not historical
    RED;
  - **the restart proof:** it waits for Codex's review of the design
    above;
  - **the full gate.**
