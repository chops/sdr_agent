# R0-07 readiness packet: profile-exact witness tuples, calibration, per-invocation result gate

Status: **draft for independent entity review.** This packet implements the
accepted ADR-0005 R0 amendment (PR #128, owner D-108) within G5-R0's scope.
Nothing here is implemented until Codex records an entity-model **PASS** on
section 2. G5-R0 already authorizes R0-07, conditional on that PASS. No real
model call happens until a tuple is promoted, and calibration runs only under
the exception the owner accepted.

Story: R0-07 (#126). Depends on R0-02 (merged, #131), R0-03 profiles, C9
admission (#130 merged, #132 approved) and C9-03 launch admission.

Code facts are from `main` at 1096b13, and from the witness research pass
on 440b6e4:

- **Shipped allowlist.** The allowlist in `config/config.exs`
  (`reconciled_methods`) holds one entry,
  `(claude_cli, 2.1.291, claude-message-json/3+prompt-builder/1, propagated_id)`.
  It has no model or profile field.
- **Reconciliation path.** `Witness.reconcile/2` runs as REC (actor
  `reconciler`). It observes the proxy store with no database locks held,
  then persists `WireWitnessLink`s under the invocation lock.
- **Scheduling.** A five-minute `ScanWorker` enqueues `ReconcileWorker` on a
  concurrency-1 queue shared with delivery reconciliation.
- **No gate today.** The model output is used before reconciliation:
  `ModelProvider` returns `parsed_output`, which `SDR.Model` callers consume.
  Stored outputs are also read by `SDR` replay (`sdr.ex:255`),
  `Agents.Changes.DecisionRules` (decision `output_pointer`) and
  `Outreach.Changes.AssessmentRules`.
- **Test-only overrides.** Per-call method overrides exist only where
  `allow_method_override: true` (`config/test.exs`).

## 1. Requirements

| ID | Requirement |
|---|---|
| REQ-07-1 | An allowlist entry names exactly `(provider, cli_version, profile_id, model_id, projection_version, method)` and a `stage`: `:calibration` or `:reconciled`. The existing 2.1.291 entry becomes `profile_id: nil, model_id: "claude-opus-5-5", stage: :reconciled` and matches only generation-1 rows (no profile). |
| REQ-07-2 | **Admission before spend.** An ordinary real call (any usage origin except `:proof`) is refused before reservation, and again at launch, unless its exact tuple is on the allowlist at stage `:reconciled` and the result gate is active (trusted witness store root configured). Nothing is reserved, charged or sent on refusal; the refusal is recorded like other admission refusals. |
| REQ-07-3 | **Calibration.** A call with usage origin `:proof` is admitted only:<br>• when its exact tuple is at stage `:calibration`;<br>• through the admin-only calibration action (REQ-07-6);<br>• with the fixed synthetic calibration prompt;<br>• charged to the G-R0 `:proof` allocation for its profile.<br>Its result is never released to any business read; its release record says `:calibration`. |
| REQ-07-4 | **Result gate.** After a `:reconciled`-stage call's response is validated and stored, the facade reconciles that invocation in-process. No lock is held while it waits for the capture. The wait is bounded (default 120 s; configuration may only lower it). Only a `reconciled` link releases the output to the caller. Mismatch, missing capture, timeout or an unreadable store withholds it. The run stops with `:witness_mismatch` or `:witness_unreconciled`, and an attention item opens. The charged attempt and the evidence are kept, and nothing is retried automatically. |
| REQ-07-5 | **Release record.** Each release decision is one immutable `ModelResultRelease` row per invocation, written once after the terminal outcome. The invocation itself is never updated for it. Every business read of a generation-2 `claude_cli` output requires a `:released` record: the facade's return, SDR replay, decision output pointers, assessment rules. Witness evidence and reconciliation reads stay available while an output is withheld. |
| REQ-07-6 | **Calibration action.**<br>• Admin-only and audited, it launches one calibration call for a chosen profile at stage `:calibration`.<br>• It refuses when the G-R0 allocation is exhausted, or when the previous calibration call's evidence has not been recorded.<br>• Each call's raw request and response digests, projection result and diagnostics are written to a quarantined evidence file (`docs/audit/r0-calibration-<profile>-<n>.json`, synthetic content only), marked unreviewed. |
| REQ-07-7 | **Promotion.** A tuple moves from `:calibration` to `:reconciled` only through a separate reviewed config change citing Codex's evidence PASS. The app never promotes a tuple itself. If the captured grammar does not fit a reviewed projection, work stops and is reported; more attempts need a new owner grant. |
| REQ-07-8 | **Fail-closed store.** No real `claude_cli` call is admitted (calibration or ordinary) while the witness store root is unset or untrusted. |

## 2. Entity model

Entity Model trigger: **yes**. It adds:

- a new persisted resource (`ModelResultRelease`);
- a new configuration contract that now carries meaning (allowlist stage and
  identity fields);
- new AgentRun stop reasons;
- new admission refusal reasons;
- a new admin action (calibration);
- read-gating of an existing attribute (`ModelInvocation.parsed_output` for
  business consumers).

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Witness allowlist entry (config, not persisted) | Existing (delta) | Which exact tuples may reconcile, and at what stage | `provider`, `cli_version`, `profile_id` (nil = generation-1 rows only), `model_id`, `projection_version`, `method`, `stage : :calibration \| :reconciled` | Matched against the invocation's recorded identity plus the projection and method actually evaluated | `exact_entry?` requires all seven keys. Only `config/*.exs` defines entries; changes are reviewed PRs. The test environment keeps an empty list plus test-only overrides. | n/a (code) | OQ-1 |
| ModelResultRelease | New | The immutable release decision for one model output | `id : uuid_v7`; `tenant_id`; `model_invocation_id : uuid, not nil, unique`; `disposition : :released \| :withheld \| :calibration`; `reason : :reconciled \| :witness_mismatch \| :witness_missing \| :witness_timeout \| :store_unreadable \| :calibration`; `wire_witness_link_id : uuid, nullable`; `projection_version : string, nullable`; `decided_at : utc_datetime_usec`; `trace_id`, `span_id` | belongs_to Tenant; belongs_to ModelInvocation (restrict, same tenant via composite FK); belongs_to WireWitnessLink (optional, restrict) | Created only by `:decide`, once per invocation (unique). Append-only: a trigger rejects update and delete.<br>`:released` requires `reason :reconciled` and a link that is a current reconciled primary link of that invocation.<br>`:withheld` requires a non-reconciled reason.<br>`:calibration` requires the invocation's run `usage_origin :proof`.<br>Only for generation-2 `claude_cli` invocations with status `completed` (failed and unknown outputs are never used, so they need no release). | `:decide`: `agent_runtime` only, inside the facade's gate step. Reads: admin, auditor, `agent_runtime`, `reconciler`, kernel. Audited `model.result.released \| withheld \| calibration`. | none |
| ModelInvocation | Existing (delta, no new columns) | — | `parsed_output` is unchanged | — | Business reads of a generation-2 `claude_cli` invocation's `parsed_output` (SDR replay, DecisionRules pointer resolution, AssessmentRules) require its release with disposition `:released`; otherwise refused (`:result_not_released`). Generation-1 and Fake rows are unchanged. | unchanged | none |
| AgentRun | Existing (delta) | — | `status_reason` gains `:witness_mismatch` (status `failed`) and `:witness_unreconciled` (status `failed`) | — | Set by `:fail` from the facade's gate outcome. The run's attention links the gate's Failure (critical `reconciliation_required`-class mismatch item, or warning item), so no second run-stopped Failure opens. This follows the #132 single-Failure pattern. | unchanged actors | none |
| Admission (contract) | Existing (delta) | — | New refusal reasons: `:tuple_not_promoted`, `:tuple_not_in_calibration`, `:witness_store_untrusted`, `:calibration_evidence_pending` | — | Checked inside reservation admission after the existing locks, and again in `admit_launch` (C9-03). Recorded as one deduplicated Failure, like the other refusals. | unchanged | none |
| Calibration action | New (action) | Launch one calibration call | Arguments: `profile_id` | Uses the `:proof` usage origin and the fixed synthetic prompt; charged to G-R0 | Refuses unless the tuple is at stage `:calibration`, the store is trusted, the G-R0 `:proof` allocation for that profile has room, and every previous calibration invocation has an evidence file recorded. One at a time (serialized server). | Human admin only (CurrentAdmin re-read); audited `model.calibration.started` | OQ-1 |
| Tenant, Accounts.User, WireWitnessLink, Operations.Failure | Existing | — | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (WireWitnessLink gains only an inbound optional reference from ModelResultRelease; its lineage rules are unchanged) | — | — |

### Changed contracts

- **The facade's gate step** (generation-2 `claude_cli`, after `complete`):
  1. Commit the completed invocation, as today. This releases the
     run/invocation/head locks.
  2. Call `Witness.reconcile/2` for that invocation as REC, waiting up to the
     deadline for the capture, with no database lock held while waiting.
  3. In one transaction (invocation row `FOR SHARE`, then head), create the
     `ModelResultRelease`.
  4. Return the output only if it was `:released`. Otherwise stop the run
     with the withheld reason through the #132 single-Failure path.
- **The serialized CLI server** has already released the call before step 2.
  Later calls do not wait behind this call's reconciliation; only this call's
  run does.
- **`ScanWorker` stays as a backfill.** It may add or upgrade links later,
  but it never creates or changes a release, and a withheld output is never
  released by it.

## 3. Open question for Codex and the owner

**OQ-1 Where calibration runs.** ADR-0005's text says calibration runs in an
isolated test database through the external proof harness with test-only
overrides. But the owner's G-R0 grant is created by the owner in the app's
own database through the admin form (D-099). A test database cannot hold
that authority without someone other than the owner creating a grant there.
Proposal:

- **Where it runs.** Calibration runs in the owner's local app, against the
  owner-created G-R0, through the admin-only calibration action (REQ-07-6).
- **Under which tuple.** It runs under an exact tuple at stage
  `:calibration`, added by a reviewed config PR, not under a test-only
  override.
- **What makes it isolated.** The isolation the exception requires comes
  from three things:
  - the fixed synthetic prompt;
  - the `:proof` usage origin and allocation, so it is never a business
    flow;
  - the `:calibration` release disposition, so its output is never released.
- **Recording.** Evidence is recorded and quarantined as in REQ-07-6.

The alternative keeps the test-database harness. It needs the owner to
create G-R0 in that database too, through a separate owner-run step.
Choosing this proposal needs the owner's confirmation, because it changes
where the accepted exception runs, though not what it protects.

## 4. Test plan (RED first; synthetic only; no real calls)

- **Allowlist:** seven-key exactness; a Sonnet tuple never matches an Opus
  entry; the generation-1 entry matches only profile-nil rows; stage
  handling.
- **Admission:** an ordinary call with an unpromoted tuple, an inactive gate
  or an untrusted store is refused before reservation (no rows), and again
  at launch. A `:proof` call is refused outside stage `:calibration`.
  Calibration is refused when the allocation is exhausted or evidence is
  pending.
- **Gate (fake CLI and stand-in proxy store):** reconciled → released and
  returned. Mismatch, missing capture, timeout and unreadable store →
  withheld, run stopped with the exact reason and one attention item,
  attempt still charged, no new call. No lock is held during the wait
  (concurrent reservation proceeds).
- **Release record:** unique per invocation; trigger blocks update and
  delete; dispositions require their reasons and links. A business read of
  an unreleased output (replay, decision pointer, assessment) is refused.
  Witness and REC reads still work.
- **Calibration action:** admin only (reviewer, auditor and system actors
  denied); writes a quarantined evidence file; never released.
- **Gate:** `bin/verify`, credo and codegen check.

## 5. Gate record (to fill)

- Entity-model reviewer: Codex via ai-pair. Verdict: _pending_.
- Owner: OQ-1 answer _pending_.
