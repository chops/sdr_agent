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

## The restart proof (built; design passed by Codex, 406efa56)

**The test:** `test/sdr_agent/agents/grant_restart_proof_test.exs`, with
its scripts in `test/support/restart_proof/`. It is tagged
`:restart_proof` and runs in the default gate. If it can't run, C9-04's
restart acceptance is unverified, not passed.

**The binding conditions (Codex) and how the test meets them:**

1. **An owned database.** The test uses a uniquely named synthetic
   database, `sdr_agent_test_rp<10 hex>`, through `MIX_TEST_PARTITION`.
   Both the test and each child check its name and that it is on
   localhost:5520 before any write. The parent never touches the Repo,
   and nothing changes the suite's sandbox mode; sandbox-off is used only
   inside the child scripts. Cleanup drops only that database (`mix
   ecto.drop` with the same partition) and the test's own temporary
   folder. A cleanup failure is reported.
2. **A scrubbed child.**
   - Literal argv through `Port.open/2` with `:spawn_executable`.
   - The environment comes from `SdrAgent.ChildEnv`: its base allowlist,
     plus the devenv toolchain's paths (`MIX_HOME`, `HEX_HOME`,
     `MIX_DEPS_PATH`, `MIX_BUILD_ROOT`, `ERL_LIBS`), plus
     `MIX_ENV=test` and the partition. Secrets and provider settings are
     removed.
   - Each child checks the Fake provider and makes only reservations,
     never a launch.
   - Each child has a 300-second deadline, after which it is killed and
     reported. Its exit status is checked.
3. **Persisted state, read by a fresh BEAM.**
   - `setup.exs` commits through the domain APIs, then exits:
     - a grant (6 attempts) with three allocations: b1 with 2 attempts,
       b5 with 1, and a workshop reserve with 1 that opens Nov 1;
     - the owner's release of the workshop reserve (revision 2);
     - one charged reservation each on b1 and b5.
   - `verify.exs` then starts as a new OS process. It checks:
     - the revision, the total and every allocation's id, key, buckets,
       attempts, window, `released_at` and `grant_revision`, exactly as
       committed;
     - the setup charges are still counted, and still bound to their own
       allocations;
     - full b5 is refused with `{:budget_exhausted, :allocation}`;
     - the next b1 call is charged to that b1 allocation and this grant;
     - full b1 is then refused with the same exact reason;
     - there is no borrowing and no extra debit;
     - the grant total is counted.

     It freezes its own clock and does not rely on the parent's state.
4. **The result file.** It goes to a unique temporary path. The test
   checks that the file exists, that all 11 named checks are true, that
   `ok` is set, and the exit status. A missing or stale result fails the
   test.

## Results at main (executed)

- **Existing tests at main `3b09183`:** `model_call_admission_test.exs`,
  `model_call_grant_test.exs`, `admin_budgets_live_test.exs` and
  `grant_refusal_worker_test.exs`. **89 passed**, 0 failed (isolated
  test partition 9).
- **With the two added characterization tests:** the admission and grant
  files ran **64 passed**, 0 failed. Both new tests passed on first run,
  as expected for characterization.
- **The restart proof:** 1 passed in about 5 seconds, on its own owned
  database, which was dropped afterwards. No leftover databases or
  temporary folders were found.
- **Sensitivity checks.** Each is a temporary local change, reverted
  afterwards and never committed. They are evidence about the tests, not
  historical RED:
  - **A2:** the grant policy was changed to also allow the scheduler.
    The new test and the existing create test failed (2 of 25).
  - **A3:** expiry was ignored in both places that enforce it, the query
    filter and `grant_eligible?/3`. The new test and the existing expiry
    test failed (2 of 39). Ignoring expiry in only one place fails
    nothing, because the other check still applies (defense in depth).
  - **A4:** the setup was changed to skip the b5 charge. Exactly three
    checks failed: `setup_charges_still_counted`,
    `setup_charges_bound_to_their_allocations` and
    `full_b5_refused_exactly`.
- **All of these results are author-executed**, not independently rerun.
- **The full gate:** pending.
