# C4 readiness packet: minimal run settings and per-run snapshot

Status: **draft for independent entity review (Codex) and owner acceptance.**
C4-01, Claude author → Codex reviewer. Nothing here authorizes code, a
migration, a UI change or a model call. Implementation starts only after
(1) Codex records an entity-model verdict of PASS on section 3 and (2) the
owner accepts the scope and answers the questions in section 9.

Sources (precedence): owner decisions D-050 to D-053, D-057, D-061, D-062,
D-065, D-069, D-101, D-102 (`docs/sdlc/decisions.md`); approved build plan
(`owner-decisions` branch) §1-§3, §8, §9, §9a, §10 (contract C4); backlog
rows C4-01, B1-04, B1-05, B3-03, B5-03, B8-01..03; default research brief
revision 2 (`research-brief` branch, `docs/product/briefs/default-research-brief.md`,
draft awaiting owner review); ADR-0009 (persistence conventions, layering),
ADR-0014 (constraints 1-7, amendment 2). Code facts are from `origin/main`
at 182bde6.

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
- Sender identity (name, email, footer, quiet hours) stays on
  `SdrAgent.Sales.Campaign`.

## 2. Requirements (observable behavior)

| ID | Requirement |
|---|---|
| C4-R1 | An active human admin can save a new revision of any of the five settings through an admin form with a review step and a confirmation. Saving appends a numbered revision; earlier revisions are never changed or deleted. |
| C4-R2 | No other actor can write settings: reviewers, auditors, disabled or demoted users (re-read at the time of the action) and every system actor, including `agent_runtime`, are refused. Refusals of guarded actions are audited as today (`authz.denied`). |
| C4-R3 | A save made against a revision that is no longer current is refused as stale, names the current revision, and writes nothing. Two concurrent saves of one setting produce exactly one new revision. |
| C4-R4 | Every new agent run binds exactly one settings snapshot in the transaction that creates the run. The snapshot records, for each setting, the exact revision used (or the built-in default version, or "absent"), the content hashes, and the effective run limits. A snapshot never changes. A later save never changes what a queued, running or finished run uses. |
| C4-R5 | Agents read settings only from their run's snapshot (`SdrAgent.Agents.run_settings/2`), never from the current revisions. A run with no snapshot gets no settings and its settings-dependent steps fail closed. |
| C4-R6 | An operator retry reuses the original run's snapshot (its budget limits are already copied and never raised). New settings apply to a new assignment. |
| C4-R7 | The research brief, writing guide and operational limits have built-in defaults in code, used until an admin saves a revision. The offering profile and booking link have none. |
| C4-R8 | An assignment (and any other business run: referral, follow-up, discovery, channel) is refused before anything is written when no offering profile revision exists, with the typed reason `{:settings_incomplete, [:offering_profile]}`. Reply-classification and proof runs are never blocked by settings, so an unsubscribe is always classified and suppressed. |
| C4-R9 | A missing booking link never blocks a run. A consumer step that needs one (B5 interested reply, B3 call-notes ask) refuses with its own typed reason; it never invents a link. |
| C4-R10 | Each operational limit is validated against a fixed bound in code. A save above the bound is refused with the bound named. At use, the effective limit is the lowest of the snapshot value, the current fixed bound and every independent budget (grant, provider quota, tenant day). Raising a setting never grants spend (D-062). |
| C4-R11 | The settings page shows every limit with its value, fixed bound, source (saved revision or built-in default) and whether code enforces it yet; tenant-day limits, grants and quotas read-only with their source; and the fixed architectural safeguards with their reasons, never editable here (D-062). |
| C4-R12 | Settings text is business content that may be sent to the model. Saves refuse secret-shaped text (the `SdrAgent.Operations.Redactor` patterns), control characters other than newline and tab, and content above the size caps in section 3.5. Settings text never appears in logs, Failure messages or telemetry attributes. |
| C4-R13 | The booking link is an `https` URL with a host name, no user info, no IP-literal or local host, no explicit non-default port, at most 2,048 bytes. Until C5-04's real-data switch exists and is on, its host must be under a reserved name (`SdrAgent.Sales.Synthetic`), like `Campaign.sender_email`. |
| C4-R14 | The run page shows the run's snapshot: revision number or built-in default version per setting, and its effective limits. Auditor views of settings and snapshots go through `SdrAgentWeb.AuditedView` and fail closed. |

## 3. Entity model

Entity Model trigger: **yes**. New persisted resources (settings revision,
run settings snapshot), new embedded value types with invariants, a new
admin-only write boundary, a new relationship and immutable attribute on
AgentRun, and changed backend action contracts (`AgentRun :create` and
`:retry`, `SDR.assign_lead/2`, reply intake).

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
constraint) gives one lifecycle, one policy and one lock rule. Five tables
would repeat all three.

**Snapshot as its own append-only row.** A separate `RunSettingsSnapshot`
row gets ADR-0009's append-only trigger for free and can be shared by a
run and its retries. The AgentRun row is not append-only (status changes),
so storing the snapshot inline would need column-level immutability anyway.

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
only admin saves change it. The settings page labels a built-in default as
"not yet reviewed by you". Owner question OQ-1 asks the owner to accept
this.

**Fixed rules are not settings.** The research brief's Fixed rules
(evidence, citations, never-collect, source text is data, no tools) live
in code with the prompt templates (versioned and hashed per ModelInvocation,
ADR-0002) and always frame the editable text. The research brief setting
holds only the editable guidance (purpose framing, research order,
emphasis). No settings text can remove or weaken a Fixed rule (B8-02).

**Research caps live in operational limits, not in the brief.** One place
holds every numeric ceiling, validated against one bounds table and shown
together (D-062). The brief guidance refers to limits; the consumer passes
the snapshot's effective values to the model as the research policy input
(brief input 8).

### 3.2 Entity table (delta)

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| SettingsRevision | New (APPEND-ONLY) | One immutable revision of one tenant-wide run setting | `id : uuid_v7`; `tenant_id : uuid, not nil`; `kind : atom, not nil, one of :offering_profile, :booking_link, :writing_guide, :research_brief, :operational_limits`; `number : int ≥ 1, not nil`; `supersedes_id : uuid, nullable`; one embedded content attribute per kind (`offering_profile`, `booking_link`, `writing_guide`, `research_brief`, `operational_limits`), each nullable; `content_sha256 : string, not nil` (canonical hash of the set content, server-computed); `note : string, nullable, ≤ 200`; `created_by_id : uuid, not nil`; `inserted_at`; trace ids | belongs_to Tenant (restrict); belongs_to User as `created_by` (restrict); `supersedes` self-reference via composite FK `(supersedes_id, tenant_id, kind)` → `(id, tenant_id, kind)` so a revision supersedes only its own tenant's same kind; unique `(id, tenant_id)` for snapshot FKs; identity unique `(tenant_id, kind, number)`; partial unique `(supersedes_id) WHERE supersedes_id IS NOT NULL` (superseded at most once); partial unique `(tenant_id, kind) WHERE supersedes_id IS NULL` (one root per kind) | Check: exactly the embedded attribute named by `kind` is non-null. Check: `number = 1` iff `supersedes_id IS NULL`. `number` = predecessor's number + 1, set by the action under the head lock (section 4). Trigger rejects UPDATE, DELETE, TRUNCATE. Current revision of a kind = highest `number` (no successor). No destroy action. | `:create_revision` (args `kind`, `content`, `expected_number : int ≥ 0` where 0 means "no revision yet", `note`): active human admin only (`CurrentAdmin`, persisted row re-read); auditor role and every system actor forbidden. Appends `settings.revision.created` (kind, number, supersedes_id, content_sha256). Reads: admin, reviewer, auditor (through AuditedView), `agent_runtime`, `auditor_cli`, kernel. | OQ-6 (reviewer read) |
| OfferingProfile, OfferingItem | New (embedded) | What we sell, as structured items the research and draft cite | OfferingProfile: `name : 1..120`; `summary : 1..1,500` (what we sell, to whom); `audience : 0..1,500`; `items : list, 1..30`. OfferingItem: `id : string ^[a-z0-9][a-z0-9_-]{0,39}$`; `kind : :feature \| :use_case \| :outcome \| :limit \| :proof_point`; `text : 1..400` | embedded in SettingsRevision | Item ids unique within the profile. Canonical JSON ≤ 16 KiB. Text rules of section 3.5. Citations name `(revision id, item id)` (brief appendix), so they resolve against the exact revision even if a later revision drops the item. | via SettingsRevision | OQ-1 |
| BookingLink | New (embedded) | The owner's scheduling page, used in asks (D-025, D-053, D-082) | `url : string, not nil, ≤ 2,048 bytes` | embedded in SettingsRevision | `https` scheme only; host required; no user info; no IP literal, `localhost` or `.local`; port absent or 443; no control or whitespace characters; redactor rule (no tokens in the query). Synthetic guard: host reserved (`Synthetic.reserved_domain?/1`) until C5-04's switch is on. | via SettingsRevision | OQ-3 |
| WritingGuide | New (embedded) | Tone and shape of drafts (D-053, D-065) | `text : string, 1..6,000` | embedded in SettingsRevision | Text rules of section 3.5. Built-in default from D-053 (code). | via SettingsRevision | OQ-1, OQ-5 |
| ResearchBrief | New (embedded) | Editable research guidance (D-050, D-051) | `guidance : string, 1..12,000`; `depth : atom, not nil, one of :standard` | embedded in SettingsRevision | `depth` has one value in the MVP (D-052); a later depth is a contract extension. Holds no Fixed rule; Fixed rules are code (section 3.1). Built-in default from the brief's editable sections (code). | via SettingsRevision | OQ-1, OQ-5 |
| OperationalLimits | New (embedded) | Per-run ceilings an admin may lower or raise up to a fixed bound | the twelve integer fields of section 3.3, each not nil | embedded in SettingsRevision | Each field within its bound (section 3.3); cross-field: `research_max_total_source_chars ≥ research_max_source_chars`, `research_max_model_calls ≤ run_max_model_calls`, `research_target_seconds ≤ research_job_limit_seconds`. A save above a bound is refused, never clamped. | via SettingsRevision | OQ-2 |
| RunSettings.CodeDefaults | New (code registry, not persisted) | Built-in defaults for research brief, writing guide, operational limits | per kind: list of released `{version, content, sha256}` | referenced by version from RunSettingsSnapshot | Released versions are never edited or removed; a golden-hash test pins each. Each default passes the same validation as an admin save. | n/a (code, reviewed) | OQ-1 |
| RunSettings.Safeguards | New (code registry, not persisted) | Fixed bounds and the read-only safeguard list | `version : string`; bound per limit field; safeguard entries `{name, reason, enforced_by}` | referenced by `safeguards_version` from RunSettingsSnapshot | Changes only by reviewed code. A lowered bound applies to existing snapshots at use (effective = min). | n/a (code, reviewed) | OQ-2 |
| RunSettingsSnapshot | New (APPEND-ONLY) | The exact settings one run (and its retries) uses | `id : uuid_v7`; `tenant_id`; per kind `<kind>_revision_id : uuid, nullable` and `<kind>_source : atom, not nil, one of :revision, :code_default, :absent`; `code_default_versions : map kind → version` (kinds resolved to a built-in default); `content_sha256s : map kind → sha256` (present kinds); `effective_limits : EffectiveLimits, not nil`; `safeguards_version : string, not nil`; `snapshot_sha256 : string, not nil` (canonical hash of all of the above); `inserted_at`; trace ids | belongs_to Tenant; each `<kind>_revision_id` composite FK `(id, tenant_id)` → SettingsRevision (restrict); has_many AgentRun | Check per kind: `source = 'revision'` iff `revision_id IS NOT NULL`; `:code_default` only for brief, guide, limits; `:absent` only for offering and booking link. Each referenced revision's `kind` matches its slot (verified by the building change, which reads the revisions itself; no caller supplies ids). Trigger rejects UPDATE, DELETE, TRUNCATE. | Created only inside `AgentRun :create` through a context marker (`SettingsSnapshotContext`, the `GrantContext` pattern); a direct create is forbidden for every actor. Appends `settings.snapshot.created` (snapshot id, revision ids, versions, `snapshot_sha256`, correlation id). Reads: admin, reviewer, auditor (AuditedView), `agent_runtime`, `auditor_cli`, kernel. | none |
| EffectiveLimits | New (embedded) | Limits a run actually gets | the twelve fields of section 3.3; `clamped : {:array, atom}` (fields lowered to a bound at snapshot time) | embedded in RunSettingsSnapshot | Each field = min(revision or built-in value, bound at snapshot time). At every check: min(field, current bound, independent budgets). | via snapshot | none |
| AgentRun | Existing (delta) | Agent run with per-run budget | add `settings_snapshot_id : uuid, nullable` (null only for runs created before C4) | belongs_to RunSettingsSnapshot (optional, restrict), many runs to one snapshot (a run and its retries) | Set only by `:create` (a change builds the snapshot; no input accepts an id) and `:retry` (copied from the original run). Immutable once set (no action accepts it; a trigger rejects a change of a non-null value). `:create` refuses `{:settings_incomplete, kinds}` when the run's `usage_origin` requires a kind that is `:absent` (business origins require `offering_profile`; `:reply` and `:proof` require none). Budget: `max_model_calls`, `max_tool_calls`, `max_tokens` = min(caller argument when given, snapshot `run_*` effective value). `:retry` of a run with null snapshot is refused (`no_settings_snapshot`); re-assigning makes a new run. | Unchanged (AGT, SCH create; ADM retry inside `SDR.retry_run/2`) | OQ-4 |
| Accounts.User | Existing | Human operators | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (referenced as `created_by` only; roles and role-change rules unchanged) | — | — |
| Tenant | Existing | Singleton tenant | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found | — | — |
| Sales.Campaign | Existing | Sender identity and compliance defaults | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (sender identity stays on the campaign; campaign-scoped settings are B8) | — | — |
| Actor | Existing | System actor types | — | — | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found (no new system actor; `agent_runtime` gains read only) | — | — |

### 3.3 Operational limits and their fixed bounds

Defaults are the built-in limits revision. Bounds are proposals for the
owner (OQ-2); the run bounds equal today's code values, so C4 never
loosens anything.

| Field | Default | Fixed bound | Where the bound is enforced today or by whom |
|---|---|---|---|
| `run_max_model_calls` | 20 | 1..20 | ADR-0004 per-run cap; `SDR.assign_lead/2` clamp (`lib/sdr_agent/sdr.ex`), `AgentRun :reserve_model_call` refuses at `budget.max_model_calls` (`lib/sdr_agent/agents/agent_run.ex`, `Agents.Changes.BudgetCounter`) |
| `run_max_tool_calls` | 60 | 1..60 | `AgentRun :record_tool_call`; today 60 is a default with no bound |
| `run_max_tokens` | 100,000 | 1..100,000 | `AgentRun.Budget.max_tokens` (`lib/sdr_agent/agents/budget.ex`) |
| `research_max_search_requests` | 4 | 0..8 | C5-02 adapters, before each request, retries and pagination counted |
| `research_max_page_fetches` | 4 | 0..8 | C5-03 safe fetch |
| `research_max_sources` | 6 | 1..10 | B1-04 evidence bundle |
| `research_max_source_chars` | 4,000 | 500..8,000 | B1-04 |
| `research_max_total_source_chars` | 24,000 | 500..48,000 | B1-04 |
| `research_max_output_tokens` | 2,500 | 256..4,000 | B1-04 model request |
| `research_max_model_calls` | 2 | 1..2 (at most one repair, never more sources) | B1-04 |
| `research_target_seconds` | 180 | 30..600 (warning only, D-061) | B1-04 progress, H1 row |
| `research_job_limit_seconds` | 600 | 60..900 (finite job limit, D-061) | B1-04 worker |

Until a consumer enforces a research field, the page shows it as "not yet
enforced" (C4-R11). Per-call and per-fetch timeouts stay fixed in code
(`SdrAgent.AI.ModelProvider.ClaudeCLI` default 120 s) and are not
settings. Reply runs keep their code budget (2 model calls, 5 tool calls,
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
- Refused when `SdrAgent.Operations.Redactor.redact/1` would change it
  (PEM blocks, bearer credentials, JWTs, API-key shapes, secret key/value
  pairs, long hex or base64 runs). The error names the field, never the
  matched text.
- Size caps: offering profile 16 KiB canonical (field caps in 3.2),
  writing guide 6,000 characters, brief guidance 12,000 characters, booking
  link 2,048 bytes, note 200 characters.
- Consumers place settings text in a labeled data section beneath the
  Fixed rules. A guide or brief that tells the model to skip citations or
  invent facts changes nothing the deterministic validators check.
- Never logged, never in Failure messages or span attributes (the existing
  real-data stance turns content capture off; settings get no exception).
- Tests, fixtures and public docs use synthetic settings only.

### 3.6 Changed backend action contracts

- **`Agents.create_settings_revision/2`** (new). Inputs: kind, content,
  `expected_number`, note; actor a human admin. Returns the revision or a
  typed error: `:forbidden`, `{:stale_revision, current_number}`,
  `{:invalid, field_errors}`. Writes one revision and one audit event, or
  nothing.
- **`Agents.current_settings/1`** (new, for the settings page only). The
  current revision or built-in default per kind with effective limits.
  Never called by agent code (xref test).
- **`Agents.run_settings/2`** (new). The resolved settings of a run's
  snapshot: revision content, or built-in default content by version with
  its hash re-checked (a mismatch or a missing version fails closed with
  `:settings_default_unavailable`). `{:error, :no_settings_snapshot}` for a
  run without one.
- **`AgentRun :create`** (changed). Builds the snapshot itself (section 4),
  refuses `{:settings_incomplete, kinds}`, derives budget limits from the
  snapshot, and records `settings_snapshot_id` in `agents.run.created`.
- **`AgentRun :retry`** (changed). `RetryOf` copies `settings_snapshot_id`;
  refuses `no_settings_snapshot` when the original has none.
- **`SDR.assign_lead/2`** (changed). Pre-checks required kinds before any
  write (returns `{:error, {:settings_incomplete, kinds}}` with nothing
  written); budget from the snapshot; the `max_model_calls`/`max_tool_calls`
  options may only lower.
- **`SDR.ReplyIntake.received/3`** (changed). Its run gets a snapshot;
  settings never refuse it.

### 3.7 Synthetic example

An admin saves offering revision 1 (`name` "Example Widgets Scheduler",
items `calendar_sync` feature, `fewer_no_shows` outcome, `no_payroll`
limit) and booking link revision 1 (`https://book.example.test/demo/intro`).
The brief, guide and limits stay on built-in defaults. A lead at
`acme.example` is assigned. The snapshot:

```json
{
  "offering_profile": {"source": "revision", "revision": 1},
  "booking_link": {"source": "revision", "revision": 1},
  "writing_guide": {"source": "code_default", "version": "1"},
  "research_brief": {"source": "code_default", "version": "2"},
  "operational_limits": {"source": "code_default", "version": "1"},
  "effective_limits": {"run_max_model_calls": 20, "research_max_sources": 6, "clamped": []},
  "safeguards_version": "1"
}
```

The admin then saves writing guide revision 1 while the run is queued. The
queued run still drafts with built-in guide version 1; the next assignment
uses guide revision 1. A retry of the first run uses its original snapshot.
A save of the offering against `expected_number` 0 after revision 1 exists
is refused `{:stale_revision, 1}`.

## 4. Locks and transactions

Existing order: domain row locks first, then the audit chain head
(`SdrAgent.Audit.Kernel.lock_head/1`), which every audited write takes at
its first event append and holds to commit (ADR-0009 §6).

**Revision write** (`:create_revision`, one transaction):

1. Read the current revision of the kind and lock it `FOR NO KEY UPDATE`
   (not `FOR UPDATE`, so a snapshot's FK check, which takes `FOR KEY
   SHARE`, never waits on an editor).
2. Re-read under the lock: refuse stale if its number ≠ `expected_number`
   or it now has a successor. With no current revision, `expected_number`
   must be 0.
3. Insert revision `number + 1` with `supersedes_id`, then append the
   event (chain head).

Two concurrent editors serialize on step 1; the second is refused stale.
Two concurrent first saves have no row to lock; the partial unique index
on `(tenant_id, kind) WHERE supersedes_id IS NULL` makes the second wait
for the first and then fail, mapped to `{:stale_revision, 1}`. The unique
index on `supersedes_id` backstops step 2. Editors lock one revision row
and then the chain head, never a run, lead or snapshot.

**Snapshot at run creation** (inside the creating transaction): the
building change first takes the chain head explicitly (`Kernel.lock_head`,
as `Admission` does), then reads the current revision of each kind, then
inserts the snapshot and the run. Every revision insert commits while
holding the chain head, so a read made after taking the head sees exactly
the revisions whose events precede this run's in the chain, and no
revision can commit until this transaction ends. The snapshot therefore
matches the audit order with no extra row locks. Plain reads do not block
on an editor; the FK checks take `FOR KEY SHARE`, compatible with an
editor's `FOR NO KEY UPDATE`. No cycle is possible: editors never take a
lock that run creators hold before the head.

- `SDR.assign_lead/2`: Lead `FOR UPDATE` → advisory required-kinds
  pre-check (plain read; kinds never disappear, so a pass cannot turn into
  a fail) → existing writes (chain head) → `AgentRun :create` builds the
  snapshot under the already-held head.
- Reply intake: runs inside the reply's transaction, which may already
  hold the head; the change takes it again (reentrant) and reads. No new
  lock is taken before the head, so the Outreach lock order is unchanged.
- `:retry`: copies the original's snapshot id; no settings read.

Isolation: the default `READ COMMITTED`; each head read is its own
statement after the head lock. Clock: `inserted_at` from `SdrAgent.Clock`.

## 5. Test plan (RED first, synthetic only)

Each test is written first and must fail for the missing behavior, not for
setup or compilation. Per-test setup only; nothing seeded in
`test_helper.exs`. No model calls (Fake provider), no dev database.

Revisions and policy:
1. Admin saves revision 1 of each kind; numbers, `supersedes_id` and
   `content_sha256` correct; one `settings.revision.created` per save.
2. Reviewer, auditor, disabled admin, demoted admin (stale struct) and each
   system actor (`agent_runtime`, `scheduler`, `seeder`, kernel) are
   refused; nothing written; guarded denial audited.
3. Stale `expected_number` refused with the current number; first save
   with `expected_number` 1 refused.
4. Concurrent saves (two tasks, shared sandbox): exactly one succeeds, the
   other is stale; concurrent first saves likewise.
5. UPDATE, DELETE and TRUNCATE on revisions and snapshots raise (trigger).
6. Check constraints: wrong embedded attribute for the kind, `number`/
   `supersedes_id` mismatch, cross-kind or cross-tenant `supersedes_id`.

Validation (one success and the boundary failures per field):
7. Each limit at its bound passes, bound + 1 is refused naming the bound;
   cross-field rules refused.
8. Booking link: `http`, `javascript:`, user info, IP literal, `localhost`,
   port 8443, over 2,048 bytes, non-reserved host while the guard is on,
   token-shaped query — each refused; a reserved `https` link passes.
9. Text: control character, secret-shaped string (error does not echo it),
   over-size, duplicate offering item id, bad item id — refused.

Snapshot and runs:
10. `assign_lead/2` with no offering returns `{:settings_incomplete,
    [:offering_profile]}` and writes no lead change, run, job, Operation or
    event.
11. Assignment binds a snapshot; `run_settings/2` returns built-in
    defaults by version with hashes for unsaved kinds and revision content
    for saved ones.
12. Save after assignment: the queued run's `run_settings/2` is unchanged;
    a new assignment sees the new revision.
13. Retry shares the original snapshot id; retry of a null-snapshot run is
    refused.
14. Reply intake with no settings at all creates its run and snapshot;
    unsubscribe classification still proceeds.
15. Budget: run limits equal snapshot effective values; a caller option can
    lower but not raise; a bound lowered in code after snapshot (test
    override) lowers the effective limit at check time.
16. Snapshot order: a save committed while an assignment holds the head is
    not in that run's snapshot and appears after it in the chain; no
    deadlock under repeated interleaving (bounded loop).
17. A built-in default whose hash no longer matches, or a removed version,
    makes `run_settings/2` fail closed.
18. Golden-hash test for every released built-in default version.
19. Xref test: no module outside `SdrAgent.Agents` reads current revisions;
    agent actions use `run_settings/2` only.
20. `settings_snapshot_id` cannot be supplied to `:create` or changed by
    any update (action and trigger).

UI (LiveView):
21. Admin sees the form, review step and confirmation; save calls the
    domain with the revision seen; stale shows a reload prompt; refusals
    shown next to fields; a forged confirm event without a review step does
    nothing (the C9-05 `GrantForm` pattern).
22. Reviewer sees read-only settings; auditor view records an AuditAccess
    and fails closed; non-operators redirected.
23. The page shows bounds, sources, "not yet enforced" labels and the
    safeguard list; the run page shows the snapshot.

Gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix credo`, `mix sobelow`, full `mix test`, `mix precommit`; Ash codegen
check clean.

## 6. Affected modules and slices

New: `lib/sdr_agent/agents/settings_revision.ex`,
`lib/sdr_agent/agents/run_settings_snapshot.ex`, embedded types under
`lib/sdr_agent/agents/run_settings/` (offering profile and item, booking
link, writing guide, research brief, operational limits, effective
limits), `run_settings/code_defaults.ex`, `run_settings/safeguards.ex`,
`agents/changes/build_settings_snapshot.ex`,
`agents/checks/settings_snapshot_context.ex`, validations for URL and
text; migration with triggers, checks and indexes;
`lib/sdr_agent_web/live/settings_live.ex` (route `/settings` in the
operator live session) and a staged form module.

Changed: `lib/sdr_agent/agents.ex` (resources, code interfaces),
`lib/sdr_agent/agents/agent_run.ex` (`settings_snapshot_id`, `:create`),
`lib/sdr_agent/agents/changes/retry_of.ex`, `lib/sdr_agent/sdr.ex`
(`assign_lead/2`), `lib/sdr_agent/sdr/reply_intake.ex`,
`lib/sdr_agent_web/live/run_live.ex`, `lib/sdr_agent_web/router.ex`,
`lib/sdr_agent_web/live/admin_live.ex` (link to settings),
`docs/architecture/domain-boundaries.*` (regenerated for the new
resources).

Slices, each a reviewed PR with exact-head CI:
- **C4-01a** resources, migration, policies, snapshot on create/retry/
  reply, domain API, tests 1-20.
- **C4-01b** settings page, read-only view, run page summary, tests 21-23.
- Consumer fence: B1-04 and B1-05 start building only after C4-01a
  merges; their prompts read `run_settings/2`.

## 7. Architecture decisions

No ADR: new resources inside the accepted Agents domain (C9 precedent),
no new dependency, technology or boundary; ADR-0009 conventions followed
(append-only trigger, supersedes chain, tenant column, layering). The
domain-boundaries diagram is regenerated in C4-01a. If the reviewer
prefers a separate `Settings` domain, that is an ADR-0009 §7 amendment for
the owner.

## 8. Risks

- Built-in default drift before the owner saves (mitigated: recorded per
  run, labeled on the page; OQ-1).
- Item-id reuse with a new meaning in a later offering revision cannot be
  prevented mechanically; citations bind the revision id.
- The redactor rule can refuse legitimate long tokens in text (for example
  a long URL in the guide); the error says which field to change.
- Research bounds are proposals until the owner confirms (OQ-2); C4 can
  merge with the proposals because each is at or below a value consumers
  have not yet built against.

## 9. Owner questions

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
- **OQ-3 No booking link.** When no booking link is saved, should a
  first-touch email use your "questions first" ask (recommended; D-053
  allows either), or should drafting stop until one is saved? B5's
  interested reply never drafts without one.
- **OQ-4 Retry.** A re-run of a failed run uses the settings it started
  with (recommended, so a re-run is the same job); a fresh assignment uses
  the current settings. Accept, or should re-runs pick up current settings?
- **OQ-5 Publication.** The built-in writing guide is derived from your
  own words (D-053) and would sit in the public repository as code. Is
  that allowed, or should the built-in guide be a neutral synthetic text
  and your version entered only in the app?
- **OQ-6 Reviewer access.** Reviewers can read settings, read-only
  (recommended, since they judge drafts against the guide and offering).
  Accept?

## 10. Gate record (to fill)

- Configured capabilities (`.workflow/recipe.json`): `ai_pair=true`,
  `codex_review=true`. Reviewer: Codex via ai-pair (correlated `ap
  consult`).
- Entity-model verdict: **UNREVIEWED** (pending Codex). This blocks
  implementation.
- Owner acceptance of scope and answers to OQ-1..OQ-6: pending.
- Not authorized by this packet: code, migrations, UI, real data, model
  calls.
