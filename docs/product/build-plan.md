# MVP build plan

Revision: **v3.1 (2026-10-14).** §4 gains the S2–S5 re-plan (forecast v2.2) and §7 gains the early-warning tripwires, both approved by the owner on 2026-10-14 (D-110, D-111). Everything else is v3 as approved.

Status: **approved by the owner on 2026-10-11** (walkthrough row 22, D-097). Codex approved this exact text (v3, sha256 7866ee5f…) for owner presentation; Codex's private reviews of v1, v2 and v3 are kept outside git. Approval of the plan is not a G5, an entity PASS or a build start. Budget grants in §8 were granted by the owner with the preconditions recorded in row 22; until those preconditions and contract C9 are met, the real-model budget remains 0.


Date: 2026-10-11 (Sun). Supersedes v2 (sha 44a39637…) after Codex re-review
codex-build-plan-v2-review-20261011.md (sha 0a02ece5…, CHANGES REQUESTED,
narrow), which followed v1 (sha c93a0912…) and its review (sha 373b81d6…).
Scope source: docs/product/walkthrough-2026-10-09.md @ owner-decisions daa5aba
(rows through 21b; D-084..D-096 proposed). Residual inventory: read-only scan of
origin/main b2a946a.

Status of this document: a plan for owner approval. Nothing here is a G5, an
entity PASS, a build start or a spend grant. Budgets in §8 are proposals until
the owner explicitly grants them; the confirmed real-model budget is 0.

## 0. What changed

v2 → v3 (Codex v2 review):

| Finding | Change |
|---|---|
| MF1 billing | §8: no zero-cost claim; owner-confirmed billing posture is a grant precondition (§11). |
| MF2 data flow | §9a: the actual storage and processing flow, stated truthfully; real-content telemetry capture off. |
| MF3 entity trigger | §3: full trigger; per-contract yes/no evaluation. |
| MF4 schedule | §3/§4: C3 implemented and merged in S1; C4 first PR of S2 with an explicit consumer fence. |
| I1-I4 | C2 rollback guarded; C9 atomic admission, launch-time eligibility, reserve rules (transfers later withdrawn, D-099); workshop-day expiry; provider billing windows; 35% allowance measured at S1 review. |

v1 → v2:

| Finding | Change |
|---|---|
| MF1 | §1 milestone column. Owner chose (D-094): all ten epics targeted for Oct 30; R0, B1, H1-core, B2 are the protected core. Non-core slip goes to the owner the same day. |
| MF2 | B5 includes the interested-reply draft (D-025). Referral rule per D-095. One common admission/qualification path (contract C3). |
| MF3 | §3 dependency table with contract IDs, authors, reviewers, consumers. B1 → H1 contract C1 made explicit. B4 cross-lane edges. Minimal B1 settings (C4) vs B8 editors. B6 extends C3. HubSpot portal checkpoint before B6. |
| MF4 | §5 capacity: one deep review per agent, WIP limits, review/rework allowance. §6 dependency-aware queue. |
| MF5 | §8 full grant definitions incl. two R0 profiles (D-096), attempt counting, allocations, expiry, enforcement contract C9; Brave/Exa allocation. |
| I1 | §2 residual inventory per epic; §4 forecast split into core vs all-ten with checkpoints; day convention stated. |
| I2 | §9 real-source readiness list. |
| I3 | §10 coverage checklist. |
| I4 | C2 includes full quiescence/rollback/provenance terms. |
| I5 | §7 escalation: mandatory stops immediate; all slips in same-day status. |
| Optional | RC tag ≠ acceptance (§4); owner checkpoint register (§11); Slice A review kept as history, fixes carried only where reused. |

## 1. Epics and milestone coverage

"Core" = must be in the Oct 30 RC and is never put at risk for non-core work.
"Target" = planned for Oct 30; if projected past Oct 29 the owner chooses that
day between Nov 6 and post-workshop. The Nov 6 demo script is set by the owner
at RC acceptance from what passed.

| ID | Epic | Milestone | Author → reviewer |
|---|---|---|---|
| R0 | Model runtime: app-only pinned Claude CLI on owner subscription; provider seam; two reviewed profiles (Opus, Sonnet); in-app audited switch; status without a model call | Core | Claude → Codex |
| B1 | One real prospect end to end: manual add, Brave+Exa research under default brief, first-touch email from offering + writing guide, approve/edit/reject from Home, capture | Core | Claude → Codex |
| H1 | Home inbox core: inbox item contract, draft-review rows acted in place, failure/timeout rows with explicit re-run, empty state, status page split | Core | Codex → Claude |
| B2 | Finding real people: account search (Brave/Exa, ABM lists), one active target per company, attended LinkedIn, owner's email/phone algorithm, contact-candidate lane | Core | Claude → Codex |
| B3 | Channels: LinkedIn message + call notes drafts, call-notes template, owner-reported send, one-click outcomes; their Home rows | Target | Codex → Claude |
| B4 | Sequences: default 3-5 touch mixed-channel sequence, follow-up drafting on `sdr.followup.due`, research refresh per touch; due rows on Home | Target | Claude → Codex |
| B5 | Replies: owner-entered replies classified; interested-reply draft with booking link; referral handover; OOO pause/resume; Home rows | Target | Codex → Claude |
| B6 | Intake: CSV import and HubSpot import through C3 (same admission/dedupe/qualification); extends B1 manual add | Target | Codex → Claude |
| B7 | HubSpot writeback: timeline notes, reviewed creates, suppression writeback, sync preview + durable dispatch; field-ownership table | Target | Codex → Claude |
| B8 | Settings and results: editors for briefs, limits, offering, writing guide, call-notes template; results per campaign and overall | Target | Codex → Claude |

Home is not "done" at H1: each producing epic owns and tests its own row kinds
(§10). H1 owns the framework, draft and failure rows, empty state and status page.

## 2. Residual work per epic (exists on main vs to build)

| Epic | Exists (reuse after invariant check) | To build | First demonstrable outcome | Owner checkpoint |
|---|---|---|---|---|
| R0 | ModelProvider facade with reserve/sent/validate/record; ClaudeCLI with attestation; Runtime.children/resolve/status; Reaper with admission lease; AdminLive provider status; per-run + UTC-day model limits; ~60 provider tests | App-only CLI runtime decoupled from agent CLIs (pin currently hard-coded 2.1.291, system now 2.1.294 → fail-closed); profile registry replacing hard-coded alias/model/version; persisted active-profile setting + audited switch action with quiescence; grant enforcement C9; Sonnet profile attestation | Admin shows both profiles; switch Opus→Sonnet and back with audit rows; one proof attempt per profile | ADR-0004 amendment; CLI install (owner sudo if needed); R0 grant |
| B1 | Research flow (CRM history, website, search, page read, evidence bundle with verbatim quotes + spans); drafting flow with claim/personalization validation and citations; approval binding (revision sha + recipient); capture-only delivery; Sales.create_lead/contact/account (no caller) | Manual-add UI + C3 admission path; Brave + Exa adapters and real safe-fetch adapter (only fixture adapters today); default research brief in code (doc on research-brief branch); offering profile, booking link, writing guide (C4 minimal); real-data guard policy per constraint-7 amendment (today reserved-domain-only, blocks all real data); Home approve/edit/reject via C1 | One real company researched with cited claims, draft on Home, approved, captured | Constraint-7 ADR; Brave/Exa keys in sops (owner); offering + booking link + guide sign-off; Brave/Exa allocation |
| H1 | DashboardLive (read-only counts, oldest drafts, attention); DraftLive actions (edit/approve/reject/revoke); OperationsLive failures; Outreach review queue | Inbox item projection (C1) with freshness + authorization + exact subject/revision; actions in place reusing DraftLive domain actions; failure/timeout rows with guarded re-run; empty state; status page split from `/` | Home shows a draft row, approve in place, row disappears; empty state | H1 G5; hands-on try |
| B2 | Account/Contact/Lead resources; unique domain/email/open-lead identities; ICP definition | Company discovery search, ABM list import, account-level active-target rule, LinkedIn attended flow (deterministic, human-paced, CAPTCHA stop), owner algorithm, contact-candidate fields (phone, LinkedIn URL, per-source candidates) never auto-promoted | Search a target set, pick one account, find one person, candidate contact with source | Mockups (agents, by Oct 15); algorithm walkthrough (owner, target Oct 16-17); LinkedIn screenshot-citation storage decision |
| B3 | `SequenceStep.channel` (email only) | Channel enum + per-channel draft artifacts (C6); call-notes structure + template; owner-reported send and outcome logging; Home rows | LinkedIn message and call notes for the B1 prospect; mark sent / log call from Home | Call-notes template sign-off |
| B4 | Sequence/step/enrollment/campaign; advance_step scheduler; FollowupWorker emits `sdr.followup.due` (unrouted); stop-on-reply (apply_reply) | Route `sdr.followup.due` to drafting; mixed-channel default sequence; research refresh per touch; how owner-reported sends advance or pause; due rows | Second touch drafted with a fresh angle from refreshed research | Default sequence steps sign-off |
| B5 | Signed simulated reply webhook; classification (8 labels) with human override; suppression + apply_suppression; hand-off queue | Owner-entered reply UI; interested-reply draft (booking link, no times, no calendar); referral handover per D-095 via C3; OOO pause/resume; Home rows | Paste a referral reply → original closed "referred", new target researched, draft names referrer | Booking link (C4) |
| B6 | Identities only | CSV import with validation + dedupe through C3; HubSpot import (ADR-0013 import side, A1/A2 entity findings) | Import a synthetic CSV; rows land as leads that go through qualification | HubSpot portal/scopes read-only check (owner, before B6 build) |
| B7 | CRM behaviour (update_contact/record_activity, fake read-only); email delivery outbox pattern | HubSpot client, CRM outbox with stable keys, sync preview + dispatch, field-ownership table, suppression writeback, no blind retry of unknown writes | Preview + confirm one timeline note to the dev portal | Field-ownership table; no-messaging-automation check (owner) |
| B8 | Caps shown read-only on Admin; send quota day counter; pipeline counts | Persisted settings with run snapshot (extends C4); editors; results definitions (agent output, founder time, quality, usage vs caps, owner-reported pipeline); per campaign + overall, on-screen only | Change a campaign limit with audited confirmation; results page | Results definitions sign-off |

Not ten greenfield builds: R0, B1, B4, B5 reuse substantial reviewed code; B2,
B3, B6, B7, B8 are mostly new.

## 3. Shared contracts and dependencies

Each contract is a narrow PR (resource/action/projection + positive and negative
contract tests), one accountable author, one independent reviewer. Entity
review uses the project's full trigger (persisted concepts, meaningful
attributes/invariants, relationships/cardinality, ownership/authorization,
lifecycles, backend action/event contracts); each contract records an explicit
yes/no evaluation, and a triggered delta needs an independent PASS before its
implementation is approved (UNREVIEWED blocks). This table is not itself an
entity delta or a PASS. Consumers may draft against a reviewed spec but build
behind a contract only after it merges.

| ID | Contract | Author → reviewer | Consumers | Merged by | Entity trigger |
|---|---|---|---|---|---|
| C1 | Inbox item: kind, subject ref + exact revision/channel, producer, allowed actions, freshness, authorization, resolution | Codex → Claude | B1, B2, B3, B4, B5, B7 | S1 end | yes: new projection, actions, authorization |
| C2 | Model profile + switch: closed reviewed profile registry; active-profile setting; switch fences new admission, waits for prepared/reserved/queued/in-flight calls under the old profile, each invocation freezes its expected profile, old provenance kept, unconfirmed Reaper lease never released to start another model; configured vs active/pending/blocked shown truthfully; failed activation rolls back to the previous profile; restart restores the persisted active profile. Desired (persisted) vs effective (process) profile kept distinct; abandoned prepared callers drained or refused; switch wait bounded; failed activation never starts a rollback process over unconfirmed candidate work | Claude → Codex | all model callers, Admin, H1 status | S1 | yes: persisted setting, switch action, lifecycle, provenance |
| C3 | Lead admission: manual/CSV/HubSpot/agent-found/referral enter one path → dedupe → mandatory research → qualification; source provenance; one active outbound target per company with history; referral closes original as "referred" and admits the referred person | Claude → Codex | B1, B2, B5, B6 | S1 end | yes: admission lifecycle, active-target invariant, referral |
| C4 | Run settings (minimal): offering profile, booking link, writing guide, default research brief, operational limits within fixed safeguards; snapshot per run. B1 ships admin-only input forms; B8 adds full editors without changing the contract | Claude → Codex | B1, B3, B4, B5, B8 | S2 day 1 | yes: persisted settings, run snapshot |
| C5 | Source providers: Brave + Exa adapters, real safe fetch, per-provider quota counter on each provider's billing window checked before each request (requests incl. pagination, retries, content fetches; Exa dollars too), real-data guard policy matching the constraint-7 amendment, content recording per §9a | Claude → Codex | B1, B2, B4 | S2 | yes: quota counter, real-data guard invariant |
| C6 | Channel touch: channel enum (email, linkedin_message, call), per-channel draft, owner-reported send/outcome (owner-attested, never wire-confirmed), effect on enrollment | Codex → Claude | B4, B5, B7, B8 | S2 end | yes: channel enum, owner-attested outcomes, enrollment effect |
| C7 | CRM outbox: stable keys, preview, durable dispatch, pending/done/failed/unknown, no blind retry | Codex → Claude | B7 (B6 reads) | S4 | yes: outbox lifecycle, unknown-write handling |
| C8 | HubSpot import: portal identity, scopes, field mapping, suppression import | Codex → Claude | B6 | S3, after portal check | yes: external identity, field mapping, suppression import |
| C9 | Grant enforcement: persisted grant (purpose, profiles, total, per-UTC-day, per-allocation, expiry, reserve) with grant+run+day admission in one transaction under the existing lock order; idempotent (a duplicate never consumes twice); eligibility, expiry and revocation re-checked at actual launch, and a reserved call that became ineligible is refused, never run under another grant or profile; allocations and reserve survive restart; exhaustion → typed refusal + inbox row + Telegram | Claude → Codex | all model callers | S1, before any R0 proof | yes: grant admission invariant, allocations |

Epic dependencies (→ = needs):
R0 → C2, C9 · H1 → C1 · B1 → R0, C1, C3, C4, C5 · B2 → C3, C5, algorithm,
mockups · B3 → C1, C4, C6 · B4 → C6, C1, C5, B5 stop/pause semantics ·
B5 → C1, C3, C4 · B6 → C3, C8, portal check · B7 → C6, C7, portal check ·
B8 → C4, B3-B5 outputs for results.

Critical chain: C9+C2 → R0 proof → (C1, C3, C4, C5) → B1 loop → B2.

## 4. Calendar

### 4.0 v3.1 re-plan, S2 to S5 (approved 2026-10-14, D-110)

Forecast v2.2. Codex approved it for owner presentation (62b886c0), after
review rounds b27ee237, 1fad17f1 and c710d8ae. The owner chose option C,
"i choose option C" (about 10:29 MDT): re-plan S2 to S5 now and run R0
first for 48 hours, with independent work in parallel. The owner approved
the forecast with "i approve but we're going to have to be more
disciplined about early notifications if it looks like we're falling
behind" (about 10:55 MDT). That led to the tripwires in §7.

This is a plan revision. It is not a G5, an entity PASS or a grant. Every
gate, the WIP limits, the protected S6 and same-day slip reporting are
unchanged. **The S2 to S5 rows of the v3 table below are superseded by
this section.** The S0, S1, S6 and Oct 30 rows, and the forecast-honesty
rules, still apply.

**S1 close.** 9 of 25 stories closed; the exit was **not met**. Every
open S1 story is carried forward with a new date. Nothing is closed by
relabeling.

**Core work is lopsided.** About 30 open core stories are in the Claude
lane (C9-04, C9-06, C2-02, R0-04 to 07, C3-01 to 03, C5-01 to 04, C4-01,
B1-01, B1-03 to 07, B2-01 to 08). There are 7 in the Codex lane (C1-01
to 03, H1-01 to 04).

- That is a rough count, not a rate. Stories vary widely in size: R0-07
  was one story and about 12 PRs.
- So the Claude lane is the critical resource, and the Codex lane has
  core slack once C1 and H1 are done.
- **All dates below are low-confidence.** They are calibrated at the
  Oct 15 gate review against measured time.

| Window | Claude lane | Codex lane | Owner | Exit / check |
|---|---|---|---|---|
| Oct 14–15 (48h R0-first) | #146 merge; C2-02; R0-04; R0-05; C9-04, C9-06 | C1 authoring and, once its owner gates pass, the C1 build (then exact-head green CI, then merge); review Claude's R0 PRs. C3-01 and C4-01 already have entity PASS | Merge #146; create G-R0; book the attended proof slot; B1 inputs; confirm the B2 walkthrough Oct 16–17; ADR-0015 amended text and scoped C1 G5 (H1 G5 is separate); C3: ADR-0009 amendment, OQ-1..3, scoped G5 (C3 also depends on C4's ADR-0005 logging amendment); C4: ADR-0005 logging amendment, OQ-1..7, the PostgreSQL server-log prerequisite, scoped G5 | **S2 gate review, end of Oct 15:** each R0 item has an owner and a date, or a same-day slip |
| Oct 16–17 | R0-06 proof (attended, before G-R0 expires; **conditional** on #146 merged, G-R0 created and C2-02, R0-04/05, C9-04/06 merged; §3 puts C9 before any R0 proof) and the tuple promotion PR; C3-02/03 once C3's owner gates pass; C4 build once C4's owner gates pass; B2-01 mockups, then the B2-02 walkthrough | H1-01..03; review C3/C4 | Attended proof; B2 walkthrough; H1 G5 | R0 proven, both profiles (conditional); C1 merged if its gates passed; C3 and C4 in review |
| Oct 18–20 (S3) | C5-01, C5-03/04, and C5-02 unless transferred; B1-01 G5 packet, then B1-03..05 | H1-04 and H1 acceptance; **possible lane transfer, decided at the Oct 15 gate review:** one build story with a named author, reviewer, prerequisites and start date, or none and a re-forecast. Candidates: C5-02 (adapters; only useful if it can start before H1 acceptance) or B2-03 (account discovery). A candidate sits in one lane only | B1 G5; B2 G5; Brave/Exa keys after C5-01 | **End-S3 checkpoint:** H1 accepted; B1 loop drafting |
| Oct 21–23 (S4) | B1-06/07 (Home and the real acceptance run, G-DEMO); B2-04..06, and B2-03 unless transferred | The transferred story, if any; B3/B5 only without core contention | B1 acceptance; HubSpot portal check only if B6/B7 are kept | B1 accepted (stretch Oct 23) |
| Oct 24–26 (S5) | B2-07/08 | Review B2; non-core as capacity allows | B2 acceptance | B2 accepted (plausible Oct 26–29) |
| Oct 27–29 (S6) | Protected integration and rehearsal 1 | same | Full rehearsal | RC candidate (at risk) |

**Forecast (Codex's numbers; Claude concurs):**

- **R0 proven: Oct 17, conditional.** It needs #146 merged, G-R0 created
  by Oct 15, C2-02, R0-04/05 and C9-04/06 merged, and the attended slot
  holding.
- **H1 accepted:** Oct 20–23.
- **B1 accepted:** Oct 23–26.
- **B2 accepted:** Oct 26–29. This is conditional on C3, C5 and the
  Oct 16–17 walkthrough.
- **Core four by Oct 23:** a stretch, not the baseline.
- **The Oct 30 RC is at risk,** because B2 can collide with S6.
- **On any further R0, C3 or C4 slip:** re-forecast immediately. S6 is
  never spent silently.

**Candidate non-core cuts,** named now and decided on S2 evidence. They
are listed in the order they would move past Oct 29, most likely first:

1. B7 HubSpot writeback (C7, B7-01..04): portal-dependent, the riskiest
   new integration.
2. B6 intake (C8, B6-01..04). CSV (B6-02/03) could be kept on its own.
3. B8 editors (B8-02/03). C4's admin-only forms cover the MVP inputs.
4. B4 sequences (B4-01..06). It needs C6 plus B5 semantics.
5. B3 channels and B5 replies: the last to cut.

Codex's S2 work on C6 (#88–#90), B3-01 (#101) and B5-00 (#105) waits
until C1 and H1 are done. It is not cancelled.

**Measurement:** authoring, review, correction and CI time per PR is
tracked daily and resets the 35% allowance (§5). "Contracts closed versus
planned" is reported at each standup.

**Milestones:** GitHub milestones are updated by moving issues between
them, never by closing issues.

### 4.1 v3 calendar (approved 2026-10-11; S2–S5 rows superseded by 4.0)

Day convention: build days Oct 12-29 = 18 calendar days in six sprints; Oct 30
is RC acceptance, not build capacity. Today (Oct 11) is planning only.
Sprints close early when their exit is met and the next sprint is pulled
forward (D-092). Owner sprint planning at start, hands-on review at end (owner
tries uncoached), short retro.

| Sprint | Lane 1 (Claude) | Lane 2 (Codex) | Owner | Exit |
|---|---|---|---|---|
| S0 Oct 11 | Plan v2; backlog draft | Re-review plan | Approve plan, grants; backlog preview | Plan + backlog approved |
| S1 Oct 12-14 | In order: C9, C2, R0 build + proof, C3 build (all source kinds enumerated, tested); B1 requirements + prototype | C1; H1 requirements, prototype, entity review; review R0 | ADR-0004 amendment, constraint-7 ADR, R0 grant, keys, offering inputs, H1/B1 G5 | R0 merged, both profiles proven; C1 + C3 merged |
| S2 Oct 15-17 | C4 first (day 1; B1 drafting waits on its merge), C5, then B1 build; B2 mockups | H1 build; C6; B3 requirements | Algorithm walkthrough (Oct 16-17); B2 G5; B3 G5 | B1 real loop through Home; H1 accepted |
| S3 Oct 18-20 | B2 build | B3 build; B5 requirements + build start; C8 | HubSpot portal check; B5/B6 G5 | B3 accepted; B2 search + people working |
| S4 Oct 21-23 | B2 finish; B4 build | B5 finish; B6 build; C7 | B4/B7 G5 | Core four accepted (target Oct 23) |
| S5 Oct 24-26 | B4 finish; review | B6 finish; B7; B8 | B8 G5 | All target epics merged or escalated |
| S6 Oct 27-29 | Protected: integration, acceptance tasks, recovery/restore, rehearsal 1 | same | Full rehearsal | RC candidate |
| Oct 30 | RC tagged | | Acceptance (tag ≠ acceptance) | Accept / fix list |
| Oct 31-Nov 5 | Owner daily use; fixes only; rehearsal 2 | | Nov 6 script | Workshop claims fixed |

Forecast honesty: the core four target end of S4 leaves S5 + S6 as buffer.
The all-ten plan is a stretch target, not an evidence-backed forecast yet:
B2 (algorithm unknown, LinkedIn reliability), B6/B7 (portal capabilities,
ADR-0013 findings) and B8 (late) carry the risk. Checkpoints: end S2 (core
projection), end S3 (non-core projection). A non-core epic projected past Oct 29
goes to the owner that day; no unfinished scope moves into S6 silently.

## 5. Capacity and WIP

- The 35% allowance and half-day review target are provisional planning
  assumptions; S1 review compares actual contract completion and review
  turnaround with the core chain and updates the forecast.
- Each agent holds one deep review at a time and alternates authoring and
  reviewing at safe boundaries (after a commit, before starting a new story).
  Review is shared capacity, not extra slots; plan ~35% of each agent's time
  for review, rework and integration.
- WIP: at most one authored PR in review plus one in progress per agent.
- A ready review starts at the reviewer's next safe boundary (target within
  half a day); verdicts and blockers go out as soon as found, not at sprint end.
- Subagents do bounded, isolated work under one accountable author (file
  ownership, context, verification). The parent owns integration; subagent
  output is never the independent review.
- Every merge: exact-head CI + independent approving review; contracts whose
  full entity trigger fires (§3) also need entity PASS. Nothing waived for the calendar.
- Gemini (agy): non-binding analyst (eval cases, usability walks, docs checks).

## 6. Review queue (owner delegated ordering, D-091)

1. Mandatory stops, safety/security findings, broken main.
2. Ready work that unblocks the core chain (C1-C5, C9, R0/B1/H1/B2 prerequisites), whichever lane.
3. Other ready core work.
4. Ready prerequisites of target epics (e.g. C6 before B4).
5. Remaining ready work; smaller first, then older.
A blocked or unready PR never outranks a ready prerequisite. Lane labels do
not set priority.

## 7. Escalation (D-090, D-091)

- Immediate Telegram (bin/notify-telegram, sendMessage only, metadata only,
  project-tagged, no secrets or personal data): mandatory charter stop,
  safety/security failure, allowance exhausted or unknown model outcome, an
  owner decision blocking the core chain.
- Same-day status (chat, daily): done, next, waiting on owner, risks, every
  observed slip (any size), calendar delta.
- Harmless CI retries and routine progress are not notified.
- Waiting on the owner: pause that piece, continue other approved work.
- **Early-warning tripwires (v3.1, approved 2026-10-14, D-111).** A slip
  is reported as soon as it is projected, not once it is observed. If any
  one of these trips, the owner is told the same day in chat, with the
  date impact. For the critical chain, a Telegram goes out too if the
  owner might be away. Each lane applies them to its own work.
  1. **Growth:** a story needs more PRs or slices than planned, or its
     contract gains a new component.
  2. **Repeat findings:** the same item comes back "changes requested" a
     second time. This is a signal to report, not a cap on review rounds.
  3. **Age:** a critical-chain item has not started on its planned day,
     or runs past its planned window.
  4. **Owner gate:** an owner decision is needed within 24 hours and is
     not scheduled yet.
  5. **Daily line:** each critical-chain item gets "on track", "at risk"
     or "slipping" at standup, with the date change.

## 8. Budget grants (proposals; nothing authorized until the owner grants)

Common rules: a count is an application attempt (completed, failed, invalid or
unknown all count). Extra upstream exchanges observed by the witness are
recorded and reported but do not change the attempt count. An unknown outcome
is never retried automatically; a re-run is a new, explicit attempt. Day
boundary is the UTC day (matching existing daily limits). No standing
allowance is active (PR #37 open); these grants do not depend on it.

Billing posture (precondition for G-R0 and G-DEMO, owner checkpoint):
subscription use is not automatically free. If paid extra usage is enabled on
the account, usage past the plan's included limits is billed separately. The
owner confirms one of: (a) included usage only, extra usage disabled, stop at
the limit (recommended); or (b) extra usage allowed up to a dollar ceiling
the owner sets and checks in the account settings. Agents do not inspect
account settings or credentials. The app counts only its own attempts; the
owner's other Claude sessions share the same plan.

**G-R0 (profile proof).** Purpose: prove each reviewed profile end to end
through the app runtime and witness. Profiles: Claude CLI Opus and Claude CLI
Sonnet at the one pinned candidate CLI version. Input: synthetic fixed proof
prompt only. Count: 2 attempts per profile, 4 total, separate from G-DEMO.
Expiry: end of 2026-10-18 owner local time (proposed 2026-10-19 05:59 UTC, i.e. 23:59 MDT, if the owner is on America/Denver; owner confirms). Exhaustion before both profiles pass: stop,
Telegram, new grant request.

**G-DEMO (development evidence, acceptance, daily use, workshop).** Total 200
attempts, max 30 per UTC day, expiry end of the workshop day in the
owner's local time (proposed 2026-11-07 06:59 UTC, i.e. 23:59 MST, for America/Denver; owner
confirms the timezone and that it covers the workshop), both profiles.
Input: synthetic, plus real prospect data only after the constraint-7
amendment is accepted. Allocations:

| Use | Attempts |
|---|---|
| B1 evals + acceptance | 35 |
| B2 evals + acceptance | 25 |
| B3 evals + acceptance | 15 |
| B4 evals + acceptance | 20 |
| B5 classification + interested/referral drafts | 15 |
| S6 integration + rehearsal 1 | 25 |
| Owner daily use + rehearsal 2 (Oct 30-Nov 5) | 35 |
| Workshop reserve (Nov 6, held unless the owner releases it) | 30 |

Grant changes (superseded by row 22, D-099): only the owner changes a grant
(terms, allocations, reserve release, revocation), through the audited
owner-only form in the app; agents may ask for a change but never make one.
The earlier "agents may move up to 10 attempts" rule is withdrawn. Automatic
usage accounting (counting attempts against a grant) is not a grant change.
The reserve is usable only on the workshop day, or earlier only when the owner
releases it. Enforcement of totals, allocations, reserve and expiry: C9 at
admission and at launch, plus a daily ledger report.

**G-SRC (Brave, Exa).** The owner states each plan's request and dollar
ceilings, its billing window and reset, and the SDR share (proposal: 50% of
each, set by the owner). Every request counts, including pagination, retries
and Exa content fetches; Exa is also capped in dollars. Enforced by the C5
counter before each request, with per-research caps from the default brief.
The owner confirms each provider's terms allow the processing and storage in
§9a. Not active until the owner supplies the numbers.

## 9. Real-source readiness (before any real company or person data)

Owner-accepted constraint-7 ADR amendment; owner permission for the §9a flow; app guard policy changed to match
(today reserved domains only) with allow/deny tests; G-SRC allocation and key
injection by the owner through sops/with-secrets (agents never handle keys);
short retention/deletion rules written; accepted immutable-PII limits recorded;
fixtures and public evidence synthetic; LinkedIn screenshot citations decided
explicitly in B2's source contract (private local storage vs none) — not
assumed. HubSpot writes additionally need the owner's portal check for
recipient-reaching automations.

## 9a. Actual data flow for real sources (stated truthfully, for the owner's permission)

When real companies and people are enabled, the app as built today:

1. Calls Brave and Exa search APIs (query terms leave the machine); Exa content
   fetches return page text.
2. Fetches company web pages directly through the safe fetcher.
3. Stores the full fetched source content as an audit payload in local
   Postgres (Research StoreContent), not only cited quotes; claims keep
   verbatim quotes and character spans.
4. Sends prompts containing quoted research content and prospect fields to
   Anthropic through the Claude CLI on the owner's subscription.
5. Keeps raw model request and response bytes in the private wire-witness
   store on the local filesystem.
6. Keeps all of the above in the append-only audit trail; none of it can be
   erased in the MVP (limitation already accepted by the owner, D-038..D-045).

What stays out: git, GitHub issues and public artifacts (synthetic only);
OpenTelemetry content capture (dev currently sets `otel_capture_content: true`;
C5 turns content capture off whenever real data is enabled, under the existing
synthetic-only observability stance, with a test). The owner confirms the
search providers' terms and the model provider's terms cover items 1-5. If a
provider permits only bounded snippets, C5's recording contract stores only
those (trimming model input alone is not enough, because item 3 stores full
content).

## 10. Coverage checklist (decision → epic → test home)

| Behavior | Epic | Evidence |
|---|---|---|
| Home empty state = nothing needs the founder; status cards on separate page | H1 | LiveView test + owner try |
| Draft rows: fresh, authorized, exact revision/recipient; act in place | H1 (C1) + B1 | binding + policy allow/deny tests |
| Timeout/unknown rows: investigate + explicit re-run (new attempt, budget-counted, original kept, never auto) | H1 + R0 | unknown-outcome tests |
| Contact-candidate confirmation: separate from claims, never auto-promoted or CRM-overwritten | B2 | candidate lane tests |
| Referral: original "referred" in history; referred person researched before approval; referrer in subject and body | B5 (C3) | referral flow test |
| Interested reply: draft with booking link, no invented times, no calendar; unclear/sensitive → owner, no draft; fresh approval after edit; suppression blocks; capture only | B5 | reply-draft tests + synthetic signed replies |
| OOO pause and resume after return date | B5 + B4 | enrollment tests |
| LinkedIn manual send + call outcome logging, owner-attested; when it advances/pauses a sequence | B3 (C6) + B4 | channel tests |
| Call notes structure + editable template; no dialer | B3 (+B8 editor) | template tests |
| One research depth; default + campaign briefs; global/campaign limits vs fixed safeguards; run snapshot | B1 (C4) + B8 | settings tests |
| No bulk approve; no edit-learning | all | absent by design |
| Results: agent output, founder time, quality, usage vs caps, owner-reported pipeline; per campaign + overall; no invented rates; no export | B8 | results tests |
| HubSpot sync preview row, pending/done/failed/unknown, suppression writeback, never lift suppression | B7 (C7) | outbox tests |
| Common qualification for manual/CSV/HubSpot/agent-found; research never skipped | C3, B1/B6 | admission tests |
| One model call at a time | R0 | existing serialization tests |

## 11. Owner checkpoint register

| Checkpoint | Needed by | Blocks |
|---|---|---|
| Approve plan v3 + backlog | S0 | everything |
| Billing posture (included-only or dollar ceiling) | S1 day 1 | G-R0, G-DEMO |
| Timezone for grant expiries | S1 day 1 | G-R0, G-DEMO |
| Data-flow permission (§9a) incl. provider terms | S1 | B1 real data |
| ADR-0004 amendment (R0 pin, seam, switch) | S1 day 1 | R0 |
| G-R0 grant; CLI install with owner sudo if needed | S1 | R0 proof |
| Constraint-7 ADR amendment; retention rules | S1 | B1 real data |
| Brave/Exa keys into sops; G-SRC allocation | S1 | B1 real research |
| Offering profile, booking link, writing guide sign-off | S1 | B1 drafts, B5 |
| G-DEMO grant | S1 end | B1 evals onward |
| Algorithm walkthrough after mockups | S2 | B2 |
| HubSpot portal/scopes read-only check | S3 | B6, B7 |
| Field-ownership table; default sequence; call-notes template; results definitions | S3-S4 | B7, B4, B3, B8 |
| PR #37 accept/decline (standing allowance) | any | nothing in this plan |

## 12. Backlog

Epics = §1 rows; stories are small outcome slices with owner (author),
reviewer, consumer/dependency (contract IDs), acceptance behavior, gate evidence
and test/proof needs; done = evidence passed, not code written. GitHub Issues:
one label per epic, `lane:claude`/`lane:codex`, `core`/`target`, `risk:*`,
status labels; one milestone per sprint; project board. Requirements, gate
records and evidence stay in the git workbook; issues link them. No real
people data, URLs identifying people, payloads or credentials in issues. An
artifact board, if any, is a read-only projection with source-of-truth label.
Issues are created only after the owner sees the backlog.

## 13. Next

Codex re-review → owner approval of plan + grants → epics/stories draft →
owner backlog preview → GitHub Issues → S1 planning (Oct 12). In parallel:
decisions D-021..D-096 docs PR.
