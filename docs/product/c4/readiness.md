# C4 readiness packet: minimal run settings and per-run snapshot

Status: **entity PASS (Codex, round 2, at a15cf8b); owner answers
recorded 2026-10-14; revision 3 (owner-editable limits, OQ answers)
PASS by Codex at aa1cab8; awaiting the owner's scoped C4 G5.**
C4-01, Claude author → Codex reviewer. Nothing here authorizes code, a
migration, a UI change or a model call. On 2026-10-14 the owner accepted
the ADR-0005 C4 amendment on SQL logging (section 7) and answered OQ-1..OQ-7
(section 9). OQ-2 changed the limits contract: no limit has a fixed ceiling
in code; the owner raises or lowers each one in the app (D-062; sections
3.3, 3.8). Entity PASS, owner answers, ADR acceptance and G5 are separate
gates; none implies another. The implementation obligations Codex attached
to the PASS are in section 11.

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
  is a B8-03 extension, decided in B8-03's own review under D-062.
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
| C4-R6 | An operator retry reuses the original run's snapshot (its budget limits are already copied and never raised); current grants, tenant-day limits, provider quotas and safeguards still apply at use (C4-R10; OQ-4). New settings apply to a new assignment. A retry of a run with no snapshot is refused before anything is written. |
| C4-R7 | The research brief, writing guide and operational limits have built-in defaults in code, used until an admin saves a revision. The offering profile and booking link have none. |
| C4-R8 | Business-content completeness: runs whose origin is `:assignment`, `:referral`, `:followup`, `:discovery` or `:channel` require a saved offering profile and are refused before anything is written with `{:settings_incomplete, [:offering_profile]}`. Runs of origin `:reply` and `:proof` are exempt from this completeness rule only. They still bind a snapshot, and every operational, grant, tenant-day and provider limit and every R0 proof authority applies to them unchanged. An unknown or missing origin is refused as today. Reply classification and its unsubscribe and suppression effects never wait on an offering-, guide- or booking-dependent step; an interested-reply draft is a separate step that may refuse for missing business input. |
| C4-R9 | A missing or withheld booking link never blocks a run. A first-touch draft without a usable link uses the writing guide's "questions first" ask (OQ-3). A consumer step that needs a link (B5's interested reply) refuses with a typed reason. No step invents, substitutes or leaks a link, or proposes times in its place. |
| C4-R10 | Each operational limit is an owner setting with no fixed ceiling in code (D-062; OQ-2). A save is validated (a whole number, at least the field's minimum, at most its sanity maximum, the cross-field rules of section 3.3) and refused, never clamped, when invalid. A save that raises any field above the value in effect is refused unless the admin confirmed each raised field; the confirmed set is recorded on the revision. At use, inside the guarded counter or admission path, the allowance is the lowest of the run's frozen maximum, the snapshot value and every independent budget (grant allocation, provider quota, tenant-day limit). Raising a setting never grants spend (D-062). Snapshot values are never rewritten; a save, raise or lower, applies to runs created after it (OQ-4). |
| C4-R11 | The settings page shows every limit with its value, built-in default, validation range, source (saved revision or built-in default) and whether code enforces it yet; tenant-day limits, grants and quotas read-only with their source; and the fixed architectural safeguards with their reasons, never editable here (D-062). The run page labels "limit at snapshot" separately from "allowed now". |
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
holds every numeric per-run ceiling, owner-editable and validated by one
rules table (D-062; section 3.3).
Consumers pass the run's allowances to the model as the research policy
input (brief input 8).

### 3.2 Entity table (delta)

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| SettingsRevision | New (APPEND-ONLY) | One immutable revision of one tenant-wide run setting | `id : uuid_v7`; `tenant_id : uuid, not nil`; `kind : atom, not nil, one of :offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits`; `number : int ≥ 1, not nil`; `supersedes_id : uuid, nullable`; `raised_fields : {:array, atom}, not nil, default []`, each one of the twelve limit-field names of section 3.3 (a closed set; sorted, no duplicates; names raised above the value in effect, confirmed by the admin; empty unless `kind = :operational_limits`; not sensitive); one embedded content attribute per kind (`offering_profile`, `booking_link`, `writing_guide`, `research_brief`, `operational_limits`), each nullable and `sensitive?: true`; `content_sha256 : string, not nil` (section 3.7); `note : string, nullable, ≤ 200, sensitive?: true`; `created_by_id : uuid, not nil`; `inserted_at`; trace ids | belongs_to Tenant (restrict); belongs_to User as `created_by` (restrict). Keys: PK `(id)`; UNIQUE `(id, tenant_id, kind)` (target of the self FK); UNIQUE `(id, tenant_id, kind, content_sha256)` (target of snapshot slot FKs); identity UNIQUE `(tenant_id, kind, number)`; partial UNIQUE `(supersedes_id) WHERE supersedes_id IS NOT NULL` (superseded at most once); partial UNIQUE `(tenant_id, kind) WHERE supersedes_id IS NULL` (one root per kind). Self FK `(supersedes_id, tenant_id, kind)` → `(id, tenant_id, kind)`, RESTRICT, so a revision supersedes only its own tenant's same kind. | Check: exactly the embedded attribute named by `kind` is non-null. Check: `number = 1` iff `supersedes_id IS NULL`. Check: `raised_fields` empty unless `kind = 'operational_limits'`. `number` = predecessor's number + 1, set by the action while it holds the predecessor's row lock (section 4). `content_sha256` computed from the cast, validated content (section 3.7). Trigger rejects UPDATE, DELETE, TRUNCATE. Current revision of a kind = highest `number`. No destroy action. | `:create_revision` (args `kind`, `content`, `expected_number : int ≥ 0` where 0 means "no revision yet", `note`, `confirm_raised : {:array, atom}, default []`): the action computes `raised_fields` against the value in effect (the locked predecessor, or the built-in default when none) and refuses `{:invalid, [confirm_raised: :mismatch]}` unless `confirm_raised` equals it exactly; active human admin only (`CurrentAdmin`, persisted row re-read); auditor role and every system actor forbidden. Appends `settings.revision.created` (section 3.6: metadata and hashes only). Row reads: admin, reviewer, auditor (through AuditedView), `agent_runtime`, `auditor_cli`, kernel. Field policy on the content attributes and `note`: admin, reviewer (read-only, OQ-6), auditor (audited), `agent_runtime`, `auditor_cli`, kernel. | none |
| OfferingProfile, OfferingItem | New (embedded) | What we sell, as structured items the research and draft cite | OfferingProfile: `name : 1..120`; `summary : 1..1,500`; `audience : 0..1,500`; `items : list, 1..30`. OfferingItem: `id : string ^[a-z0-9][a-z0-9_-]{0,39}$`; `kind : :feature \| :use_case \| :outcome \| :limit \| :proof_point`; `text : 1..400` | embedded in SettingsRevision | Item ids unique within the profile. Canonical JSON ≤ 16 KiB. Text rules of section 3.5. Citations name `(revision id, item id)` (brief appendix), so they resolve against the exact revision. | via SettingsRevision | OQ-1 |
| BookingLink | New (embedded) | The owner's scheduling page, used in asks (D-025, D-053, D-082) | `url : string, not nil, ≤ 2,048 bytes` | embedded in SettingsRevision | `https` only; host required; no user info; no IP literal, `localhost` or `.local`; port absent or 443; no control or whitespace characters; redactor rule. Real-data guard at save and at each use (C4-R13). | via SettingsRevision | OQ-3, OQ-7 |
| WritingGuide | New (embedded) | Tone and shape of drafts (D-053, D-065) | `text : string, 1..6,000` | embedded in SettingsRevision | Text rules of section 3.5. The built-in default is neutral generic text in code, not the owner's D-053 wording (OQ-5); the owner's version is saved in the app as a revision, after the server-log prerequisite. | via SettingsRevision | none |
| ResearchBrief | New (embedded) | Editable research guidance (D-050, D-051) | `guidance : string, 1..12,000`; `depth : atom, not nil, one of :standard` | embedded in SettingsRevision | One depth in the MVP (D-052). Holds no Fixed rule. Built-in default from the brief's editable sections (code). | via SettingsRevision | OQ-1, OQ-5 |
| OperationalLimits | New (embedded) | Per-run ceilings the admin raises or lowers (D-062, OQ-2) | the twelve integer fields of section 3.3, each not nil | embedded in SettingsRevision | Each field passes its validation rule in section 3.3 (whole number, minimum, sanity maximum; no policy ceiling); cross-field: `research_max_total_source_chars ≥ research_max_source_chars`, `research_max_model_calls ≤ run_max_model_calls`, `research_target_seconds ≤ research_job_limit_seconds`. An invalid save is refused, never clamped. Raised fields need confirmation (SettingsRevision `raised_fields`). | via SettingsRevision | none |
| RunSettings.CodeDefaults | New (code registry, not persisted) | Built-in defaults for research brief, writing guide, operational limits | per kind: list of released `{version, content, content_sha256}` | referenced by version from RunSettingsSnapshot | Released versions are never edited or removed; a golden-hash test pins each `content_sha256` computed by the section 3.7 rule. Each default passes the same validation as an admin save. | n/a (code, reviewed) | OQ-1 |
| RunSettings.Safeguards | New (code registry, not persisted) | The limit validation rules and the read-only safeguard list | `version : string`; validation rule per limit field (minimum, sanity maximum; no policy ceiling); safeguard entries `{name, reason, enforced_by}` | referenced by `safeguards_version` from RunSettingsSnapshot | Changes only by reviewed code. Validation applies at save only; it never rewrites or re-limits a snapshot. | n/a (code, reviewed) | none |
| RunSettingsSnapshot | New (APPEND-ONLY) | The exact settings one run (and its retries) uses | `id : uuid_v7`; `tenant_id`; for each kind K: `K_source : atom, not nil, one of :revision, :code_default, :absent`, `K_revision_id : uuid, nullable`, `K_code_default_version : string, nullable`, `K_content_sha256 : string, nullable`, and `K_kind : text GENERATED ALWAYS AS ('K') STORED`; `limits : SnapshotLimits, not nil`; `safeguards_version : string, not nil`; `hash_version : string, not nil` (`"c4-run-settings-snapshot/1"`); `snapshot_sha256 : string, not nil`; `inserted_at`; trace ids | belongs_to Tenant (restrict). Keys: PK `(id)`; UNIQUE `(id, tenant_id)` (target of the AgentRun FK). Per kind: FK `(K_revision_id, tenant_id, K_kind, K_content_sha256)` → SettingsRevision `(id, tenant_id, kind, content_sha256)`, RESTRICT, MATCH SIMPLE (skipped when `K_revision_id` is null). has_many AgentRun. | Per-kind checks: `:revision` ⇒ revision id and content hash set, version null; `:code_default` ⇒ version and content hash set, revision id null, allowed only for brief, guide and limits; `:absent` ⇒ all three null, allowed only for offering and booking link. The FK makes the DB refuse a cross-tenant, wrong-kind or wrong-hash revision reference. A code default's version and hash are checked against `CodeDefaults` by the building change and again at use. `snapshot_sha256` per section 3.7. Trigger rejects UPDATE, DELETE, TRUNCATE. | Created only inside `AgentRun :create` by `BuildSettingsSnapshot` under a context marker (`SettingsSnapshotContext`, the `GrantContext` pattern). The snapshot create action accepts no attributes: every id, version, hash and limit is computed by the change from the run's tenant and origin. A direct create, or a create with any supplied attribute, is forbidden for every actor. Appends `settings.snapshot.created` (references, hashes, limits only). Reads: admin, reviewer, auditor (AuditedView), `agent_runtime`, `auditor_cli`, kernel. | none |
| SnapshotLimits | New (embedded) | Limits recorded at snapshot time | the twelve fields of section 3.3 | embedded in RunSettingsSnapshot | Each field = the revision or built-in value in effect at snapshot time. Never rewritten; the allowance at use is computed (C4-R10), not stored. | via snapshot | none |
| AgentRun | Existing (delta) | Agent run with per-run budget | add `settings_snapshot_id : uuid, nullable` | composite FK `(settings_snapshot_id, tenant_id)` → RunSettingsSnapshot `(id, tenant_id)`, RESTRICT; many runs to one snapshot (a run and its retries) | **Cutover trigger** (BEFORE INSERT OR UPDATE): an INSERT with null `settings_snapshot_id` is refused; an UPDATE that changes `settings_snapshot_id` (attach to a historical null, detach, or replace) is refused. Historical null rows keep every existing transition. No backfill. Set only by `:create` (the change builds the snapshot; no input accepts an id) and `:retry` (copied by `RetryOf`). `:create` refuses `{:settings_incomplete, kinds}` per C4-R8. Frozen budget: `max_model_calls`, `max_tool_calls`, `max_tokens` = min(caller argument when given, snapshot `run_*` value). `:retry` of a historical null-snapshot run is refused `no_settings_snapshot` before any Operation, job or attention resolution is written (`SDR.retry_run/2` pre-check; the transaction also rolls back). | Unchanged (AGT, SCH create; ADM retry inside `SDR.retry_run/2`) | none (OQ-4 answered: a retry keeps its snapshot) |
| AgentRun counters (`:reserve_model_call`, `:record_tool_call`) | Existing (behaviour delta) | Guarded per-run counters | — | unchanged | On the row locked `FOR UPDATE` (`BudgetCounter`): `:reserve_model_call` refuses when `model_calls_reserved ≥ budget.max_model_calls` or `tokens_used ≥ budget.max_tokens`; `:record_tool_call` refuses when `tool_calls_used ≥ budget.max_tool_calls` (the run's frozen budget, from the snapshot). Grant admission (C9) and the tenant-day model-call limit still apply in their own guarded paths. The token check moves here from the caller-side preflight in `SdrAgent.SDR.Model` (kept as an early message). Tokens are known only after a call, so one call can overshoot the remaining token allowance; the limit stops the next call. | unchanged | none |
| AuditEvent (via `AppendEvent`) | Existing (behaviour use) | Ledger after-images | — | unchanged | No change to `AppendEvent`: it already omits `sensitive?` attributes from the after-image, names them under `redacted`, and keeps `record_sha256` over the full row. C4 marks every settings content attribute and `note` sensitive, so generic event readers (admin, reviewer, auditor) see kind, number, `supersedes_id`, `content_sha256` and `record_sha256`, never the text. | unchanged | none |
| Telemetry.GenAI | Existing (behaviour delta) | GenAI spans | request option `content_capture : :inherit \| :off` | — | A request whose input carries run settings is built with `content_capture: :off`; then no `gen_ai.input.content` or `gen_ai.output.content` span event is emitted, whatever `otel_capture_content` says (dev sets it true today, `config/dev.exs`). Span attributes stay metadata and hashes. | — | none |
| Accounts.User | Existing | Human operators | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (referenced as `created_by` only; roles and role-change rules unchanged) | — | — |
| Tenant | Existing | Singleton tenant | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Sales.Campaign | Existing | Sender identity and compliance defaults | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (sender identity stays on the campaign; campaign-scoped settings are B8) | — | — |
| Actor | Existing | System actor types | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no new system actor; `agent_runtime` gains read only) | — | — |

### 3.3 Operational limits, validation and where each is enforced

Defaults are the built-in limits revision. The owner decided on 2026-10-14
(OQ-2) that no limit has a hard ceiling that no setting can change: the
admin raises or lowers every field in the app (D-062). Validation only
keeps a value sane: a whole number, at least the minimum below, at most the
representation maximum, and the cross-field rules of the OperationalLimits
row. Every field, counts and seconds alike, has the maximum 2,147,483,647,
the stored signed 32-bit integer range; a finite job limit (D-061) needs
nothing lower. The pinned runtime accepts that many seconds as a timer:
Codex ran `:erlang.start_timer/3` under the project's OTP 29.0.5 with
4,294,967,295 ms, 4,294,968,000 ms and 2,147,483,647,000 ms, and each was
accepted and cancelled (answer 214dbafb, 2026-10-14). Consumers convert
seconds to milliseconds with integer arithmetic and check the result before
any timer or deadline. These are representation limits, not policy
ceilings. A raise above the value
in effect needs a per-field confirmation that names the old value, the new
value, the built-in default and the budgets that still bound it; the
confirmed fields are recorded on the revision (`raised_fields`) and in its
event.

Spend stays bounded where it is today, and no limit setting raises it
(section 3.4): C9 grants and allocations, 200 model calls per UTC day and
25 sends per local day (config may only lower), and the D-102 provider
quotas. A larger per-run value lets one run use more of those budgets; it
never adds to them.

| Field | Default | Validation (minimum..sanity maximum) | Authoritative check at use |
|---|---|---|---|
| `run_max_model_calls` | 20 | ≥ 1 | `AgentRun :reserve_model_call` (`BudgetCounter`, row `FOR UPDATE`) against the run's frozen budget; C9 grant admission and the 200-per-UTC-day limit separately; ADR-0004 C4 note |
| `run_max_tool_calls` | 60 | ≥ 1 | `AgentRun :record_tool_call` against the run's frozen budget |
| `run_max_tokens` | 100,000 | ≥ 1 | `AgentRun :reserve_model_call` against the run's frozen budget (moved from `SdrAgent.SDR.Model`); stops the next call, one call may overshoot |
| `research_max_search_requests` | 4 | ≥ 0 | C5-02 adapter, before each request (retries and pagination counted), within the D-102 quota — not enforced until C5-02 |
| `research_max_page_fetches` | 4 | ≥ 0 | C5-03 safe fetch — not enforced until C5-03 |
| `research_max_sources` | 6 | ≥ 1 | B1-04 evidence bundle — not enforced until B1-04 |
| `research_max_source_chars` | 4,000 | ≥ 500 | B1-04 — not enforced until B1-04 |
| `research_max_total_source_chars` | 24,000 | ≥ 500 | B1-04 — not enforced until B1-04 |
| `research_max_output_tokens` | 2,500 | ≥ 256 | B1-04 model request — not enforced until B1-04 |
| `research_max_model_calls` | 2 | ≥ 1, ≤ `run_max_model_calls` | B1-04 — not enforced until B1-04; each extra call is a deliberate repair inside the run budget, never a retry of an unknown outcome (D-064) |
| `research_target_seconds` | 180 | 30..2,147,483,647, ≤ job limit (warning only, D-061) | B1-04 progress, H1 row — warning, never a stop |
| `research_job_limit_seconds` | 600 | 60..2,147,483,647 (finite job limit, D-061) | B1-04 worker deadline; an in-flight model call ends by its own timeout and is recorded unknown, never cut silently or retried (D-064) — not enforced until B1-04 |

Count fields not shown with a maximum have the sanity maximum 2,147,483,647.

Consumers read an allowance only through `Agents.RunSettings.allowance(run,
field)`, which returns the snapshot value (for the three `run_*` fields,
the run's frozen budget), and combine it with their own independent
budgets inside their guarded step. The settings
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
| SQL logging and query spans | Ecto logs query parameters at debug (dev), and `opentelemetry_ecto` 1.2.0 copies the exception message into the span status and the Repo URL into `db.url`. The default Ecto logger and `OpentelemetryEcto` are detached; `SdrAgent.Repo.QueryLog` and `SdrAgent.Telemetry.RepoSpans` emit only fields allowlisted by `SdrAgent.Repo.SafeMetadata` (never parameters, SQL text, exception messages, DETAIL/HINT, URLs or credentials), in every environment; a logger filter and Oban worker boundaries cover automatic exception reports. This also covers prospect data under the real-data switch. The ADR-0005 C4 amendment, accepted by the owner on 2026-10-14 (section 7). |
| PostgreSQL server log | Not covered by app controls. Separate prerequisite, owned by the owner: before private settings content is saved or the real-data switch is on, either a server-log configuration decision is accepted with its own test or the owner accepts an explicit retention exception (ADR-0005 C4 amendment). |
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
  "safeguards_version": V, "slots": S, "limits": L}`.
  S has all five kinds as keys, always. A slot is exactly one of
  `{"source": "revision", "revision_id": id, "content_sha256": h}`,
  `{"source": "code_default", "version": v, "content_sha256": h}`,
  `{"source": "absent"}`; no other keys, never `null`. L has all twelve
  limit fields as integers.
  Excluded: the snapshot id, trace ids, `inserted_at`, `hash_version` (it
  names the schema already in the input) and the digest itself. The
  hashed slots must equal the stored per-kind columns exactly; the
  building change derives both from one value and a test recomputes.

### 3.8 Changed backend action contracts

- **`Agents.create_settings_revision/2`** (new). Inputs: kind, content,
  `expected_number`, note, `confirm_raised` (limits only); actor a human
  admin. Returns the revision or a
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
- **`Agents.RunSettings.allowance/2`** (new). The snapshot value of one
  limit field (the frozen budget for the `run_*` fields).
- **`Agents.RunSettings.booking_link_for_use/1`** (new). `{:ok, url}`,
  `{:error, :booking_link_absent}` or `{:error, :booking_link_withheld}`
  (guard fails now). Consumer obligations: call it when building model
  input and again before persisting a draft; record the booking-link
  revision id on the draft so the capture gate can re-check it. The
  capture re-check lands with the first consumer that puts a link in a
  draft (B1-05 or B5-03), under its own entity delta (section 6); C4-01
  does not add a Draft attribute.
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
- **`AgentRun :reserve_model_call`, `:record_tool_call`** (changed). Enforce
  the run's frozen budget on the locked row, including the token check
  (3.2 counters row).
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
  "limits": {"run_max_model_calls": 20, "run_max_tool_calls": 60, "research_max_sources": 6, "…": "…"}
}
```

The admin then saves writing guide revision 1 while the run is queued. The
queued run still drafts with built-in guide version 1; the next assignment
uses guide revision 1. A retry of the first run uses its original snapshot.
A save of the offering against `expected_number` 0 after revision 1 exists
is refused `{:stale_revision, 1}`. If the admin later saves limits with
`run_max_model_calls` 30 (confirming the raise), the queued run keeps 20
and the next assignment gets 30; that run is still refused by grant
admission or the 200-per-UTC-day limit whenever those run out first.

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
   policy; a reviewer reads them and cannot write (OQ-6).

Validation (one success and the boundary failures per field):
7. Each limit at its minimum and at its sanity maximum passes; minimum − 1,
   maximum + 1, a non-integer and nil are refused; cross-field rules
   refused. A value far above the built-in default (e.g. 1,000 model calls)
   passes with confirmation: no policy ceiling exists.
7a. Raise confirmation: a raise without `confirm_raised`, or with a set that
   differs from the raised fields (missing, extra, a lowered field), is
   refused and writes nothing; an exact match saves with sorted
   `raised_fields` on the revision and in its event; a pure lowering needs
   no confirmation; the first save compares against the built-in default.
   `raised_fields` on a non-limits kind is refused by the DB check.
   `confirm_raised` with a duplicate name, an unknown name or a non-limit
   atom is refused `{:invalid, [confirm_raised: ...]}` and writes nothing;
   unknown strings never create atoms.
7b. Time fields: `research_job_limit_seconds` 86,401, 4,294,968 and
   2,147,483,647 pass and convert to exact milliseconds that the pinned
   runtime accepts as a timer (`:erlang.start_timer/3`, then cancelled);
   2,147,483,648 is refused as outside the stored integer range; the
   conversion is checked, never truncated or wrapped.
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
21. Limits saved after a snapshot, raised and lowered: the run's snapshot
    and frozen budget are unchanged; `:reserve_model_call`,
    `:record_tool_call` and the token check refuse at the frozen budget,
    also for a retry and for a direct domain call; `allowance/2` returns
    the snapshot value. A raised `run_max_model_calls` still yields to an
    exhausted grant allocation and to the tenant-day limit (one refusal
    case each).
21a. First touch without a usable link (absent, or withheld as in 22) uses
    the questions-first ask: the Fake model input carries no URL and
    no proposed times; B5's interested-reply step refuses with the typed
    reason (OQ-3). (Consumer tests land with B1-05 and B5-03.)
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
31. The page shows values, built-in defaults, validation ranges, sources,
    "not yet enforced" labels, the raise confirmation and the safeguard
    list; the run page shows the snapshot with "limit at
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
- **Not in C4-01:** recording the booking-link revision on a draft and the
  capture-time re-check (section 3.8) add an attribute and a gate to the
  Outreach draft. That is a separate entity delta, submitted by B1-05 or
  B5-03 for its own independent review before it is implemented; C4's
  PASS does not cover it.

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
- **Metadata-only database logging and spans** in every environment
  changes debugging for all queries and replaces the `opentelemetry_ecto`
  handler. Recorded as the "C4 amendment (2026-10-12): metadata-only
  database logging and spans" in
  `docs/adr/0005-observability-wire-witness-anchoring.md` (OpenTelemetry
  section): Codex approved revision 2 at 7f6d97d; **accepted by the owner
  on 2026-10-14**. The PostgreSQL server log is a separate prerequisite
  named there (direction approved 2026-10-14; proposal pending).
- **Per-run model-call cap becomes an owner setting** (OQ-2). ADR-0004's
  "at most 20 model calls per agent run" becomes the built-in default of
  `run_max_model_calls`; a one-line C4 note in
  `docs/adr/0004-model-provider.md` records it. The 200-per-UTC-day limit,
  C9 grants and pre-call reservation are unchanged.
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
- Owner-editable limits (OQ-2) let one run use more of the shared budgets:
  a large `run_max_model_calls` can spend a day's 200 calls or a grant's
  allocation in one run. Mitigated by the raise confirmation naming those
  budgets, the frozen per-run snapshot, and the unchanged tenant-day,
  grant and provider limits; the owner chose editability over a fixed
  ceiling.
- The built-in writing guide is neutral generic text (OQ-5); drafts sound
  generic until the owner saves their own guide, which waits for the
  server-log prerequisite.
- Generated stored columns in a composite FK are standard PostgreSQL
  (RESTRICT only); the migration test confirms it on the pinned version. A
  constraint trigger is the fallback if not.

## 9. Owner questions

These are the owner's decisions. The owner answered all seven on
2026-10-14 (America/Denver) in the private Claude session chat; the
answers are quoted after each question and modeled in the sections named.

- **OQ-1 Content sign-off and defaults.** Please enter the offering
  profile and booking link (the build plan S1 checkpoint), and approve
  (a) the built-in writing guide drafted from your D-053 default and
  (b) the editable part of research brief revision 2 (row F3b). Until you
  save each one, runs use the built-in version and a deploy can change it;
  after you save, only your edits change it. Accept?
  **Answer (12:16 MDT): "accept the behavior now".** Built-in defaults
  until saved; only the owner's revisions after that; offering and booking
  link have no default. The texts of (a) and (b) are approved later in the
  C4 implementation PR; per OQ-5, (a) is the neutral built-in guide. The
  owner enters content after the server-log prerequisite closes.
- **OQ-2 Bounds.** Confirm the fixed bounds in section 3.3, in particular
  the research ceilings (8 searches, 8 fetches, 10 sources, 48,000
  characters, 4,000 output tokens) and the job limit (600 s default,
  900 s bound).
  **Answer (12:23 MDT): "i don't think there should be a hard ceiling that
  no setting can change. that's not user-friendly."** Claude noted the
  conflict with D-062 and proposed owner-raisable and lowerable limits with
  sanity validation, audited confirmation and the per-run snapshot,
  budgets and safeguards unchanged, and a one-line ADR-0004 note; the
  owner said **"revise C4 that way"**. Modeled in C4-R10, sections 3.2,
  3.3, 3.8, 7 and tests 7, 7a, 21. The fixed bounds above are withdrawn.
- **OQ-3 No booking link.** When no booking link is saved (or it is
  withheld), should a first-touch email use your "questions first" ask
  (recommended; D-053 allows either), or should drafting stop until one is
  saved? B5's interested reply never drafts without one.
  **Answer (12:48 MDT): "i choose (a)"** (questions first; Codex also
  recommended (a)). Never an invented link or times, no fallback URL; B5
  still requires a saved, usable link (D-025). C4-R9, test 21a.
- **OQ-4 Retry.** A re-run of a failed run uses the settings it started
  with (recommended, so a re-run is the same job; current safeguards still
  apply); a fresh assignment uses the current settings. Accept, or should
  re-runs pick up current settings?
  **Answer (13:03 MDT): "i choose (a)".** C4-R6.
- **OQ-5 Publication.** The built-in writing guide is derived from your
  own words (D-053) and would sit in the public repository as code. Is
  that allowed, or should the built-in guide be a neutral synthetic text
  and your version entered only in the app?
  **Answer (13:12 MDT): "i choose (b)".** The built-in guide is neutral
  generic text; the owner's version is a saved revision, entered after the
  server-log prerequisite. WritingGuide row.
- **OQ-6 Reviewer access.** Reviewers can read settings text, read-only
  (recommended, since they judge drafts against the guide and offering).
  Accept? If not, reviewers see only hashes and revision numbers.
  **Answer (13:15 MDT): "i choose (a)".** Reviewers read settings text,
  read-only; admin and auditor access unchanged, auditor views audited and
  fail closed. SettingsRevision field policy, test 6.
- **OQ-7 Booking link and the real-data switch.** This packet treats your
  own booking URL like other real data: allowed only while the real-data
  switch is on, checked at every use. Should your booking link instead be
  usable regardless of the switch (it is your own business link, not
  prospect data)?
  **Answer (13:16 MDT): "(a)".** The booking link is real data: usable only
  while the real-data switch is on, checked at each use; otherwise withheld
  and the first touch uses questions first. C4-R13 unchanged, test 22.

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
- Round 2 at a15cf8b: **PASS**. Reviewer Codex via ai-pair; answer
  `codex-c4-round2-pass`, in reply to `m_1791846449000004412_b8827755`;
  2026-10-12. Report:
  `/Users/charles/.local/state/sdr-agent/handoff-20261008/tmp/codex-c4-01-a15cf8b-entity-pass.md`
  (private, outside git; sha256
  `43c8d75a6d9c1bfd4a732e46056f544e023ae8e8e8030add875879cfff534542`).
  The PASS is a docs/entity review only: not implementation, RED
  verification, owner acceptance, ADR acceptance, merge, deployment or
  spend authority. It carries seven implementation obligations
  (section 11). Once the owner answers OQ-1..OQ-7, only a changed entity,
  authority or lifecycle contract goes back for recheck.
- ADR-0005 C4 amendment (metadata-only database logging and spans):
  revision 1 at 1f88700 reviewed by Codex: **REQUEST_CHANGES**, one
  security must-fix (the `opentelemetry_ecto` span status copies the
  exception message; `db.url` copies the Repo URL). Report
  `/Users/charles/.local/state/sdr-agent/handoff-20261008/tmp/codex-c4-adr0005-1f887005-review.md`
  (private; sha256
  `8de031ba1c2c1126aacb5ef29a11fda8fcabaf4740865a6095fafadf421f87f2`).
  Revision 2 adds the safe span handler and status, no `db.url`, named
  duration fields, fixed identifiers only, logger filter and Oban
  boundaries for automatic reports, full-span canary tests, and the
  server log as a separate gated prerequisite. Revision 2 at 7f6d97d:
  **APPROVE** by Codex for owner consideration (answer
  `codex-c4-adr0005-rev2-answer`, in reply to
  `m_1791849930000026234_68d25cfc`; report
  `/Users/charles/.local/state/sdr-agent/handoff-20261008/tmp/codex-c4-adr0005-7f6d97d-review.md`,
  private; sha256
  `6f82940887d7ba9f7eba4d58f3135ff76b5cdd72d5511e9a52fcf2ff9251c79d`).
  **Accepted by the owner on 2026-10-14** (about 11:48 MDT, standup item
  5a). The owner first said: "no, i don't think the C4 logging amendment
  is a good idea. for example, if we're using nondeterministic methods to
  reproduce data there's a possibility we won't be able to reproduce the
  original data. am i understanding this correctly?" Claude explained that
  the durable stores (audit payloads, invocation rows, the witness store)
  keep the original data and that only failed or rolled-back write values
  are lost from logs, and gave the benefits. The owner then said: "no, i
  accept the C4 logging amendment as-is."
- PostgreSQL server-log prerequisite: open, owner-owned; gates saving
  private settings content and turning on the real-data switch. Direction
  approved 2026-10-14 (about 11:55 MDT, "i approve option 1's direction for
  5b", after Codex's recommendation 4aff1677); Claude drafts the proposal,
  Codex reviews.
- Owner answers to OQ-1..OQ-7: **recorded 2026-10-14** (section 9).
- Revision 3: owner-editable limits and the OQ answers. **Pending Codex's
  narrow re-review** of the changed limits, authority and confirmation
  contract (C4-R6, C4-R9..R11; sections 3.2, 3.3, 3.7, 3.8, 3.9, 7, 8;
  tests 6, 7, 7a, 21, 21a, 31; obligation 6 note).
  Round at c447470: **NEEDS-REVIEW** (Codex answer
  8763438d-62e1-48fd-8fea-ef1c9619e1f0, in reply to
  m_1792010909482749000_ea17c252). One must-fix: the 86,400 s maximum on
  the time fields was a policy ceiling, not a representation limit.
  Revised: the maximum is the timer representation limit (4,294,967 s,
  checked ms conversion, re-verified against the pinned OTP), test 7b.
  Nonblocking, also done: section 3.6 status wording; `raised_fields` and
  `confirm_raised` limited to the closed set of limit names, with
  duplicate and unknown tests (7a).
  Round at aec6304: **NEEDS-REVIEW** (Codex answer
  214dbafb-8cb3-45e0-87ce-e831947bdb46). One must-fix: the pinned OTP
  29.0.5 accepts timers above 4,294,967,295 ms (checked up to
  2,147,483,647,000 ms), so 4,294,967 s was not the runtime limit.
  Revised: the time fields share the stored integer maximum, 2,147,483,647,
  with the runtime check cited and test 7b at that value. The closed
  confirmation set and the 3.6 wording passed. This was the second
  NEEDS-REVIEW on the same item; the owner was told the same day
  (tripwire 2).
  Round at aa1cab8: **PASS** (Codex answer
  c9f3457c-8aec-47f0-9d9c-ee866515f195, 2026-10-14T20:53:55Z, delta
  aec6304..aa1cab8). Earlier qualifications carry (raise confirmation,
  immutable snapshot and counters, unchanged independent budgets, booking
  link, content access). No RED, GREEN or merge approval; the server-log
  prerequisite (5b) stands.
- Owner scoped C4 G5: **pending** (revision 3 passed at aa1cab8).
- Not authorized by this packet: code, migrations, UI, real data, model
  calls.

## 11. Implementation obligations (Codex round-2 PASS qualifications)

Copied from the round-2 report. Each is binding on the C4-01a and C4-01b
implementation and its review.

1. **Relational rules.** Preserve every rule stated here, including each
   source-slot check and the wrong-kind, wrong-hash and wrong-tenant
   database negative tests. A fallback constraint trigger must implement
   the same binding and immutability semantics; if it changes them, return
   for entity review. Generated kind columns are database-derived and never
   caller-writable attributes.
2. **Cutover at the database boundary,** not only in `:create`: no new
   null snapshot; no attaching to a historical null, replacing or
   detaching. Existing null runs stay readable and can transition;
   settings-dependent use and retry refuse without an orphan Operation,
   job, snapshot or attention resolution. The privileged database owner is
   the usual trusted administrator boundary, not an application backfill
   path.
3. **Privacy QA** covers valid and invalid content, debug logs,
   content-enabled dev telemetry and event parameters. The SQL handler
   logs allowlisted metadata only: never parameters, exception inspection,
   raw SQL containing literals or embedded error values. Content
   suppression applies to span attributes and events and cannot be undone
   by a provider or request option. The authorized model payload, witness
   and settings UI seams are preserved and described as allowed copies.
4. **Architecture decisions before implementation approval.** The
   all-environment replacement of Ecto parameter logging is decided
   explicitly (the proposed ADR-0005 C4 amendment, with the tradeoff,
   allowed metadata, error-path controls, the safe span status and tests;
   revised after Codex's ADR review). The durable retention
   of released defaults and the head-first snapshot convention are
   recorded in the Phase 3 architecture evaluation (section 7), relying on
   existing accepted decisions only where they actually cover the choice.
   Entity PASS is not ADR acceptance. The resource diagram is regenerated
   in C4-01a.
5. **Locks.** The compatibility assessment is settings-only (editor `FOR
   NO KEY UPDATE` versus snapshot FK `FOR KEY SHARE`). Keep the current
   read, the locked-predecessor check and the fresh latest-number lookup
   after rollback. Whole-flow tests account for the actual FK, user,
   definition, Operation, job and implicit audit locks; whole-flow
   correctness is not inferred from the local argument. Races use
   independent real PostgreSQL connections and bounded barriers, never a
   shared sandbox.
6. **Limits.** Guarded counters enforce current code bounds, including on
   direct domain calls and retries. *(Revision 3 note, 2026-10-14: the
   owner's OQ-2 answer removes fixed code bounds; the counters enforce the
   run's frozen budget on direct domain calls and retries, and grants,
   tenant-day limits and provider quotas still apply. Subject to Codex's
   narrow re-review; the rest of this obligation stands.)* Snapshots stay immutable; creation-time
   limits are reported separately from the current allowance. Token
   enforcement stops the next call, with one-call overshoot as stated.
   Research limits whose consumers are not built stay labelled not
   enforced. Proof and reply origins are exempt only from missing business
   content, never from budget, provider or proof authority.
7. **Booking link.** The use-time guard and no-substitution are the
   default pending OQ-7 *(answered (a) on 2026-10-14: the default stands)*. The draft binding and capture re-check in
   section 3.8 are a consumer prerequisite, not approval of a new Draft
   attribute: B1-05 or B5-03 submits that entity delta before implementing
   it, with switch-off tests at model input, draft persistence and
   capture. C4 alone does not authorize emitting real URLs. The owner's
   answer to OQ-7 may require a narrow recheck of this boundary.

Owner answers to OQ-1..OQ-7 are not assumed by this PASS. Built-in
defaults stay synthetic and unpublished as owner content until the
publication decision (OQ-5). *(OQ-5 answered (b) on 2026-10-14: the
built-in guide stays neutral and the owner's text is never in the
repository.)*

## 12. C4-01a interface rulings (RED round 1, Codex 533402a2, 2026-10-15)

These are names and shapes the packet left open, chosen by the RED at
`f2d2253` and ruled on by Codex in `codex-c401a-f2d2253-red-review.md`.
They are binding on GREEN, and on consumers (B1-04 and B1-05) before
those depend on them.

**Accepted:**
- **The APIs:** `create_settings_revision(%{kind, content,
  expected_number, note, confirm_raised}, opts)`, `current_settings/1`,
  `run_settings/2`, `RunSettings.allowance/2`, `booking_link_for_use/1`.
- **Resources and tables:** SettingsRevision and RunSettingsSnapshot
  (`settings_revisions`, `run_settings_snapshots`).
- **Content shapes,** atom-keyed and per kind:
  - offering: `%{name, summary, audience, items: [%{id, kind, text}]}`;
  - booking: `%{url}`;
  - guide: `%{text}`;
  - brief: `%{guidance, depth}`;
  - limits: a flat map of the 12 fields.
- **`run_settings/2`** returns `{:ok, %{kind => %{source, content,
  version, revision_id}}}`. An unsaved kind that has a built-in default
  returns that default by version (`source: :code_default`, `revision_id:
  nil`). An unsaved kind with no built-in default (the offering profile,
  the booking link) returns the absent slot (below). Neither ever falls
  back to the current revision.
- **`allowance/2`** returns `{:ok, integer}` or `{:error,
  :no_settings_snapshot}`.
- **Errors:** validation errors are `{:invalid, keyword}`, keyed by field.
  A stale save is `{:stale_revision, latest}`. A refusal is never
  inferred from a crash.
- **Helpers:** `CodeDefaults.released/1` and `current/1`,
  `Safeguards.version/0`, `RunSettings.completeness/0`, and
  `RunSettings.milliseconds/1`. The last does exact integer conversion
  with range checks.
- **Storage formats:** `raised_fields` is a closed-name `text[]`; hashes
  are lowercase hex.
- **`content_capture: :off | :inherit`,** as a request key and as GenAI
  metadata. `:off` dominates any conflicting provider or request option.
- **`agents.run.created`** reports the persisted `settings_snapshot_id`
  in `payload["changes"]`.

**Accepted with limits:**
- **`SettingsSnapshotContext`:** only as a read-only accessor to a
  phase that is already open, private and bound to its process. It is
  never a public constructor of authority. A forged or copied context
  grants nothing.
- **`:booking_link_guard` override:** only as a failure-injection seam in
  test builds. Builds without the seam ignore or refuse it. It is never a
  production bypass or an owner-facing override. Dev and non-seam
  evidence is due at GREEN.

**Rules that resolve ambiguities:**
- **Trimming:** surrounding whitespace is normalized first, then the
  normalized value is cast, stored and hashed. A control character or
  secret-shaped text at the edges is refused, never trimmed away.
- **`confirm_raised`:** an exact **set** of the raised names. Any order is
  accepted, and the names are stored sorted. A duplicate, unknown, extra
  or missing name is refused. No atom is created from an unknown string.
- **Golden defaults:** each pin is added at GREEN from exact, reviewed
  default content and an independently recomputed canonical hash. A pin
  is never derived from the implementation, and a historical pin is never
  changed.

**Chosen in RED round 2, for review:**
- **Constraint names:**
  - `settings_revisions_content_matches_kind`;
  - `settings_revisions_root_number`;
  - `settings_revisions_raised_fields_limits_only`;
  - `settings_revisions_one_root_per_kind_index`;
  - `settings_revisions_supersedes_once_index`;
  - `settings_revisions_supersedes_fkey`;
  - `run_settings_snapshots_<kind>_slot` and
    `run_settings_snapshots_<kind>_revision_fkey`;
  - `agent_runs_settings_snapshot_fkey`.
- **Append-only:** a `<table>_guard_truncate` trigger calls
  `<table>_append_only()`, which raises "<table> is append-only".
- **Kind columns:** writing a kind column is refused with
  `generated_always`.
- **The cutover trigger** names `settings_snapshot_id` in its message.
- **The absent slot**, for an unsaved kind with no built-in default:
  `%{source: :absent, revision_id: nil, version: nil, content_sha256:
  nil, content: nil}`.
- **Snapshot create:** an empty or supplied-attribute create is refused
  as Forbidden, never as a NoSuchInput Invalid.
