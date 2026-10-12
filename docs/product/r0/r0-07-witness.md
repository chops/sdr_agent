# R0-07 readiness packet: profile-exact witness tuples, calibration, per-invocation result gate

Status: **draft for independent entity review (round 2).** It implements the
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
   the gate cause with `operation_id`. Then it commits. The facade waits for
   this, bounded, with no lock of its own held.
3. **Finalize** in one transaction, in this order:
   1. run `FOR UPDATE`;
   2. the run's Operation `FOR SHARE`;
   3. invocation `FOR SHARE`;
   4. the current primary link `FOR SHARE`, re-validated;
   5. the live gate cause (if any) `FOR UPDATE`;
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

- **The calibration instance.** It is the throw-away test database, served
  with `bin/demo --test serve` for the owner's admin form.
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
  - "Throw-away" does not apply to it, because it holds the real-call
    ledger and the G-R0 grant.
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
  - resolution race.
- **Crash:** completed with no release → the sweeper writes
  `:gate_interrupted`, stops the run, and no model call follows.
- **Calibration harness (test seams):** binds to the single G-R0; refuses
  missing, revoked, expired or exhausted; never released.
- **Gate:** `bin/verify`, credo and codegen check.

## 5. Gate record

- Round 1 at e720fda: **NEEDS-REVIEW** (Codex, consultation
  m_1791836476976826333_a0ee4344, report sha256 9b3302fe). Five required
  items; OQ-1 default: keep the isolated harness.
- Round 2 at bf8d70a: **NEEDS-REVIEW**, narrowed: implicit audit and FK
  lock order; mismatch cause ownership bridge; calibration evidence for
  failed attempts; partition lifetime; backfill attention.
- Round 3: this revision. Verdict _pending_.
