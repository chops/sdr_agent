# #235 fix plan (revision 1, Codex PASS b812aabf to the narrow RED)

- **Base:** main `18c01f9b`.
- **Branch:** `fix-235-await-switch`.
- **Scope:** test-only.
  - Changed: `test/sdr_agent/ai/profile_coordinator_test.exs` and this record.
  - Not changed: `lib/`, `config/` and `test/support/resolve_harness.ex`.
- **Entity Model trigger:** no. Only a private test observation helper changes, with no persisted concept, authorization, lifecycle or domain action delta.
- **ADR and diagram:** none. This reuses the accepted #188 test-support convention.
- **Plan and review:** plan `tmp/i235/claude-235-plan-r1.md` (sha256 `e49292f6…`). Codex review `tmp/i235/codex-235-plan-r1-review-20261027.org` (sha256 `b812aabf…`) gave PASS to the narrow RED: OQ1/OQ2 yes, OQ3 one follow-up issue after merge, OQ4 all six mutants.
- **Mechanism:** cumulative shared-sandbox contention while the coordinator does its activation-failure and rollback writes is **inferred**, not reproduced.

## The observed error (CI run 40460413797, attempt 1, log line 31802)

`profile_coordinator_test.exs:176` ("a failed candidate preflight rolls back and fails the switch") failed at `:181` inside this file's own `await_switch/4` (`:524`). The loop hard-matches `{:ok, switches} = Agents.list_profile_switches(actor: ctx.admin)`. The read returned:

```
{:error,
 %Ash.Error.Unknown{
   errors: [
     %Ash.Error.Unknown.UnknownError{
       error: "** (DBConnection.ConnectionError) could not checkout the connection owned by #PID<0.1292974.0> ({:sql_sandbox_owner, %{started_by: #PID<0.1292973.0>}}). When using the sandbox, connections are shared, so this may imply another process is using a connection. Reason: connection not available and request was dropped from queue after 255ms. You can configure how long requests wait in the queue using :queue_target and :queue_interval. See DBConnection.start_link/2 for more information"
     }
   ]
 }}
```

This is the same single-cause shape as #188, and it meets `ResolveHarness`'s classifier: the prefix, the sandbox-owner marker and the queue-drop reason are all present.

**Not proven to be unrelated to #233.** The facts:
- Attempt 2 of the same run passed on the same head (author-reported).
- The coordinator code did not change.

These support intermittency. They do not prove there is no causal timing or test-order interaction.

## Change

**RED** adds a behaviour-preserving seam:
- `await_switch!/4` keeps its arity, its 20 s default and its 11 call sites.
- It forwards to a private `await_switch_with!(read, id, status, timeout)`.
- At RED that function is the old loop, with `read.()` in place of the direct read: the same strict match, post-read deadline check, late acceptance and message.

**GREEN** deletes the local loop. `await_switch_with!/4` delegates to the **unchanged** `ResolveHarness.await_switch_with!/4` from #188. That path has the following properties:
- one monotonic deadline, never renewed, checked before each read and before accepting a match;
- only the exact single-cause sandbox queue drop is transient;
- any other error fails at once;
- the matching observation is returned with no further read;
- a timeout reports the held observation.

The harness gets an `alias`, not an `import`, because this file has its own `await_status!`, `kill_coordinator!`, `starts!` and `tree!`. There is no fallback copy of the classifier.

## Tests (RED first): `describe "the switch observation (#235)"`

The subject is hermetic: an Agent-scripted reader, supervised by the test, counts reads, and no database is read inside the subject. The module setup still bootstraps a tenant on the runner's owned database. The CI string above is used verbatim.

| # | Test | RED expectation |
|---|---|---|
| T1 | two queue drops, then the match: that row, after exactly 3 reads | **fails**: the outcome is `{:raised, %MatchError{}}` |
| T2 | a persistent queue drop flunks at the deadline, naming `sandbox_queue_drop` | **fails**: `assert_raise` got `MatchError` |
| T3 | a match that arrives after the deadline (slow reader, 300 ms vs 100 ms) is not accepted; 1 read | **fails**: the late match is returned |
| T4 | a wrong status, then an absent row, stay pending until the match; 3 reads | control |
| T5 | a non-matching `{:ok, []}` past the deadline ends the wait; 1 read | control |
| T6 | a persistent wrong status flunks at the deadline | control |
| C1–C8 | refused shapes fail on the first read (1 read, token in the message) | controls |

**The refused shapes C1–C8:**
- C1–C4: the CI drop with exactly one required part changed: no sandbox-owner marker; an owner exit as the reason; a disabled queue as the reason; the OwnershipError prefix.
- C5: the drop under `Ash.Error.Invalid`.
- C6: a Postgrex deadlock error.
- C7: two causes, both drops.
- C8: a bare `DBConnection.ConnectionError`.

No assertion checks elapsed time.

**Mutants (to follow GREEN):**
- M1: the old local loop restored.
- M2: a local wrapper that maps every error to `{:ok, []}`.
- M3: a trailing re-read.
- M4: the harness classifier widened to any ConnectionError text.
- M5: the harness classifier never transient.
- M6: the harness's late-acceptance check removed.

M4–M6 are transient, applied in this owned worktree only. Each is hashed and reverted.

## Scope inventory only

These are listed, not changed. One tracking issue will be filed after merge, linked to #188 and #235.
- **Other shared-sandbox polls with an unguarded read (plan F1–F10):** `profile_coordinator_review_r2_test` (two), `profile_coordinator_review_test` `switch_terminal/3`, the `await_blocked!` helpers in `profile_coordinator_boot_gap_test` and `profile_restart_test`, the `RH.starts!` polls in `profile_coordinator_resolve_review_test` and `runtime_status_test`, the `Ash.read_one!` polls in `launch_boundary_test`, `reserved_recovery_test` and `terminal_sent_recovery_test`, and the `Ash.read!` poll in `calibrate_recover_test`.
- **Strict single reads in this file:** `switch_failure/2`, `starts!/1` and the setting reads.

## Verification

The standing lane runner is used throughout.
1. **RED:** `CLASS=focused` on this file and the #188 harness test file, at the exact RED head. The intended failures are T1–T3 only. The 15 existing tests and the 11 new controls are reported separately. Any existing-test flake is preserved as an additional failure, with one same-head rerun.
2. **GREEN:** the same files, all passing.
3. **Mutants:** M1–M6.
4. **Full gate:** `CLASS=gate` at the exact GREEN head. It includes plain Credo; a separate local `mix credo` run is additional evidence. Then Codex review, exact-head CI, and D-157.

## RED record

Pending the lane run at the RED head.
