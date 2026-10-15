# R0-07f: the calibration console's witness store and result wait (contract, draft 2)

- **Status:** draft 2. **Interface/entity PASS** (Codex, ai-pair reviewer;
  capabilities `ai_pair: true`, `codex_review: true`): exact `0ee216e`,
  request `m_1792080510401704916_82b61777`, answer `af639929`, 2026-10-15
  16:10 UTC; report `codex-r007f-0ee216e-contract-pass.md`. Scoped RED only;
  not VERIFIED RED, GREEN, merge, retry or spend. Draft 1 (`cbc3db5`) was
  NEEDS-REVIEW (`e510d654`). Binding qualifications from the PASS:
  argv/profile/recovery parsing precedes the root prerequisite (the AST
  check distinguishes pure `Calibrate.command`/`recover_command` parsing
  from effectful `run`/`recover`); a `require/2` refusal must short-circuit
  the effectful branch; exactly one plan line and one witness line,
  compared without trimming; the delayed-capture test proves the applied
  console budget without fixture pre-promotion; the command-table order
  applies to each command's own applicable steps.
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
| C3 | `CalibrationConsole.require/2` (new) | Command scope: `calibrate` and every `calibrate-recover ID` require a non-nil root. This is a conservative command-level precondition: sent recovery reads the store, but an ID whose history turns out not to need a store read is still refused before database work when the root is absent (the owner sets the variable and re-runs). Malformed argv keeps today's usage refusal, checked first. `check`, `serve`, `bootstrap-admin` and `calibrate-recover --release-aborted` do not. The Mix task calls it right after `plan!/0`, **before** `prepare!`, `apply!`, `ensure_storage!`, `app.start`, the tenant, the definition and the claim. So an absent root refuses `calibrate` with no record, no claim and no database effect, as `calibrate refuses: SDR_WITNESS_STORE_ROOT is not set …`. `Calibrate.store/0` and admission's store checks stay unchanged as defense in depth. |
| C4 | `CalibrationConsole.apply!/2` | Puts `Witness` as the build's keyword list with only `store_root` replaced (`reconciled_methods: []` and `allow_method_override: true` are kept), and `ResultGate` as the plan's `result_gate`, both before the app starts. `apply!/2` and the post-start `verify_started!/0` both assert, against the root **carried in the plan** (never a second environment read), that `Witness.store_root()` equals it, that `Witness.reconciled_methods()` is `[]`, that `allow_method_override` is still `true`, and that the effective `ResultGate` wait and poll are 120 000 and 1 000. |
| C5 | `mix sdr.calibration.console check` and `bin/calibration-console check` | The machine-parsed `SDR_CALIBRATION_CONSOLE` plan line is **unchanged byte for byte** (the wrapper rejects extra fields). **Framing:** `plan/1` also refuses a present root containing any control character (bytes 0x00–0x1F or 0x7F), console-local, before `validate_root`; spaces and other printable characters are allowed. The task prints exactly one more line: `SDR_CALIBRATION_WITNESS set ` followed by the root verbatim (so a space round-trips, and no newline can occur), or `SDR_CALIBRATION_WITNESS unset`. The wrapper reads it with `IFS= read -r`, takes everything after the fixed `SDR_CALIBRATION_WITNESS set ` prefix as data, compares it byte for byte with its own `SDR_WITNESS_STORE_ROOT`, refuses on a mismatch or a missing line, and prints it only with `printf '%s'`: never `eval`, `source` or unquoted expansion. `check` then reports `witness store <root> (trusted at check)` or `witness store unset: calibrate and calibrate-recover ID will refuse; set SDR_WITNESS_STORE_ROOT`, and exits 0 in both cases (OQ-F2). A green `check` is not readiness or authorization for a real call. The wrapper passes `SDR_WITNESS_STORE_ROOT` through unchanged. |
| C5a | `bin/calibration-console` (wrapper guard) | Before any Mix command, `calibrate` and `calibrate-recover ID` refuse when `SDR_WITNESS_STORE_ROOT` is unset or empty: `refusing: SDR_WITNESS_STORE_ROOT is not set; calibrate needs the witness proxy's store root`. `check`, `serve`, `bootstrap-admin` and `calibrate-recover --release-aborted` are unaffected. This is the outer fail-before-effects guard; C3 is the inner one for a direct `mix` call. |
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

- **Entity Model trigger: yes.** Reason: new fields on the console's
  server-side plan value object, a new command precondition (`require/2`)
  and changed effect ordering of two backend commands. No persisted
  entity, table, Ash resource, event or audit write changes. Delta only:

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Console config (`CalibrationConsole.config`, value object) | Existing (delta) | What `plan/1` reads | + `witness_store_root : String.t() \| nil` (from `SDR_WITNESS_STORE_ROOT`, owner-controlled environment, no default); + the build's `Witness` and `ResultGate` keyword lists, read for replacement only | none | Read once per command by `current/1`; never persisted, never printed except the C5 witness line | Owner sets the variable in their own shell; agents never set or read it on the owner's behalf | none |
| Console plan (`CalibrationConsole.plan`, value object) | Existing (delta) | The configuration a console command runs with | + `witness : %{store_root: String.t() \| nil}`: nil only when the input is absent; a present value is canonical absolute, has no control character and passed `Store.validate_root/1`, else the plan is refused for every command (OQ-F1); + `result_gate : [wait_ms: 120_000, poll_ms: 1_000]`, fixed | none | Built per command; applied by `apply!/2` **before** `app.start`; `apply!/2` and `verify_started!/0` verify the applied values against the plan; immutable for the command's life | No actor; produced by the Mix task process only | none |
| Console command contract (`mix sdr.calibration.console`, `bin/calibration-console`) | Existing (delta) | The owner's console commands | Command classes: **capture-required** = `calibrate PROFILE`, `calibrate-recover ID [--owner-verified-stopped]`; **capture-optional** = `check`, `serve`, `bootstrap-admin`, `calibrate-recover --release-aborted` | none | Order for every command: argv usage check → wrapper guard (C5a, capture-required only) → `plan!` (creates the secrets file on first use, already disclosed; refuses an invalid present root) → `require/2` (capture-required: refuses a nil root) → only then `prepare!`, `apply!`, `ensure_storage!`, `app.start`, tenant, definition, claim. A refusal at or before `require/2` performs none of the steps after it. Refusals keep their existing exit and message style | Unchanged: the owner runs every command and types every confirmation; the console's system actors, G-R0 selection, the one-shot staging authority and recovery confirmations are unchanged | none |

  `existing dependency: unchanged — relationship/policy/lifecycle impact
  checked, none found` for `Witness` configuration consumers (admission,
  `ResultGate`, `Witness.reconcile`, `Store`), `ModelCallGrant` (G-R0),
  `ModelInvocation`, the calibration launch record and evidence.

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
4. **No effects before the refusal.** Two layers, neither touching the
   real `sdr_agent_calibration` database:
   - **Wrapper (subprocess):** `bin/calibration-console calibrate
     claude_cli_opus` and `calibrate-recover <uuid>` with the variable
     unset, run with a `PATH` whose `mix` is a stub that records any
     invocation and exits non-zero. Assert exit 2, the refusal message, and
     that the stub was never invoked. On main the wrapper invokes `mix`
     (`check` first), so the stub records a call and the test fails for
     the intended reason without reaching any database.
   - **Task ordering (in-process, structural):** for the task's
     `calibrate` and `calibrate-recover` clauses, assert from the compiled
     source's AST that `CalibrationConsole.require/2` is called after
     `plan!/0` and before `prepare!`, `CalibrationConsole.apply!`,
     `ensure_storage!`, `Mix.Task.run("app.start")` and the `Calibrate`
     call, and that no other effectful call precedes it; plus unit tests
     of `require/2`'s refusal for each capture-required command. A
     runtime negative run of the task in-process is **not** used: on main
     it would migrate and claim against the real calibration database.
   Secrets creation in `plan!` is a separate, already-disclosed effect;
   the claim is "no storage, app start, claim or record", not "no
   effects at all".
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
8. **Isolation.** Other test VMs are unaffected. (a) With the variable
   set, `Config.Reader.read!("config/runtime.exs", env: :test)` returns no
   `Witness` `store_root` (the returned config, not the VM's environment).
   (b) A clean `MIX_ENV=test mix run --no-start -e` subprocess with the
   variable set prints `Witness.store_root()` as nil. Every test in this
   file restores the `Witness`, `ResultGate` and `System` environment on
   exit, so an earlier console `apply!` cannot fake this case.
9. **Framing.** A root containing a space round-trips through the witness
   line and the wrapper's comparison; a root containing a newline, tab or
   other control character is refused by `plan/1`; a stub task that prints
   a forged second `SDR_CALIBRATION_CONSOLE` or witness line, or a witness
   line that differs from the variable, makes the wrapper refuse.

## 6. Owner steps after the merge

The merge also waits on the Bandit pin (D-130). After it, the attended
sequence resumes at step 4: run `bin/calibration-console check` with the
variable set, confirm the witness line, then `calibrate claude_cli_opus`.
G-R0 is unchanged (0 of 4) and valid until 2026-10-19 05:59 UTC.

## 7. Open questions (resolved in draft 2)

- **OQ-F1:** an explicitly supplied invalid root refuses **every** command,
  never downgraded to nil or repaired; an absent root is allowed for the
  capture-optional commands. Claude's proposal; Codex supports (`e510d654`).
- **OQ-F2:** `check` with an absent root exits 0 and reports that capture
  is not ready; the capture-required commands refuse. Claude's proposal;
  Codex supports. The owner may override either.
