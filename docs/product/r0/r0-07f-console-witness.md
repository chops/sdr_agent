# R0-07f: the calibration console's witness store and result wait (contract, draft 1)

- **Status:** draft 1, for Codex review. No code, retry or spend is authorized.
- **Base:** main `3b09183` (includes #146 `b0709f1`).
- **Trigger:** the owner's first attended calibration (2026-10-15, 09:54 MDT)
  stopped at preflight with `calibrate stopped: witness_store_untrusted;
  record :released, invocation none, no evidence`. No invocation, no
  reservation and no charge.
- **Diagnosis:** Claude's diagnosis (`claude-calibration-witness-store-gap-20261015.md`),
  **confirmed** by Codex (`002b8f36`, reply to `a42ca98c`; report
  `codex-calibration-witness-store-diagnosis-20261015.md`), including a
  no-start probe of the real console plan.

## 1. The defects

1. **The console never configures a witness store root.** The console runs
   the test-seam build. `config/test.exs` sets `Witness` `store_root: nil`,
   `config/runtime.exs` reads `SDR_WITNESS_STORE_ROOT` only outside `:test`,
   and `CalibrationConsole.plan/1` and `apply!/2` carry no Witness
   configuration. `Calibrate.store/0` therefore refuses every attended call
   with `:witness_store_untrusted`. The #146 tests supply a trusted root
   through `AdmissionFixtures.admit_tuples!/0`, so no test drove the real
   console plan through store trust.
2. **The console inherits the unit-test result wait.** `config/test.exs`
   lowers `ResultGate` to `wait_ms: 1_000, poll_ms: 25`. Calibration's
   observation (`calibrate.ex:811`) and sent recovery's fresh observation
   (`calibrate.ex:1325`) both use `ResultGate.await/3`, so a charged attempt
   could be frozen as a timeout before the proxy publishes its capture. It
   is not a pre-spend refusal, but it can waste an attempt's evidence.

**Not defects (Codex survey, kept as is):**
- The empty shipped `reconciled_methods` is not a blocker: the authorized
  calibration path supplies its exact candidate entry, and recovery supplies
  the recorded tuple. **No tuple is promoted**; normal real calls stay
  unpromoted.
- The Authority registry, the definition, the proof run, G-R0 selection,
  the compiled CLI pin, the process probe and the clock already have real
  console paths.

## 2. The change

All of it is console-local. Nothing changes for any other test VM, for dev
or for production.

| # | Where | Change |
|---|-------|--------|
| C1 | `CalibrationConsole.current/1` | Adds `witness_store_root: System.get_env("SDR_WITNESS_STORE_ROOT")`, the console's only new input. It also reads the build's `Witness` and `ResultGate` configuration, so `plan/1` can check what it replaces. |
| C2 | `CalibrationConsole.plan/1` | Adds `witness: %{store_root: root \| nil}` and `result_gate: [wait_ms: 120_000, poll_ms: 1_000]` to the plan. A **present** value must pass `Witness.Store.validate_root/1` unchanged: absolute and canonical, every ancestor and the root `lstat`ed, no symlink, owned by this user (ancestors by root or this user), not group- or world-writable, no URI, relative or empty fallback. A present value that fails is refused for **every** command, with a message naming `SDR_WITNESS_STORE_ROOT` and the reason (`store_root_missing` or `store_root_untrusted`). Nothing is created, chmodded, repaired or followed, and no capture is read. **Absent** gives `store_root: nil`. |
| C3 | `CalibrationConsole.require/2` (new) | Command scope: `calibrate` and `calibrate-recover ID` (sent recovery reads the store) require a non-nil root. `check`, `serve`, `bootstrap-admin` and `calibrate-recover --release-aborted` do not. The Mix task calls it right after `plan!/0`, **before** `prepare!`, `apply!`, `ensure_storage!`, `app.start`, the tenant, the definition and the claim. So an absent root refuses `calibrate` with no record, no claim and no database effect, as `calibrate refuses: SDR_WITNESS_STORE_ROOT is not set …`. `Calibrate.store/0` and admission's store checks stay unchanged as defense in depth. |
| C4 | `CalibrationConsole.apply!/2` | Puts `Witness` as the build's keyword list with only `store_root` replaced (`reconciled_methods: []` and `allow_method_override: true` are kept), and `ResultGate` as the plan's `result_gate`, both before the app starts. `verify_applied!/0` also asserts that `Witness.store_root()` equals the plan's root, that `Witness.reconciled_methods()` is `[]`, and that `ResultGate.wait_ms()` is 120 000. |
| C5 | `mix sdr.calibration.console check` and `bin/calibration-console check` | The machine-parsed `SDR_CALIBRATION_CONSOLE` plan line is **unchanged** (the wrapper rejects extra fields). The task prints one more line, `SDR_CALIBRATION_WITNESS <root>` or `SDR_CALIBRATION_WITNESS unset`, and the wrapper's `check` reports it as `witness store <root> (trusted)` or `witness store unset: calibrate and sent recovery will refuse; set SDR_WITNESS_STORE_ROOT`. The wrapper passes `SDR_WITNESS_STORE_ROOT` through unchanged; it already does. |
| C6 | Docs | Wrapper header, task moduledoc, `CalibrationConsole` moduledoc, and the packet's §8.2 wiring note that the root comes from the console's plan input. The owner's command becomes `SDR_WITNESS_STORE_ROOT=$HOME/.local/share/llm-otel-proxy/blobs bin/calibration-console calibrate PROFILE`. No user-specific path is checked in. |

**Why 120 s and 1 s:** these are `ResultGate`'s own ceiling and default
poll. Configuration may only lower the ceiling, so this restores the
reviewed production bound instead of choosing a new one. A longer bounded
wait changes no attempt count and adds no retry: one observation per
command, as today.

**Why an environment input and not a fixed path:** the proxy's blob
directory is per machine. A checked-in path would name a user's home
directory, and reading the variable in `runtime.exs` for `:test` would let
ambient configuration reach every test VM. The console already takes all
its other configuration through its plan, which validates it.

## 3. Unchanged (must stay true)

- Fake runtime provider, no model server outside `calibrate`'s one private
  server, `testing: :manual` Oban, `sdr_agent_calibration` on 5520 only,
  loopback 4124, per-machine secrets.
- `reconciled_methods: []` and no global tuple promotion; the calibration
  candidate stays the only path.
- The private verified pin, the one-shot staging authority, evidence
  quarantine, the at-most-one-invocation rule and the recovery commands.
- Store trust is still re-observed at admission, at launch and at every
  store read (B5'); this change does not claim more than observation-time
  trust.

## 4. Entity model and ADR

- **Entity Model trigger: no.** Reason: no persisted concept, attribute,
  relationship, policy, action or event contract changes; the change is
  console configuration and command preconditions.
- **ADR:** none proposed. This is wiring inside the accepted ADR-0005 R0-07
  harness amendment (calibration-only boundary, test-seam console). It adds
  no technology, dependency or reviewer boundary. Codex to confirm.

## 5. RED tests (before any code)

Each fails on main for the intended missing behavior, not setup. All are
`async: false` and restore `Application` env and `System` env on exit.

1. **Real plan wiring.** From the clean test configuration, with no
   `AdmissionFixtures` and no manual Witness `put_env`, and with a trusted
   temporary root in `SDR_WITNESS_STORE_ROOT`: `current/1 → plan/1 →
   apply!/2` makes `Witness.store_root()` that root, keeps
   `reconciled_methods()` `[]`, and `Admission`'s store observation
   (`Store.validate_root(Witness.store_root())`) trusted. On main the root
   stays nil.
2. **Refusals, without repair.** A present value that is relative,
   `file://…`, empty-segment, missing, a symlink, under a symlinked
   ancestor, group-writable or world-writable is refused by `plan/1`, with
   a message naming the variable. The filesystem is unchanged afterwards:
   no directory created, no mode changed.
3. **Absent root, command scope.** With the variable unset, `plan/1`
   succeeds with `store_root: nil`. `require/2` passes `check`, `serve`,
   `bootstrap-admin` and `calibrate-recover --release-aborted`, and refuses
   `calibrate claude_cli_opus`, `calibrate claude_cli_sonnet` and
   `calibrate-recover ID`.
4. **No effects before the refusal.** The task's `calibrate` with the
   variable unset refuses before any database effect: no claim, no launch
   record, no tenant or definition write, `app.start` not run. A probe
   asserts the Repo was not started.
5. **The effective wait.** After `apply!/2`, `ResultGate.wait_ms()` is
   120 000 and the poll is 1 000. A hermetic observation whose capture is
   published about 1.5 s after the call is still observed, within the
   console's budget, with no second reservation or launch. The same test
   under the plain test configuration times out, which shows the budget
   comes from the console.
6. **Recovery uses the same root and budget.** The sent-recovery fresh
   observation reads the applied root and budget, not a test override.
7. **Check output.** The plan line is byte-for-byte unchanged. The witness
   line reports the root or `unset`, and the wrapper's `check` prints the
   matching sentence.
8. **Isolation.** Other test VMs are unaffected: with the variable set in
   the environment, `config/runtime.exs` under `:test` still leaves
   `Witness.store_root()` nil outside the console path (read with
   `Config.Reader.read!("config/runtime.exs", env: :test)`).

## 6. Owner steps after the merge

The merge also waits on the Bandit pin (D-130). After it, the attended
sequence resumes at step 4: run `bin/calibration-console check` with the
variable set, confirm the witness line, then `calibrate claude_cli_opus`.
G-R0 is unchanged (0 of 4) and valid until 2026-10-19 05:59 UTC.

## 7. Open questions

- **OQ-F1:** whether a present-but-invalid root should refuse every command
  (proposed: yes, fail closed and visible) or only the commands that need
  it.
- **OQ-F2:** whether `check` should also exit non-zero when the root is
  unset (proposed: no; it reports and exits 0, and `calibrate` refuses).
