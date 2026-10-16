# C2-02c interface: restart and status

**Status:** draft 3, 2026-10-15.
- **Review:** interface PASS and Entity Model PASS (Codex `2971a846`, exact
  `401df6f`, `codex-c202c-401df6f-interface-pass.md`; configured
  `ai_pair=true`, `codex_review=true`).
- **What it permits:** scoped RED only.
- **OQ-1:** accepted by the owner on 2026-10-15 (D-139). Row c of the
  slice plan is updated with that reference.
- **Still open:** implementation, which comes after b2β.
- **Binding:** the report's "Binding interpretations for RED/GREEN" (items
  1–6) bind the tests and the implementation. Slice plan: `c2-02-slices.md` row c. Builds on b2α (merged at
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
- **Draft 2** (`445f006`): a narrow NEEDS-REVIEW (Codex `9e98ed5e`). Codex
  accepted the restart and lag groups. Draft 3 answers its two residuals:
  - **R2-1:** the bracket now covers the server sample and eligibility, so
    nothing is re-read by name outside it (2a);
  - **R2-2:** a timestamped confirmed-none switch, split ledger and
    runtime observations, and every remaining shape (2b).
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

`Runtime.status/0` reports two kinds of information, and promises nothing
about any later instant. Admission is still decided by normal reservation
and launch fencing: the durable fence, grants, quotas, the hold and the
per-call attestation. **Status is never authority.**

- **Ledger fields:** `desired_profile` and `switch`. These are the
  coordinator's last confirmed observations. Each one carries its own
  `confirmed_at`, including the confirmed "no switch open".
- **Runtime fields:** `observed_profile`, `hold`, `stage`, the
  eligibility, and the admission and attestation views. These come from
  one bracketed sample (2a).

**Public shapes:**

| Key | Value |
|---|---|
| `desired_profile` | `%{profile_id, source: :setting \| :default, confirmed_at}` \| `:unknown` \| `:not_applicable` |
| `switch` | `%{state: :none, confirmed_at}` \| `%{state: :open, id, from_profile_id, to_profile_id, status: :pending \| :blocked, failure_reason, confirmed_at}` \| `:unknown` \| `:not_applicable` |
| `observed_profile` | the bound server's profile \| `:none` (the coordinator positively has no bound server, and no process holds the name) \| `:unknown` \| `:not_applicable` |
| `hold`, `stage` | the published values \| `:unknown` \| `:not_applicable` |
| `effective_profile` | the observed profile, only if the runtime sample is `:consistent`, `hold` is `:released`, and eligibility passed inside the bracket; otherwise nil |
| `effective`, `refusal` | from the same bracketed eligibility (2a). When the sample isn't consistent: `effective: nil` with `refusal: :status_inconsistent` or `:status_unavailable` |
| `ledger_observation` | `:valid` (the coordinator row and its owner were validated) \| `:unavailable` \| `:not_applicable` |
| `runtime_observation` | `:consistent` \| `:inconsistent` \| `:unavailable` \| `:not_applicable` |
| `published_at` | the validated coordinator row's publication time, else nil |

**Unknown ledger fields don't block eligibility.** When the runtime is
consistent and released, but `desired_profile` or `switch` is `:unknown`
(a failed read), eligibility still follows the runtime and the ledger
fields show `:unknown`. The reason: before any switch work, the
coordinator **holds** the server, and a hold is a runtime fact. So a
released, consistent server isn't mid-switch. An unknown ledger field
only means the last read failed.

**When the coordinator publishes.** Only the coordinator's own process
writes its protected table, after the outcome of each of its own bounded
reads and writes: the boot reads of the setting and the switch, and
`request`, `block`, `complete`, `fail` and `resolve`. It never publishes
inside `publish` or on a status read, and it adds no database read.

**Lag intervals,** all acceptable:

| Interval | What status shows |
|---|---|
| The caller commits a request, then casts to the coordinator (`request_switch/2`) | the previous confirmed observation, for example `%{state: :none, confirmed_at: <older>}`, until the coordinator handles the cast and publishes. No synchronous publication of another process's write is promised |
| An uncertain finalization or resolution, until it is settled | `switch: :unknown`, `desired_profile: :unknown`, and `stage` as published (`:finalizing` or `:settling`) |
| A failed read | `:unknown` for that field |

### 2a. The bracketed sample

**The coordinator's row.** It is one ETS row with a public part (the
fields above) and a private part, which is never returned by either
`Runtime.status/0` or `Coordinator.status/0`. `Coordinator.status/0` is
sanitized to the public part. The private part holds:
- the coordinator's own pid;
- the bound server pid, or `:none`;
- the start id;
- the boot id.

**One attempt** is read-only, and calls neither process:
1. **C1:** read the coordinator row. Check that the table's owner is
   `Process.whereis(Coordinator)` and matches the row's private
   coordinator pid.
2. **S1:** if the row binds a server, read the server's status table
   once:
   - its identity: the table id and owner, where the owner equals both
     `Process.whereis(ClaudeCLI.server())` and the row's bound pid;
   - every runtime value status needs: the profile, admission, held, and
     the attestation view.
3. **Eligibility,** computed **inside the bracket** as a pure function
   of C1, S1 and the permitted read-only checks:
   - the pin's file metadata (`PinnedExecutable`, no CLI run);
   - the staging configuration.

   It is the same check logic `resolve/1` uses, factored out. `resolve/1`
   keeps its behaviour for real calls. Status never calls `resolve`,
   `details` or the attestation again by registered name outside the
   bracket.
4. **S2, then C2:** re-collect the server view with its identity, then
   the coordinator row with its owner.

**The outcome of an attempt:**
- **Consistent:** C1 = C2 and S1 = S2, and every owner matches its
  binding.
- **Otherwise, retry,** up to three attempts. A later wholly consistent
  attempt succeeds.
- **After three:**
  - **The coordinator check fails or is missing:** `ledger_observation:
    :unavailable`, with the ledger fields and the runtime fields
    `:unknown`.
  - **The coordinator is valid, but the bound server's table is missing,
    or its owner or name doesn't match:** `ledger_observation: :valid`
    (the ledger fields as confirmed in C1), and `runtime_observation:
    :unavailable` with the runtime fields `:unknown`. A missing server
    isn't positively established, so it is never reported as `:none`.
  - **Both exist but keep changing:** `runtime_observation:
    :inconsistent`.

  A positive combination is never synthesized from parts of different
  attempts.

**No raw pid, ref or capability** is in any public status.

### 2b. Shapes in every case

| Case | ledger | runtime | `desired_profile` / `switch` | `observed_profile` | `hold` / `stage` | `effective_profile` | `effective` / `refusal` | `published_at` |
|---|---|---|---|---|---|---|---|---|
| **Fake provider** | `:not_applicable` | `:not_applicable` | `:not_applicable` | `:not_applicable` | `:not_applicable` | nil | as today (`effective: Fake`) | nil |
| **ClaudeCLI, no coordinator or row** | `:unavailable` | `:unavailable` | `:unknown` | `:unknown` | `:unknown` | nil | nil / `:status_unavailable` | nil |
| **Coordinator invalid** (owner mismatch, changing) | `:unavailable` | `:unavailable` | `:unknown` | `:unknown` | `:unknown` | nil | nil / `:status_unavailable` | nil |
| **Coordinator valid, no bound server** (none yet, or a known failed start) | `:valid` | `:consistent` | confirmed | `:none` | published | nil | nil / `:provider_not_running` | C1's |
| **Coordinator valid, bound server missing or unbound** | `:valid` | `:unavailable` | confirmed | `:unknown` | `:unknown` | nil | nil / `:status_unavailable` | C1's |
| **Both valid, but changing** | `:valid` | `:inconsistent` | confirmed | `:unknown` | `:unknown` | nil | nil / `:status_inconsistent` | C1's |
| **Consistent, hold `:held`** | `:valid` | `:consistent` | confirmed or `:unknown` | the profile | `:held`, stage | nil | nil / `:provider_held` | C1's |
| **Consistent, hold `:pending`** | `:valid` | `:consistent` | confirmed or `:unknown` | the profile | `:pending`, stage | nil | nil / `:provider_held` (a pending hold counts as held) | C1's |
| **Consistent, released, eligibility passes** | `:valid` | `:consistent` | confirmed or `:unknown` | the profile | `:released` | the profile | `ClaudeCLI` / nil | C1's |
| **Consistent, released, eligibility refuses** (pin, staging, admission) | `:valid` | `:consistent` | confirmed or `:unknown` | the profile | `:released` | nil | nil / that reason | C1's |

**`profile_id` and the model fields** (`model_alias`, `model_id`,
`reviewed_version`) follow the known `observed_profile`, then the
confirmed `desired_profile`. Otherwise they are **nil**, never the
registry default. The reviewed registry identity and the per-call init
attestation stay separate.

**`Runtime.desired_profile/0`:**
- **When ledger observation is `:valid` and the desired profile is
  confirmed:** `{:ok, %{profile_id, source, confirmed_at}}`.
- **Otherwise, for ClaudeCLI:** `{:error, :unknown}`.
- **For the Fake:** `:not_applicable`. This means only that no real
  profile is configured. It never claims a stored setting is absent.

**Callers:** `runtime.ex` (`details/1`) and
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
| Coordinator published record (runtime) | Existing (delta) | What operators see | **Public, added:** `desired` (`%{profile_id, source, confirmed_at}` \| `:unknown`), `switch` (`%{state: :none, confirmed_at}` \| `%{state: :open, …, confirmed_at}` \| `:unknown`), `published_at`. **Private, added, never returned** (`Coordinator.status/0` is sanitized): the coordinator pid, the bound server pid or `:none`, the start id, the boot id | — | Written only by the coordinator, after its own bounded reads and writes. `publish` makes no database read. An uncertain or failed outcome publishes `:unknown`, never a stale value as current. No raw refs | written by the coordinator; read in-node (protected ETS) | none |
| `Runtime.status/0`, `Runtime.desired_profile/0` (runtime read API) | Existing (delta) | The admin card | the keys and shapes in 2 and 2b (`ledger_observation`, `runtime_observation`, `effective_profile`, `published_at`); `desired_profile/0`'s tagged result; eligibility factored out of `resolve/1` as a pure function | — | No database read, coordinator call or write. Permitted read-only work: pin file metadata. At most three attempts (C1, S1, eligibility, S2, C2). No positive value from parts of different attempts. A missing server is never `:none` unless the coordinator positively has none. No default on unknown | unchanged (the admin page) | none |

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
9. **The bracket:**
   - a barrier **after S1**, then a replacement server with the same
     profile, then a change of hold or admission → no positive
     eligibility from mixed samples; a later consistent attempt succeeds;
   - a coordinator restart between C1 and C2;
   - the server table deleted and recreated mid-attempt;
   - three changing attempts → `:inconsistent` or `:unavailable`.
10. **The lag intervals,** with barriers around commit, publication and an
    unknown outcome:
    - a committed caller request shows the older `%{state: :none,
      confirmed_at}` until the coordinator publishes;
    - an uncertain outcome shows `:unknown`;
    - a failed read shows `:unknown`, with eligibility still following the
      consistent runtime.
11. **No side effects:** across 8–10, zero database queries (a
    query-telemetry trace), zero coordinator messages (a trace), zero
    writes (counts of events, starts and switches), zero launches and
    reservations, and no CLI run. Only pin file metadata is read.
12. **No default on unknown:** with no bound server and an unknown desired
    profile, `profile_id` and the model fields are nil.
13. **`desired_profile/0`:**
    - Fake → `:not_applicable`, even with a stored Sonnet setting;
    - a valid, confirmed observation → `{:ok, …}`;
    - otherwise → `{:error, :unknown}`.
14. **Sanitized:** neither `Coordinator.status/0` nor `Runtime.status/0`
    returns a pid, a ref or the private binding.
15. **A regression budget:** in a controlled test, `status/0` returns
    within 50 ms while the coordinator is blocked in a ledger call (a
    test-only pause). This is not a wall-clock promise under load.

## Open questions

- **OQ-1 (for the owner):** the narrowing in section 0. **Recommendation
  (Claude and Codex): yes.**
- **OQ-2 (Codex: a qualified yes):** a real `ProfileSupervisor` stop and
  start, plus a simulated loss of VM-local state, is accepted as the
  scoped hermetic lifecycle test. It is labelled as not a BEAM restart
  and not proof of OS cleanup. An isolated disposable BEAM test would be
  optional, stronger evidence.

## RED gate record

- **Round 1** (`b659d21`): NEEDS-REVIEW (Codex `098ce609`,
  `codex-c202c-b659d21-red-review.md`). The must-fix is 5A/B: a new boot's
  fencing allocation is an intent, and is allowed. Only launch, readiness,
  hold release and repeated spawning over a retained dead lease are
  forbidden. Plus cleanup and warning hygiene.
- **Staged qualification.** Restart tests 5A, 5B and 5C stop at b2β's
  resolver guard in both the real and the mutant runs. They are **staged
  and unverified** for C2-02c's downstream recovery and status behaviour
  until b2β GREEN lands. Then they are re-run, and their intended-reason
  evidence is reviewed before the affected C2-02c GREEN.
- **The b2α boot gap** (3A′ and 3B′): fixed as a b2β GREEN prerequisite
  (`c2-02b2b-interface.md`, "Prerequisite correction"). C2-02c keeps its
  integration tests.
