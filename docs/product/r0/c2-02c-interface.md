# C2-02c interface: restart and status

**Status:** draft 2, 2026-10-15, for Codex's interface and entity
re-review. Slice plan: `c2-02-slices.md` row c. Builds on b2α (merged at
`22db5c0`) and b2β (`c2-02b2b-interface.md`, PASS at `e60943c`).
Implementation lands after b2β.

**Review record:**
- **Draft 1** (`183d2cc`): interface and entity NEEDS-REVIEW (Codex
  `1a54ed3e`, `codex-c202c-183d2cc-interface-review.md`). Draft 2 answers:
  - **MF1:** a retained lease is separated from simulated VM-state loss,
    and the current setting is authoritative (section 1);
  - **MF2:** status is last confirmed observations plus sampled runtime
    eligibility, with no promise about calls admitted now (section 2);
  - **MF3:** a bounded sample binding, and every downgrade shape (2a, 2b).
  - **Codex rulings:** OQ-1 is technically recommended yes, pending the
    owner. OQ-2 is a qualified yes (section 1).
- **Pre-read:** `codex-c202-slice-c-preread-22db5c0.md`.

## 0. Scope, and one narrowing

**The narrowing (the owner decides, OQ-1):** drop the slice plan's
"clean pending switch → failed at boot" branch. Every pending switch at a
coordinator start stays **blocked**, as b2α already does
(`coordinator_restarted`), and the exit is b2β's attended resolver.
- **Why:** a restart never proves that earlier external CLI work stopped.
  b2α's `fail` needs a ready rollback start with preflight evidence, so
  there is no honest route to it. b2β already covers every blocked switch.
- **No new ADR is needed:** the accepted ADR-0004 C2-02b2 amendment
  already says that a crash during a switch leaves it blocked until b2β.
- **What changes once the owner decides:** the decision is recorded, and
  the row c text of the slice plan is updated with the decision's
  reference. Accepted text is never overwritten silently.

Slice c adds **no lifecycle transition and no persisted change**. It pins
the restart behaviour that b2α and b2β already have, and builds the
status contract.

## 1. Restart (behaviour pinned, not changed)

**The current setting decides the profile.** The desired profile at a
start is the **current committed setting**, read fresh at that start.
Switch history never decides it: after several completed switches, the
start runs the latest setting's profile, and terminal history is
unchanged.

**Three restart forms, tested separately:**

| Form | What it does | What it is not |
|---|---|---|
| **A. Coordinator-only restart** | The coordinator is killed while idle; `:rest_for_one` restarts it | — |
| **B. Profile-tree restart, lease retained** | `ProfileSupervisor` is stopped and started again. Its retained fixture lease (`:persistent_term`) is untouched, because a tree restart doesn't clear it | — |
| **C. Simulated VM boundary** | B, plus explicit removal of VM-local state. This happens only after every fixture-owned server, reaper and worker has been stopped and joined, and only for a uniquely owned test lease | an actual BEAM restart, or proof of OS cleanup (OQ-2, Codex: qualified yes) |

**Expected outcomes:**

| State at the start | A and B (lease retained) | C (VM-local state gone) |
|---|---|---|
| no open switch, setting = Sonnet | Sonnet (adopted, or a fresh start), released after the reconciled read | Sonnet, fresh start, preflight, released |
| setting positively absent | the default (`:claude_cli_opus`) | same |
| setting read fails | no start, held, boot retried; never the default | same |
| pending switch | blocked (`coordinator_restarted`), held | blocked, held. The lost lease proves nothing about the interrupted switch |
| blocked switch | still blocked, held | still blocked, held; needs the attended resolver |
| resolved (b2β), with a dead lease | held at `:cleanup_unprovable`; no release | b2β's no-open-switch branch, since no lease and no live server: a fresh start, preflight and reconciliation, then the release |
| completed switch(es) | the current setting's profile | same |

**Test-only state.** No application cleanup bypass and no production
seam is added. The owner's runtime and leases are never touched.

## 2. Status: last confirmed observations, plus sampled runtime eligibility

`Runtime.status/0` reports two kinds of information, and promises
nothing about any later instant:

- **Ledger-derived fields** (`desired_profile`, `switch`) are the
  coordinator's **last confirmed observation**. Each carries the time it
  was confirmed.
- **Runtime fields** (`observed_profile`, `hold`, `stage`, the admission
  and attestation views) come from **one bounded sample** of the
  coordinator's and the server's published tables (2a).

**Authority stays elsewhere.** Admission is decided by normal reservation
and launch fencing: the durable fence, grants, quotas, the hold, and
per-call attestation. Status is never authority.

**Its keys for ClaudeCLI** (all existing keys keep their meaning):

| Key | Value |
|---|---|
| `desired_profile` | `%{profile_id, source: :setting \| :default, confirmed_at}` or `:unknown` |
| `switch` | nil (none open, confirmed), `%{id, from_profile_id, to_profile_id, status: :pending \| :blocked, failure_reason, confirmed_at}`, or `:unknown` |
| `observed_profile` | the bound server's profile, nil (confirmed: no server), or `:unknown` |
| `hold` | `:held \| :released \| :pending \| :unknown` |
| `stage` | the coordinator's stage (including `:cleanup_unprovable`), nil, or `:unknown` |
| `effective_profile` | `observed_profile` only if the sample is consistent, the hold is `:released`, and `resolve([])` passed at sample time; nil otherwise. **Sampled eligibility, not a promise** about any later call |
| `observation` | `:consistent \| :inconsistent \| :unavailable` |
| `published_at` | when the coordinator **published** the record the sample used. It is not when every field was confirmed, which is `confirmed_at` |

**When the coordinator publishes.**
- **Who writes:** only the coordinator's own process writes its protected
  table.
- **When:** after the outcome of each of its own bounded reads and
  writes, such as the setting read at boot, the switch read at boot, and
  `request`, `block`, `complete`, `fail` and `resolve`.
- **Never** inside `publish`, and never on a status read. There is no new
  database read.

**The intervals in which status lags, all acceptable:**

| Interval | What status shows |
|---|---|
| **Request.** The caller commits the request, then casts to the coordinator (`request_switch/2`) | the previous confirmed observation (`switch` nil, `confirmed_at` older), until the coordinator handles the cast and publishes. No synchronous publication of another process's write is promised |
| **Uncertain finalization or resolution, until settled** | `switch: :unknown`, `desired_profile: :unknown` and `stage` as published (for example `:finalizing` or `:settling`). It never shows the previous value as current |
| **A failed read** | `:unknown` for that field |

### 2a. The bounded sample binding

**The coordinator's published record** holds a public part (the fields
above) and a private part, kept in the same ETS row but never returned:
- the coordinator's own pid;
- the bound server pid;
- the start id;
- the boot id.

**`Runtime.status/0` takes at most three attempts.** Each attempt is
read-only and calls neither process:
1. **Read** the coordinator row, R1.
2. **Check the coordinator.** The table's owner (`:ets.info(table,
   :owner)`) is `Process.whereis(Coordinator)` and is R1's private
   coordinator pid.
3. **Check the server.** Read the server's status table. Its owner is
   `Process.whereis(ClaudeCLI.server())` and is R1's private bound server
   pid. A replacement server with the same profile fails this check.
4. **Re-read** the coordinator row, R2, and check it equals R1.

**The outcome:**
- **All four hold:** the sample is `:consistent`.
- **A check fails or the tables change:** retry, up to three attempts in
  total.
- **Then:**
  - `:inconsistent` when both tables exist but stay unbound or changing;
  - `:unavailable` when either table or process is missing.

  A positive combination is never synthesized from partial samples.

**No raw pid, ref or capability** appears in the public status.

### 2b. Shapes in every case

| Case | `desired_profile` | `switch` | `observed_profile` | `hold`/`stage` | `effective_profile` | `effective`/`refusal` | `observation` |
|---|---|---|---|---|---|---|---|
| **Fake provider** | `:not_applicable` | `:not_applicable` | `:not_applicable` | `:not_applicable` | nil | as today (`effective: Fake`) | `:not_applicable` |
| **ClaudeCLI, no coordinator or table** | `:unknown` | `:unknown` | `:unknown` | `:unknown` | nil | `effective: nil`, `refusal`: from `resolve([])`, otherwise `:status_unavailable` | `:unavailable` |
| **Inconsistent sample** | as last confirmed in R1, or `:unknown` | same | `:unknown` | `:unknown` | nil | `effective: nil`, `refusal: :status_inconsistent` | `:inconsistent` |
| **Consistent, held** | confirmed or `:unknown` | confirmed or `:unknown` | the profile | `:held`, stage | nil | `effective: nil`, `refusal: :provider_held` | `:consistent` |
| **Consistent, released, `resolve` passes** | confirmed | confirmed | the profile | `:released` | the profile | `effective: ClaudeCLI`, `refusal: nil` | `:consistent` |
| **Consistent, released, `resolve` refuses** (pin, staging, admission) | confirmed | confirmed | the profile | `:released` | nil | `effective: nil`, `refusal`: that reason | `:consistent` |

**`profile_id` and the model fields** (`model_alias`, `model_id`,
`reviewed_version`) follow `observed_profile` when it is known, then the
confirmed `desired_profile`, and are **nil** otherwise, never the
registry default. The reviewed registry identity and the per-call init
attestation stay separate fields.

**`Runtime.desired_profile/0`** (it is today a constant default) becomes:
- `{:ok, %{profile_id, source, confirmed_at}}`, from the published record
  when it is consistent and confirmed;
- `{:error, :unknown}` otherwise, for ClaudeCLI;
- `:not_applicable` for the Fake. **This never claims** that a stored
  setting is absent: it means only that no real profile is configured.

The callers are `runtime.ex` (`details/1`) and
`provider_runtime_test.exs:213`, which is updated to the new shape.

## 3. ADR evaluation

None needed:
- the status fields and the reuse of b2α and b2β are within ADR-0004's
  status card and the C2-02b2 amendment;
- the narrowing is consistent with that amendment ("a crash during a
  switch leaves it blocked until b2β"), and is recorded once the owner
  decides OQ-1.

## Entity Model

**Entity Model trigger:** yes, narrowly. Nothing persisted changes. A
runtime read contract changes: the coordinator's published record,
`Runtime.status/0` and `Runtime.desired_profile/0`.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Coordinator published record (runtime) | Existing (delta) | What operators see | **Public, added:** `desired` (`%{profile_id, source, confirmed_at}` \| `:unknown`), `switch` (projection with `confirmed_at` \| nil \| `:unknown`), `published_at`. **Private, added, never returned:** the coordinator pid, the bound server pid, the start id, the boot id (the binding for 2a) | — | Written only by the coordinator, after its own bounded reads and writes. No database read inside `publish`. An uncertain or failed outcome publishes `:unknown`, never the previous value as current. No raw refs | written by the coordinator; read in-node (protected ETS) | none |
| `Runtime.status/0`, `Runtime.desired_profile/0` (runtime read API) | Existing (delta) | The admin card | the keys and shapes in 2 and 2b; `desired_profile/0`'s tagged result | — | No database read, coordinator call or write. At most three bound-and-recheck attempts (2a). No positive value from a partial sample. No default on unknown. `effective_profile` is sampled eligibility only | unchanged (the admin page) | none |

ModelProfileSwitch: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelProfileSetting: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.
ModelServerStart: existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found.

## 4. Tests (RED first)

Files: `test/sdr_agent/ai/profile_restart_test.exs` and
`test/sdr_agent/ai/runtime_status_test.exs`. All hermetic, with zero
model calls and no spend. Every lease belongs to the test and is cleared
only after its fixture processes are stopped and joined.

**Restart (forms A, B and C, as in the section 1 table):**
1. **Setting = Sonnet with no open switch:** A and B adopt or start
   fresh; C starts fresh. All end at Sonnet.
2. **Setting absent:** the default. **Setting read fails** (a test-only
   fault): no start, held, retried, and recovery once the read works.
3. **A pending switch → blocked**, under A, B and C. The request history
   is unchanged; the switch is never completed, continued or failed.
4. **A blocked switch:** still blocked and held under A, B and C.
5. **Resolved with a dead lease:** held at `:cleanup_unprovable` under A
   and B, with no release. Under C, a fresh start reaches ready, then the
   release.
6. **Several completed switches** (Opus → Sonnet → Opus): the start runs
   the current setting's profile; the history is unchanged.
7. **Old-boot replies:** a reply or `DOWN` from an old boot's server or
   worker can't reopen the new hold.

**Status:**
8. **Every row of the 2b table.**
9. **The binding:** a replacement server with the same profile; a
   coordinator restart between R1 and R2; and the table deleted and
   recreated mid-sample. Each → `:inconsistent` or `:unavailable`, never
   a positive `effective_profile`, within three attempts.
10. **The lag intervals,** with barriers around the commit, the
    publication and an unknown outcome:
    - a caller's committed request shows the old confirmed observation
      until the coordinator publishes;
    - an uncertain finalization shows `:unknown`;
    - a failed read shows `:unknown`.
11. **No side effects:** across 8–10, zero database queries (a
    query-telemetry trace), zero coordinator messages (a trace), zero
    writes (counts of events, starts and switches), and zero launches or
    reservations.
12. **No default on unknown:** with nothing running and the desired
    profile unknown, `profile_id` and the model fields are nil.
13. **`desired_profile/0`:** Fake → `:not_applicable` (even with a stored
    Sonnet setting); consistent → `{:ok, …}`; otherwise `{:error,
    :unknown}`.
14. **A regression budget:** in a controlled test, `status/0` returns
    within 50 ms while the coordinator is blocked in a ledger call (a
    test-only pause). This is a budget for regressions, not a wall-clock
    promise under load.

## Open questions

- **OQ-1 (for the owner):** the narrowing in section 0. **Recommendation
  (Claude and Codex): yes.**
- **OQ-2 (Codex: a qualified yes):** a real `ProfileSupervisor` stop and
  start, plus a simulated loss of VM-local state, is accepted as the
  scoped hermetic lifecycle test. It is labelled as not a BEAM restart
  and not proof of OS cleanup. An isolated disposable BEAM test would be
  optional, stronger evidence.
