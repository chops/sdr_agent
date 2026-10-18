# #188 fix plan (revision 2, Codex PASS 917dbbad)

- **Base:** main `258283d`.
- **Scope:** test-only, `test/support/resolve_harness.ex` `await_switch!/4` and a new focused test file. Entity and ADR triggers don't apply (Codex).
- **Diagnosis:** `claude-188-diagnosis.md` (sha256 `bd5c5ea8…`).
- **Status of the mechanism:** cumulative shared-sandbox contention during the coordinator restart burst is **inferred**, not reproduced. The local green repetitions are not a reproduction and not a fix demonstration.

## The observed error (pinned from CI run 39162215483, log line 8360)

The polled read `Agents.list_profile_switches(actor: admin)` returned:

```
{:error,
 %Ash.Error.Unknown{
   errors: [
     %Ash.Error.Unknown.UnknownError{
       error: "** (DBConnection.ConnectionError) could not checkout the connection owned by #PID<…> ({:sql_sandbox_owner, %{started_by: #PID<…>}}). When using the sandbox, connections are shared, so this may imply another process is using a connection. Reason: connection not available and request was dropped from queue after 343ms. You can configure how long requests wait in the queue using :queue_target and :queue_interval. See DBConnection.start_link/2 for more information"
     }
   ]
 }}
```

## Change (must-fix 1: the whole observation path)

`await_switch!/4` keeps its public arity and its 20 s default timeout. It delegates to a private `await_switch_with(read, id, status, timeout)`; the default reader is `fn -> Agents.list_profile_switches(actor: ctx.admin) end`. The new test file reaches it through one `@doc false` test-support entry (`await_switch_with!/4`), never the shared config.

The loop:
1. Take one monotonic deadline at entry. It is never reset on retry.
2. Before each read, if the deadline has passed, flunk.
3. Call `read.()` exactly once.
   - `{:ok, switches}` with the switch at `status`: if the deadline passed while the read was in flight, flunk (no late acceptance). Otherwise return **that switch**, with no further read.
   - `{:ok, switches}` without a match (absent, or a different status): record `{:observed, switch_or_nil}`, sleep 20 ms, go to 2.
   - `{:error, error}` where `sandbox_queue_drop?(error)`: record `{:transient, :sandbox_queue_drop}`, sleep 20 ms, go to 2.
   - Anything else (a different error, a raise, an unexpected shape): fail immediately, with the value inspected.
4. A flunk names the status awaited and the last recorded observation **held in the loop**. A timeout performs no extra database read.

- **No final strict re-read.** The old trailing `switch!(ctx, id)` is removed: the function returns the matching observation itself.
- **`switch!/2` is unchanged and stays strict.**
- **In-flight bound:** a read already in progress is bounded by the repo and DBConnection timeouts, not by the poll deadline. So this does not claim a strict 20 s wall-clock cap, only that no new read starts after the deadline and no late result is accepted.

## Classifier (must-fix 2: exact shape, refusal boundaries)

`sandbox_queue_drop?/1` is true only for:

```elixir
%Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{error: msg}]} when is_binary(msg)
```

…with exactly one error, where `msg`:
- starts with `"** (DBConnection.ConnectionError) could not checkout the connection owned by "`;
- contains `"({:sql_sandbox_owner, "`;
- contains `"Reason: connection not available and request was dropped from queue after "`.

Everything else is false, and so fails at once:
- an owner exit (`"owner #PID<…> exited"` / `"could not checkout the connection owned by"` with a reason other than queue drop);
- `queue: false` / `"connection not available because of queue disabled"`;
- connection refused, or any `Postgrex.Error`;
- a plain queue drop **without** the sandbox-owner marker;
- a different Ash wrapper (`Ash.Error.Invalid`, `Forbidden`, a bare `DBConnection.ConnectionError` struct);
- two or more errors, or mixed causes;
- a non-binary `error`.

## Tests (RED first) — `test/sdr_agent/test_support/resolve_harness_await_switch_test.exs`

These are hermetic, with an injected reader (an Agent-backed script of responses) and no database. The test values use **the real formatted CI string** above, with fixed PIDs.

1. Two observed sandbox queue drops, then a matching row: the call returns that row; the reader is called exactly 3 times (no fourth checkout).
2. A wrong status, then an absent row, stay pending until the matching row arrives.
3. A persistent queue drop until the deadline flunks; the message names the transient category; the reader is not called after the deadline.
4. A matching row returned after the deadline (a slow reader) is not accepted.
5. Each refused shape in the list above raises or flunks on the **first** read (reader called once). These are table-driven, one case per shape.

**Mutants** (each must turn a test red):
- (a) drop the classifier, treating every error as fatal: test 1 fails;
- (b) widen it to any `ConnectionError` text: the plain-queue-drop and owner-exit cases fail;
- (c) restore the trailing `switch!/2` re-read: test 1's call-count assertion fails.

**What it proves:** correct handling of the observed error shape and the refusal boundaries, deterministically. It does not prove the restart-burst mechanism, nor that CI cannot show some other contention.

## Scope inventory only (must-fix 3)

These other polled reads in `resolve_harness.ex` hard-match `{:ok, _}` and could see the same error:
- `starts!/1` and its callers;
- the effects and facts reads;
- the generic `await!/3` callers.

They are **listed, not changed**. Any extension needs its own reviewed scope, because their assertion semantics differ.

## Verification

1. RED: the new file fails against the unchanged harness.
2. GREEN: the new file passes.
3. The `admin_live_switch_test.exs` file, on seeds 0–4.
4. The three mutant checks, each run, then reverted, then disclosed.
5. Full gate at a fixed head; Codex review.
6. #183 then rebases onto it, gets Codex's re-sign and CI.

## Binding RED clarifications (Codex PASS 917dbbad)

1. The injected entry point is callable with the **old** strict read and poll behaviour at RED, through a test-support-only forwarding seam (`await_switch_with!/4`, `@doc false`). `await_switch!/4` forwards to it unchanged. An undefined function, a setup failure or a compile error is not an intended-reason RED. The already-passing controls are disclosed.
2. The re-read mutant performs its extra read through the injected reader and fails the call-count or returned-observation assertion. It never queries a real database from the hermetic test.

## RED record

**Round 2** (Codex `codex-188-a27863b-red-review.md` must-fixes 1 to 3). Run `mix test test/sdr_agent/test_support/resolve_harness_await_switch_test.exs --seed 0`: 14 of 19 passed.

**Intended failures, each through an assertion:**
1. Two queue drops, then a match: the outcome is `{:raised, %MatchError{}}`, not `{:returned, row}`. The old strict match raises on the first drop, and the test captures that as an observed outcome.
2. Wrong status, then an absent row, then the match: 4 reads instead of 3, because of the old trailing re-read.
3. A persistent drop: `MatchError` instead of a deadline flunk naming `sandbox_queue_drop`. This is an `assert_raise` mismatch.
4. A non-matching answer that arrives past the deadline: 2 reads instead of 1, because the old timeout message re-reads. This replaces round 1's timing-sensitive start-time assertion.
5. A late match is accepted instead of refused.

**Already-passing controls, disclosed (14):**
- the 10 refused shapes;
- 4 near misses built from the exact CI string with one required part changed each: no sandbox-owner marker; an owner exit as the reason; a disabled queue as the reason; a different error prefix.

Each fails on its first read under the old strict match. The near misses isolate the classifier's three required checks.

**The seam is behaviour-preserving:** `admin_live_switch_test.exs` seed 0 passed 44 of 44 (round 1; the seam is unchanged since).

## GREEN record

`await_switch_with!/4` now:
- takes one monotonic deadline;
- checks it before every read, and before accepting a match;
- retries only the exact sandbox queue drop (three required parts);
- fails at once on anything else;
- returns the matching observation, with no further read.

`switch!/2` is unchanged. The new file passes 19 of 19 at seed 0.

**Mutants** (each applied, run, then reverted; log `claude-188-mutants.log`):

| Mutant | Result | Caught by |
|---|---|---|
| a. never transient | 17/19 | two-drops-then-match; persistent drop |
| b. any `ConnectionError` text | 12/19 | seven controls (owner exit, disabled queue, refused connection, plain queue drop, and three near misses) |
| c. trailing re-read | 17/19 | both call-count tests |
| d1. no prefix check | 18/19 | the different-prefix near miss |
| d2. no marker check | 18/19 | the no-marker near miss |
| d3. no reason check | 17/19 | the owner-exit and disabled-queue near misses |

**Disclosure:** a first mutant run was invalid. Its mutation script ran inside the dev shell, where it did not modify the file, so every "mutant" was the unchanged fix (19/19). That was detected because the file failed to match the saved fix before the rerun. The results above come from the rerun, with each mutation applied and confirmed (`[mutated]`) before its test run.
