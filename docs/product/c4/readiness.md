# C4 readiness packet: minimal run settings and per-run snapshot

Status: **draft, revision 2, for independent entity re-review (Codex) and
owner acceptance.** C4-01, Claude author → Codex reviewer. Nothing here
authorizes code, a migration, a UI change or a model call. Implementation
starts only after (1) Codex records an entity-model verdict of PASS on
section 3 and (2) the owner accepts the scope and answers the questions in
section 9. Entity PASS and owner answers are separate gates; neither
implies the other. Revision 2 answers Codex's round-1 NEEDS-REVIEW
(section 10).

Sources (precedence): owner decisions D-050 to D-053, D-057, D-061, D-062,
D-064, D-065, D-069, D-101, D-102 (`docs/sdlc/decisions.md`); approved
build plan (`owner-decisions` branch) §1-§3, §8, §9, §9a, §10 (contract
C4); backlog rows C4-01, B1-04, B1-05, B3-03, B5-03, B8-01..03; default
research brief revision 2 (`research-brief` branch,
`docs/product/briefs/default-research-brief.md`, draft awaiting owner
review); ADR-0002 (canonical serialization, payloads), ADR-0009
(persistence conventions, layering), ADR-0014 (constraints 1-7, amendment
2). Code facts are from `origin/main` at 182bde6.

Consumers: B1 (research and first-touch draft), B3 (LinkedIn and call
notes), B4 (follow-ups), B5 (interested reply with booking link), B8 (full
editors). Consumers may draft against this spec but build against C4 only
after it merges (build plan §3).

## 1. Scope and non-goals

**In scope.** Five tenant-wide settings, each a versioned, admin-edited
input to agent runs: the offering profile, the booking link, the writing
guide, the default research brief (editable guidance only), and per-run
operational limits that can only sit inside fixed safeguards. Every new
agent run binds one immutable snapshot of the exact settings it will use.
B1 gets minimal admin-only input forms and a read-only view; the run page
shows which settings a run used.

**Non-goals.**

- B8's full editors: campaign-scoped briefs and limits, the call-notes
  template, diff views, "reset to built-in default", results pages. The C4
  snapshot shape already carries source references and effective values,
  so B8 adds settings kinds and campaign-scoped rows without changing what
  a snapshot means (section 3.1).
- Tenant-day limits (daily model calls 200, daily sends 25), grant terms
  (C9) and provider quotas (C5, D-102). They stay where they are and are
  shown read-only on the settings page. Making a tenant-day limit editable
  is a B8-03 extension under the same "lower only" rule.
- A research-depth selector (D-052: one fixed depth), per-lead research
  overrides (D-057: post-MVP), learning from edits (D-055).
- Prompt wording, the split of the brief's Fixed rules into code, and the
  enforcement of research caps inside search, fetch and evidence steps:
  B1-04, B1-05 and C5 own those, reading values only through C4.
- The real-data switch itself (C5-04). C4 calls one guard predicate that
  C5-04 later widens; until then the switch is treated as off.
- Sender identity (name, email, footer, quiet hours) stays on
  `SdrAgent.Sales.Campaign`.

## 2. Requirements (observable behavior)

| ID | Requirement |
|---|---|
| C4-R1 | An active human admin can save a new revision of any of the five settings through an admin form with a review step and a confirmation. Saving appends a numbered revision; earlier revisions are never changed or deleted. |
| C4-R2 | No other actor can write settings: reviewers, auditors, disabled or demoted users (re-read at the time of the action) and every system actor, including `agent_runtime`, are refused. Refusals of guarded actions are audited as today (`authz.denied`). |
| C4-R3 | A save made against a revision that is no longer current is refused as stale, names the latest committed revision number, and writes nothing. Two concurrent saves of one setting produce exactly one new revision. |
| C4-R4 | Every agent run created after the C4 migration binds exactly one settings snapshot in the transaction that creates it. The snapshot records, for each setting, the exact revision (id and content hash), or the built-in default version and hash, or "absent", plus the limits at snapshot time. A snapshot never changes. A later save never changes what a queued, running or finished run uses. Runs created before the migration keep a null snapshot and stay readable; nothing is backfilled. |
| C4-R5 | Agents read settings only from their run's snapshot (`SdrAgent.Agents.run_settings/2`), never from the current revisions. A run with no snapshot gets no settings and its settings-dependent steps fail closed. |
| C4-R6 | An operator retry reuses the original run's snapshot (its budget limits are already copied and never raised); current fixed bounds still apply at use (C4-R10). New settings apply to a new assignment. A retry of a run with no snapshot is refused before anything is written. |
| C4-R7 | The research brief, writing guide and operational limits have built-in defaults in code, used until an admin saves a revision. The offering profile and booking link have none. |
| C4-R8 | Business-content completeness: runs whose origin is `:assignment`, `:referral`, `:followup`, `:discovery` or `:channel` require a saved offering profile and are refused before anything is written with `{:settings_incomplete, [:offering_profile]}`. Runs of origin `:reply` and `:proof` are exempt from this completeness rule only. They still bind a snapshot, and every operational, grant, tenant-day and provider limit and every R0 proof authority applies to them unchanged. An unknown or missing origin is refused as today. Reply classification and its unsubscribe and suppression effects never wait on an offering-, guide- or booking-dependent step; an interested-reply draft is a separate step that may refuse for missing business input. |
| C4-R9 | A missing or withheld booking link never blocks a run. A consumer step that needs one refuses with a typed reason; it never invents, substitutes or leaks a link. |
| C4-R10 | Each operational limit has a fixed bound in code. A save above the bound is refused with the bound named. At use, inside the guarded counter or admission path, the allowance is the lowest of the run's frozen maximum, the snapshot value, the current fixed bound and every independent budget (grant, provider quota, tenant day). Raising a setting never grants spend (D-062). Snapshot values are never rewritten. |
| C4-R11 | The settings page shows every limit with its value, fixed bound, source (saved revision or built-in default) and whether code enforces it yet; tenant-day limits, grants and quotas read-only with their source; and the fixed architectural safeguards with their reasons, never editable here (D-062). The run page labels "limit at snapshot" separately from "allowed now". |
| C4-R12 | Settings text is business content that may be sent to the model through the model-payload seam. It is refused when secret-shaped, holds no control characters other than newline and tab, and stays under the size caps of section 3.5. It is not copied into audit event payloads, logs (application, LiveView, SQL), Failure messages or telemetry, even with dev content capture on (section 3.6). |
| C4-R13 | The booking link is an `https` URL with a host name, no user info, no IP-literal or local host, no explicit non-default port, at most 2,048 bytes. Its host must pass the real-data guard (`SdrAgent.Sales.Synthetic.reserved_domain?/1`, widened only by C5-04 when its switch is on) at save **and again at every use**. A link that fails at use is withheld: the step refuses `:booking_link_withheld`, history is kept, nothing newer is substituted, and the URL reaches no model input, draft or capture. |
| C4-R14 | The run page shows the run's snapshot: revision number or built-in default version per setting, and its limits. Auditor views of settings and snapshots go through `SdrAgentWeb.AuditedView` and fail closed. |

## 3. Entity model

Entity Model trigger: **yes**. New persisted resources (settings revision,
run settings snapshot), new embedded value types with invariants, a new
admin-only write boundary and content field policies, a new relationship
and immutable attribute on AgentRun with a cutover rule, a changed audit
after-image rule for sensitive content, and changed backend action
contracts (`AgentRun :create` and `:retry`, `:reserve_model_call`,
`:record_tool_call`, `SDR.assign_lead/2`, `SDR.retry_run/2`, reply intake,
GenAI content capture).

### 3.1 Design choices

**Revision model: append-only revision chain, no mutable pointer.**
Alternatives considered:

| Option | Why not chosen |
|---|---|
| A. Mutable singleton row per setting, history in audit events (the C9 grant pattern) | A snapshot would have to copy every text into each run; history lives only in event payloads; an edit overwrites the row runs read |
| B. Draft → active → retired versions (the `Sales.IcpDefinition` pattern) | Adds a draft state and an activation step the owner did not ask for; "one active per kind" needs a second invariant |
| C. Immutable revisions plus a mutable current-pointer row | Two writes that must agree; the pointer is mutable state needing its own lock and audit; a pointer and revision can diverge |
| **D. Append-only chain (chosen)** | ADR-0009 §5's correction pattern: each revision `supersedes_id` its predecessor, one root per kind, each row superseded at most once; the current revision is the one with no successor (equivalently the highest number). Immutability is a database trigger, not a promise. A snapshot references revision ids and needs no copy. The unique index on `supersedes_id` is the concurrency backstop. |

**Placement: the `SdrAgent.Agents` domain.** Settings are agent-run inputs,
and Agents already owns run budgets and the owner-edited grants (C9). This
keeps ADR-0009's layering intact (Sales may later hold an FK down to a
revision for campaign overrides; Agents holds the run's FK to its
snapshot) and reuses `SdrAgent.Agents.Checks.CurrentAdmin`. A new
`Settings` domain was considered; it would need an ADR-0009 layering
amendment for no added protection.

**One resource for all kinds.** One `SettingsRevision` table with a `kind`
and one typed embedded attribute per kind (exactly one set, by check
constraint) gives one lifecycle, one policy and one lock rule.

**Snapshot as its own append-only row** with flat per-kind columns (not
maps), so every slot's agreement rules are check constraints and its
revision reference is a composite foreign key that also pins the kind and
content hash.

**Snapshot at run creation, not at run start.** The run is committed to
the work when it is created (assignment, reply intake). Binding then means
the queued interval cannot pick up a later edit.

**Defaults when unset: built-in defaults resolved at snapshot time, not
seeded rows.** B1-04 ships "default brief in code" and iterates it during
S2. Seeding revision 1 at bootstrap would freeze an early default and need
an "adopt" action per code change. Instead, until an admin saves a kind,
the snapshot records the built-in default's version and hash; code keeps
every released default version so a run created before a deploy still
resolves the exact text (golden-hash test). Once an admin saves a kind,
only admin saves change it. The page labels a built-in default "not yet
reviewed by you". OQ-1 asks the owner to accept this.

**Fixed rules are not settings.** The research brief's Fixed rules live in
code with the prompt templates (versioned and hashed per ModelInvocation,
ADR-0002) and always frame the editable text. No settings text can remove
or weaken a Fixed rule (B8-02).

**Research caps live in operational limits, not in the brief.** One place
holds every numeric ceiling, validated against one bounds table (D-062).
Consumers pass the run's allowances to the model as the research policy
input (brief input 8).

### 3.2 Entity table (delta)

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| SettingsRevision | New (APPEND-ONLY) | One immutable revision of one tenant-wide run setting | `id : uuid_v7`; `tenant_id : uuid, not nil`; `kind : atom, not nil, one of :offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits`; `number : int ≥ 1, not nil`; `supersedes_id : uuid, nullable`; one embedded content attribute per kind (`offering_profile`, `booking_link`, `writing_guide`, `research_brief`, `operational_limits`), each nullable and `sensitive?: true`; `content_sha256 : string, not nil` (section 3.7); `note : string, nullable, ≤ 200, sensitive?: true`; `created_by_id : uuid, not nil`; `inserted_at`; trace ids | belongs_to Tenant (restrict); belongs_to User as `created_by` (restrict). Keys: PK `(id)`; UNIQUE `(id, tenant_id, kind)` (target of the self FK); UNIQUE `(id, tenant_id, kind, content_sha256)` (target of snapshot slot FKs); identity UNIQUE `(tenant_id, kind, number)`; partial UNIQUE `(supersedes_id) WHERE supersedes_id IS NOT NULL` (superseded at most once); partial UNIQUE `(tenant_id, kind) WHERE supersedes_id IS NULL` (one root per kind). Self FK `(supersedes_id, tenant_id, kind)` → `(id, tenant_id, kind)`, RESTRICT, so a revision supersedes only its own tenant's same kind. | Check: exactly the embedded attribute named by `kind` is non-null. Check: `number = 1` iff `supersedes_id IS NULL`. `number` = predecessor's number + 1, set by the action while it holds the predecessor's row lock (section 4). `content_sha256` computed from the cast, validated content (section 3.7). Trigger rejects UPDATE, DELETE, TRUNCATE. Current revision of a kind = highest `number`. No destroy action. | `:create_revision` (args `kind`, `content`, `expected_number : int ≥ 0` where 0 means "no revision yet", `note`): active human admin only (`CurrentAdmin`, persisted row re-read); auditor role and every system actor forbidden. Appends `settings.revision.created` (section 3.6: metadata and hashes only). Row reads: admin, reviewer, auditor (through AuditedView), `agent_runtime`, `auditor_cli`, kernel. Field policy on the content attributes and `note`: admin, auditor (audited), `agent_runtime`, `auditor_cli`, kernel; reviewer only if the owner says yes (OQ-6). | OQ-6 |
| OfferingProfile, OfferingItem | New (embedded) | What we sell, as structured items the research and draft cite | OfferingProfile: `name : 1..120`; `summary : 1..1,500`; `audience : 0..1,500`; `items : list, 1..30`. OfferingItem: `id : string ^[a-z0-9][a-z0-9_-]{0,39}$`; `kind : :feature \| :use_case \| :outcome \| :limit \| :proof_point`; `text : 1..400` | embedded in SettingsRevision | Item ids unique within the profile. Canonical JSON ≤ 16 KiB. Text rules of section 3.5. Citations name `(revision id, item id)` (brief appendix), so they resolve against the exact revision. | via SettingsRevision | OQ-1 |
| BookingLink | New (embedded) | The owner's scheduling page, used in asks (D-025, D-053, D-082) | `url : string, not nil, ≤ 2,048 bytes` | embedded in SettingsRevision | `https` only; host required; no user info; no IP literal, `localhost` or `.local`; port absent or 443; no control or whitespace characters; redactor rule. Real-data guard at save and at each use (C4-R13). | via SettingsRevision | OQ-3, OQ-7 |
| WritingGuide | New (embedded) | Tone and shape of drafts (D-053, D-065) | `text : string, 1..6,000` | embedded in SettingsRevision | Text rules of section 3.5. Built-in default from D-053 (code). | via SettingsRevision | OQ-1, OQ-5 |
| ResearchBrief | New (embedded) | Editable research guidance (D-050, D-051) | `guidance : string, 1..12,000`; `depth : atom, not nil, one of :standard` | embedded in SettingsRevision | One depth in the MVP (D-052). Holds no Fixed rule. Built-in default from the brief's editable sections (code). | via SettingsRevision | OQ-1, OQ-5 |
| OperationalLimits | New (embedded) | Per-run ceilings an admin may set up to a fixed bound | the twelve integer fields of section 3.3, each not nil | embedded in SettingsRevision | Each field within its bound; cross-field: `research_max_total_source_chars ≥ research_max_source_chars`, `research_max_model_calls ≤ run_max_model_calls`, `research_target_seconds ≤ research_job_limit_seconds`. A save above a bound is refused, never clamped. | via SettingsRevision | OQ-2 |
| RunSettings.CodeDefaults | New (code registry, not persisted) | Built-in defaults for research brief, writing guide, operational limits | per kind: list of released `{version, content, content_sha256}` | referenced by version from RunSettingsSnapshot | Released versions are never edited or removed; a golden-hash test pins each `content_sha256` computed by the section 3.7 rule. Each default passes the same validation as an admin save. | n/a (code, reviewed) | OQ-1 |
| RunSettings.Safeguards | New (code registry, not persisted) | Fixed bounds and the read-only safeguard list | `version : string`; bound per limit field; safeguard entries `{name, reason, enforced_by}` | referenced by `safeguards_version` from RunSettingsSnapshot | Changes only by reviewed code. A lowered bound applies at use to every existing run (C4-R10). | n/a (code, reviewed) | OQ-2 |
| RunSettingsSnapshot | New (APPEND-ONLY) | The exact settings one run (and its retries) uses | `id : uuid_v7`; `tenant_id`; for each kind K: `K_source : atom, not nil, one of :revision, :code_default, :absent`, `K_revision_id : uuid, nullable`, `K_code_default_version : string, nullable`, `K_content_sha256 : string, nullable`, and `K_kind : text GENERATED ALWAYS AS ('K') STORED`; `limits : SnapshotLimits, not nil`; `safeguards_version : string, not nil`; `hash_version : string, not nil` (`"c4-run-settings-snapshot/1"`); `snapshot_sha256 : string, not nil`; `inserted_at`; trace ids | belongs_to Tenant (restrict). Keys: PK `(id)`; UNIQUE `(id, tenant_id)` (target of the AgentRun FK). Per kind: FK `(K_revision_id, tenant_id, K_kind, K_content_sha256)` → SettingsRevision `(id, tenant_id, kind, content_sha256)`, RESTRICT, MATCH SIMPLE (skipped when `K_revision_id` is null). has_many AgentRun. | Per-kind checks: `:revision` ⇒ revision id and content hash set, version null; `:code_default` ⇒ version and content hash set, revision id null, allowed only for brief, guide and limits; `:absent` ⇒ all three null, allowed only for offering and booking link. The FK makes the DB refuse a cross-tenant, wrong-kind or wrong-hash revision reference. A code default's version and hash are checked against `CodeDefaults` by the building change and again at use. `snapshot_sha256` per section 3.7. Trigger rejects UPDATE, DELETE, TRUNCATE. | Created only inside `AgentRun :create` by `BuildSettingsSnapshot` under a context marker (`SettingsSnapshotContext`, the `GrantContext` pattern). The snapshot create action accepts no attributes: every id, version, hash and limit is computed by the change from the run's tenant and origin. A direct create, or a create with any supplied attribute, is forbidden for every actor. Appends `settings.snapshot.created` (references, hashes, limits only). Reads: admin, reviewer, auditor (AuditedView), `agent_runtime`, `auditor_cli`, kernel. | none |
| SnapshotLimits | New (embedded) | Limits recorded at snapshot time | the twelve fields of section 3.3; `clamped : {:array, atom}` (sorted; fields lowered to a bound at snapshot time) | embedded in RunSettingsSnapshot | Each field = min(revision or built-in value, bound at snapshot time). Never rewritten; the allowance at use is computed (C4-R10), not stored. | via snapshot | none |
| AgentRun | Existing (delta) | Agent run with per-run budget | add `settings_snapshot_id : uuid, nullable` | composite FK `(settings_snapshot_id, tenant_id)` → RunSettingsSnapshot `(id, tenant_id)`, RESTRICT; many runs to one snapshot (a run and its retries) | **Cutover trigger** (BEFORE INSERT OR UPDATE): an INSERT with null `settings_snapshot_id` is refused; an UPDATE that changes `settings_snapshot_id` (attach to a historical null, detach, or replace) is refused. Historical null rows keep every existing transition. No backfill. Set only by `:create` (the change builds the snapshot; no input accepts an id) and `:retry` (copied by `RetryOf`). `:create` refuses `{:settings_incomplete, kinds}` per C4-R8. Frozen budget: `max_model_calls`, `max_tool_calls`, `max_tokens` = min(caller argument when given, snapshot `run_*` value). `:retry` of a historical null-snapshot run is refused `no_settings_snapshot` before any Operation, job or attention resolution is written (`SDR.retry_run/2` pre-check; the transaction also rolls back). | Unchanged (AGT, SCH create; ADM retry inside `SDR.retry_run/2`) | OQ-4 |
| AgentRun counters (`:reserve_model_call`, `:record_tool_call`) | Existing (behaviour delta) | Guarded per-run counters | — | unchanged | On the row locked `FOR UPDATE` (`BudgetCounter`): `:reserve_model_call` refuses when `model_calls_reserved ≥ min(budget.max_model_calls, bound(run_max_model_calls))` or `tokens_used ≥ min(budget.max_tokens, bound(run_max_tokens))`; `:record_tool_call` refuses when `tool_calls_used ≥ min(budget.max_tool_calls, bound(run_max_tool_calls))`. The token check moves here from the caller-side preflight in `SdrAgent.SDR.Model` (kept as an early message). Tokens are known only after a call, so one call can overshoot the remaining token allowance; the limit stops the next call. | unchanged | none |
| AuditEvent (via `AppendEvent`) | Existing (behaviour use) | Ledger after-images | — | unchanged | No change to `AppendEvent`: it already omits `sensitive?` attributes from the after-image, names them under `redacted`, and keeps `record_sha256` over the full row. C4 marks every settings content attribute and `note` sensitive, so generic event readers (admin, reviewer, auditor) see kind, number, `supersedes_id`, `content_sha256` and `record_sha256`, never the text. | unchanged | none |
| Telemetry.GenAI | Existing (behaviour delta) | GenAI spans | request option `content_capture : :inherit \| :off` | — | A request whose input carries run settings is built with `content_capture: :off`; then no `gen_ai.input.content` or `gen_ai.output.content` span event is emitted, whatever `otel_capture_content` says (dev sets it true today, `config/dev.exs`). Span attributes stay metadata and hashes. | — | none |
| Accounts.User | Existing | Human operators | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (referenced as `created_by` only; roles and role-change rules unchanged) | — | — |
| Tenant | Existing | Singleton tenant | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Sales.Campaign | Existing | Sender identity and compliance defaults | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (sender identity stays on the campaign; campaign-scoped settings are B8) | — | — |
| Actor | Existing | System actor types | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no new system actor; `agent_runtime` gains read only) | — | — |

### 3.3 Operational limits, fixed bounds and where each is enforced

Defaults are the built-in limits revision. Bounds are proposals awaiting
the owner (OQ-2) and are not accepted until answered. The run bounds equal
today's code values, so C4 loosens nothing.

| Field | Default | Fixed bound | Authoritative check at use |
|---|---|---|---|
| `run_max_model_calls` | 20 | 1..20 | `AgentRun :reserve_model_call` (`BudgetCounter`, row `FOR UPDATE`), with the current bound; ADR-0004 per-run cap |
| `run_max_tool_calls` | 60 | 1..60 | `AgentRun :record_tool_call`, with the current bound |
| `run_max_tokens` | 100,000 | 1..100,000 | `AgentRun :reserve_model_call`, with the current bound (moved from `SdrAgent.SDR.Model`); stops the next call, one call may overshoot |
| `research_max_search_requests` | 4 | 0..8 | C5-02 adapter, before each request (retries and pagination counted) — not enforced until C5-02 |
| `research_max_page_fetches` | 4 | 0..8 | C5-03 safe fetch — not enforced until C5-03 |
| `research_max_sources` | 6 | 1..10 | B1-04 evidence bundle — not enforced until B1-04 |
| `research_max_source_chars` | 4,000 | 500..8,000 | B1-04 — not enforced until B1-04 |
| `research_max_total_source_chars` | 24,000 | 500..48,000 | B1-04 — not enforced until B1-04 |
| `research_max_output_tokens` | 2,500 | 256..4,000 | B1-04 model request — not enforced until B1-04 |
| `research_max_model_calls` | 2 | 1..2 (at most one repair) | B1-04 — not enforced until B1-04 |
| `research_target_seconds` | 180 | 30..600 (warning only, D-061) | B1-04 progress, H1 row — warning, never a stop |
| `research_job_limit_seconds` | 600 | 60..900 (finite job limit, D-061) | B1-04 worker deadline; an in-flight model call ends by its own timeout and is recorded unknown, never cut silently or retried (D-064) — not enforced until B1-04 |

Consumers read an allowance only through `Agents.RunSettings.allowance(run,
field)`, which returns min(snapshot value, current bound), and combine it
with their own independent budgets inside their guarded step. The settings
page shows "not yet enforced" for every field whose consumer has not
merged, read from the same registry the consumers register in. Per-call
and per-fetch timeouts stay fixed in code (`ClaudeCLI` default 120 s).
Reply runs keep their code budget (2 model calls, 5 tool calls,
`lib/sdr_agent/sdr/reply_intake.ex`), lowered further by the snapshot if
smaller.

### 3.4 Safeguards settings never touch

Shown read-only with their reason (D-062); changed only through review:

| Safeguard | Enforced by |
|---|---|
| Captured delivery only (constraint 1) | `SdrAgent.Outreach.Delivery` (local capture) |
| Approval bound to exact recipient and revision (constraint 2) | `SdrAgent.Outreach.Approval` |
| Suppression before every delivery, never lifted by an agent (constraint 3) | `SdrAgent.SDR.SuppressionCheck`, `SdrAgent.Outreach.Suppression`, delivery gate |
| No tools, per-call attestation (constraint 5) | `SdrAgent.AI.ModelProvider.ClaudeCLI` |
| One model call at a time (D-069) | provider runtime serialization |
| Real-model grants and allocations (C9) | `SdrAgent.Agents.Admission` |
| 200 model calls per UTC day, config may only lower | `SdrAgent.Agents.daily_model_call_limit/0` |
| 25 sends per local day, config may only lower | `SdrAgent.Outreach.Compliance`, `SendQuotaDay` check `cap BETWEEN 1 AND 25` |
| Source quotas: 1,000 Brave requests, $5 Exa per month (D-102) | C5-02 counter |
| Synthetic-data guard until the real-data switch (constraint 7) | `SdrAgent.Sales.Synthetic`, C5-04 |
| Unknown model outcomes never retried automatically (D-064) | ModelInvocation lifecycle, `SdrAgent.SDR.Retry` |
| Fixed research rules (brief "Fixed") | prompt templates (`SdrAgent.SDR.Prompts`), deterministic validators |

### 3.5 Content rules

Settings text is the owner's business content. It may go to Anthropic in
prompts (build plan §9a item 4) and is stored in the local database. It is
not prospect data and must hold no secrets.

- Valid UTF-8, trimmed, no control characters except newline and tab.
- Refused when `SdrAgent.Operations.Redactor.redact/1` would change it.
  The error names the field and rule, never the matched text.
- Size caps: offering profile 16 KiB canonical (field caps in 3.2),
  writing guide 6,000 characters, brief guidance 12,000 characters, booking
  link 2,048 bytes, note 200 characters.
- Consumers place settings text in a labeled data section beneath the
  Fixed rules. Guide or brief text that tells the model to skip citations
  or invent facts changes nothing the deterministic validators check.
- Tests, fixtures and public docs use synthetic settings only.

### 3.6 Where settings content may and may not be copied

Allowed copies: the SettingsRevision row; the model request built from a
run's settings and its ADR-0002 payload and witness records (the
authorized model-payload seam); the authorized settings UI. Every other
copy is prevented by an executable control, each with a canary test
(section 5):

| Surface | Control |
|---|---|
| AuditEvent payloads | content attributes and `note` are `sensitive?: true`, so `AppendEvent` omits them (named under `redacted`); `record_sha256` still covers the full row. `settings.revision.created` carries kind, number, `supersedes_id`, `content_sha256`. `settings.snapshot.created` carries snapshot id, per-kind source, revision id, version and content hash, limits, `snapshot_sha256`. No event carries settings text. |
| Ash errors and inspect output | `sensitive?` values are redacted by Ash in errors and `inspect`; validation messages never interpolate the value. |
| LiveView event logging | `SettingsLive` uses `log: false`; form params live under the key `settings_content`, added to `config :phoenix, :filter_parameters` (with `password`). |
| SQL logging | Ecto logs query parameters at debug (dev). `SdrAgent.Repo` sets `log: false` and attaches `SdrAgent.Repo.QueryLog`, a telemetry handler that logs source, command and timing, never parameters, in every environment. This also covers prospect data under the real-data switch. |
| GenAI telemetry | settings-bearing requests use `content_capture: :off` (3.2 row Telemetry.GenAI); no content span events even with dev capture on. |
| Failure messages, application logs | consumers name the setting kind and reason only; no code path formats settings text into a message. |

### 3.7 Hash contracts

All hashes use `SdrAgent.Audit.Canonical` (`sdr-canonical-json/1`),
lowercase hex sha256.

- **`content_sha256`** = sha256 of the canonical encoding of
  `{"schema": "c4-settings-content/1", "kind": K, "content": C}`, where C
  is the content after Ash casting and all validations, dumped with
  `Ash.Type.dump_to_embedded/3` (string keys, typed values, list order
  preserved). Computed in a `before_action` after validation; the caller
  never supplies it. A recompute test checks every stored row.
- **`snapshot_sha256`** = sha256 of the canonical encoding of
  `{"schema": "c4-run-settings-snapshot/1", "tenant_id": T,
  "safeguards_version": V, "slots": S, "limits": L, "clamped": X}`.
  S has all five kinds as keys, always. A slot is exactly one of
  `{"source": "revision", "revision_id": id, "content_sha256": h}`,
  `{"source": "code_default", "version": v, "content_sha256": h}`,
  `{"source": "absent"}`; no other keys, never `null`. L has all twelve
  limit fields as integers. X is the sorted list of clamped field names.
  Excluded: the snapshot id, trace ids, `inserted_at`, `hash_version` (it
  names the schema already in the input) and the digest itself. The
  hashed slots must equal the stored per-kind columns exactly; the
  building change derives both from one value and a test recomputes.

### 3.8 Changed backend action contracts

- **`Agents.create_settings_revision/2`** (new). Inputs: kind, content,
  `expected_number`, note; actor a human admin. Returns the revision or a
  typed error: `:forbidden`, `{:stale_revision, latest_committed_number}`,
  `{:invalid, field_errors}`. Writes one revision and one audit event, or
  nothing. On a unique violation the transaction rolls back first; the
  function then reads the latest committed number in a fresh statement and
  returns it.
- **`Agents.current_settings/1`** (new, settings page only). Current
  revision or built-in default per kind with limits. Never called by agent
  code (xref test).
- **`Agents.run_settings/2`** (new). The resolved settings of a run's
  snapshot: revision content, or built-in default content by version with
  its hash re-checked (`:settings_default_unavailable` on mismatch or
  missing version). `{:error, :no_settings_snapshot}` for a run without
  one. Content is returned to the agent process only.
- **`Agents.RunSettings.allowance/2`** (new). min(snapshot value, current
  bound) for one limit field.
- **`Agents.RunSettings.booking_link_for_use/1`** (new). `{:ok, url}`,
  `{:error, :booking_link_absent}` or `{:error, :booking_link_withheld}`
  (guard fails now). Consumer obligations: call it when building model
  input and again before persisting a draft; record the booking-link
  revision id on the draft so the capture gate can re-check it. The
  capture re-check lands with the first consumer that puts a link in a
  draft (B1-05 or B5-03).
- **`AgentRun :create`** (changed). Builds the snapshot itself (section 4),
  refuses `{:settings_incomplete, kinds}`, freezes budget limits from the
  snapshot, records `settings_snapshot_id` in `agents.run.created`.
- **`AgentRun :retry`** (changed). `RetryOf` copies `settings_snapshot_id`;
  refuses `no_settings_snapshot` when the original has none.
- **`SDR.assign_lead/2`** (changed). Pre-checks business completeness
  before any write (returns `{:error, {:settings_incomplete, kinds}}` with
  nothing written); the `max_model_calls`/`max_tool_calls` options may only
  lower.
- **`SDR.retry_run/2`** (changed). Pre-checks the original run's snapshot
  before creating the new Operation, job or resolving attention.
- **`SDR.ReplyIntake.received/3`** (changed). Its run binds a snapshot;
  business completeness is not required (C4-R8).
- **`AgentRun :reserve_model_call`, `:record_tool_call`** (changed). Apply
  the current bound (3.2 counters row).
- **`Telemetry.GenAI.with_span/3`** (changed). Honors `content_capture:
  :off`.

### 3.9 Synthetic example

An admin saves offering revision 1 (`name` "Example Widgets Scheduler",
items `calendar_sync` feature, `fewer_no_shows` outcome, `no_payroll`
limit) and booking link revision 1 (`https://book.example.test/demo/intro`).
The brief, guide and limits stay on built-in defaults. A lead at
`acme.example` is assigned. The hashed snapshot input (ids and hashes
shortened):

```json
{
  "schema": "c4-run-settings-snapshot/1",
  "tenant_id": "0190…",
  "safeguards_version": "1",
  "slots": {
    "offering_profile": {"source": "revision", "revision_id": "0192…a1", "content_sha256": "3f…"},
    "booking_link": {"source": "revision", "revision_id": "0192…b7", "content_sha256": "9c…"},
    "writing_guide": {"source": "code_default", "version": "1", "content_sha256": "51…"},
    "research_brief": {"source": "code_default", "version": "2", "content_sha256": "e0…"},
    "operational_limits": {"source": "code_default", "version": "1", "content_sha256": "7a…"}
  },
  "limits": {"run_max_model_calls": 20, "run_max_tool_calls": 60, "research_max_sources": 6, "…": "…"},
  "clamped": []
}
```

The admin then saves writing guide revision 1 while the run is queued. The
queued run still drafts with built-in guide version 1; the next assignment
uses guide revision 1. A retry of the first run uses its original snapshot.
A save of the offering against `expected_number` 0 after revision 1 exists
is refused `{:stale_revision, 1}`. If a later release lowers the
`run_max_model_calls` bound to 10, the queued run's snapshot still says 20
but `:reserve_model_call` refuses its eleventh reservation.

## 4. Locks and transactions

Existing rule: domain row locks first, then the audit chain head
(`SdrAgent.Audit.Kernel.lock_head/1`), which every audited write takes at
its first event append and holds to commit (ADR-0009 §6).

**Revision write** (`:create_revision`, one transaction):

1. Read the current revision of the kind and lock it `FOR NO KEY UPDATE`
   (not `FOR UPDATE`, so a snapshot's FK check, which takes `FOR KEY
   SHARE`, never waits on an editor).
2. Re-read under the lock: refuse stale if its number ≠ `expected_number`
   or it now has a successor. With no current revision, `expected_number`
   must be 0.
3. While still holding that lock, insert revision `number + 1` with
   `supersedes_id`, then append the event (chain head).

Two concurrent editors serialize on step 1; the second is refused stale.
Two concurrent first saves have no row to lock; the partial unique index
on `(tenant_id, kind) WHERE supersedes_id IS NULL` makes the second wait
for the first and then fail. The unique index on `supersedes_id`
backstops step 2. A unique violation is mapped to stale only after the
transaction has rolled back, with the latest committed number read afresh
(section 3.8). Editors lock one revision row and then the chain head,
never a run, lead, Operation, job, definition or snapshot.

**Snapshot at run creation** (inside the creating transaction): the
building change takes the chain head explicitly (`Kernel.lock_head`, as
`Admission` does; reentrant if already held), then reads the current
revision of each kind, then inserts the snapshot, then the run. Every
revision insert commits while holding the chain head, so a read made
after taking the head sees exactly the revisions whose events precede
this run's in the chain, and no revision can commit until this
transaction ends. An editor that inserted a successor and is waiting for
the head is invisible to this reader, which binds the preceding committed
revision. The snapshot's FK checks take `FOR KEY SHARE` on the referenced
revisions, compatible with an editor's `FOR NO KEY UPDATE`, so the creator
never waits on an editor while holding the head.

Whole-flow lock accounting (existing edges unchanged; new edges marked
*new*):

- `SDR.assign_lead/2`: Lead `FOR UPDATE` → plain reads (campaign, active
  runs) → *new* plain completeness pre-check (kinds never disappear, so a
  pass cannot become a fail) → Lead `:assign` (chain head) →
  AgentDefinition register → Oban job insert → Operation insert →
  `AgentRun :create`: head (held) → *new* plain revision reads → *new*
  snapshot insert (FK `FOR KEY SHARE` on revisions and tenant) → run
  insert (FK `FOR KEY SHARE` on definition, Operation, snapshot) → signal
  event.
- `SDR.retry_run/2`: *new* plain read of the original's snapshot id before
  its existing writes; `:retry` copies it (FK `FOR KEY SHARE` on the
  snapshot). No revision read.
- Reply intake: inside the reply's transaction, after its existing locks;
  the change re-takes the already-held head and reads. No new lock is
  taken before the head, so the Outreach lock order is unchanged.
- Editors: revision row `FOR NO KEY UPDATE` → head.

The only rows both sides touch are the revision rows (editor `FOR NO KEY
UPDATE`, creator `FOR KEY SHARE`: compatible) and the chain head (creators
take it before touching revisions; editors after). A creator never waits
on an editor while holding the head, and an editor waiting for the head
holds nothing a creator needs, so the new edges add no cycle. The
existing run, Lead, Operation, job and definition edges are unchanged by
C4 and keep their reviewed order. The real-connection race tests in
section 5 are the required proof.

Isolation: the default `READ COMMITTED`; each revision read is its own
statement after the head lock. Clock: `inserted_at` from `SdrAgent.Clock`.

## 5. Test plan (RED first, synthetic only)

Each test is written first and must fail for the missing behavior, not for
setup or compilation. Per-test setup only; nothing seeded in
`test_helper.exs`. No model calls (Fake provider), no dev database.

Revisions and policy:
1. Admin saves revision 1 of each kind; numbers, `supersedes_id` and
   `content_sha256` correct (recomputed); one `settings.revision.created`
   per save, without content.
2. Reviewer, auditor, disabled admin, demoted admin (stale struct) and each
   system actor (`agent_runtime`, `scheduler`, `seeder`, kernel) are
   refused; nothing written; guarded denial audited.
3. Stale `expected_number` refused with the current number; first save
   with `expected_number` 1 refused.
4. UPDATE, DELETE and TRUNCATE on revisions and snapshots raise (trigger).
5. DB constraints by direct insert: wrong embedded attribute for the kind;
   `number`/`supersedes_id` mismatch; cross-kind and cross-tenant
   `supersedes_id`; snapshot slot with wrong kind, wrong tenant or wrong
   content hash; slot column combinations outside the per-kind checks;
   AgentRun with a snapshot of another tenant.
6. Field policy: content and `note` hidden from roles outside the field
   policy; reviewer case written once OQ-6 is answered.

Validation (one success and the boundary failures per field):
7. Each limit at its bound passes, bound + 1 is refused naming the bound;
   cross-field rules refused.
8. Booking link: `http`, `javascript:`, user info, IP literal, `localhost`,
   port 8443, over 2,048 bytes, non-reserved host while the guard is off,
   token-shaped query — each refused; a reserved `https` link passes.
9. Text: control character, secret-shaped string (error does not echo it),
   over-size, duplicate offering item id, bad item id — refused.

Snapshot, runs and cutover:
10. `assign_lead/2` with no offering returns `{:settings_incomplete,
    [:offering_profile]}` and writes no lead change, run, snapshot, job,
    Operation or event (action-level, row counts and chain length).
11. Assignment binds a snapshot; `run_settings/2` returns built-in
    defaults by version for unsaved kinds and revision content for saved
    ones; `snapshot_sha256` recomputes from the stored columns.
12. Save after assignment: the queued run's settings are unchanged; a new
    assignment sees the new revision.
13. Retry shares the original snapshot id. Retry of a historical
    null-snapshot run is refused with no new Operation, job, run or
    attention resolution.
14. Reply intake with no saved settings creates its run and snapshot; an
    unsubscribe reply is classified and suppressed; reply runs still hit
    their model-call, grant and daily limits (refusal case per limit).
15. Every `UsageBucket` origin appears in the completeness table (test
    fails when a new origin is added without a row); an unknown origin is
    refused.
16. Cutover trigger: INSERT with null snapshot refused; UPDATE attaching a
    snapshot to a historical null run refused; UPDATE changing or clearing
    a non-null snapshot refused; historical null runs still transition.
17. Snapshot rollback: when the run insert fails after the snapshot insert
    (forced FK error), no snapshot row remains.
18. Marker path: a snapshot create with any supplied id, hash or limit is
    forbidden; `settings_snapshot_id` cannot be supplied to `:create`.
19. Built-in default whose hash no longer matches, or a removed version,
    makes `run_settings/2` fail closed; golden-hash test for every
    released default version.
20. Xref test: no module outside `SdrAgent.Agents` reads current
    revisions; agent actions use `run_settings/2` only.

Live checks at use:
21. Bound lowered after a snapshot (test-only bound override): the run's
    snapshot value is unchanged, `:reserve_model_call`, `:record_tool_call`
    and the token check refuse at the lower bound, also for a retry and for
    a direct domain call; `allowance/2` returns the lower value.
22. Booking link withheld: with a revision whose host fails the guard now
    (test-only guard override standing in for "switch turned off"), a new
    assignment, a queued run and a retry all get `:booking_link_withheld`
    from `booking_link_for_use/1`; the URL is absent from the model input
    the Fake receives; history is unchanged; no newer revision is used.

Privacy canaries (Logger at `:debug`, `otel_capture_content: true`,
in-memory span exporter; canary string in every text field):
23. Valid save, invalid save (secret-shaped and over-size), snapshot,
    Fake model call carrying settings, LiveView form submit: the canary is
    absent from captured logs (application, Phoenix, LiveView, SQL), span
    attributes and events, AuditEvent payloads and Failure rows; present
    only in the revision row and the model request payload.

Real-connection concurrency (independent PostgreSQL connections with
`Sandbox.checkout(Repo, sandbox: false)`, `async: false`, the isolated
test database and a small pool, as the existing `*_race_test.exs` files;
deterministic ordering with explicit barriers; bounded loops; cleanup per
test):
24. Existing-revision edit first, snapshot second: editor holds the
    revision lock and has inserted its successor, waiting for the head;
    creator then snapshots. Both orders of head acquisition are driven.
    Creator binds the revision committed before its head acquisition;
    chain order matches; no deadlock.
25. Snapshot first: creator holds the head; editor locks the revision and
    inserts; creator's FK `FOR KEY SHARE` does not wait; creator binds
    the old revision; editor commits after.
26. First-root race: two first saves; exactly one revision 1; the loser
    gets `{:stale_revision, 1}` after rollback.
27. Stale mapping after rollback: while one save waits, two other saves
    commit; the loser reports the latest committed number (3), not 1.
28. Two editors of one existing revision: one succeeds, one stale.

UI (LiveView):
29. Admin sees the form, review step and confirmation; save calls the
    domain with the revision seen; stale shows a reload prompt; refusals
    shown next to fields; a forged confirm event without a review step does
    nothing (the C9-05 `GrantForm` pattern).
30. Read-only view per the field policy; auditor view records an
    AuditAccess and fails closed; non-operators redirected.
31. The page shows bounds, sources, "not yet enforced" labels and the
    safeguard list; the run page shows the snapshot with "limit at
    snapshot" and "allowed now".

Gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix credo`, `mix sobelow`, full `mix test`, `mix precommit`; Ash codegen
check clean.

## 6. Affected modules and slices

New: `lib/sdr_agent/agents/settings_revision.ex`,
`lib/sdr_agent/agents/run_settings_snapshot.ex`, embedded types under
`lib/sdr_agent/agents/run_settings/` (offering profile and item, booking
link, writing guide, research brief, operational limits, snapshot limits),
`run_settings/code_defaults.ex`, `run_settings/safeguards.ex`,
`run_settings.ex` (`allowance/2`, `booking_link_for_use/1`),
`agents/changes/build_settings_snapshot.ex`,
`agents/checks/settings_snapshot_context.ex`, URL and text validations,
`lib/sdr_agent/repo/query_log.ex`; migration with triggers (append-only,
AgentRun cutover), checks, generated kind columns, unique keys and
composite FKs; `lib/sdr_agent_web/live/settings_live.ex` (route
`/settings` in the operator live session) and a staged form module.

Changed: `lib/sdr_agent/agents.ex` (resources, code interfaces),
`lib/sdr_agent/agents/agent_run.ex` (`settings_snapshot_id`, `:create`,
counters), `lib/sdr_agent/agents/changes/budget_counter.ex`,
`lib/sdr_agent/agents/changes/retry_of.ex`, `lib/sdr_agent/sdr.ex`
(`assign_lead/2`, `retry_run/2`), `lib/sdr_agent/sdr/retry.ex`,
`lib/sdr_agent/sdr/reply_intake.ex`, `lib/sdr_agent/sdr/model.ex` (token
preflight kept as message), `lib/sdr_agent/telemetry/gen_ai.ex`,
`lib/sdr_agent/ai/model_provider.ex` (pass `content_capture`),
`config/config.exs` (`filter_parameters`, Repo `log: false`),
`lib/sdr_agent_web/live/run_live.ex`, `lib/sdr_agent_web/router.ex`,
`lib/sdr_agent_web/live/admin_live.ex` (link to settings),
`docs/architecture/domain-boundaries.*` (regenerated).

Slices, each a reviewed PR with exact-head CI:
- **C4-01a** resources, migration, policies, snapshot on create/retry/
  reply, counters, domain API, privacy controls, tests 1-28.
- **C4-01b** settings page, read-only view, run page summary, tests 29-31
  (and the LiveView part of 23).
- Consumer fence: B1-04 and B1-05 start building only after C4-01a
  merges; their prompts read `run_settings/2`, `allowance/2` and
  `booking_link_for_use/1`.

## 7. Architecture decisions

To evaluate explicitly at Phase 3, not assumed settled by "no new
dependency or domain":

- **Durable retention of released built-in defaults in code** (golden
  hashes, never removed). This is a new cross-cutting convention; if
  accepted it may warrant an ADR or an ADR-0002 note on reproducible
  inputs.
- **Head-first snapshot reads** (read inputs only after taking the chain
  head, editors use `FOR NO KEY UPDATE`). The C9 admission pattern
  (`Admission`) takes the head before its reads for the same reason; check
  whether that reviewed pattern covers this use or an ADR-0009 note is
  needed.
- **Parameter-free SQL logging** in every environment changes debugging
  for all queries; an ADR-0005 (observability) note may be needed.
- **Placement in Agents**: within the accepted domain and ADR-0009
  conventions (append-only trigger, supersedes chain, tenant column,
  layering). A separate `Settings` domain would be an ADR-0009 §7
  amendment for the owner.

The domain-boundaries diagram is regenerated in C4-01a.

## 8. Risks

- Built-in default drift before the owner saves (mitigated: recorded per
  run, labeled on the page; OQ-1).
- Item-id reuse with a new meaning in a later offering revision cannot be
  prevented mechanically; citations bind the revision id.
- The redactor rule can refuse legitimate long tokens in text; the error
  says which field to change.
- The research bounds and the built-in guide are proposals. Neither is
  accepted, published or merged as settled until the owner answers OQ-2
  and OQ-5; implementation waits for those answers as well as entity PASS.
- Generated stored columns in a composite FK are standard PostgreSQL
  (RESTRICT only); the migration test confirms it on the pinned version. A
  constraint trigger is the fallback if not.

## 9. Owner questions

These are the owner's decisions; this packet does not answer them.

- **OQ-1 Content sign-off and defaults.** Please enter the offering
  profile and booking link (the build plan S1 checkpoint), and approve
  (a) the built-in writing guide drafted from your D-053 default and
  (b) the editable part of research brief revision 2 (row F3b). Until you
  save each one, runs use the built-in version and a deploy can change it;
  after you save, only your edits change it. Accept?
- **OQ-2 Bounds.** Confirm the fixed bounds in section 3.3, in particular
  the research ceilings (8 searches, 8 fetches, 10 sources, 48,000
  characters, 4,000 output tokens) and the job limit (600 s default,
  900 s bound).
- **OQ-3 No booking link.** When no booking link is saved (or it is
  withheld), should a first-touch email use your "questions first" ask
  (recommended; D-053 allows either), or should drafting stop until one is
  saved? B5's interested reply never drafts without one.
- **OQ-4 Retry.** A re-run of a failed run uses the settings it started
  with (recommended, so a re-run is the same job; current safeguards still
  apply); a fresh assignment uses the current settings. Accept, or should
  re-runs pick up current settings?
- **OQ-5 Publication.** The built-in writing guide is derived from your
  own words (D-053) and would sit in the public repository as code. Is
  that allowed, or should the built-in guide be a neutral synthetic text
  and your version entered only in the app?
- **OQ-6 Reviewer access.** Reviewers can read settings text, read-only
  (recommended, since they judge drafts against the guide and offering).
  Accept? If not, reviewers see only hashes and revision numbers.
- **OQ-7 Booking link and the real-data switch.** This packet treats your
  own booking URL like other real data: allowed only while the real-data
  switch is on, checked at every use. Should your booking link instead be
  usable regardless of the switch (it is your own business link, not
  prospect data)?

## 10. Gate record (to fill)

- Configured capabilities (`.workflow/recipe.json`): `ai_pair=true`,
  `codex_review=true`. Reviewer: Codex via ai-pair.
- Round 1 at 9abf55c (draft PR #140): **NEEDS-REVIEW**. Report:
  `/Users/charles/.local/state/sdr-agent/handoff-20261008/tmp/codex-c4-01-9abf55c-entity-review.md`
  (private, outside git). Direction accepted, including the settings-only
  head-first read with editor `FOR NO KEY UPDATE` versus FK `FOR KEY
  SHARE`. Required revisions and where revision 2 addresses them:
  1. Relational and cutover contracts: explicit FK target keys
     (3.2 SettingsRevision keys), snapshot `(id, tenant_id)` and AgentRun
     composite FK, per-kind generated kind columns with kind- and
     hash-pinning FKs, AgentRun cutover trigger and no backfill, retry
     refusal with no writes (3.2, 3.8), exact hash fields, version,
     exclusions and slot agreement (3.7), no caller-supplied values on the
     marker path (3.2 snapshot row).
  2. Privacy: sensitive content attributes so `AppendEvent` copies no
     text, metadata-only events, field policy (3.2, 3.6); GenAI
     `content_capture: :off` despite dev capture; LiveView `log: false`
     and `filter_parameters`; parameter-free SQL logging; canary tests
     (3.6, test 23).
  3. Live checks: current bound applied in the guarded counters, token
     check moved into the counter with stated overshoot, consumer
     `allowance/2`, "not yet enforced" labels, separate "limit at snapshot"
     and "allowed now" (3.2, 3.3, C4-R10, C4-R11); booking-link guard at
     every use with a typed withheld state and consumer obligations
     (C4-R13, 3.8, test 22; OQ-7 routes the interpretation to the owner).
     Reply and proof exemption narrowed to business completeness only
     (C4-R8, tests 14-15).
  4. Locks: number set under the predecessor lock (3.2, section 4); stale
     mapped after rollback with the latest committed number; whole-flow
     lock accounting; real-connection race tests 24-28; action-level
     no-write and no-orphan tests 10, 13, 17.
  Owner and architecture notes: §8 no longer implies the bounds can merge
  before the owner answers; section 7 lists the conventions for explicit
  Phase 3 ADR evaluation.
- Round 2: **UNREVIEWED** (pending Codex re-review of this revision). This
  blocks implementation.
- Owner acceptance of scope and answers to OQ-1..OQ-7: pending.
- Not authorized by this packet: code, migrations, UI, real data, model
  calls.
