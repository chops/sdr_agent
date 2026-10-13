# R0-07 readiness packet: profile-exact witness tuples, calibration, per-invocation result gate

Status: **entity-model PASS (Codex, round 4 at 1da747a).** It implements the
accepted ADR-0005 R0 amendment (PR #128, owner D-108) within G5-R0's scope.
Nothing here is implemented until Codex records an entity-model **PASS** on
section 2. No real model call happens until a tuple is promoted, and
calibration runs only under the accepted exception.

Story: R0-07 (#126). Depends on R0-02 (#131, merged), C9 records and
reservation admission (#130 and #132, merged), R0-03 profiles and C9-03
launch admission (in progress).

Code facts are from `main` at 7972019:

- **Allowlist.** The shipped allowlist (`config/config.exs`,
  `reconciled_methods`) holds one entry:
  `(claude_cli, 2.1.291, claude-message-json/3+prompt-builder/1, propagated_id)`.
- **Reconcile.** `Witness.reconcile/2` runs as `reconciler`. It observes the
  proxy store with no database locks held, then persists `WireWitnessLink`s
  under the invocation lock. It opens `reconciliation_required` Failures:
  critical on mismatch, warning otherwise.
- **Output is readable everywhere.** `ModelInvocation.parsed_output` is a
  public attribute, and the read policy allows any present actor.
- **Output consumers today.**
  - The `ModelProvider` return value, used by `SDR.Model` callers.
  - SDR replay (`sdr.ex:255`).
  - `Agents.Changes.DecisionRules` (decision `output_pointer`).
  - `Outreach.Changes.AssessmentRules`.
- **Test-only overrides.** Per-call method overrides exist only where
  `allow_method_override: true` (`config/test.exs`).
- **Isolated serving.** `bin/demo --test serve` serves the console from a
  separate throw-away test database.

Round 1 at e720fda was **NEEDS-REVIEW** (Codex). This revision answers its
five required items. OQ-1 now keeps the accepted isolated harness (section 3).

## 1. Requirements

| ID | Requirement |
|---|---|
| REQ-07-1 | **Exact allowlist entries.** An entry names exactly `(provider, cli_version, profile_id, model_id, projection_version, method)`, and nothing else. Only reviewed `config/*.exs` changes define entries.<br>• The existing 2.1.291 entry becomes `profile_id: nil, model_id: "claude-opus-5-5"` and matches only generation-1 rows.<br>• There is no shipped `:calibration` stage. Promotion is a reviewed config PR that cites Codex's evidence PASS; the app never promotes. |
| REQ-07-2 | **Admission before spend.** Every real call is refused before reservation, and again at launch (`admit_launch`), unless the **result gate is active**, which means all three of these hold:<br>• the compiled gate mode is `:enforced` (it is in every build);<br>• the witness store root is trusted;<br>• the invocation's exact tuple is on the shipped allowlist.<br>On refusal nothing is reserved, charged or sent. The refusal is recorded through the #132 receipt path with new reasons (section 2), and the run stops as `:model_not_admitted`. |
| REQ-07-3 | **Calibration runs only in the isolated harness.**<br>• It runs only in a test-environment build (`:claude_cli_test_seams`), through the external calibration harness, against the isolated calibration database.<br>• It uses a test-only exact override for the candidate tuple, set by the harness, plus a `CalibrationContext` marker that exists only in test-seam builds.<br>• The prompt and schema are fixed and server-owned.<br>• It is charged to the single owner-created G-R0 in that database: two `:proof` attempts per profile.<br>• A `:proof` usage origin alone authorizes nothing. No production entry point can create a `:proof` run.<br>• Results are never released to a business read. |
| REQ-07-4 | **Result gate.**<br>• **The wait.** After a call's response is validated and stored, the facade reconciles that invocation in-process. No lock is held while it waits for the capture. The wait is bounded (default 120 s; configuration may only lower it) and cancellation-safe.<br>• **Release.** Only a reconciled primary link for this invocation, re-validated under lock, releases the output.<br>• **Withholding.** A mismatch, missing capture, timeout or unreadable store withholds it. The run stops (section 2), the charged attempt and evidence are kept, and nothing is retried automatically. |
| REQ-07-5 | **Release record and read gate.**<br>• **The record.** One immutable `ModelResultRelease` per completed generation-2 `claude_cli` invocation, written once after the terminal outcome. The invocation is never updated for it.<br>• **The read gate.** `parsed_output` of such an invocation is readable only:<br>&nbsp;&nbsp;– through the released-output read, which requires disposition `:released`;<br>&nbsp;&nbsp;– through the witness evidence seam (reconciler, auditor, the calibration harness).<br>• **Everything else is withheld.** Generic resource reads, domain list and detail APIs, and kernel-context business reads see the field as withheld. |
| REQ-07-6 | **Crash recovery.** A completed generation-2 invocation with no release after a crash yields no business output.<br>• The scan never creates or changes a release.<br>• Run recovery (`StaleRunSweeper`) writes a withheld release with reason `:gate_interrupted` and stops the run as `:witness_unreconciled`.<br>• No model call is repeated. |
| REQ-07-7 | **Durable calibration order.** A calibration attempt is admitted only if every earlier calibration invocation in that database has its `ModelResultRelease` (`:calibration`) with an `evidence_sha256`. A file alone is not authority. If the captured grammar does not fit a reviewed projection, work stops and is reported; more attempts need a new owner grant. |

## 2. Entity model

Entity Model trigger: **yes**. The changes:

- a new persisted resource (`ModelResultRelease`);
- a field-read boundary on `ModelInvocation.parsed_output`;
- new AgentRun stop reasons with receipt arguments;
- new admission refusal reasons;
- a new Failure provenance contract for gate causes;
- a test-only calibration context;
- a changed allowlist contract.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Witness allowlist entry (config) | Existing (delta) | Exact tuples that may reconcile | `provider`, `cli_version`, `profile_id` (nil only for generation 1), `model_id`, `projection_version`, `method` | Matched against the invocation's recorded identity **and** the projection and method actually evaluated for the exchange | `exact_entry?` requires all six keys. Test env ships an empty list plus test-only overrides. No stage key. | n/a (code) | none |
| ModelResultRelease | New | The immutable release decision for one completed output | `id : uuid_v7`; `tenant_id`; `model_invocation_id : uuid, not nil, unique`; `disposition : :released \| :withheld \| :calibration`; `reason`; `wire_witness_link_id : uuid, nullable`; `projection_version`, `method : nullable`; `evidence_sha256 : string, nullable`; `decided_at : utc_datetime_usec, not nil`; `trace_id`, `span_id : not nil` | belongs_to Tenant; belongs_to ModelInvocation (restrict; composite FK `(model_invocation_id, tenant_id)`); belongs_to WireWitnessLink (optional, restrict; composite FK `(wire_witness_link_id, model_invocation_id)` → links `(id, model_invocation_id)`, so the link must be this invocation's) | **Allowed pairs:**<br>• `:released` ↔ `:reconciled`, with a link that is non-null, reconciled, the current primary at decision time, and whose evidence identity equals the invocation's identity and an allowlist entry;<br>• `:withheld` ↔ one of `:witness_mismatch`, `:witness_missing`, `:witness_timeout`, `:store_unreadable`, `:gate_interrupted`;<br>• `:calibration` ↔ `:calibration`: a quarantined evidence latch, never an output release. It is allowed only under `CalibrationContext`, for a calibration invocation in **any** terminal status (completed valid or invalid, failed, unknown), with `evidence_sha256` non-null. It records the captured evidence, or an empty capture, and keeps the attempt charged.<br>**`:released` and `:withheld` require** the invocation to be generation 2, `claude_cli` and `completed`; `:released` additionally requires `validation_status :valid`.<br>**Append-only:** a trigger rejects update and delete.<br>**Duplicate decide:** an identical replay returns the existing row; a conflicting one is refused.<br>**Later supersession:** a link superseded after release leaves the release as the historical decision. A later mismatch opens the existing sticky critical attention, but does not retract an output already used. | `:decide`: `agent_runtime` only, from the facade gate step and run recovery; `:calibration` only with `CalibrationContext`. Reads: admin, auditor, `agent_runtime`, `reconciler`, `auditor_cli`. Audited `model.result.released \| withheld \| calibration`. | none |
| ModelInvocation | Existing (delta) | — | `parsed_output` gets a field policy | — | For generation-2 `claude_cli` rows, `parsed_output` is readable only (a) by the released-output read (`Agents.released_output/2`, which requires a `:released` release), (b) by `reconciler` and `auditor_cli`, and auditors through the existing audited content read, or (c) under `CalibrationContext` in the harness. Every other read returns the field as forbidden. That includes generic Ash reads, domain list and detail APIs, kernel-context business reads, admins and agent_runtime. Generation-1 and Fake rows are unchanged. | Field policy (Ash) plus `released_output/2` | none |
| AgentRun | Existing (delta) | — | `status_reason` gains `:witness_mismatch`, `:witness_unreconciled` and `:model_not_admitted`, all with status `failed` | — | **Gate reasons.** `:fail` with `:witness_mismatch` or `:witness_unreconciled` takes `witness_failure_id` and `release_id`, required with these reasons and refused with any other. Validated: the release is `:withheld` for an invocation of this run with the matching reason; the Failure is the gate Failure for that invocation (next row).<br>**Admission reason.** `:model_not_admitted` (admission refusals in REQ-07-2) reuses #132's `refusal_failure_id` and `refusal_request_id` receipt, under the "unavailable" category.<br>**Resolved cause.** If the cause is resolved before the stop, it remains the run's historical cause and no crash is recorded (as in #132). | Existing actors | none |
| Operations.Failure | Existing (delta) | Gate causes and their ownership | No new columns.<br>**The gate cause** is exactly one live `reconciliation_required` Failure with subject = the generation-2 invocation **and** `operation_id` = that invocation's run's Operation:<br>• mismatch → critical;<br>• missing, timeout, unreadable store, interrupted → warning.<br>**Who opens it:**<br>• in the gate path, reconcile's own `Witness.open/4` sets `operation_id` (changed contract, next row), so a mismatch has one live item, not two;<br>• for timeout and interrupted, the gate opens it, deduplicated on (invocation, reason) under the head.<br>**Admission refusals** use the #132 path with class `provider_error` and the new reasons. | subject = invocation; `operation_id` = run's Operation (FK) | **The exact-receipt validator** (the #132 one, generalized) accepts three categories, each with its own provenance:<br>• budget refusal: #132 unchanged;<br>• admission refusal: `provider_error` and `model_not_admitted` reasons, the same refusal event and request id;<br>• witness gate: `reconciliation_required`, with a `ModelResultRelease :withheld` for an invocation of this run whose reason matches, the Failure's subject being that invocation and its `operation_id` the run's Operation.<br>An arbitrary `reconciliation_required` Failure is refused. A Failure opened by the backfill scan for an invocation outside the gate path carries no `operation_id` and is witness attention only, never a run cause. **Resolution race:** as in #132. | Existing open/ack/resolve policy | none |
| Witness reconciliation (`Witness.reconcile/2`, `open/4`) | Existing (delta) | — | Optional `gate:` option, passed only by the facade gate step and run recovery: `%{run_id, operation_id}` | — | With `gate:`, the Failure it opens carries `operation_id`. Lock order inside its persist step becomes: Operation `FOR SHARE` (only with `gate:`), invocation `FOR UPDATE`, chain head. This is compatible with Operation writers (Operation `FOR UPDATE`, then head) and with reservation and launch (they never lock an Operation after the head). Without `gate:` (the scan), behaviour is unchanged. | `reconciler` only, as today | none |
| Operations.Operation | Existing (delta) | — | No new attributes | — | `Operation :fail` is unchanged: it accepts a live cause whose `operation_id` matches. What changes is the worker: its witness-stop classification maps `:witness_mismatch` and `:witness_unreconciled` to failing the Operation with the gate cause (live), or with its own Failure naming the resolved cause (the #132 race rule). There is no generic provider-error fallback for these reasons. | Existing | none |
| Admission (contract) | Existing (delta) | — | New refusal reasons: `:result_gate_inactive`, `:tuple_not_promoted`, `:witness_store_untrusted`, `:calibration_not_authorized`, `:calibration_evidence_pending` | — | Checked inside reservation admission after the existing locks and the admission instant, and again in `admit_launch`. Recorded through the #132 receipt. | unchanged | none |
| CalibrationContext | New (test-seam builds only) | The only calibration authority | A changeset context marker plus the profile id | Set only by the external calibration harness module, compiled only with `:claude_cli_test_seams` | Requires the single G-R0 `:proof` allocation for that profile, the test-only exact tuple override, the fixed server-owned prompt and schema, and REQ-07-7 order. Never present in dev or prod builds. | Harness runs as `agent_runtime`; G-R0 created by the owner (human admin) in that database | none |
| Tenant, Accounts.User, WireWitnessLink | Existing | — | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (WireWitnessLink gains only an inbound optional composite reference) | — | — |

### Commit and lock boundaries (counting implicit audit and FK locks)

Every audited insert or update appends under the chain head, and every FK
check takes `FOR KEY SHARE` on its target. So each transaction below locks
all its dependent rows **before** its first audited write.

1. **Complete** the invocation as today (its own transaction), then commit.
2. **Reconcile** (`Witness.reconcile/2`, REC, with `gate:`). Observation holds
   no locks. Its persist step locks the Operation `FOR SHARE`, then the
   invocation `FOR UPDATE`, then the head, then writes links and, if needed,
   the gate cause with `operation_id`. Then it commits. It returns a receipt
   naming the link it evaluated and the gate cause it opened or found (its
   Failure id). The facade waits for this, bounded, with no lock of its own
   held.
3. **Finalize** in one transaction, in this order:
   1. run `FOR UPDATE`;
   2. the run's Operation `FOR SHARE`;
   3. invocation `FOR SHARE`;
   4. the current primary link `FOR SHARE`, re-validated;
   5. the **exact selected gate cause** `FOR UPDATE`, live or already
      resolved. It is identified by the receipt that reconcile returns to
      the facade (its Failure id) and carried into finalization, never by a
      live or newest lookup. A cause created later in this transaction,
      under the head, is already owned by it;
   6. the chain head, explicitly;
   7. then, all under the head with every dependent row already locked: the
      dedupe check and insert of a timeout or interrupted cause (its FKs find
      the Operation and invocation already locked), the release insert, and
      for a withheld outcome, the run stop with its receipt (its validator
      re-reads the cause already held `FOR UPDATE`).

   No row lock is requested after the head.
4. **Fail the Operation** later, in the worker's existing transaction
   (Operation `FOR UPDATE`, then the cause, then head), as in #132.
5. **Return** the output only after step 3 commits with `:released`.

**Crash recovery.** A crash after 1 and before 3 commits leaves a completed
invocation with no release. That is no business output (REQ-07-5).
`StaleRunSweeper` performs steps 2 and 3 with reason `:gate_interrupted`, and
step 2 only if nothing has been persisted. A crash after 3 is the existing
#132 recovery.

**Backfill after a withheld result.** If the scan later reconciles a
withheld invocation, the release stays `:withheld`, the run stays stopped,
and no output is released. The gate cause stays live, and the scan never
resolves it. The scan appends a note that wire evidence now matches. The
owner's remaining action is an explicit, budget-counted re-run, or resolving
the cause with a note. It is shown as a Home row through C1.

## 3. Calibration setup (OQ-1, resolved to the accepted harness)

Calibration uses the accepted isolated harness, so no ADR change is needed:

- **The calibration instance.** It is a dedicated, persistent database,
  `sdr_agent_calibration`, served for the owner's admin form by a new
  reviewed entry point, `bin/calibration-console`. That entry point is part
  of R0-07's implementation and review. It does not reuse `bin/demo` or
  `Mix.Tasks.Sdr.Demo.Serve`, whose guards correctly accept only the
  `sdr_agent_test…_demo` smoke database. It:
  - runs the test-seam build against exactly that database (refusing any
    other);
  - listens on loopback only, on its own port 4124, which is not the demo
    port 4120 or the smoke port 4122;
  - has no reset, drop or seed path except a one-time create-if-absent with
    migrations;
  - starts no model server, makes no model call, and offers only the admin
    sign-in and budget pages.

  The owner bootstraps their own admin account in it with the existing
  first-admin bootstrap.
- **The owner's grant.** The owner signs in to that instance and creates the
  **single authoritative G-R0** there through the reviewed admin form: four
  attempts, two `:proof` per profile, expiry 2026-10-19 05:59 UTC. No other
  G-R0 is created anywhere. The main app gets only G-DEMO.
- **No resets.** The calibration database is a fixed, named database
  (`sdr_agent_calibration`), separate from every `MIX_TEST_PARTITION`, CI and
  smoke database.
  - `bin/demo --test reset` and ordinary test setup refuse to drop or reset
    it, and it is never auto-created by tests.
  - It lives until the owner decides otherwise, after promotion and review.
  - It is not a throw-away database: it holds the real-call ledger and the
    G-R0 grant.
- **Running the harness.** The owner then runs the external calibration
  harness (an owner-run command, one profile at a time). It binds to that
  G-R0 and refuses if the grant is missing, revoked, expired or exhausted.
- **Evidence.** It writes the quarantined evidence (`docs/audit/r0-calibration-
  <profile>-<n>.json`, synthetic and metadata-only) and the `:calibration`
  latch with its `evidence_sha256`, whatever the outcome. A failed, invalid
  or unknown calibration call still gets its latch (with the empty or
  partial capture), stays charged, and is never released.
- **When an attempt is still running.** A calibration invocation still
  `reserved` or `sent` blocks the next attempt until recovery makes it
  terminal (unknown). The harness then records its latch. A later
  owner-authorized grant continues from there; the latch never blocks
  forever.
- **Review and promotion.** Codex reviews the evidence. On PASS, a separate
  config PR adds the exact tuple.

## 4. Test plan (RED first, synthetic, no real calls)

- **Allowlist:** six-key exactness; Sonnet never matches Opus; the
  generation-1 entry matches only profile-nil rows.
- **Admission:**
  - Every refusal reason, before reservation (no rows) and at launch, each
    mapped to `:model_not_admitted` with one Failure.
  - A forged `:proof` run without `CalibrationContext` is refused.
  - Calibration is refused when evidence is pending (durable check) or the
    allocation is exhausted.
- **Read gate:**
  - An unreleased generation-2 `parsed_output` is forbidden through generic
    Ash reads, domain list and detail APIs, and kernel context.
  - Replay, DecisionRules and AssessmentRules refuse with
    `:result_not_released`.
  - Reconciler and auditor evidence reads succeed.
  - `released_output/2` returns the output only when released.
- **Release record:**
  - Every invalid disposition/reason pair is refused.
  - A link from another invocation or tenant is refused (composite FK and
    validation).
  - A superseded link is refused at decision time.
  - An invalid-schema completion cannot be released.
  - The trigger blocks update and delete.
  - Identical replay versus conflicting duplicate; concurrent decide.
- **Gate (fake CLI with a stand-in proxy store):**
  - reconciled → released;
  - mismatch, missing, timeout and unreadable → withheld, the exact run stop
    and one cause, attempt still charged, no new call;
  - no lock held during the wait (a concurrent reservation proceeds);
  - resolution race, including a cause resolved before finalization: it is
    locked before the head, the run stops on it, no crash is recorded, and a
    held-lock regression covers it.
- **Calibration console:** `bin/calibration-console` refuses any database
  but `sdr_agent_calibration`, binds loopback 4124, has no reset or drop
  path, and starts no model server.
- **Crash:** completed with no release → the sweeper writes
  `:gate_interrupted`, stops the run, and no model call follows.
- **Calibration harness (test seams):** binds to the single G-R0; refuses
  missing, revoked, expired or exhausted; never released.
- **Gate:** `bin/verify`, credo and codegen check.

## 5. Slice A deltas (round 5)

Slice A is the exact allowlist, `ModelResultRelease` and the
`parsed_output` read gate (draft PR #139, code at 0116281). Its ten
deviations from the round-4 PASS went to Codex. The verdict was
**NEEDS-REVIEW** (report sha256 165c1840, on submission sha256 f18bfe62).
This section records those decisions and models the four contracts the
verdict left open: (a) to (d). It also covers item 7 and the G2/G3 notes.
Nothing here is implemented until Codex records a PASS on it.

**Slice A is a staged foundation, not the full gate.**
- Ordinary real calls stay refused (`:real_model_staged`).
- Slice C must land before enablement. It owns the facade's in-process
  return, typed stopping and recovery, and finalization.
- The current `:crash` stop of a fake-CLI generation-2 run (its unreleased
  output is refused at the Decision) is temporary staging behaviour. It is
  not the accepted final classification.
- Real calibration waits for the reviewed harness (slice D) and the
  owner's G-R0.

### 5.1 Decisions on the slice A deviations

| Item | Codex decision | Recorded boundary |
|---|---|---|
| 1. Integrity read of gated output | Accept, narrow | Contract (b) below. |
| 2. Kernel reads of releases | Accept | Kernel reads are tenant-scoped metadata and integrity reads only. The kernel gets no ordinary output-read bypass: a plain kernel read of `parsed_output` stays masked. |
| 3. `:released` needs the whole invocation reconciled | Accept | Defensive tightening: any unknown, unclassified or ambiguous current evidence blocks the **first** release. A historical release is never revoked or rewritten when later evidence changes. |
| 4. A supplied link must be current | Accept, for a first decision | **Identical replay** (same disposition, reason, link and `evidence_sha256`) returns the existing immutable row and appends no event. This holds even if its link has since been superseded: a past decision is never relitigated. A new or conflicting decision still validates binding and currentness, and a conflict fails with `ReleaseConflict`. |
| 5. Projection and method come from the link | Accept | They are copied from the evaluated, immutable link. The caller can never choose them. |
| 6. Proof runs are never released; a missing calibration context is Invalid | Accept | **Forbidden vs Invalid:** a wrong principal (anyone but AGT; an auditor's attempt is audited) is `Forbidden`. An authorized AGT whose calibration preconditions fail (context missing or for another profile, not a proof run, no evidence) gets `Invalid`, with no release and no event. A `:proof` origin alone authorizes nothing. |
| 7. Model and profile evidence keys omitted | Needs revision | Keep the ADR-0005 keys; the delta is below. |
| 8. Bare-atom test override | Accept, for hermetic legacy fixtures only | Contract (c) below: the calibration harness uses exact six-key overrides. |
| 9. Minimal `CalibrationContext` in slice A | Accept, as a staged foundation only | Contract (c) below. |
| 10. Locked rows passed from finalization | Accept the direction | Contract (d) below. |

### 5.2 Entity deltas

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| (a) AuditEvent payload of a gated ModelInvocation write (`AppendEvent`) | Existing (delta) | Keep unreleased model output out of the audit ledger, while the ledger stays verifiable | No new columns. Payload gains `output_commitment`: `{version: "sdr-output-commitment/1", canonicalization: "sdr-canonical-json/1", fields, validation_status, output_schema_id, output_schema_version}`. In `changes` (and in `previous` and `arguments`, if one ever lists such a field), each **output-bearing field** F is replaced by `F_sha256`. | Subject: the ModelInvocation, as today | **Scope:** every event whose stored subject row is generation 2 **and** `claude_cli`: reserved, sent, completed, failed (including invalid-output writes) and unknown. Gated-ness is read from the row's own metadata (`ledger_generation`, `provider`).<br>**Output-bearing fields:** `parsed_output`, `validation_errors` (its messages render the invalid value) and `refusal` (model-authored text).<br>**Commitment:** `F_sha256` is the lowercase hex SHA-256 of `Canonical.encode!(value)` under `sdr-canonical-json/1`. **Nil convention (PASS clarification 1):** when F is nil (or absent from the after-image being rewritten), the key `F_sha256` is still present, with the JSON `null` marker as its value. It is never the hash of the string `"null"`, and the key is never dropped. Every non-nil value, `[]` and `%{}` included, is hashed. The full-row `record_sha256` still covers the actual nil.<br>**What stays as is:** `record_sha256` is still over the full stored row, read through the integrity read (b). The verifier recomputes it unchanged. Schema refs and `validation_status` stay in plaintext. No plaintext copy may enter `changes`, `previous`, `arguments`, `redacted`, canonical event bytes or validation diagnostics.<br>**Unchanged:** generation-1 and Fake events; events already written (never re-encoded, `canonical_bytes` immutable); other resources' after-images (Decision and ReplyAssessment are written only from a released output).<br>A commitment proves equality with a value held elsewhere. It never reconstructs quarantined content offline. | Unchanged: kernel append only | Raw Payload and wire evidence stay readable only through the existing authorized, audited seams (`read_content`, `read_reconciliation_payloads`), never as a business-read fallback. |
| ModelInvocation output-bearing fields | Existing (delta) | Close the copy of output in the diagnostic fields | — | — | The `parsed_output` field policy (section 2 delta) extends to `validation_errors` and `refusal` on generation-2 ClaudeCLI rows, with the same readers (released-output read, REC, AUD, integrity read, scoped calibration read). `released_output/2` returns `parsed_output` only.<br>**Masked consumers (PASS clarification 5):** every existing UI or domain consumer of these fields handles `%Ash.ForbiddenField{}`. It never renders a forbidden value and never crashes. No business consumer reads the diagnostics except through the masked path. | Field policy | none |
| (b) Integrity reader (`Kernel.integrity_opts/1`, `Audit.Checks.IntegrityRead`) | New | Hash and verify the stored row without exposing withheld fields | Query context: the kernel marker **plus** the private integrity marker | — | **Who matches:** only a `:kernel` `SdrAgent.Actor` carrying both markers. A plain `Kernel.opts/1` read never matches, so kernel business reads stay masked.<br>**Callers:** exactly two seams — `AppendEvent` (re-reading a policy-masked record to hash the stored row) and `Audit.Verifier` (`record_sha256` check). An architecture test pins this caller set.<br>**What it emits:** nothing in plaintext. The caller gets the original masked record. Event payloads carry commitments (a). Verifier reports name issue types and ids only.<br>**Trust:** a trusted in-process convention, like `KernelContext`. It is not an unforgeable capability against arbitrary server code. | Kernel only | none |
| (c) CalibrationContext (`Agents.Checks.CalibrationContext`) | New (test-seam builds only; staged foundation) | Scope the calibration latch and read to one proof invocation | Marker: `{profile_id, model_invocation_id}` | — | **Builds:** the builder and its acceptance (`match?`, `profile/1`, the field-policy check) exist only with `:claude_cli_test_seams`. In every other build they answer "absent", even for a forged marker.<br>**Builder:** `context(profile_id, model_invocation_id)` refuses anything but a reviewed real profile (`ModelProfiles.real?/1`).<br>**Scope:** it authorizes the `:calibration` latch, and the calibration read of the output-bearing fields, only for the named invocation. That invocation must be generation 2, `claude_cli`, of that profile, and belong to a `:proof` run. It never covers every generation-2 row merely because a marker is present.<br>**Never launch authority:** the marker is no input to admission or `admit_launch`.<br>**Deferred to the harness (slice D):** G-R0 binding, the fixed server-owned prompt and schema, the REQ-07-7 order and real-call authority. | AGT only | none |
| Calibration witness override (item 8) | Existing (delta) | No inexact tuple in a spending path | — | — | `Witness.exact_overrides/1` accepts only exact six-key entries. It refuses a bare atom, a partial map or an extra key (`{:error, :inexact_override}`). The calibration harness must pass its candidate tuple through it.<br>The bare-atom per-call override stays for hermetic legacy fixtures only. Being a test build is never spend authority, and there is no production or config override. | Test seams only | none |
| (d) Prelocked decision context (`Agents.ReleaseDecision.Prelocked`) | New (private, transaction-scoped) | Let finalization decide the release without any fresh lock request after the chain head | Private struct: `{ref, tenant_id, model_invocation_id, wire_witness_link_id, receipt_id, xact_id}` | Binds one invocation, its optional link and the reconcile receipt (the selected gate cause's Failure id) | **Who establishes it:** only the owning finalizer, inside its open `Audit.transaction`, after it has taken every dependent lock (section 2, step 3, sub-steps 1–5) and **before** the head. Establishing records `pg_current_xact_id()` and registers `ref` in the calling process for that transaction.<br>**Accepted only when:** the call is in the same process and transaction (same `xact_id`), `ref` is registered, and every binding equals the **registered** context, not just the struct's copy. Those bindings are tenant, invocation, link and, where present, the selected receipt or cause id; decide checks the receipt against the gate cause the finalizer selected.<br>**Cleanup (PASS clarification 4):** the registration is removed when its transaction ends, by commit, rollback or process exit. A rolled-back inner transaction or savepoint never leaves a usable reference whose locks were lost; slice A checks this by re-validating `xact_id` and the live transaction on every use. Then decide reads its parents **without** a lock clause. Its FK checks find the rows already held.<br>**Refused:** a context outside its transaction, after the transaction, mismatched, forged (no registered `ref`) or a hand-built struct, with no write.<br>**No bypass:** there is no Boolean option, and no row or struct argument proves locks.<br>**Standalone decide** (no context) always locks invocation then link `FOR SHARE` before the head, then appends. It never silently takes the no-lock path. | AGT; finalizer (slice C) and run recovery | **Split:** slice A adds the context type, the decide-side checks and the standalone order. Slice C adds the finalizer half, which establishes the context, and the whole-finalization regression. |
| WireWitnessLink evidence (item 7) | Existing (delta) | Profile-exact evidence, as ADR-0005 R0 item 1 requires | Evidence allowlist gains `model_id` (text, at most 39 bytes, redactor-clean) and `profile_id` (one of the real profile ids) | — | **Gated parent (PASS clarification 3):** the predicate is generation 2 **and** `claude_cli`. New links of a gated parent carry both keys, validated equal to the immutable invocation's `model_id` and `profile_id` (`WitnessLineage`). `:released` re-checks that equality. Fake and other non-ClaudeCLI parents are never required to carry real-profile metadata.<br>**Generation 1:** keeps the legacy construction. Its links carry neither key and `profile_id` is refused, so there is no churn, mutation or backfill of existing links. A successor appears only through normal reconciliation lineage when the observation changes. | REC, as today | none |

### 5.3 Notes

- **G2, trusted code.** Field masking constrains reads that go through Ash
  authorization. It does not constrain arbitrary trusted server code: a
  code-level `Ash.Query.filter`, direct Repo access and similar trusted
  in-process code are outside it, like any trusted code. Input-annotated
  filters and sorts over the output-bearing fields are denied, and are
  tested. Every business consumer reads only through `released_output/2`.
  - **Aggregates are a trusted-code limit, not a denial (code review
    important 1).** Ash never applies field policies to the field an ad-hoc
    aggregate reads unless the call passes `authorize_fields?: true`. A
    default `Ash.aggregate(query, {name, :max, field: :refusal})` as AGT
    returns the unreleased value; with `authorize?: true, authorize_fields?:
    true` it returns nil. Slice A exposes no aggregate surface, so this is
    accepted for the staged foundation. Two structural guards are tested: no
    resource declares an aggregate or calculation reaching the
    output-bearing fields, and no application code runs a field aggregate.
    A test also documents the default and authorized aggregate behaviours.
    Before any aggregate surface over these fields is exposed, it must pass
    `authorize_fields?: true` and add protected-field regression tests.
- **G3, existing rows.**
  - A generation-2 ClaudeCLI output without a release defaults to withheld.
    There is no automatic release, backfill or history rewrite.
  - The premise "no real generation-2 rows exist" needs an owner metadata
    inventory before enablement, not reviewer reads of live data.
  - Any plaintext audit copies that do exist need an explicit owner
    handling decision. The prospective payload change (a) does not erase
    history.

### 5.4 Test plan for these deltas (RED first, synthetic)

- **(a) Canary:**
  - A unique canary string is placed only in an unreleased generation-2
    output: valid completed, invalid completed (diagnostics) and failed
    validation.
  - It is absent from every AuditEvent `payload` and `canonical_bytes`,
    from the **decoded** event after-images of an audit export (the signed
    wrapper, event bytes and payload encodings are decoded first; a search
    of the outer base64 bundle proves nothing), and from the generic, list
    and kernel reads of all three fields.
  - **Raw-evidence exception (PASS clarification 2):** the existing
    exporter deliberately includes audited raw response Payloads (through
    `Audit.read_content`, with an AuditAccess). An authorized evidence
    export may therefore contain the quarantined output. The test asserts
    and discloses this exception and its audit access, and it is never a
    business-read fallback. Removing raw evidence from full exports would
    need its own AuditExport/Payload delta and verdict; the exporter is
    not changed here.
  - `record_sha256` matches the full stored row, `verify_chain` is valid and
    the export verifies.
  - The commitment equals `sha256(Canonical.encode!(value))`, and nil gives
    `null`.
  - Generation-1 and Fake events keep plaintext after-images.
- **(b):**
  - A plain kernel read is masked; only the double-marked kernel read
    matches.
  - Verifier issues carry no field values.
  - The caller-set test fails if a third module calls `integrity_opts/1`.
- **(c):**
  - The builder refuses `:fake` and unknown profiles.
  - The context reads and latches only its named proof invocation; another
    generation-2 row under the same marker stays masked and refused.
  - `exact_overrides/1` refuses bare atoms, partial maps and extra keys.
- **(d):**
  - Forged, mismatched (tenant, invocation, link), outside-transaction and
    stale contexts are each refused, with no row and no event.
  - Standalone decide's query order: lock requests (`FOR SHARE`, then the
    head `FOR UPDATE`) and no lock request after the head, captured from
    Repo telemetry.
  - The prelocked path issues no lock clause at all.
  - Slice C adds the whole-finalization order regression.
- **Item 7:** a generation-2 link without the keys, or with values that
  differ from the invocation's, is refused; a generation-1 link is refused
  with `profile_id`; re-reconciling a generation-1 invocation writes no
  successor.
- **G2:** `filter_input` and `sort_input` over the output-bearing fields
  are denied (no row is selected, no order is derived). For aggregates,
  the structural guards hold, and a test documents both behaviours: the
  default leaks, `authorize_fields?: true` withholds (see 5.3).

## 6. Slice C deltas (round 6)

Slice C is the per-invocation result gate in the facade, the worker and run
recovery (section 2, "Commit and lock boundaries"). Before writing code
against them, the pre-code gap review found seven contracts the packet left
open. Codex's ruling was **NEEDS-REVIEW, narrow** (report sha256 ce1420a2,
reply to m_1791847186000021427_a461941f):
- accepted, with bounds: 1, 2, 6 and 7;
- revised: 3, 4 and 5.

This section records the ruling and the revised rows. Nothing that gaps 1–5
touch is implemented until Codex records a PASS on this section.

**Already built at 6897808 (outside gaps 1–5):**
- `Witness.reconcile/2`'s `gate:` option and receipt;
- the bounded, no-lock wait (`ResultGate.await/3`).

**Unchanged:**
- observation and the capture wait stay outside every lock;
- the 120-second hard ceiling and shorter configured values stand;
- no new model attempt, override or re-call is made.

### 6.1 Decisions

| Gap | Codex decision | Recorded contract |
|---|---|---|
| 1. Runs without an Operation (reply runs) | Accept: the cause is bound by the release event | Row G1 below. |
| 2. Outcomes for which reconcile opens no cause | Accept fail-closed cause creation, with truthful semantics | Row G2 below. |
| 3. The scan racing the gate | Revise: a scheduling-only skip is not enough | Revised row G3 below. |
| 4. The gate cause's lifetime under witness attention | Revise: an `operation_id` is not provenance | Revised row G4 below. |
| 5. Run recovery (`:gate_interrupted`) | Revise: one recovery selection rule, with no duplicate attention | Revised row G5 below. |
| 6. A lock-free run stop under the head | Accept, under the corrected verified Prelocked context only | Row G6 below. |
| 7. A decide refused inside the finalizer | Accept one bounded recovery attempt in a fresh transaction | Row G7 below. |

### 6.2 Entity and action rows

| Row | Entity / action | Delta | Invariants / lifecycle | Actor / locks | Tests (RED first) |
|---|---|---|---|---|---|
| G1 | ModelResultRelease `:decide` and its `model.result.withheld` event; AgentRun `:fail` gate stop | `:decide` gains an argument `gate_cause_id` (uuid, optional), recorded in the event payload's `arguments`. It is accepted only under a verified Prelocked context whose `receipt_id` equals it, and only for `:withheld`. | **With an Operation:** the stop's validator requires the cause's `operation_id` to equal the run's Operation exactly, as before.<br>**Without an Operation** (the run's `operation_id` is nil): the validator requires a `model.result.withheld` event of a withheld release for an invocation of this run whose recorded `gate_cause_id` is this Failure. It also requires the Failure's tenant, its subject (that invocation), its class (`reconciliation_required`), that the reason category matches, and that the run has no Operation.<br>No other null-Operation Failure can become a gate cause.<br>**Both branches:** the exact receipt cause is locked before the head, live or resolved; the #132 resolution-race semantics are kept. | AGT; the finalizer and run recovery | Forged or foreign `gate_cause_id`; null-Operation cause without the event; a resolved cause; both branches. |
| G2 | Gate outcome → withheld reason and cause | When the receipt names no usable cause, the finalizer opens one, deduplicated, under the head. Its FKs find the invocation and the Operation already locked. | **Reasons:**<br>• a mismatch dominates: `:witness_mismatch`, with reconcile's critical cause;<br>• the store disappeared or is unconfigured after spend: `:store_unreadable` (before spend it remains an admission refusal, slice B);<br>• the bound passed while the capture was still pending: `:witness_timeout`;<br>• any other non-reconciled outcome (inferred, `method_not_enabled`, ambiguous, unclassified, unsupported): `:witness_missing`. This reason means **no usable exact witness**, not that a file is absent.<br>**Typed classification:** the actual one is recorded as metadata only, as the withheld event's argument `gate_classification`, a reason code; that event is its authoritative record. A gate-opened cause's message names the reason only, so it deduplicates on (invocation, reason) (code review ruling 5). No content is recorded in either.<br>**Dedupe:** at most one live gate-opened cause per (invocation, reason). Its exact id is returned as the receipt for the stop.<br>No method override and no re-call. | AGT; under the head, every FK target already locked | One test per reason; mismatch dominance; the typed classification recorded; no duplicate cause on replay. |
| G3 (revised) | Scan ownership (`ScanWorker` and `Witness.reconcile/2` without `gate:`) | **Gate-owned** means a generation-2 ClaudeCLI invocation that is completed, has no ModelResultRelease, and whose run is `running`. | **Scheduling:** the scan does not schedule gate-owned invocations.<br>**Execution:** the reconciler rechecks ownership at its locked persistence boundary. That is after the invocation `FOR UPDATE` lock, reading the release and the run status without a lock clause. If the invocation is gate-owned, it returns `{:ok, %{status: :deferred_to_gate}}` and writes no link and no attention. This covers a queued job or a direct background call that outlives the prefilter.<br>**Why it holds:** the gate's own reconcile holds the invocation `FOR UPDATE`, and finalization holds it `FOR SHARE` while it writes the release and the stop. So the scan's persist step waits for either to commit, then sees their outcome.<br>**Unchanged:** generation-1 rows and backfill of released or withheld rows.<br>**Terminal run without a release** (for example, an operator cancelled during the wait) is not gate-owned. It is recovered by run recovery (G5, case R3), never by the scan. | REC; invocation `FOR UPDATE`, then plain reads | True-connection held-lock race: the gate holds the invocation while a scan reconcile runs; once it commits, the scan has written no link and no attention. A queued scan job running after the gate commits is backfill. Generation 1 is unchanged. |
| G4 (revised) | The gate cause's lifetime under witness attention (`Witness.attention`) | **Protected cause:** exactly the Failure named as `gate_cause_id` by a `model.result.withheld` event of the invocation's release. This includes null-Operation runs. Having an `operation_id` protects nothing by itself. | **Before the release:** the invocation is gate-owned (G3), so no scan touches its attention. The gate's own polls may supersede their own earlier pending items until the receipt is taken.<br>**After the release:**<br>• the scan never resolves the protected cause;<br>• it counts as the invocation's live warning, so no duplicate warning is opened;<br>• a later mismatch still opens its own critical (mismatch dominates, witness attention).<br>**Resolved causes:** an already-resolved cause stays resolved. The scan cannot resurrect it or alter the historical stop.<br>**Note:** a metadata-only audit event, `agents.witness.gate_evidence_changed`, appended by the kernel inside the scan's persist transaction:<br>• links: `model_invocation_id`, `agent_run_id`;<br>• payload: `release_id`, `cause_failure_id`, `previous_status`, `current_status` (C1 witness status codes) and the current link ids;<br>• emitted only when the invocation's C1 status differs from the last such note's `current_status` for that release (or from the release's decision status when there is none). Repeated scans therefore do not repeat it.<br>No content and no hidden copy of the model output. | REC; scan persist | Protected warning not resolved by a changed condition; no duplicate warning; mismatch critical still opens; a resolved cause is not reopened; the note is emitted once per status change and carries no content. |
| G5 (revised) | Run recovery (`StaleRunSweeper`) for a completed generation-2 invocation with no release | One selection rule, with no scan-semantic reconcile and no duplicate attention. | **Nothing persisted** means the invocation has no WireWitnessLink, no `reconciliation_required` Failure with this invocation as subject (live or resolved), and no release.<br>**R1, abandoned running run, nothing persisted:** recovery runs `Witness.reconcile/2` with `gate:` (the run's Operation, or nil), then selects:<br>• a mismatch: `:witness_mismatch` with reconcile's critical cause; known mismatch evidence is never turned into an innocuous warning;<br>• otherwise: `:gate_interrupted` with reconcile's cause, if it opened one, else a deduplicated interrupted warning opened under the head.<br>**R2, abandoned running run with links or a cause:** no reconcile. A current mismatch link gives `:witness_mismatch` with that invocation's critical cause; otherwise `:gate_interrupted` with the existing gate-capable warning of this invocation (G1 provenance), else a new deduplicated interrupted warning.<br>**R3, terminal run with a completed generation-2 invocation and no release:** the same selection, and a withheld release only; no run stop and no Operation change.<br>**R1 and R2 stop the run** (`:witness_mismatch` or `:witness_unreconciled`) through finalization, with the gate's lock order and Prelocked, then fail the Operation by the worker's rule.<br>**Always:**<br>• completed-without-release output stays withheld;<br>• no model call is made;<br>• this replaces the original single sentence "writes a withheld release with reason `:gate_interrupted`" for the mismatch case. | AGT; finalization lock order | Bounded true-connection tests: crash before reconcile (R1), crash after reconcile (R2), finalizer wins (recovery sees the release or a stopped run and skips), recovery wins (the late finalizer sees the release, G7), and R3. |
| G6 | AgentRun `:fail` gate stop, lock-free re-read | Under a verified Prelocked context whose invocation belongs to this run and whose receipt is the selected cause, the gate stop re-reads the run and that Failure **without** lock clauses. The finalizer already holds both, before the head. | **Ordinary `:fail` keeps its locks.** No caller Boolean, row-shaped object or generic `context:` skips them.<br>**Marker consumer contract:** the Prelocked marker (MF1 savepoint fix) must still be set, and the bindings and receipt must match.<br>**Implicit FK locks** of the stop's writes count, and find their targets already held. | AGT; finalizer only | The whole-finalization SQL order regression (no lock clause after the head except the head itself); the savepoint-lifetime regression from #139; the ordinary `:fail` still locks. |
| G7 | A decide refused inside the finalizer | The original transaction is fully rolled back first (Ash rolls it back with the changeset). Then **one** recovery attempt runs in a fresh transaction. | **Order:** the recovery reacquires every dependent lock in the finalization order and rereads the immutable release first.<br>**If a release now exists** (a competing finalizer committed one), it is respected. It is never overwritten, and no second cause is made.<br>**If no release exists:** it writes withheld `:gate_interrupted` plus the typed run stop, selecting the cause by G5's rule.<br>**Bounds:** no recursive or unbounded recovery. If the recovery is refused or the database fails, no business output is returned and the run remains recoverable by the sweeper. An unreleased output never becomes success or a gratuitous `:crash`. | AGT | A refused decide leads to the recovery; a competing committed release is respected; a second failure returns no output and leaves the run sweepable. |

### 6.3 Test plan additions (RED first, synthetic, no real calls)

- **G1:** forged or foreign `gate_cause_id`; a null-Operation cause without
  its event; a resolved cause; both branches (with and without an
  Operation).
- **G2:** one test per reason; mismatch dominance; the typed classification
  recorded; dedupe.
- **G3:** the held-lock race (true connection); a queued job after commit;
  generation 1 unchanged.
- **G4:** the protected cause is not resolved and not duplicated; a mismatch
  still opens; the note is emitted once per status change.
- **G5:** R1, R2 and R3; finalizer wins and recovery wins.
- **G6:** the whole-finalization SQL order regression; the savepoint
  regression; the ordinary `:fail` still locks.
- **G7:** recovery; a competing release; bounded failure.

### 6.4 Round 7: two narrow cases and implementation bounds

Codex's round-6 recheck at f31d61a was **NEEDS-REVIEW, two narrow
clarifications** (report sha256 2ee51092, reply to
m_1791848756000001078_e5faee73). G3, G4 and G5 are otherwise resolved, and
the G1, G2 and G6 bounds stand.

| Row | Entity / action | Delta | Invariants / lifecycle | Actor / locks | Tests (RED first) |
|---|---|---|---|---|---|
| R7-1 | ModelResultRelease `:decide` replay with `gate_cause_id` | `gate_cause_id` joins the replay identity. Its stored value is read from the existing release's immutable `model.result.withheld` event (`payload.arguments.gate_cause_id`). There is no new column. | **Identical replay:** the same disposition, reason, link and evidence **and** the same `gate_cause_id`, or both absent. It returns the existing row and appends no event.<br>**Typed conflict:** any other `gate_cause_id` — different, absent to present, or present to absent — is refused with `ReleaseConflict`, carrying the existing release id and its bound `existing_cause_id`.<br>Never an apparent success for a different receipt, and never a replacement binding.<br>**Concurrency:** concurrent decides with different causes serialise on the unique index; the loser gets the typed conflict. A finalizer that gets the conflict follows G7: it rereads the release and its authoritative receipt, and never claims its own. | AGT; finalizer and run recovery | Identical replay with no extra event; a different cause conflicts; absent to present and present to absent conflict; concurrent decides with different causes (true connection): exactly one row and one event, the loser conflicts. |
| R7-2 | G7 recovery, and G5's R2/R3 with an unusable mismatch cause | **G7 uses G5's selection.** `:witness_mismatch` with its critical cause whenever a current mismatch is known; `:gate_interrupted` only when none is. | **The critical cause for a known mismatch:**<br>• a correctly bound one (`operation_id` equal to the run's Operation; or, for a run without an Operation, bindable through the withheld event per G1) is locked before the head and used;<br>• if no live critical exists for the invocation, the recovery opens one, bound under the head with every FK target already locked (no duplicate, since none is live);<br>• if a live critical exists but is not usable for this run (another Operation, or a scan-opened critical without `operation_id` on a run that has an Operation), the recovery fails closed. It writes no release, no stop and no new cause. It returns `{:error, :mismatch_cause_unbound}` and no business output, leaving the recoverable state (run running, invocation completed, no release). That existing critical remains the owner's attention. Once the owner resolves it, the next recovery pass opens a bound critical (none is live) and completes.<br>The mismatch is never downgraded, and no receipt provenance is forged.<br>**If a recovery cannot commit for any other reason**, it returns no output and the state stays sweepable. One attempt only, never recursive. | AGT; finalization lock order | Bounded recovery tests: no live critical, so one is opened and bound and the run stops on the mismatch; an unusable scan or foreign critical gives the refusal, with nothing written and the run still running; after the owner resolves it, recovery completes; a run without an Operation binds the existing critical through the event. |

**Implementation bounds** (Codex, no further entity change):
- **G3:** the locked execution guard skips both pending running rows and
  terminal-without-release generation-2 rows. "Not gate-owned" never means
  writable by the scan. Race tests distinguish the gate's reconcile commit
  (still unreleased, so deferred) from the finalizer's commit (a release
  exists, so backfill is allowed). The unlocked run read claims no atomicity
  against cancellation; later ownership and finalization checks are
  authoritative.
- **G4:** a protected cause counts at its actual severity. A protected
  mismatch is critical and is not duplicated when the mismatch recurs. A
  resolved historical cause stays resolved, and an unchanged observation
  never recreates the same warning under a new id. A distinct later
  mismatch's attention is still allowed. Note status codes and the typed
  classification are a pinned, bounded code set; no raw string or output
  enters a cause message or event argument.
- **R1:** observation stays outside every row and head lock. Recovery
  rechecks job liveness and run state under its locks; the abandoned
  prefilter is never authority to fail a newly live job. R3 changes no
  terminal run or Operation.
- **G6 and G7:** G6 uses the rollback-aware marker from #139, and
  finalization holds every dependent row and FK target before the head;
  ordinary `:fail` keeps its locks. G7 is one fresh recovery transaction,
  never recursive, and an already committed release stays authoritative.

## 7. Slice B deltas (round 8, proposed)

Slice B is admission before spend (REQ-07-2, REQ-07-3, REQ-07-7, and the
Admission row of section 2). A pre-code read of `main` at 553b568 found five
contracts the packet leaves open. Each row below gives a recommended default
and the alternatives, for Codex to rule on. Nothing in this section is
implemented until Codex records a PASS on it.

**Stacking.** Slice B is **stacked on slice C**.
- Its branch is rebased onto `r0-07c-result-gate` once section 6 of that
  branch passes, the PR targets that branch, and it merges after slice C.
- The gate mode (B3) lives in slice C's `ResultGate`.
- Both slices add AgentRun stop reasons. Neither needs a migration
  (`status_reason` has no database check constraint), so the rebase stays
  mechanical.
- Stacked on slice C: this section follows slice C's section 6.

**Unchanged:**
- `:real_model_staged` still refuses every ordinary real call before
  admission. Slice B is testable beneath it only with the existing test
  seams (`test_launcher: true`, the Fake CLI). It enables no real call.
- The #132 reservation-refusal path (rollback, then a separate transaction
  that records the Failure and the event).
- The #136 identity and state refusals, and `run_not_running_at_launch`.

**Code facts at 553b568** (they motivate B1):
- `admit_launch/3` fails the reserved row and opens a `provider_error`
  Failure whose subject is the invocation. It then returns
  `{:error, atom}`, with no event.
- ClaudeCLI's `admit_launch/2` passes on only atom reasons.
- The facade re-reads the row, finds it terminal and returns the error.
- `SDR.Model` treats that error as a generic provider error, and AgentRun
  `:fail` opens a second Failure. This is the tracked prerequisite "Launch
  refusal opens two live Failures" in the readiness packet.
- In the test environment, `reconciled_methods` is `[]` and `store_root` is
  nil. The 29 test files that reserve generation-2 calls are all
  `async: false`.
- `Store.validate_root/1` makes one `lstat` per ancestor of the root and, on
  its first call, runs `id -u` as a subprocess.

### 7.1 Entity and action rows

| Row | Entity / action | Delta | Invariants / lifecycle | Actor / locks | Alternatives |
|---|---|---|---|---|---|
| B1 (Q1) | Launch refusal receipt: `Agents.admit_launch/3`, `Admission.Refused`, ClaudeCLI `admit_launch/2`, the `ModelProvider` facade, `SDR.Model.stop_refused/3`, `LinkRefusalAttention`, `AgentWorker.fail_operation/3` | **Lock order** (changed): run `FOR UPDATE` → the run's Operation `FOR SHARE` (if any) → invocation `FOR UPDATE` → grant `FOR SHARE` → allocation `FOR SHARE` → head. Taking the Operation before the head lets the launch Failure's FK find it already locked; no Operation lock is taken after the head.<br>**Refusal, recorded inside the launch transaction.** This covers every refusal of an owned `reserved` row, except `run_not_running_at_launch` (the eligibility checks, `legacy_invocation_without_grant`, `profile_mismatch_at_launch` and the five reasons of B5). In order, under the head:<br>1. fail the invocation, as today;<br>2. open **one** critical `provider_error` Failure. Its subject is **the run** (it was the invocation) and its `operation_id` is the run's Operation. Its detail names `model_invocation_id`, the reason and the check;<br>3. append `model.launch.refused`, with `agent_run_id`, `model_invocation_id`, `idempotency_key` set to the invocation's `idempotency_key` (the reserved request's id, the same as `SDR.Model`'s request id), and a payload of the reason, the check and `failure_id`.<br>Then it commits and returns `{:error, %Refused{reason, failure_id, event_id, agent_run_id, request_id}}`. `Refused` gains `stage: :reservation \| :launch`.<br>**The receipt's path:**<br>• ClaudeCLI `admit_launch/2` passes `%Refused{}` through unchanged. It holds metadata only.<br>• The server replies with it.<br>• The facade re-reads the row, finds it `failed`, and its existing terminal clause returns the error **with no write and no Failure**.<br>• `SDR.Model` stops the run from the receipt (`:fail`, `:model_not_admitted`). | **One Failure:** the row leaves `reserved` exactly once, under its own lock, so no dedupe is needed.<br>**The validator** (`LinkRefusalAttention`) checks three categories, each keyed by event type and reason set:<br>• reservation budget: #132, unchanged;<br>• reservation admission: `model.reservation.refused`, class `provider_error`, one of the five B5 reasons;<br>• launch: `model.launch.refused`, class `provider_error`, a launch reason, and the event's `model_invocation_id` an invocation of this run.<br>Every category also requires the Failure's tenant, its subject (the run), `operation_id` equal to the run's Operation (or none), and the event's `idempotency_key` and `failure_id`.<br>**Identity-refusal events** carry no `failure_id`, so they can never validate as a cause.<br>**AgentRun:** `:model_not_admitted` is a reason of `:fail` only (status `failed`). It requires the receipt arguments and is refused without them.<br>**Worker:** `:model_not_admitted` joins `@refused`. In the resolution race, the worker's own Failure naming the resolved cause has class `provider_error`.<br>**This closes the tracked prerequisite** "Launch refusal opens two live Failures"; its readiness row is marked closed when this is implemented. | AGT. Lock order: run → Operation → invocation → charge → head. It matches finalization (run → Operation → invocation, section 2 step 3) and the sweeper (run → Operation → job → invocations). Operation writers (Operation `FOR UPDATE` → Failure → head) never lock a run. | **Stop mapping (recommended):** every launch receipt stops the run as `:model_not_admitted`, with the cause in the event's reason and check. Alternative: grant-term launch refusals (`grant_ineligible_at_launch`) stop as `:grant_unavailable`, and only profile, legacy and B5 reasons as `:model_not_admitted`.<br>**Not recommended: rollback, then a separate transaction (the #132 style).** It leaves the row `reserved` between the two transactions, where the facade or the sweeper could fail it with a second Failure. It also needs a re-check that the row is still `reserved`, and a second lock pass. |
| B2 (Q2) | The pre-call tuple predicate (`Witness.promoted?/2`, new; called by admission) | The predicate holds for (profile, identity) when **some exact shipped entry** (`reconciled_methods/0`, never a test override) has all of these:<br>• `provider: :claude_cli`;<br>• `cli_version` = the profile's `cli_version`;<br>• `profile_id` = the profile;<br>• `model_id` = the profile's `resolved_model`;<br>• `method: :propagated_id`;<br>• a `projection_version` ending in `"+" <> ClaudeCLI.prompt_builder()` that is one of the versions `Witness` evaluates (v1, v2 or v3).<br>At reservation it checks the call's profile. At launch it checks the invocation's recorded `provider_version`, `model_id` and `profile_id`, after `profile_mismatch_at_launch` has passed. | **Fail-closed:** the test environment's allowlist is empty, so every call is refused by default.<br>**Slice C enforces the exact evaluated projection:** an exchange evaluated under a projection outside the allowlist is `method_not_enabled`, so it is withheld as `:witness_missing` (G2).<br>Admission therefore never admits a tuple that the gate could release under an unlisted projection. | Code only | Not recommended:<br>• a pinned `Projection.current/0` (the grammar is chosen from the observed request after the call, so a pinned value would be guessed);<br>• a five-key match that ignores the projection (weaker: any projection would admit). |
| B3 (Q3) | The result-gate mode (slice C's `SdrAgent.Agents.ResultGate`, stacked) | `@mode Application.compile_env(:sdr_agent, [ResultGate, :mode], :enforced)`, with `mode/0` and `active?/0` (true only for `:enforced`).<br>No `config/*.exs` file sets it. Any other value makes `active?/0` false, and every generation-2 real call is then refused `:result_gate_inactive`. | **Fail closed:** the mode can only refuse, never admit.<br>**A structural test** asserts that no config file sets the key and that the test build compiles `:enforced`.<br>**Testing `:result_gate_inactive`:**<br>• the refusal is a pure step, `Admission.gate_check/1`, unit-tested with an inactive gate;<br>• an integration test uses a refuse-only seam, compiled only with `:claude_cli_test_seams`, read from Application env so that it also reaches the ClaudeCLI server process, and restored on exit. It can set `active?/0` to false, never to true. | Code only | Not recommended:<br>• a recompiled `MIX_ENV` just for this test (costly);<br>• defining the mode in slice B (`ResultGate` would collide with slice C). |
| B4 (Q4) | Calibration admission authority (`Agents.Checks.CalibrationAdmission`, new; test-seam builds only) | **A separate marker**, `{profile_id, entry}`, passed to `reserve_model_invocation/3` as option `calibration:`.<br>• Its builder and acceptance are compiled only with `:claude_cli_test_seams`; in any other build the marker is absent.<br>• Slice D's harness is its only non-test caller.<br>• `CalibrationContext` is unchanged: it scopes the latch and the read, and it is never an admission input (contract (c)).<br>**It is accepted only when:**<br>• the run's `usage_origin` is `:proof`;<br>• `Witness.exact_overrides([entry])` passes;<br>• `entry.profile_id` is the call's profile;<br>• the entry satisfies B2's predicate for that profile, in place of the shipped allowlist.<br>**At launch** (ClaudeCLI passes no marker), authority is re-derived from durable state: the admitted entry is recorded as the argument `calibration_tuple` of the invocation's immutable `model.invocation.reserved` event. | **Refusals:**<br>• a `:proof` run without a valid marker, a marker on any other run, or an entry that fails the checks above: `:calibration_not_authorized`. So a forged `:proof` run is refused;<br>• **REQ-07-7 (durable):** under the head, every earlier ModelInvocation of a `:proof` run in the tenant, of any status, must have a `ModelResultRelease :calibration` with a non-null `evidence_sha256`. A `reserved` or `sent` one, or a terminal one with no latch, refuses `:calibration_evidence_pending`. At launch, "earlier" excludes the invocation itself. The head serialises concurrent calibration reservations.<br>**Allocation exhaustion** stays #132's `{:budget_exhausted, :allocation}` and stops the run `:exhaust_budget` / `:grant_exhausted`, not `:model_not_admitted`.<br>**Deferred to slice D:** G-R0 binding, and the fixed prompt and schema. | AGT; under the head, plain reads only | Alternatives:<br>• the harness passes the marker through the server request to `admit_launch` (a caller input at launch);<br>• slice B refuses every `:proof` run `:calibration_not_authorized` and leaves `:calibration_evidence_pending` to slice D (then REQ-07-7 has no test in B). |
| B5 (Q5) | Check order and store trust in admission | **Reservation**, after run → candidates → head and `now`:<br>1. the run counter and the daily limit (unchanged; no receipt);<br>2. `:no_usage_origin` (unchanged);<br>3. for `:proof` runs only: `:calibration_not_authorized`, then `:calibration_evidence_pending`;<br>4. `:result_gate_inactive`;<br>5. `:witness_store_untrusted`;<br>6. `:tuple_not_promoted` (for an authorized calibration call, against its entry);<br>7. the existing grant, allocation and room checks.<br>**Launch:** the identity and state refusals → `run_not_running_at_launch` → legacy → profile mismatch → steps 3–6 → the grant terms.<br>**Store trust:**<br>• before the first lock, `Store.validate_root(Witness.store_root())` runs the full filesystem check, plus the `id -u` read the first time;<br>• under the head, a pure check with no I/O: the root is still the one validated before the locks, and that check passed. Otherwise the call is refused `:witness_store_untrusted` (unset, untrusted or changed). The same applies at launch, before the run lock.<br>**This refines section 2's "after the existing locks":** the filesystem check moves before the locks, and only the pure re-check runs under them. | **Why the gate checks come before the grant checks:** they mean "this build or configuration may not spend", which no grant can fix. Reporting them first names the cause the owner can act on.<br>**Store changes after the check:** a filesystem change after the pre-lock check is caught after spend as slice C's `:store_unreadable` (G2).<br>**Tests:** no process-scoped config exists. Launch admission runs in the ClaudeCLI server process, so a process-dictionary override would not reach it. All 29 affected files are already `async: false`, so a shared helper costs no parallelism: `AdmissionFixtures.admit_tuples!/1` writes exact entries into `reconciled_methods` and a trusted temporary `store_root`, then restores both on exit (it extends `put_allowlist!/1`). It changes configuration and is not a caller input, so no ordinary-call admission seam exists (ADR-0005 R0 item 3). A structural test asserts that admission never reads `allow_method_override` or a per-call `methods:`. | AGT. No filesystem I/O or subprocess under the run or head locks. | Store trust, not recommended:<br>• a boot-time trusted flag (it misses changes after boot until after spend);<br>• `lstat` under the locks (filesystem I/O and a possible subprocess while holding the run and head locks).<br>Order alternative: the grant checks first, then steps 3–6. |

### 7.2 Test plan (RED first, synthetic, no real calls)

- **Before reservation:** each of the five reasons, with no invocation,
  payload or counter change. The run stops `:model_not_admitted` with
  exactly one Failure, linked by the receipt. The worker fails the
  Operation on that cause, and the resolution race is covered.
- **At launch:** each reason that applies at launch. The row is `failed`
  and never `sent`, with one Failure (subject the run) and one
  `model.launch.refused` event. The facade writes nothing more, and
  `SDR.Model` stops the run `:model_not_admitted`.
  - A regression test covers the two-Failure prerequisite.
  - A real-connection race test covers the new Operation lock against an
    Operation writer and against the sweeper.
- **Validator:** a forged or foreign `refusal_failure_id`; an
  identity-refusal event; a Failure from another run or Operation; and a
  category mismatch are each refused.
- **Calibration:**
  - A forged `:proof` run without the marker is refused, and a marker on a
    non-proof run is refused.
  - An inexact or foreign-profile entry is refused.
  - Evidence pending is refused for a `reserved` predecessor, a `sent` one
    and a terminal one without a latch. With every predecessor latched, the
    call is admitted.
  - Allocation exhaustion stops the run `:grant_exhausted`.
- **Tuples:** B2's predicate holds only for an exact profile and model. A
  Sonnet call never matches an Opus entry. A projection with a different
  prompt builder is refused.
- **Gate mode:** the structural test, the pure inactive branch and the
  refuse-only seam.
- **Store:** unset, untrusted and changed-after-validation roots are each
  refused. Repo telemetry shows the filesystem check runs before the run
  lock, and no store read runs while the locks are held.
- **An admitted tuple still proceeds**, under the test seams and the Fake
  CLI.
- **Gate:** `bin/verify`, credo and the codegen check.

### 7.3 Round 8 ruling

Codex's ruling at 4057fca was **NEEDS-REVIEW, narrow** (report sha256
034f6302, reply to m_1791850340000016490_2ec63862). B1, B2 and B3 are
accepted with the bounds below. B4 and B5 are revised in 7.4. The ruling
is docs only: it approves no implementation, RED, merge, calibration,
enablement or spend.

| Row | Codex decision | Recorded bounds (binding on the implementation) |
|---|---|---|
| B1 | Accept the recommended design | **What is accepted:**<br>• the lock order run → optional Operation `FOR SHARE` → invocation `FOR UPDATE` → grant `FOR SHARE` → allocation `FOR SHARE` → head;<br>• the failed row, one run-subject `provider_error` Failure and the launch event, all committed atomically;<br>• the typed receipt, returned only after commit; the facade's terminal branch passes it through unchanged and writes nothing;<br>• `:model_not_admitted` for every launch receipt, with the specific cause kept in the event's immutable reason and check.<br>**Unchanged:** reservation cap refusals keep `:grant_exhausted`. Identity and state refusals and `run_not_running_at_launch` keep opening no Failure. In the resolution race, the worker opens its one live follow-on Failure only when its Operation needs a live cause.<br>**The validator agrees on all of these:** stage and event type; tenant, run and Operation; the Failure id; the request key; and the event's invocation, with its actual `idempotency_key` and its failed launch outcome. A valid invocation of the same run under another request is not enough. A missing or malformed receipt never falls back to a generic second Failure.<br>**Tests:** runs with and without an Operation; duplicate and racing launches; rollback of the event append; no Port launch.<br>**The readiness prerequisite** is marked closed only after the end-to-end tests pass. |
| B2 | Accept, with precise wording | The predicate establishes an **eligible promoted runtime identity**, never "this call's evaluated projection is already proven".<br>• It compares **full literal projection ids** from the supported registry (`Projection.version/0`, `version_v2/0`, `version_v3/0`) whose prompt builder is the current one. A suffix or substring match is not used; this supersedes the suffix wording in row B2.<br>• A nil-profile (generation-1) entry never admits a generation-2 call.<br>• Ordinary admission has no per-call method override.<br>• Slice C independently enforces the exact projection and method actually evaluated; an unlisted evaluated projection withholds the result. |
| B3 | Accept | **The mode** is enforced and compiled in slice C, and B is stacked on C.<br>**The only seam** is in test builds and can only set `active?` to false. No runtime, config or input path can make an inactive gate active, and there is no new environment mode or caller activation flag.<br>**Integration tests** must show that the real facade and launch path refuse before reservation and before launch while the gate is inactive, and never return unreleased output. Structural checks alone do not prove the gate is wired. |
| B4 | Revise the predecessor scope and order | Row B4' below. Everything else in B4 is accepted as a staged seam:<br>• the separate `CalibrationAdmission` marker;<br>• launch authority re-derived from the immutable reservation event, with its exact tuple revalidated against the recorded invocation and the current profile;<br>• missing, malformed or foreign authority fails closed.<br>The fixed prompt and schema, the G-R0 identity and the harness-only real-call authority remain hard slice D prerequisites. A `:proof` origin or a test build alone grants nothing. |
| B5 | Accept the order and no-I/O locking; revise the freshness claim | Row B5' below.<br>**Accepted:** the check order (actor, tenant and input normalisation before any store probe; then counter, day and origin; then calibration → gate → root → tuple → grants). Every pre-reservation refusal rolls back the counter, payload and invocation together, before the separate guarded refusal record. Launch identity and state ordering are unchanged.<br>**Test helper bound:** exact helper configuration is allowed only in hermetic tests, with every affected case serialised. Server, worker and child activity is drained before the global configuration is restored; `async: false` alone does not stop background work. There is no production helper and no ordinary-call bypass. |

### 7.4 Round 9: revised rows

| Row | Entity / action | Delta | Invariants / lifecycle | Actor / locks | Tests (RED first) |
|---|---|---|---|---|---|
| B4' | Calibration predecessors for `:calibration_evidence_pending` (REQ-07-7) | **Scope (predecessor set):** the real calibration invocations of the tenant's ledger (the isolated calibration database). These are ModelInvocations with `ledger_generation` 2, `provider: :claude_cli`, and a run whose `usage_origin` is `:proof`, of any status and any profile.<br>**Excluded:** Fake rows and non-proof rows are never predecessors. They cannot receive a `:calibration` latch (slice A requires generation 2 ClaudeCLI), so they never wait for one.<br>**The rule:** every predecessor needs a `ModelResultRelease :calibration` with a non-null `evidence_sha256`. Otherwise the call is refused `:calibration_evidence_pending`. A `reserved`, `sent`, `failed`, `unknown` or invalid-completed predecessor blocks until its accepted terminal latch exists.<br>**"Earlier" is the serialised durable order:** the per-tenant audit chain `sequence` of each row's `model.invocation.reserved` event, appended under the chain head. It is never a wall-clock comparison, which could skip tied or rolled-back timestamps.<br>• **At reservation:** the new row does not exist yet. Every in-scope row read under the head is earlier, because the head serialises reservations and the read runs after the head is acquired, so every reservation committed before it is visible.<br>• **At launch:** the predecessors are the in-scope rows whose reserve-event `sequence` is lower than this invocation's. Exactly this invocation is excluded, by id, and never any other unfinished row. A later in-scope row cannot exist while this one is unlatched, because its own reservation would have been refused; a later row that does exist anyway (a defect) also blocks. | **Real history with malformed authority** stays fail-closed and is never silently skipped. An in-scope row whose `model.invocation.reserved` event has no valid `calibration_tuple` (absent, malformed or another profile's; for example a row written before slice B, or a defect) is still a predecessor. It blocks like any unlatched row.<br>**The refusal Failure's detail** names `predecessor_authority_invalid` and the predecessor's id (metadata only), so the owner sees why.<br>**Its only recovery** is the owner's explicit history handling: the owner-run harness records that row's `:calibration` latch (empty or partial capture, attempt kept charged) through slice D's reviewed recovery command. There is no automatic latch and no skip.<br>**Unchanged:** allocation exhaustion keeps the #132 budget receipt and category (`:exhaust_budget`, `:grant_exhausted`). | AGT; under the head, plain reads of ModelInvocation, AgentRun, ModelResultRelease and the reserve events | **Clocks:** tied `reserved_at` values, and a clock rolled back between two reservations: the order follows `sequence`.<br>**Profiles:** an unlatched predecessor of another profile blocks.<br>**Concurrency:** two concurrent calibration reservations on true connections: exactly one is admitted, and the other is refused pending.<br>**Fake rows:** a preceding Fake proof row does not block.<br>**Malformed history:** an in-scope row missing its authority blocks with `predecessor_authority_invalid` in the detail; after its latch, the next call is admitted.<br>**At launch:** the invocation excludes only itself, and an earlier unfinished row still blocks.<br>**Allocation exhaustion** stops the run `:grant_exhausted`. |
| B5' | Witness store trust at admission: what is proven, and the residual risk | **Before the locks**, at reservation and again at launch: `Store.validate_root(Witness.store_root())` runs in full (ancestor `lstat` chain, ownership and mode; the effective UID is read and cached here, never under a lock). The result is `{root, observed_at}`.<br>**Under the head**, a pure check with no I/O: the configured `store_root` still equals the validated `root`. If it changed or became unset, the call is refused `:witness_store_untrusted`.<br>**What the in-lock check proves:** the configured root is the one that was trusted **at the pre-lock observation**. It does **not** prove that the path's permissions, ownership, inode or symlink status are unchanged at the admission instant. | **Residual risk (stated, not hidden):** there is an unavoidable race between validation and use. A same-path filesystem change after the pre-lock probe is not refused before spend at that step.<br>**Where it is caught:**<br>• the launch's fresh pre-lock probe, which runs later and closer to spend, when the change precedes it;<br>• otherwise slice C's validated store read (every store read revalidates the root), which withholds the output as `:store_unreadable` before any release.<br>**Consequence:** a charged attempt can be withheld after spend, and no output is ever released from an untrusted store.<br>This corrects the claim in 7.2 that every root changed after validation is refused: that holds only for a changed configured root.<br>**Owner disclosure:** this residual is added to the remaining gates before real calls, and is shown to the owner before enablement.<br>**fd or inode re-check (not proposed):** re-checking `(dev, inode)` under the lock is filesystem I/O under the run and head locks, and it would still leave a race after the locks are released. | AGT. No filesystem I/O and no subprocess under any row lock or the head. | **Config root changed:** while admission waits on a held run lock, the configured root is switched (or unset) after the pre-lock probe. The call is refused `:witness_store_untrusted`, with no invocation, payload or counter change.<br>**Same path, filesystem changed:** after the pre-lock probe, while admission waits on a held lock, the root becomes group-writable.<br>• Reservation proceeds (the documented limit).<br>• A change made before the launch probe is refused at launch as `:witness_store_untrusted`, with the row failed and never sent.<br>• A change made after the launch probe is withheld by slice C as `:store_unreadable`, with no release and the attempt charged.<br>**No I/O under locks:** telemetry around `validate_root` and the effective-UID read, ordered against Repo lock queries, shows no store or subprocess call between the first row lock and commit. |

## 8. Gate record

- Round 1 at e720fda: **NEEDS-REVIEW** (Codex, consultation
  m_1791836476976826333_a0ee4344, report sha256 9b3302fe). Five required
  items; OQ-1 default: keep the isolated harness.
- Round 2 at bf8d70a: **NEEDS-REVIEW**, narrowed: implicit audit and FK
  lock order; mismatch cause ownership bridge; calibration evidence for
  failed attempts; partition lifetime; backfill attention.
- Round 3 at b3cb745: **NEEDS-REVIEW**, two narrow items: lock the exact
  selected cause before the head even when it is resolved, carried by the
  reconcile receipt; and the calibration console cannot reuse the
  `bin/demo` smoke serve.
- Round 4 at 1da747a: **PASS** (Codex, consultation
  m_1791838639608778250_18c04dfc, answer m_1791839074000000000_r007pass,
  report sha256 fbd9375e). Entity/action PASS only: not implementation
  approval, RED verification, calibration-call or deploy authority.
- Round 5 (slice A deviations, code at 0116281): **NEEDS-REVIEW** (Codex,
  report sha256 165c1840, on submission sha256 f18bfe62). Items 1–6 and
  8–10 accepted with boundaries; item 7 revised (keep the ADR-0005
  evidence keys). Open contracts (a)–(d) are modelled in section 5 for
  recheck.
- Round 5 recheck at dc8cae7: **PASS** (Codex, answer
  codex-r007a-round5-pass, in_reply_to m_1791844428000013421_5d27bf13,
  report `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-r0-07a-dc8cae7-entity-pass.md`,
  sha256 38f9f40e).
  - **Accepted:** the diagnostic-field extension (`validation_errors`,
    `refusal`), and the slice A/C split of the prelocked context while
    staging stays closed.
  - **Recorded inline:** clarifications 1–5 (nil marker, export-canary
    scope, gated-parent evidence, registered receipt/transaction binding
    and cleanup, masked diagnostic consumers).
  - **Entity/action PASS only:** no code, RED, CI, merge, calibration,
    deployment or spend approval.
  - **Remaining gates before real calls:** the owner metadata inventory
    and history handling, full slice C, the reviewed calibration harness
    and the owner's grants.
- Round 6 (slice C pre-code gaps, proposal
  `claude-r0-07c-gaps-20261012.md`, base #139 at 5ae6549): **NEEDS-REVIEW,
  narrow** (Codex, reply to m_1791847186000021427_a461941f, report sha256
  ce1420a2). Gaps 1, 2, 6 and 7 accepted with bounds; gaps 3, 4 and 5
  revised in section 6 for recheck.
- Round 6 recheck at f31d61a: **NEEDS-REVIEW, two narrow clarifications**
  (Codex, reply to m_1791848756000001078_e5faee73, report sha256 2ee51092).
  The replay semantics for `gate_cause_id` and G7's mismatch precedence are
  recorded as R7-1 and R7-2 in section 6.4, with the implementation bounds.
- Round 7 at e7ae2f4: **PASS** (Codex, entity/action, reply to
  m_1791850375000000194_70e6a9ad, report
  `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-r007c-e7ae2f4-entity-pass.md`,
  sha256 a6d36d70). R7-1 and R7-2 resolve both round-6 cases. The verdict
  covers the packet delta only, not later local code. It is no RED, code,
  merge, calibration, enablement or spend approval.

  Implementation obligations:
  1. **Exact original event.** The binding is read from exactly the
     release's original `model.result.withheld` event, scoped by tenant,
     resource, release and event type. A missing, duplicate or malformed
     event is not evidence that the cause was absent: it fails closed. A
     real nil or absent argument on a valid original event remains the
     legitimate no-cause case. The losing concurrent decide sees the
     winner's committed event and gets the typed conflict, never an
     apparent new-receipt success.
  2. **Exact receipt locks before the head,** resolved causes included,
     under the rollback-aware Prelocked context. In R3 a refused recovery
     leaves the run's actual terminal status unchanged; the running-state
     example in R7-2 applies only to running-run recovery. No lock clause
     after the head except reentrant head locking.
  3. **One live correctly selected critical,** including after
     unusable-cause resolution races. Observation stays outside locks, and
     job and run liveness are rechecked. Every no-write or conflict path
     returns no business output. One fresh recovery attempt only; no model
     repeat.
  4. **The G3, G4 and G6 bounds of section 6.4 stand:**
     - both unreleased running and terminal rows are deferred from the scan;
     - real severity is respected;
     - resolved causes are not resurrected;
     - notes are metadata-only and idempotent;
     - ordinary `:fail` locks are unchanged.
  5. **Executable proof:** the true-connection race, no-extra-event,
     unavailable-binding and recovery tests run through public actions.
     They are not proof until independently verified. The RED, GREEN and
     code-review gates continue for the affected implementation; this PASS
     is not retrospective approval of local code.
- Code review of PR #143 at 747aa13: **REQUEST_CHANGES** (Codex, correlation
  m_1791853566000026538_97041005, report sha256 6598690b). Five must-fix
  items (MF1–MF5) were fixed in 13d0036, 9c41438, 3a7cd7f, c5878b1 and
  43adc8d.
  - **Test order not verified.** The authoring subagent was stopped by an
    account usage limit before it reported per-commit RED, so test-first
    order for these five commits is unrecorded. The evidence is
    reconstructed behaviour only: Codex's four probes fail at 747aa13 and
    pass at ef38a7e (Claude reran them at ef38a7e on partition `_r07c`).
    This is not a claim that the tests were written before the code.
  - Rulings on the author's interpretations: 1, 3, 5, 6, 7 and 8 accepted;
    4 accepted except for MF3/MF4; 2 rejected (MF1: the durable
    gate-stop/running-Operation state is now self-healed).
  - Ruling 5 is reflected in row G2 above: the classification is in the
    event only.
- Code re-review round 2 of PR #143 at ef38a7e: **REQUEST_CHANGES, narrow**
  (Codex, correlation m_1791860081000011839_e80c0a99, report sha256
  3a03ed8c). MF1–MF5 resolved. One remaining G7 race: recovery read no
  release, waited for the head, and a standalone decider committed a
  release meanwhile; recovery returned `:release_raced`, and the sweep then
  recorded `:crash`. Also: the "RED-first" claim above was corrected.
  - **Narrow delta G7' (for independent review).** When the release
    re-read under the head finds a release committed meanwhile, recovery
    rolls back to a savepoint taken before its selection (writing nothing
    and releasing the link, cause and head locks taken after it, while
    keeping the run, Operation and invocation locks) and then decides that
    immutable winner exactly as one found first: a `:released` one returns
    its output; a bound withheld one of a running run stops the run on its
    original cause (link `FOR SHARE`, cause `FOR UPDATE`, then the head). No
    lock strength changes, no row lock after the head, no new release,
    receipt or cause, and no recursion (a found release never reaches the
    selection again). `{:error, :release_raced}` no longer exists, and the
    sweeper's skip for it is removed.
  - **Tests:** a true-connection late-winner test for a `:released` and for
    a bound withheld winner (RED: both returned `{:error, :release_raced}`;
    GREEN after the change), and Codex's G7 probe passes. The worker
    boundary is covered because recovery now returns the winner, so the
    facade never halts with `:result_not_released` for it; there is no
    separate end-to-end worker test for this race.
- Round 8 (slice B admission, proposed in section 7 at 4057fca, base
  553b568): **NEEDS-REVIEW, narrow** (Codex, reply to
  m_1791850340000016490_2ec63862, report
  `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-r007b-4057fca-round8-review.md`,
  sha256 034f6302).
  - Accepted, with bounds (7.3): B1, B2 and B3.
  - Revised (7.4): B4's predecessor scope and order; B5's freshness claim
    and its residual risk.
  - Docs-only ruling: no implementation, RED, merge, calibration,
    enablement or spend approval.
- Round 9 recheck at 3600fcf: **PASS** (Codex, reply to
  m_1791851284000031985_a333f656, report
  `~/.local/state/sdr-agent/handoff-20261008/tmp/codex-r007b-3600fcf-round9-pass.md`,
  sha256 5920c6b3). Entity/action PASS only: no RED, code, merge,
  calibration, enablement or spend approval. Slice B is stacked on slice C.
  - **Retained:** B1–B3's obligations (7.3).
  - **Malformed authority fails closed:** exactly one original tenant-, run-
    and invocation-scoped reservation event is resolved. A missing,
    duplicate or malformed sequence or tuple is not authority, and never
    silently excludes a real predecessor. `predecessor_authority_invalid`
    stays a metadata-only diagnostic under `:calibration_evidence_pending`.
  - **At launch:** the stored tuple is revalidated against the immutable
    invocation and the current reviewed profile. A latch clears the
    predecessor barrier, never a corrupt invocation's own launch authority.
  - **Store trust is observation-time trust only:** the residual is
    surfaced to the owner before enablement.
  - **Tests:** helper configuration is restored only after all child,
    server and worker activity is drained.
  - **Still required before any real call:** slice D's fixed prompt and
    schema, the G-R0 binding, owner-run recovery and real-call authority,
    code review, calibration evidence review, separate enablement and the
    owner's grants.
