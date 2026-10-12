# MVP backlog (draft for owner preview)

Status: draft, merged from Claude's lane-1 and Codex's lane-2 drafts
(2026-10-11) against docs/product/build-plan.md. Not yet in GitHub Issues;
nothing here is a G5, an entity PASS or a build start. Stories become issues
only after the owner's preview.

**How to read.** Epics are the plan's rows (R0, B1, H1, B2-B8) plus shared
contracts C1-C9. A story is a small outcome; it is done when its acceptance
behavior passes with exact-head CI, an independent approving review, an entity
PASS where triggered, and owner acceptance where marked. Sprint is the target
pull order; sprints close early when done (D-092). Lane 1 = Claude authors,
Codex reviews; lane 2 = Codex authors, Claude reviews. P-xx are future
readiness packets (requirements, entity delta, G5), not approvals.

## Sprint view

| Sprint | Lane 1 (Claude) | Lane 2 (Codex) |
|---|---|---|
| S1 Oct 12-14 | C9-01..06 grant enforcement + owner grant form; R0-01..06 + C2-01..02 model runtime, profiles, switch, proof; C3-01..03 lead admission; B1-01 requirements/prototype; B1-02 real-data rule change; C5-01 search secrets file | C1-01..03 inbox contract; H1-01 Home journey prototype |
| S2 Oct 15-17 | B4-00 stop/pause/advance rules (C6 input); C4-01 settings; C5-02..04 Brave/Exa, safe fetch, real-data guard; B1-03..07 one real prospect end to end; B2-01 mockups; B2-02 algorithm walkthrough | H1-02..04 Home inbox, review in place, failure re-run; B5-00 reply/outcome effects (C6 input); C6-01..03 channels contract; B3-01 channel prototype |
| S3 Oct 18-20 | B2-03..06 account discovery, active target, people, attended LinkedIn | B3-02..04 LinkedIn message, call notes, outcome logging; B5-01..02 replies; B6-01 intake policy; C8-01..03 HubSpot import contract |
| S4 Oct 21-23 | B2-07..08 contact candidates, acceptance (core four done); B4-01..03 sequences, follow-up drafting, research refresh | B5-03..05 interested reply, referral, OOO; B6-02..04 CSV + HubSpot import; C7-01..03 CRM outbox; B7-01; B8-01 |
| S5 Oct 24-26 | B4-04..06 mixed channels, due rows, acceptance | B7-02..04 notes, creates, suppression; B8-02..04 editors, limits, results |
| S6 Oct 27-29 | Protected: integration, acceptance, recovery, rehearsal | same |

Story count: lane 1 44, lane 2 38, total 82.

## Reconciliation decisions

1. Grant changes are owner-only (D-099); the plan's agent-transfer rule is
   withdrawn. C9 owns grant terms and the owner form (ships in S1 with R0);
   B8-03 reuses it and adds no second grant policy. Usage accounting is not a
   grant change.
2. Inbox row producers: H1 owns draft and failure rows; C9 exhausted/expired
   grant rows and C2 pending/blocked profile status conform to C1; B2 owns
   contact-confirmation rows, B3 manual-send and call rows, B4 due follow-ups,
   B5 reply/referral/OOO rows, B7 sync-preview and unknown-write rows. Home is
   not complete until its producers land.
3. Cross-lane joins: C1-01 needs C2-01/C9-01 producer specs and B1-01; B1-06
   needs C1-03 + H1-03; H1-04 needs C2-02 + C9-03 + C9-05 (owner form link); C6-01 needs C3-02 + C4-01 + B4-00 + B5-00 (S2 decision stories, so C6 does not wait for the S3/S4 B4/B5 requirements);
   B4-01 needs C6-01; B4-05 needs B5-05; B5-04 needs C3-03; B6-01/C8-02 need
   C3-02; B8-03 needs C9-05.
4. **Owner question:** model calls for researching imported leads (B6),
   referred people (B5) and follow-up refresh (B4) need a home in G-DEMO's
   allocations. Proposal: imported and referred leads count under the B1 row
   (same research + first-touch pipeline), follow-up refresh under the B4 row.
5. HubSpot import (C8, A-side) and writeback (C7, Gate B) keep separate
   entity, portal, scopes, ownership and first-live-write checkpoints. The
   owner runs any probe that needs the key.
6. Search secrets: a local gitignored encrypted file with reviewed mapping
   (C5-01); the owner copies the keys after it merges. Limits still pending.

## Lane 1 stories (Claude authors, Codex reviews)

### C9 Grant enforcement (S1, first)

| ID | Story | Depends | Acceptance | Evidence |
|---|---|---|---|---|
| C9-01 | Grant entity delta | — | Delta covers grant fields (purpose, profiles, total, per-UTC-day, allocations, expiry, reserve), owner-only changes (no agent transfers, D-099), lifecycle | Entity PASS (Codex) |
| C9-02 | Grant admission at reserve time | C9-01 | Grant+run+day checked in one transaction, existing lock order; duplicate idempotency never consumes twice; typed refusal | allow/deny + concurrency tests |
| C9-03 | Launch-time eligibility | C9-02 | Reserved call that became ineligible (expiry, revocation, profile change) is refused at launch, never run under another grant/profile | tests incl. queued call across expiry |
| C9-04 | Allocations and workshop reserve | C9-02 | Per-use allocations enforced; no agent or system changes to grant terms (D-099); reserve usable only on workshop day or after owner release; survives restart | tests |
| C9-05 | Owner-only grant editor | C9-01 | Owner-only form creates, edits, revokes grants and releases the reserve with audited confirmation; other roles and agents denied server-side; revisioned terms; queued calls re-checked (C9-03) | policy allow/deny + LiveView tests; the owner personally creates G-R0 and G-DEMO |
| C9-06 | Exhaustion signal | C9-02 | Exhausted/ineligible → Failure (inbox row once C1 lands) + metadata-only Telegram | tests |

### R0 Model runtime (S1)

| ID | Story | Depends | Acceptance | Evidence |
|---|---|---|---|---|
| R0-01 | ADR-0004 amendment: app-only pin, seam, profiles, switch | — | Drafted, Codex-reviewed | Owner accepts |
| R0-02 | App-only Claude CLI runtime | R0-01, Owner (sudo if needed) | App uses its own pinned CLI install, unaffected by agent CLI updates; drift still fails closed | attestation tests; version evidence |
| R0-03 | Closed profile registry | R0-01 | Profiles claude_cli_opus, claude_cli_sonnet replace hard-coded alias/model/version; per-profile attestation and witness tuple; no free-text model | tests |
| R0-04 | Seam cleanup | R0-03 | One facade; documented success / known-failure / unknown; test-only adapter proves a new provider plugs in | contract tests |
| C2-01 | Active-profile entity delta | R0-03 | Desired vs effective profile, switch lifecycle, provenance | Entity PASS |
| C2-02 | Audited in-app switch | C2-01, C9-02 | Admin-only; fences admission, drains prepared/reserved/queued/in-flight, bounded wait; frozen per-call profile; guarded rollback; restart restores | role deny, concurrent, queued, caller/server/reaper death, restart, failed activation tests |
| R0-05 | Admin status + switch UI | C2-02 | Shows configured vs effective profile, CLI version, last check, without a model call; switch button with confirmation | LiveView tests; owner try |
| R0-06 | Profile proof | R0-02..05, C9-05, G-R0 created by owner | 2 synthetic attempts per profile, witness reconciled; switch Opus→Sonnet→Opus in app | evidence record; owner try |

### C3 Lead admission (S1)

| ID | Story | Depends | Acceptance | Evidence |
|---|---|---|---|---|
| C3-01 | Admission entity delta | — | Source kinds (manual, csv, hubspot, agent_found, referral), provenance, one active outbound target per company, "referred" closure, history kept | Entity PASS |
| C3-02 | Single admission action | C3-01 | Every source enters one path → dedupe → mandatory research → qualification; no shortcut to a draft | allow/deny + dedupe tests |
| C3-03 | Referral handover action | C3-02 | Closes original as referred (history kept), admits referred person as active target, links referrer for drafting | tests |

### B1 One real prospect (S1 requirements; S2 build)

| ID | Story | Depends | Acceptance | Evidence |
|---|---|---|---|---|
| B1-01 | Requirements, prototype, G5 packet | plan | Founder flow: add → research → draft on Home → approve → captured | Owner G5 |
| B1-02 | Constraint-7 amendment + retention rules | — | ADR drafted, Codex-reviewed; short retention/deletion rules | Owner accepts |
| C4-01 | Minimal run settings | entity PASS | Offering, booking link, writing guide, default brief, operational limits; admin-only forms; per-run snapshot | Entity PASS; tests; owner fills in |
| C5-01 | Search secret mapping | — | Local gitignored sops file + with-secrets entries for Brave and Exa; the owner copies the keys personally | secret-scan + with-secrets tests |
| C5-02 | Brave + Exa adapters | C5-01, Owner limits | Req adapters behind SearchProvider; quota counter per provider billing window incl. pagination/retries/content fetches; Exa dollar cap | tests with fakes |
| C5-03 | Real safe fetch | — | Real WebFetch adapter with existing safety rules (host checks, size, timeouts) | tests |
| C5-04 | Real-data guard + telemetry | B1-02 | Guard policy matches amendment (allow/deny); OTel content capture off whenever real data is on; §9a recording | tests |
| B1-03 | Manual add | C3-02 | Founder adds a company + person; lands in admission | LiveView tests |
| B1-04 | Default brief in code | C4-01 | Versioned default brief drives research at one fixed depth; cited claims; visible caps | tests |
| B1-05 | First-touch draft | C4-01, B1-04 | Draft from offering + writing guide + brief; default subject/body shape; claims cited | tests + eval cases |
| B1-06 | Act from Home | C1, H1 draft rows | Approve/edit/reject from Home; binding to exact recipient + revision; captured | binding tests; owner try |
| B1-07 | Real acceptance run | all above, G-DEMO | One real company end to end; owner tries uncoached | private evidence; owner acceptance |

### B2 Finding real people (S2 mockups; S3-S4 build)

| ID | Story | Depends | Acceptance | Evidence |
|---|---|---|---|---|
| B2-01 | Mockups | — | Target set → account → person → contact candidates → LinkedIn attended step | Owner review (before walkthrough) |
| B2-02 | Algorithm walkthrough → requirements, source contract, G5 | B2-01, Owner | Includes LinkedIn screenshot-citation decision | Owner G5 |
| B2-03 | Account discovery + ABM lists | C5-02, C3-02 | Search a described market or import a target list with provenance; exclusions apply | tests |
| B2-04 | One active target per company | C3-02 | Account contact history; second target blocked unless referral handover | tests |
| B2-05 | People at an account | B2-03 | Candidate people from search sources with citations | tests |
| B2-06 | Attended LinkedIn | B2-02 | Owner's browser, deterministic flow, human-paced, stops on CAPTCHA, no evasion, model never drives; name + profile URL | tests on synthetic pages; owner attended run |
| B2-07 | Contact candidates via owner algorithm | B2-02 | Email/phone/LinkedIn URL candidates with source; never auto-promoted; owner confirms on Home | tests |
| B2-08 | Acceptance | B2-03..07, B1 | Target set → confirmed person → B1 loop | owner acceptance |

### B4 Sequences (S4-S5)

| ID | Story | Depends | Acceptance | Evidence |
|---|---|---|---|---|
| B4-00 | Stop/pause/advance rules for sequences (S2, input to C6) | C3-01 | Reviewed decision record: which owner-reported sends and outcomes advance, pause or stop an enrollment; how a reply, suppression or referral handover ends it. Builds nothing | Codex review; feeds C6-01/C6-03 |
| B4-01 | Requirements + default sequence | C6 | 3-5 touches over 2-3 weeks, mixed channels | Owner sign-off; G5 |
| B4-02 | Follow-up drafting | B4-01 | `sdr.followup.due` routed; fresh angle; stop-on-reply preserved | tests |
| B4-03 | Research refresh per touch | B4-02, C5 | Bounded, budgeted refresh feeds the angle | tests |
| B4-04 | Mixed-channel steps | C6 | LinkedIn/call steps drafted; owner-reported send advances or pauses per C6 | tests |
| B4-05 | Due rows + OOO pause | C1, B5 OOO | Due touches on Home; OOO pauses and resumes | tests |
| B4-06 | Acceptance | all | 3-touch mixed sequence, synthetic then one real | owner acceptance |

## Lane 2 stories (Codex authors, Claude reviews)

### Shared contracts

| ID | Title / target sprint | Author / reviewer | Depends | Acceptance behavior | Gate/entity evidence | Tests/proof |
|---|---|---|---|---|---|---|
| C1-01 | Lock the founder-task contract — S1 | Codex / Claude | Approved Home framing; C2/C9 producer spec; B1 consumer agreement | Owner can identify what a draft/failure row needs, why, and the permissible next action in a task prototype. Contract defines stable kind/subject/revision/channel, producer, freshness, authorization and resolution; no Task table presumed. | P-C1: concrete projection/action/actor delta, independent PASS and scoped G5 before C1 code; future producer extension rule. | Contract examples for fresh/stale/resolved/unauthorized tasks; owner task walk; no product call. |
| C1-02 | Return bounded authorized draft/failure tasks — S1 | Codex / Claude | C1-01 approved; relevant existing guarded domain reads | A permitted reader gets only applicable pending tasks; an empty result means no permitted pending tasks, not hidden failures falsely declared fixed. Stable identity/freshness supports reliable refresh; sensitive process output is absent. | P-C1 accepted scope + V; role/tenant/read-audit behavior preserved; no permission inferred from cached buttons. | Empty/nonempty/over-cap lists, stable order/IDs, stale data, actor/session denial, cross-scope references, returned/raised read failures, bounded reads. |
| C1-03 | Execute fresh permitted task actions — S1 | Codex / Claude | C1-02; approved action contracts; C2/C9 for model retry | Action gateway revalidates actor, subject, current revision/channel and capability immediately before invoking the public domain action; it does not mutate resources itself. Stale/replayed/forged commands fail safely and audibly. | P-C1 action/authorization PASS + V; task resolution from committed source state. | Fresh/stale/double-submit/role-change cases; no arbitrary action/module dispatch; retry refused if provider/grant/cleanup disallows it. |
| C6-01 | Lock channel artifact and execution semantics — S2 | Codex / Claude | C1; C3 target identity; C4 settings; B4/B5 agreement | Prototype distinguishes email capture, LinkedIn copy/send-by-owner and call notes/outcomes. Contract defines channel/revision/recipient bindings and precisely when owner reports advance/pause/stop enrollment. | P-C6 entity delta and independent PASS; no automated LinkedIn send or dialer; scoped G5. | State-transition examples and no-capture-equals-real-send cases; owner task review; no live recipient contact. |
| C6-02 | Add typed channel artifacts preserving email history — S2 | Codex / Claude | C6-01 approved; C4 | Each channel has a validated artifact/revision and allowed recipient binding. Existing email records retain their meaning; a channel switch invalidates incompatible approval rather than reusing it. | P-C6 accepted schema/action/migration scope + V; deliberate historical compatibility. | Schema success/failure for all three channels, migration/legacy rows, channel/recipient/revision mismatch, permission and suppression boundaries. |
| C6-03 | Record manual execution and outcomes once — S2 | Codex / Claude | C6-02; C1; C3 referral handover; B4 stop/pause contract | Authorized owner reports actual sending/call outcome with timestamp/source basis. It is owner-attested, never wire-confirmed; idempotent reporting and related enrollment effects commit together. | P-C6 outcome lifecycle/actor PASS + V. | Duplicate/racing reports, stale revision, stopped/suppressed target, outcome/referral mapping, UTC/timezone boundaries, no external-send capability. |
| C7-01 | Lock safe CRM-write intent and recovery contract — S4 | Codex / Claude | C6 reporting facts; C8 identity/mapping; owner portal/scopes checkpoint | Owner prototype shows exact target, allowed fields, source revision and truthful capture/report wording before confirmation. Contract defines stable key, write mode, pending/attempting/succeeded/failed/unknown and safe reconciliation. | P-C7 + ADR-0013 Gate B entity/authority review; no inherited import PASS; scoped G5. | Intent/recovery examples including accepted-request/lost-response; portal/mode/suppression fence; no live write. |
| C7-02 | Persist and dispatch a confirmed CRM intent — S4 | Codex / Claude | C7-01 approved; C8; approved fake transport seam | Confirmation creates one durable intent and worker claim; worker rechecks authorization/mode/portal/target/source conditions. A crash cannot lose the intent or silently create a second write. | P-C7 accepted lifecycle/action scope + V; public domain APIs and audit lock order. | Concurrent confirm/claim, crash/restart, revoked mode/portal, fresh pre-dispatch fences, 429/known failure, sanitized request/error telemetry. |
| C7-03 | Preserve unknown writes until authoritative resolution — S4 | Codex / Claude | C7-02 | Lost-response create stays unknown with an actionable owner task. No blind retry; authoritative positive evidence or explicitly guarded owner resolution updates the recorded outcome while retaining history. | P-C7 recovery/actor PASS + V; provider-unique marker support proven before relying on it. | Provider applied then connection lost; negative eventual-consistency search remains unknown; duplicate matches; restart; role denial; no resend on recovery. |
| C8-01 | Lock verified HubSpot import identity/mapping — S3 | Codex / Claude | Owner-run portal/scopes read-only evidence; C3; reviewed ADR-0013 import-side findings | Owner approves per-field ownership, primary-company/association handling and supported portal/scope assumptions. Key custody remains app-only and read-only import cannot alter HubSpot. | P-C8 concrete identity/mapping/suppression delta + independent PASS; ADR-0013 A-side re-review; scoped G5. | Wrong/unverified portal or scope, malformed evidence, ambiguous associations, safe credential metadata; owner runs any actual probe, not agents. |
| C8-02 | Import a verified bounded page through C3 — S3 | Codex / Claude | C8-01 approved; C3; approved HTTP fake seam | One page maps remote identities to local records and admission outcomes through guarded actions. Existing/duplicate/unsupported records are reported honestly; import never invents a contact or bypasses qualification. | P-C8 accepted mapping/ownership/transaction scope + V. | Stable portal/object IDs, dedupe/race, primary-company selection, allowed/denied fields, partial-page policy, no key/PII in logs or public evidence. |
| C8-03 | Resume import safely and honor remote opt-out/conflict — S3 | Codex / Claude | C8-02; C3 | Paging/checkpoints resume without duplicate leads; changes/merges/archives/conflicts are explicit. Most restrictive suppression wins; changed email cannot evade an opt-out; own writes do not trigger an import/research loop. | P-C8 lifecycle/ownership PASS + V; preserve historical links/observations. | Pagination/restart, stale/out-of-order observations, deletion/merge, suppression/email races, unchanged polls, own-write echo, bounded rate/retry behavior. |

### Home and channel epics

| ID | Title / target sprint | Author / reviewer | Depends | Acceptance behavior | Gate/entity evidence | Tests/proof |
|---|---|---|---|---|---|---|
| H1-01 | Approve the minimal Home task journey — S1 | Codex / Claude | C1-01; accepted Home framing; B1 task script | Owner tries draft approval/edit/reject, failure investigation and empty state without coaching. Required vs deferred row types, visibility, loading/withheld/error behavior and status-page split are explicit. | P-H1 references P-C1; new UI/action deltas evaluated; independent verdict, owner prototype acceptance and scoped G5. | Browser task script, keyboard/focus/labels, actor visibility and stale-state examples; no runtime call. |
| H1-02 | Show the founder inbox and truthful status — S2 | Codex / Claude | H1-01 approved; C1-02; C2 read-only status | Home lists permitted pending draft/failure rows, useful next actions and a correct empty state. Status cards have a separate route; effective/pending/blocked provider status never claims an unperformed attestation. | P-H1 accepted read/visibility scope + V; no model generation for display. | Bounded list/read tests, read refusal vs empty, role/session refresh, lost refresh/reconnect, nil status, markup plus browser accessibility; all synthetic. |
| H1-03 | Review a draft in place with exact approval binding — S2 | Codex / Claude | H1-02; C1-03; B1 draft/capture contract | Owner edits, approves or rejects the exact displayed draft. Editing creates the governed revision and invalidates old approval; approval targets the current recipient/revision; resolved row reflects committed state, not a client optimistic guess. | P-H1/P-C1 approved mutation scope + V; no bulk approval or new policy bypass. | Edit/approve race, stale/replayed submit, recipient change, demotion/session revocation, suppression, domain denial, capture-only outcome and owner hands-on task. |
| H1-04 | Investigate a model failure and request a safe new attempt — S2 | Codex / Claude | C1-03; C2 admission; C9 grant; existing governed retry action | Row explains failed/unknown/not-ready/exhausted states with sanitized context. Explicit rerun keeps the original record and counts new work; unconfirmed cleanup, invalid grant or stale target blocks it. Exhausted grant links to C9's owner form, never an agent increase. | P-H1 retry/backend delta PASS where changed + V; original unknown not relabelled; no Reaper-release shortcut. | Known failure vs unknown, double retry, expired/revoked grant, pending switch, caller/provider cleanup uncertainty, role denial; model fixture only unless separate approved evidence. |
| B3-01 | Approve three-channel founder tasks and artifacts — S2 | Codex / Claude | C6-01; C4; H1 | Owner sees message-to-copy versus call-preparation/outcome tasks. Accepted guide and call-note structure, recipient binding, approval/capture and manual reporting are reflected in the prototype; no send/dialer control exists. | P-B3 references P-C6; locked schemas/policy, template owner sign-off, owner prototype acceptance, scoped G5. | Task script and good/bad output fixtures; no real sending or phone initiation. |
| B3-02 | Draft and capture an approved LinkedIn message — S3 | Codex / Claude | B3-01 approved; C6-02; C4; R0/C9; accepted B1 evidence bundle | A short guide-compliant draft uses supported evidence for a selected target. Owner edits/approves/captures and copies it for manual use; unsupported claims/recipient changes fail review checks; nothing is sent by the app. | P-B3 accepted drafting/approval delta + V; existing ModelProvider only. | Zoi/citation/grounding negatives, stale approval, injected evidence, suppression; hermetic normal path; any live quality check consumes explicit B3 allocation. |
| B3-03 | Prepare useful call notes, not a dialer — S3 | Codex / Claude | B3-01 approved; C6-02; C4; R0/C9; accepted evidence | Notes include cited who/why, a short opener, 2-3 discovery questions, hypothetical objections/responses, the configured ask and short voicemail. Hypotheses are not prospect facts; approved template/revision is retained for owner use. | P-B3 call-artifact/schema PASS + V; human task acceptance of length/usefulness, no invented booking times. | Required-section/boundary cases, unsupported benefits, private/sensitive details, missing booking input, no dialing; Fake CI and bounded granted B3 evidence only. |
| B3-04 | Log manual sends and call outcomes from Home — S3 | Codex / Claude | C6-03; H1; B3-02/03 | Owner reports sent/connected/voicemail/wrong-person-referral/not-interested/meeting-booked outcomes. Home resolves or presents the next task according to C6; reports are explicitly user-attested, never provider delivery proof. | P-B3 reporting/row producer scope + V; C3/C6 own associated target/enrollment effects. | Duplicate/stale/racing reports; suppression; wrong-person referral; stop/advance/pause outcomes; no external side effects; owner hands-on demo with fixtures. |

### Reply and intake epics

| ID | Title / target sprint | Author / reviewer | Depends | Acceptance behavior | Gate/entity evidence | Tests/proof |
|---|---|---|---|---|---|---|
| B5-00 | Agree reply and outcome effects for C6 — S2 | Codex / Claude | C3-01; B4-00 | Reviewed decision record: how each reply class and call outcome (interested, referral, OOO, unsubscribe, not interested, wrong person) maps to enrollment and target effects, consistent with B4-00. Builds nothing; B5 build stays S3-S4 | Independent verdict; feeds C6-01/C6-03 | Decision examples only; no product calls. |
| B5-01 | Approve manual-reply and handoff journeys — S3 | Codex / Claude | C1; C3 referral contract; C4 booking input; C6 channel/outcome semantics | Prototype covers interested, ambiguous/sensitive, referral, unsubscribe and OOO paths. Manual input is owner-reported; no new live mailbox/LinkedIn integration is assumed. Review/override permissions and suppression effects are explicit. | P-B5 lifecycle/action/actor delta, independent PASS, owner task acceptance and scoped G5; accepted D-025/D-095 preserved. | Example classification/referral/OOO scripts, forged channel/subject cases, source-injection risks; no product calls. |
| B5-02 | Record and classify an owner-entered reply — S3-S4 | Codex / Claude | B5-01 approved; C1; C6; R0/C9; existing reply actions | Owner pastes/logs a reply to the selected contact/touch; provenance says manual. Classification, human override and governed stop/suppression effects are recorded without treating reply text as instructions. | P-B5 approved ingestion/classification scope + V; no masquerading as a signed remote webhook. | Eight-label fixtures, duplicate reply, wrong subject/channel, unsubscribe, override allow/deny, injection and invalid model result; granted B5 quality checks if needed. |
| B5-03 | Propose an interested reply for human approval — S4 | Codex / Claude | B5-02; C4; C1 approval action; R0/C9 | Interested reply retains classification/handoff and adds a draft using the owner's booking link. No calendar/time invention; unclear/sensitive context goes to the owner without a draft. Edit requires fresh exact-recipient/revision approval; result is captured only. | P-B5 proposed-reply backend/schema delta PASS + V; guide/source provenance bound. | Interested/not-interested/ambiguous/sensitive/refusal cases, bad/missing link, stale edit/approval, suppression, prompt injection; synthetic signed-reply regression and bounded granted evidence. |
| B5-04 | Hand off a same-company referral without losing history — S4 | Codex / Claude | B5-02; C3 handover; C4; C5/B1 research; C1 | Original active target closes as referred and remains in history; the referred person enters the common research/qualification path before approval. New email names the referrer in subject and body. Missing/ambiguous identity/contact details produce a confirmation task, never a fabricated address. | P-B5 references C3's active-target/referral PASS; any extension re-reviewed; V. | Atomic handover/races, duplicate referral, self-referral, suppressed target, unknown recipient, one-active-target invariant, provenance and referrer-name assertions. |
| B5-05 | Pause on OOO and resume safely after return — S4 | Codex / Claude | B5-02; C6; B4 pause/stop contract; C1 | Clear return evidence pauses the appropriate enrollment; ambiguous date/timezone needs owner confirmation. Resume after the agreed date only if still eligible; new reply/suppression/target change wins. No calendar lookup. | P-B5/P-C6 lifecycle and clock contract PASS + V; owner-visible paused reason/resume time. | Deterministic date/DST cases, ambiguous text, due-job replay/restart, concurrent reply/suppression, closed/referred target, no premature follow-up. |
| B6-01 | Approve one intake path and batch/error policy — S3 | Codex / Claude | C3; C8-01 for HubSpot; owner portal/mapping evidence | Manual, CSV and HubSpot inputs share admission, dedupe, mandatory research and qualification. Prototype makes preview/commit/partial failure explicit; missing identities never become placeholder contacts; linking respects CRM ownership. | P-B6 ingestion/actor/batch delta, independent PASS, prototype acceptance and scoped G5; no assumed default for unresolved partial-commit policy. | Invalid/duplicate/mixed row examples, cross-source matches, active-company conflicts and safe errors; owner preview only. |
| B6-02 | Preview a bounded CSV without spending model calls — S4 | Codex / Claude | B6-01 approved; C3 validated input shape | Upload/parse shows accepted, duplicate, invalid and conflicting rows with useful row/field reasons. Nothing is researched/created until explicit commit; payload limits apply and raw private values do not enter logs/public artifacts. | P-B6 approved parse/preview/retention scope + V; no CSV export feature. | Size/header/encoding/empty/duplicate/malformed cells, markup/formula-like content not executed, unauthorized upload, safe error rendering, zero model-call assertion. |
| B6-03 | Commit CSV admission once and show qualification work — S4-S5 | Codex / Claude | B6-02; C3; C5/B1 research; C9 allocation mapping | Confirmation creates/adopts each admitted record per the agreed transaction policy and queues the common pipeline. Repeated submission/resume does not duplicate targets or skip research; failures and pending work stay visible. | P-B6 admission/job/recovery PASS + V; owner-approved grant purpose/allocation for imported-lead research. | Commit race/replay, partial failure/restart, unsupported source/identity, suppressed or inactive target, row-to-job trace, exhausted grant and no unauthorized actual call. |
| B6-04 | Import and re-sync HubSpot from the owner plane — S4-S5 | Codex / Claude | C8-02/03; C3; H1; C9 allocation mapping; owner-scoped runtime key/portal readiness | Owner starts a metered import and sees pending/done/conflict/failure. Mapped CRM-owned fields stay locked locally with a safe Edit-in-HubSpot link; later observations, opt-outs and archives follow C8. No HubSpot write occurs. | P-B6 references P-C8/ADR-0013 A-side approvals + V; mode remains read-only. | Bounded fake paging/rate limits, restart/dedupe, changed/deleted/merged records, wrong portal/host, unsafe link, suppression race, field-lock allow/deny; owner runs any real read checkpoint. |

### HubSpot writeback and settings/results epics

| ID | Title / target sprint | Author / reviewer | Depends | Acceptance behavior | Gate/entity evidence | Tests/proof |
|---|---|---|---|---|---|---|
| B7-01 | Approve writeback previews and live-mode fences — S4 | Codex / Claude | C7-01; C8 verified identity/mapping; owner automation/scopes check; C6 truthful reports | Owner sees notes, opt-in reviewed creates and suppression propagation as separate bounded operations. Exact field ownership, portal, no-recipient-reaching automation, key custody and first-write checkpoint are explicit; native lifecycle/tasks/deals remain out. | P-B7 + ADR-0013 Gate B scope/entity/authority review, owner prototype acceptance, scoped G5. | Wrong portal, read-only/revoked mode, stale preflight, forbidden fields/operations, no email/task/dialer side effect; no actual write in preparation. |
| B7-02 | Preview/confirm one truthful timeline note — S5 | Codex / Claude | B7-01 approved; C7-02/03; C6; C8; H1 | Owner confirms a minimal note for a pinned target/source revision. Wording distinguishes approved/captured locally from owner-reported external activity. Status becomes pending/succeeded/failed/unknown from receipts; no fabricated SENT engagement. | P-B7 accepted note/payload/confirmation scope + V; first live write only at explicit owner checkpoint. | Preview-confirm race, stale source, duplicate submit, suppression/mode change, known rejection/unknown create, safe notes/error rendering; fake client CI, owner-authorized isolated write proof only. |
| B7-03 | Create a reviewed discovered contact/company without duplicates — S5 | Codex / Claude | B7-01; C7; C8 identity; C3; B2 confirmed candidate | Owner opts in to exact fields after existing-record resolution. Unknown/ambiguous matches require review; no domain/name-only merge or unconfirmed candidate promotion. Created associations/remote links are recorded; existing CRM-owned fields are not silently overwritten. | P-B7 create/link/actor delta PASS + V; owner-approved field matrix, no native lifecycle/deal/task expansion. | Existing/duplicate/ambiguous entities, concurrent create, wrong association/portal, owner denial, lost response unknown, archived/merged remote target; no blind retries. |
| B7-04 | Propagate suppression without lifting or echoing it — S5 | Codex / Claude | B7-01; C7; C8 suppression import; C3/C6 | Eligible local opt-out is propagated once under the approved provider contract. CRM-origin opt-out does not echo; remote or local restrictive state wins, including email/domain changes. UI never offers re-subscribe as recovery. | P-B7 suppression/writeback lifecycle PASS + V; no messaging automation triggered. | Imported/local opt-out, changed address/domain, concurrent unsubscribe/send/report, duplicate/unknown request, credential/mode revocation; no suppression lift or own-write loop. |
| B8-01 | Approve editor scope and honest results definitions — S4, build in S5 | Codex / Claude | C4; C9 owner-only grant contract/form; C6; B3/B5 output definitions | Owner confirms which guide/default/campaign inputs and operational limits can change and which safeguards remain read-only. Results distinguish actual agent output, capture, reported outcomes, usage and measured/self-reported founder time; no inferred conversion rates. | P-B8 settings/metric/actor deltas, independent PASS, prototype/definition acceptance and scoped G5. | Example metric definitions and owner task review; no data-export or bulk-approval scope; no product call. |
| B8-02 | Edit offering/brief/writing inputs with versioned snapshots — S5 | Codex / Claude | B8-01 approved; C4; B3 call-template contract | Authorized owner edits agreed defaults/campaign inputs and call-note template. Confirmed changes create auditable versions used by new runs; earlier runs preserve their snapshot. Fixed no-tools/evidence/privacy/approval rules cannot be overridden by guide text. | P-B8 approved C4 extension + V; default/campaign timing matches locked requirements; no research-depth selector or edit-learning. | Non-admin/stale concurrent edit, required/malformed booking or offering input, immutable old run, campaign/default precedence, injection/bypass attempt; no actual model request from editor. |
| B8-03 | Edit operational limits and integrate C9's grant panel — S5 | Codex / Claude | B8-01; C4; merged C9 owner form from R0; C5 quota readiness | Owner sees effective caps/headroom and safe confirmation of allowed changes. Raising a run/campaign cap cannot enlarge a grant/source allowance or weaken technical safeguards. Grant editing delegates to C9; agents cannot change terms/allocations, and consumption/history stay truthful. | P-B8 UI/role/read delta + V; C9 owns term actions and launch-time revocation; no duplicate grant policy. | Owner/non-owner/agent denial, lower-than-consumed cap behavior, stale confirmation, expiry/revocation, pending queued work, next-run snapshot, audit/read visibility; no automatic grant transfer or account-setting inspection. |
| B8-04 | Show per-campaign and overall outcomes without invented performance — S5 | Codex / Claude | B8-01 definitions; C4/C5/C9 receipts; C6; available B3/B5 events | Results page shows actual output, quality evidence/owner judgments, usage against limits, correctly sourced founder time and owner-reported pipeline, with unknown/unavailable labels. Capture is not real delivery; no invented meeting/reply rates or export. | P-B8 metric/read/visibility PASS where triggered + V; owner uncoached interpretation. | Synthetic totals/zero/unknown/replay cases, campaign/overall agreement, actor visibility, missing usage/time, no captured-to-sent inflation, bounded reads and no export endpoint. |
