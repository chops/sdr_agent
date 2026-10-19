# #194: restart test reads the attestation before init publishes it

- **Issue:** #194. CI run 39186896880 on main `967a45e`, at `test/sdr_agent/ai/provider_runtime_test.exs:460`. The test made one `ClaudeCLI.attestation()` read and got `%{status: :not_running}` after admission reopened.
- **Scope:** test-only. There is no production change and no init reorder.
- **Plan:** `claude-194-plan-r2.md` in the handoff tmp dir. Codex gave it a conditional APPROVE at sha256 `ff3f05f3…` (answer 5ac5fe0b). The addendum, written before RED, is sha256 `72738e6f…`.

## Mechanism (inferred; the real CI cause is not reproduced)

`ClaudeCLI.start/3` (`claude_cli.ex`) publishes `:admission` through `admit/1` → `sync_admission/1` before `preflight/1` notes the `:attestation`. The old test polled admission only, then read the attestation once, inside that gap.

## Change

The new helper `started/2` returns `{:ok, pid}` only when all of these hold:

- the registered server is a pid other than `previous`;
- `admission(pid)` is `:open` and `attestation(pid)` is `:pending`, both read from that same pid;
- that pid is still the registered server after the reads, and still alive.

`await_started/2` polls it under the file's existing bound (200 × 10 ms).

**First child, before the kill:**

1. `await_started(nil)`.
2. `:sys.get_state(first, 1_000)`, which proves init returned.
3. A bounded wait until `Coordinator.sample()` binds `first` with a binary `start_id`. The coordinator publishes only after the start returns, so a one-shot read here would be a new race.

**Subject:** `await_started(first)` must return a different pid.

## Evidence (handoff tmp dir)

| Check | Result | Log / artifact |
|---|---|---|
| D0+D1 transient diagnostic: barrier between admit and preflight, paused replacement | (a) old one-shot: admission `:open`, attestation `:not_running` while paused; (b) `started/2` false ×20 over 200 ms while paused; (c) after release: same pid, `:open` + `:pending`. 2 passed | `claude-194-d0d1-r3.log` sha256 `5c3eaf3c…`; patch `claude-194-d0d1-transient.patch` sha256 `96dc856a…` |
| M2: subject expects `:attested` | fails at the subject assert (`:timeout`), after step 1's `[M2] step 1 passed` marker | `claude-194-m2.log` |
| File, seeds 0–4, clean source | 29/29 each | `claude-194-seeds.log` |

The transient changes were applied outside nix and confirmed `[mutated]`. They were reverted before the clean runs: `git diff --quiet lib/` passes, and the test file was restored from the saved fixed copy.

## Disclosures

- **D1 run 1** sent the release twice. The second `:release_194` reached the server's `handle_info` and crashed the replacement (a FunctionClauseError) after the assertions had passed. That was a fault in the diagnostic, not the subject.
- **D1 run 2** failed in the `after` block on ExUnit's `catch_exit` assertion, which raised because nothing exited. All the D1 markers had passed.
- **Run 3** used a plain `try/catch` join. Logs `-d0d1.log` and `-d0d1-r2.log` are kept.
- **A `Writer crashed (:epipe)` / `:terminated` line** from `mix hex.info` at shell start is unrelated to the tests.
- **Causality:** the barrier pins the ordering that the source shows. That CI hit exactly this window remains inferred.

## Inventory only (not changed)

Other one-shot `attestation()` reads after an admission poll: the status tests in this file use `tree!/1`, which awaits the coordinator's release before reading `Runtime.status()`. They were not changed here.
