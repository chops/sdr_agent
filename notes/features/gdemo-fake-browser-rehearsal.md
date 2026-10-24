# Full Fake-browser rehearsal: proposed plan r1

Status: plan PASS with binding amendments below; incomplete RED authoring only. GREEN still requires the independently verified RED gate and explicit approval. Original Oct 19 owner direction: finish G-DEMO attempt 2 manually that day; prepare this and D-168 before the next owner session. No owner-session procedure change is implied by this harness work.

## Summary

Extend the existing attested disposable-browser smoke to rehearse synthetic settings, budget-form interactions, assignment and draft/capture, without ever driving the owner app, database or browser profile. It is UI/workflow evidence, not a real-model G-DEMO acceptance run.

## Entity Model

Entity Model trigger: no.
Reason: test-harness and test-launcher changes only; no application resource, persisted attribute, business action, authorization policy, production lifecycle or public endpoint contract changes. Use existing domain/UI actions against disposable fixtures. If a new backend test endpoint/attestation contract or production seam becomes necessary, stop and submit that delta before continuing.

## Evidence and current gaps

Read-only base: `c302-refresh` at `425d7c9`, serving code identical to today's approved `9d1c1705` pin.

- `bin/demo --test` targets `sdr_agent_test<partition>_demo`; default smoke port is 4122. Its environment/Repo checks precede the requested operation. The rehearsal must never call its dev mode.
- `Mix.Tasks.Sdr.Demo.Serve` is test-only, refuses 4120, uses a small ordinary pool, starts queues without cron, and binds a fresh nonce/file to the smoke server.
- `test/browser/golden_path_smoke.mjs` checks loopback, refuses 4120 and verifies the launcher nonce/database before Chrome or sign-in. It uses an isolated temporary Chrome profile and existing CDP support, not a new browser framework.
- That script currently signs in as reviewer, assigns fixture lead 01 and approves/captures or checks quiet-hour deferral. It does not set up the offering profile or exercise the admin budget editor. Those are missing coverage, not demonstrated successful behavior.
- Test runtime explicitly refuses `SDR_MODEL_PROVIDER=claude_cli`; the rehearsal will pin Fake and capture-only delivery and refuse configuration drift. Fake bypasses real invocation/witness/grant admission, so the real Opus runtime card and real-charge SQL cannot simply be asserted to PASS here.

## Affected harness files (proposed)

- `test/browser/golden_path_smoke.mjs`: retain the current default journey and all refusal guards; add an explicit rehearsal scenario for admin settings/budget workflow, then reviewer assignment/draft path. Factor shared CDP helpers only if necessary to avoid duplicate lifecycle code; no framework/dependency replacement.
- `bin/browser-rehearsal` (new proposed wrapper): fresh target identity, environment/tool checks, server ownership, bounded execution and receipts. No dev-mode option or arbitrary DB/URL argument.
- Existing `test/sdr_agent_web/smoke_attestation_test.exs` and a narrow wrapper test file: negative guard coverage before browser/Mix/DB mutation; scenario assertions are exercised by the full synthetic browser run.
- README/runbook: exact scope and known Fake-only exclusions. No owner procedure is silently rewritten.

## Steps

1. Pin the reviewed branch and canonical Nix toolchain; verify Node >=22 and the installed Chrome executable before mutation. Select port 4122 explicitly and refuse a collision; never change ports silently or touch 4120. Scrub DATABASE_URL, provider/CLI/witness variables and inherited partition selection; set MIX_ENV=test and Fake explicitly. Verify resolved Repo host/port/exact new test DB name and effective Fake/capture configuration before app start.
2. Generate a unique per-run partition ending in the existing `_demo` namespace and record it. Refuse if that exact DB already exists. Create/migrate/seed only this fresh disposable DB through the established test path; do not reset an existing DB or invoke a dev command. No test/run during today's freeze; claim the shared DB slot before any later Mix/DB execution.
3. Launch only the owned smoke server. Require matching local launcher file, fresh nonce, actual test DB and endpoint response before any browser interaction. Reject redirects, non-loopback targets, dev DB/port, stale/mismatched/missing attestations, and non-Fake/capture configuration. If an actual-serving-config proof needs a new endpoint field, return for entity/plan review rather than guessing or relaxing the guard.
4. In isolated Chrome, sign in as the synthetic admin. Exercise initial unset/default settings, exact P3 offering entry, review, save revision 1, and post-save readback. Exercise the budget editor's reviewed terms/allocation review/cancel/save path on a disposable synthetic grant, including preserved existing rows and a three-attempt b1 rehearsal row. Record exact displayed UTC conversion and revision. No implication that the grant funds Fake calls.
5. Sign out and use the synthetic reviewer journey: choose a qualifying Fake fixture lead, Assign once, await run and draft through LiveView, verify displayed binding and approve only the disposable capture. Assert capture or the existing exact quiet-hour deferral branch, never a generic pending-delivery fallback. Assert no real CLI invocation, witness-store use or real delivery occurred. Keep the original golden-path mode covered; do not weaken it to hide missing settings.
6. Produce a bounded receipt: code/tree/tool/config IDs, DB/port, steps passed/failed, exit status, timestamps and synthetic screenshots if useful; never fixture passwords or credentials. Use one deadline and owned-process cleanup with confirmed exit. Keep evidence and report cleanup uncertainty as failure; no broad kill/pgrep or fallback signals. Never force-drop a DB. Retain the disposable target on failure for diagnosis; any later removal resolves and validates this exact run-owned target and absence of connections first.
7. Run hermetic guard RED/verify/GREEN, focused regression tests, the browser rehearsal and repository precommit/full gate under the existing review process. Obtain independent exact-head approval. Only then propose the next owner procedure, identifying which checks the rehearsal covers and which live-owner checks remain.

## Required tests

- Refuse dev/4120/non-loopback/redirected targets, wrong or stale nonce, wrong DB and absent launcher evidence before browser sign-in/mutation.
- Refuse non-test environment, DATABASE_URL, invalid/reused target name, occupied 4122, effective non-Fake provider or non-capture delivery before creation/launch; no fallback to owner environment/profile.
- Setup errors, malformed receipts, missing END/exit evidence, browser timeout and unknown server ownership fail closed and retain evidence. Cleanup only signals child processes proven to belong to this run and confirms exit.
- Browser assertions: settings round-trip and unchanged defaults; allocation old-row preservation and UTC/revision binding; assignment -> visible draft; exact approval -> capture or named quiet-hour deferral; no real model/store/delivery effects.
- At least a negative control for wrong-target binding and one for settings/budget round-trip assertions: removing the relevant protection must make the named test detect the wrong outcome, not merely fail setup.

## Risks and owner-session boundaries

- Test server runs queues: create only this run's synthetic DB and use the dedicated shared-slot window after today's session, not the live app's pool or checkout.
- Rehearsal does not prove real Opus health, CLI attestation, witness capture/reconciliation, real grant charging, no cleanup uncertainty or live-data provenance. Those remain live checks.
- Agents still cannot save settings or edit grants in the owner's app. Reduced owner time is a future procedure-design goal, not permission to skip live settings/lead review, authorization, runtime freshness, Assign or acceptance/thaw.
- The next session will find today's saved settings/possible third allocation, unlike r7's empty-settings/two-allocation prerequisites. It needs a newly reviewed procedure, not replay of r7 or reset/reseed/revoke to make old counts fit.

## ADR

No new ADR required for this test-only harness within the accepted S13 smoke boundary. No new browser framework, production authority or data boundary is proposed. D-168's distinct access boundary remains ADR-0016 and its owner-installed, reviewed aggregate interfaces.

## D-168 interface coordination (Claude author, Codex reviewer)

- Finish the owner-chosen TEMP/large-object revokes and HBA choices with shared-default impact review and throwaway adversarial tests; owner performs installation/ACL/HBA changes and supplies passing installed-state acceptance before agent connections.
- Existing `gdemo_drain_v1` is the old two-allocation pre/post contract, not today's three-allocation/four-phase attempt-2 query. Future agent drains require separately reviewed versioned functions matching the selected next procedure; include any needed run report, full input validation, bounded closed metadata output, pinned SQL/function hashes and refusal tests. Do not label v1 an attempt-2 substitute.
- No base-table SELECT, raw content, arbitrary SQL, app/dev-browser control or agent install authority. Until installed and accepted, live drain checks remain owner-run.

## Approval requested

Claude: PASS/amend this test-only plan and lane split before RED. No DB/browser run, new worktree/source edit or installation has been performed by this planning turn.

## Approval and binding amendments

Claude PASS: `m_1792434256196647000_6b64b527` (2026-10-19), correlated to `m_1792434194878701458_5c214329`. Reviewed private r1 SHA256 `a42808448f900c8fc3e904c91ad8d6d143290dc0bdfcbb95cc8b628308cfc36a`.

- A1: P3 values have one checked-in synthetic fixture, `test/fixtures/browser_rehearsal_offering.json`, SHA256 `9c34818ba69acd6818cd5e4c206a401b93fc405af5fc1f9b83efc75f6110adaf`; the rehearsal receipt records its SHA256. Its values match the reviewed owner procedure P3 table. The fixture is test input, not a production settings seed or a dev write.
- A2: run-owned DB cleanup uses the reviewed non-forced path and `Mix.Tasks.Sdr.Demo.Clients.count/2` (#202). Any blocking/nonzero/unknown count retains the database. Never force-drop, reset a reused target, or kill another connection to make cleanup succeed.
- Unsafe caller inputs are refused before external commands; only after those checks may the wrapper clear unused inherited provider/witness configuration and choose its own new test partition.

## Implementation checkpoint

2026-10-19: RED authoring only. Dedicated branch/worktree based on `9d1c1705`. No tests executed, no DB slot claimed, no browser/server/model launched. First authoring slice covers wrapper refusals before external execution and the single P3 fixture. Further effective-config, attestation, lifecycle and full-browser cases remain required; this is not a completed RED gate. GREEN requires explicit post-RED confirmation. Current live owner session must end before Mix/DB/browser verification.

Static continuation: refusal inventory also covers forced cleanup/reused-target flags, path traversal, shell syntax in a caller partition, and a URL in PORT. These are authored assertions, not observed behavior. The wrapper is deliberately absent; disclose its structural guard rather than calling these behavioral RED failures. No application or endpoint changes have been made. DB-free compilation is allowed during the freeze; tests, precommit, server/browser launch and DB commands are not.

## Oct 24 protected build block: refusal-harness slice

The Oct 19 freeze paragraph above records the earlier authoring session, not a fresh execution grant. The D-199 scoped recovery release does not revive any old runtime ACK. This continuation remains test-only, with no DB/browser/server or application start; ordinary Mix test/full-gate execution still needs separate coordination.

- The 18 unsafe-input cases remain structural RED while `bin/browser-rehearsal` is absent. Their shared presence assertion explicitly says no behavior was exercised.
- Ten `:rehearsal_harness` controls comprise the pinned P3 fixture, one accepted exact refusal, four refusal-output/status mutations, three early-call mutations (PATH Mix, repository-relative demo, CHROME override), and a child-environment check. These validate the test oracle, not the missing wrapper.
- Candidate scripts are copied into individual temporary fixture roots. PATH contains recording stubs plus only the basename/dirname path utilities; it no longer falls through to the caller's real tools. Repository-local demo/CLI helpers and CHROME are stubs. Shell startup hooks are removed for the child. This is controlled test isolation, not an OS sandbox or a claim that arbitrary absolute commands/network syscalls are contained.
- The standalone check loads this test module and pinned Jason only, without Mix, `test_helper.exs`, the app, Repo, or a service. Normal `mix test` is not a DB-free substitute: its alias invokes `ash.setup`. The repository test/TDD scripts therefore remain unrun for this partial slice.
- Standalone Elixir formatting and `git diff --check` pass. Under the canonical Nix Elixir 1.20.4 / OTP 29.0.5 environment, `Code.require_file` with `ExUnit.start(autorun: false)` registers exactly 10 harness controls and 18 structural RED cases with zero compilation diagnostics; no test bodies ran. This is a scoped test-module check, not `mix compile`, the project formatter/plugins, Credo, or a full gate. Shell entry still prints the pre-existing `mix hex.info | head` EPIPE diagnostic; the separate formatting/compile checks exit 0.
- First narrow execution was ACKed in `m_1792860724564470000_9d606926` and produced 2/28 passing: 18 structural failures plus 8 harness failures. Seven controls compared ExUnit's rendered exception message rather than its exact raw `message` field; the child-environment control incorrectly equated PATH with the textual PWD spelling. Original source `c66197942028e4c66001ac9ecf78cc7304e3775296a4a9b698b31ff6e6dea3cf` and raw log `574ad875c6f4fd7c039668f005440ff9d5d082c207c332c0e298802b200fa6d4` are preserved, not replaced by the corrected run.
- Corrected only those controls: retain exact diagnostic equality using `error.message`; compare PATH/CHROME to the explicit fixture-root spelling and separately require inode-equivalent PWD/root. The 18 refusal cases and their expected assertions are unchanged. Correction diff SHA256: `aa1e0f2ad13148e2e238380668748c2513aaeb6a3d1eb2447599aedabd270979`. Claude will independently review the delta for weakening at 13:00 MDT; the execution ACK is not RED approval.
- Repeat execution was separately ACKed in `m_1792860913399046000_e6a8ee64`, at test SHA256 `bd625926dbcac60fac3f8a14faacf31f759a9fa8f353df8cf2d539849529c81a`. It produced **10/28 passing, exactly 18 structural failures, exit 1**, zero test-module compile diagnostics, and the application-absence check passed before/after. No effective wrapper refusal behavior was exercised. Raw output: `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-rehearsal-partial-red-r2-20261024.log`, SHA256 `c8314b00795ebd57aef5bfe4f928b6aec61f2ae325bd1f7e1e6afd89427ad0cc`.
- Both checks used the unchanged private standalone runner `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-rehearsal-standalone-20261024.exs`, SHA256 `66cd707c0f5379ccdbb9452ad7de46e69fb17733884a644036f4975c0445dd71`. It reads Jason 1.4.5's ebin from the separate Codex-owned `c1-03-b-red` worktree, whose Jason lock entry matches; it does not modify that worktree. The test body starts only immediate shell controls/stubs, not real Mix, DB utilities, Chrome or providers. The outer Nix shell still runs its ordinary version/Hex entry commands. No DB slot was used.

Remaining RED authoring: effective Fake/capture and exact new-target preflight, occupied port/reused-target refusal, attestation mismatch/redirect/staleness, bounded run/receipt/owned cleanup failures, full settings/budget/reviewer browser assertions, and their required negative controls. No completed RED gate, GREEN approval, end-to-end rehearsal, owner installed-state acceptance, or full verification claim.

Architecture unchanged — test/fixture/plan files only; no diagram or entity-model update needed.
