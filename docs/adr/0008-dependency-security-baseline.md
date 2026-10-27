---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0008: Dependency Security Baseline and Blocking Audit

## Status

Accepted (2026-10-06) on Codex's approving verdict on the S0b pull request:
https://github.com/chops/sdr_agent/pull/2#issuecomment-6026997407
(ADR-0001: agent design ADRs are accepted on peer approval; the owner can veto).
Proposed earlier the same day by Claude in slice S0b. It amends ADR-0007 decision
step 3 (the audit step stops being advisory); the rest of ADR-0007 stands.

## Context

ADR-0001 forbids changing a dependency pin without a reviewed ADR. ADR-0007
recorded that the factory pins carry published advisories and left
`mix hex.audit` as an advisory CI step (`continue-on-error: true`), following
the doctrine "Dependency audits remain advisory until promoted". Slice S5
builds password authentication on `ash_authentication`, so the
CRITICAL/HIGH advisories against it must be fixed first.

Facts on 2026-10-06 (Hex 2.5.1 `mix deps.get` / `mix hex.audit`, which read
the EEF advisory database; affected ranges confirmed against
`https://api.osv.dev/v1/vulns/<id>`):

- `ash_authentication` 4.14.2: 5 CRITICAL, 5 HIGH, 2 MEDIUM, 3 LOW.
- `ash_authentication_phoenix` 2.17.3: 1 CRITICAL, 1 HIGH (both shared with
  `ash_authentication`).
- `ash` 3.32.3: 1 HIGH, 3 MEDIUM.
- `igniter` 0.8.3 and `usage_rules` 1.2.7: 1 LOW each.
- Every advisory has a fixed **stable** release; the 5.0.0-rc / 3.0.0-rc
  lines also carry fixes but are not needed.
- `mix hex.audit` exits non-zero on any non-ignored advisory or retirement,
  whatever its severity. Accepted findings can be listed in the project's
  `hex: [ignore_advisories: [...], ignore_retirements: [...]]` config.
- `bin/verify-workflow` does not pin `mix.lock` or the `deps` list of
  `mix.exs`. Its only `mix.exs` unit is the `usage_rules` project config. The
  receipt's `generators` records (which name igniter 0.8.3 and usage_rules
  1.2.7 as the scaffolding tools) are provenance and are not compared with the
  lock, so the bumps below need no receipt change.

## Options Considered

### Target versions: minimal stable fix vs. latest stable vs. RC

The smallest stable release outside every affected range keeps the change
reviewable and limits unrelated behaviour changes. Latest stable differs only
for `ash` (3.34.4 vs. 3.34.3, no advisory difference). The RC lines
(`ash_authentication` 5.0.0-rc, `ash_authentication_phoenix` 3.0.0-rc) are
major-version pre-releases and are not needed for any fix.

### Fixing LOW findings in dev-only tooling

`igniter` and `usage_rules` are dev/test-only and the LOW findings need a
malicious package's metadata. Both fixes are patch releases with no lock
churn, and fixing them leaves the audit with nothing to accept, so a blocking
audit starts from a clean baseline instead of an ignore list.

### Blocking policy: severity filter vs. fail closed with a reviewed ignore list

A severity filter would parse `mix hex.audit` text output and fail only on
CRITICAL/HIGH. Parsing human-readable output fails open if the format
changes. Running `mix hex.audit` as a blocking step fails on any new finding;
a reviewed LOW/MEDIUM acceptance goes into `hex: [ignore_advisories: ...]`
with an ADR, which `hex.audit` honours by ID or alias. This blocks a little
more than CRITICAL/HIGH (an unreviewed LOW also blocks) but cannot fail open.

## Decision

### Pin changes (all Hex, source unchanged)

| Package                      | Old (factory) | New    | Scope    |
|------------------------------|---------------|--------|----------|
| `ash`                        | 3.32.3        | 3.34.3 | runtime  |
| `ash_authentication`         | 4.14.2        | 4.15.0 | runtime  |
| `ash_authentication_phoenix` | 2.17.3        | 2.17.4 | runtime  |
| `igniter`                    | 0.8.3         | 0.8.4  | dev/test |
| `usage_rules`                | 1.2.7         | 1.2.8  | dev      |

No transitive lock entry changes. `mix deps.update ash_authentication
ash_authentication_phoenix` also floated `ash_sql` 0.7.1 to 0.8.1, which
nothing requires (`ash_sql` 0.7.1 accepts `ash ~> 3.32`); that was reverted
and `ash_sql` stays at 0.7.1.

### Code change required by the upgrade

`ash` 3.33.0 makes `config :ash, default_string_length_count:` mandatory (the
fix for EEF-CVE-2026-82752). `config/config.exs` sets `:codepoints`, the value
the Ash installer now writes. `:mixed` would keep the vulnerable grapheme
counting. `mix igniter.apply_upgrades` for the `ash_authentication` and
`ash_authentication_phoenix` ranges proposes no changes (dry run). `ash` has
no upgrade task. The project has no OAuth2, magic-link, API-key or audit-log
strategy yet, so the 4.15.0 breaking change (OAuth2/OIDC needs an
`identity_resource`) does not apply now. It is a constraint for any later
OAuth2 work.

### Advisories resolved

| Advisory (EEF-CVE-2026-) | Severity | Package(s)                          | Fixed in      |
|--------------------------|----------|-------------------------------------|---------------|
| 86533                    | CRITICAL | ash_authentication, …_phoenix       | 4.15.0, 2.17.4 |
| 88952                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 76949                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 82761                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 85500                    | CRITICAL | ash_authentication                  | 4.15.0        |
| 86688                    | HIGH     | ash_authentication                  | 4.15.0        |
| 80218                    | HIGH     | ash_authentication                  | 4.15.0        |
| 81632                    | HIGH     | ash_authentication, …_phoenix       | 4.15.0, 2.17.4 |
| 82685                    | HIGH     | ash_authentication                  | 4.15.0        |
| 82760                    | HIGH     | ash_authentication                  | 4.15.0        |
| 94201                    | HIGH     | ash                                 | 3.34.3        |
| 78223                    | MEDIUM   | ash_authentication                  | 4.15.0        |
| 86522                    | MEDIUM   | ash_authentication                  | 4.15.0        |
| 86338                    | MEDIUM   | ash                                 | 3.33.4        |
| 82752                    | MEDIUM   | ash                                 | 3.33.0        |
| 93477                    | MEDIUM   | ash                                 | 3.33.11       |
| 81637                    | LOW      | ash_authentication                  | 4.15.0        |
| 82723                    | LOW      | ash_authentication                  | 4.15.0        |
| 82759                    | LOW      | ash_authentication                  | 4.15.0        |
| 82584                    | LOW      | igniter                             | 0.8.4         |
| 82710                    | LOW      | usage_rules                         | 1.2.8         |

Residual LOW/MEDIUM: none. `mix hex.audit` reports "No retired or security
advisory packages found", and OSV `v1/query` returns no vulnerabilities for
any of the five new versions.

### Policy

1. CI step "Dependency audit" runs `mix hex.audit` online after `mix deps.get`
   and is **blocking** (no `continue-on-error`). This promotes the dependency
   audit under the static-analysis doctrine.
2. CRITICAL and HIGH advisories are never ignored. They are fixed by a
   reviewed pin change (an ADR naming the advisory). If the only fix is a
   pre-release, the run stops and the owner decides (ADR-0001 stop condition:
   a security check fails).
3. A LOW or MEDIUM advisory with no acceptable fix may be accepted only by
   adding its ID to `hex: [ignore_advisories: [...]]` in `mix.exs`. The same
   change must carry an ADR (or an amendment to this one) with the reason it
   does not affect this project and a revisit trigger. Retirements follow the
   same rule via `ignore_retirements`.
4. Because the audit reads live advisory data, a newly published advisory
   can turn CI red on an unrelated change. That is intended: the next slice
   fixes or accepts it before merging.

## Justification

The minimal stable versions remove every CRITICAL/HIGH finding without a
pre-release or a transitive bump. Fixing the LOW findings too costs two patch
releases and gives the blocking audit a clean baseline. Fail-closed
`hex.audit` with an ADR-reviewed ignore list enforces "CRITICAL/HIGH block
CI" with no text parsing that could fail open.

## Consequences

### Positive

- S5 builds password authentication on a release with no known advisories.
- New advisories against any locked package, direct or transitive, block
  merges until someone reviews them.

### Negative

- CI depends on live Hex advisory data. A new advisory or a Hex outage can
  block an unrelated PR.
- An unreviewed LOW/MEDIUM finding blocks too, which is stricter than a
  CRITICAL/HIGH-only filter.
- "Never ignore CRITICAL/HIGH" is enforced by review, not automation: the
  ignore list holds IDs, not severities.

### Neutral

- The dependency-generated skills and the usage-rules section of `AGENTS.md`
  were produced from the old package versions. They are refreshed only when
  `mix usage_rules.sync` next runs, which is not part of this change.
- The factory receipt still records igniter 0.8.3 / usage_rules 1.2.7 as the
  generator versions. That is history and stays unchanged.

## Amendment (2026-10-10): EEF-CVE-2026-101028

**Status: accepted** by the owner in the private Claude session chat on
2026-10-10 ("accept the amendment."), after Codex's independent approval of
369ea97 (reply 12cf8940; exact-head CI 38075894593 green).

### Advisory

- **EEF-CVE-2026-101028** (MEDIUM), aka CVE-2026-101028, GHSA-xj24-8f5c-pp5p.
- `Ash.count/2`, `Ash.exists/2` and `Ash.aggregate/3` applied only the root
  resource's read policy. Filters and sorts that cross a relationship (for
  example `comments.body`, or an aggregate over one) skipped the related
  resource's read policy, so a caller who controls such a filter could infer
  hidden related rows.
- Affected: `ash` 2.6.0 to 3.34.5. Fixed in **3.34.6** (2026-10-09).
- Found by the blocking `mix hex.audit` step on CI run 38074932795 (PR #37),
  as rule 4 of the policy above intends.

### Exposure in this project

Every call to an affected function in `lib/` filters only on attributes of
the root resource, with values fixed in server code. None crosses a
relationship, none sorts, none takes caller-supplied filter input
(`filter_input`/`sort_input`), and no resource defines aggregates:

| Call site | Function | Filter |
|---|---|---|
| `lib/sdr_agent/agents.ex:265` | `Ash.count!` | `tenant_id`, `reserved_at` on ModelInvocation |
| `lib/sdr_agent/sales/changes/require_steps.ex:19` | `Ash.count!(authorize?: false)` | `sequence_id` (attribute) on SequenceStep |
| `lib/sdr_agent/sdr/followup_worker.ex:80` | `Ash.exists?` | `idempotency_key`, `tenant_id` on Decision |
| `lib/sdr_agent/audit/anchoring.ex:181` | `Ash.exists?` | `anchor_id` (attribute), `sink`, `status` on AnchorSinkReceipt |
| `lib/sdr_agent/accounts/changes/first_user_only.ex:53` | `Ash.count!` | `tenant_id` on the user resource |
| `lib/sdr_agent/outreach/webhooks.ex:451` | `Ash.exists?(authorize?: false)` | `tenant_id`, `message_id` on Reply |

So the vulnerable path is not reachable today. We bump anyway rather than
ignore the advisory: a fix exists, the change is a patch release, and future
slices (for example counts on the home screen) could add relationship
filters.

### Decision

Pin `ash` to `== 3.34.6`. The lock changes only the `ash` entry; no other
package moves (`mix deps.update ash` also offered `decimal` 3.1.1 to 3.1.2,
which is not required and was reverted). No `ignore_advisories` entry.

Changes between 3.34.3 and 3.34.6, from the upstream changelog: the security
fix; operator type-casting and embedded-resource equality fixes; notification
return shapes normalized; a field-policy related-filter fix; temporal
(`as_of`) write fixes; an opt-out for `run` compile-time dependencies. None
changes a behaviour this project relies on; the full gate below is the check.

## Amendment (2026-10-12): EEF-CVE-2026-97853

**Status: accepted** by the owner in the private Claude session chat on
2026-10-12 ("accept PR #40"), after Codex's independent approval of
233a91e (reply 01a12e51; exact-head CI 38202840312 green).

### Advisory

- **EEF-CVE-2026-97853** (MEDIUM), aka CVE-2026-97853, GHSA-6c27-994x-c52f.
- `Decimal.round/2,3` builds the result for the requested number of decimal
  places before applying context precision, so a large caller-supplied
  `places` value allocates memory in proportion to it (denial of service).
- Affected: `decimal` 0.1.0 to 3.1.1. Fixed in **3.1.2**.
- Found by the blocking `mix hex.audit` step on CI run 38202020126 (PR #39),
  as rule 4 of the policy above intends.

### Exposure in this project

`decimal` is a transitive dependency (through Ash and Postgrex). Nothing in
`lib/` calls `Decimal.round`; the app's only `round` calls are
`Kernel.round/1` and `Float.round/2` on percentages. The only dependency
call site is Ash's `round/2` query expression
(`ash/lib/ash/query/function/round.ex`), which no resource or query in this
project uses. So the vulnerable path is not reachable today. We bump anyway
rather than ignore the advisory: a fix exists and it is a patch release.

### Decision

Lock `decimal` at **3.1.2**. Only the `decimal` entry in `mix.lock`
changes; `mix.exs` is unchanged (`mix deps.update decimal` alone offered the
3.2.0 minor release, which is not required, so the patch release was
selected). No `ignore_advisories` entry.

## Amendment (2026-10-15): EEF-CVE-2026-105659

**Status: accepted** by the owner in the private Claude session chat on
2026-10-15 at about 10:58 MDT ("yes, accept the amendment and merge #161 once
its CI is green"), after Codex's independent approval of the text at 09e46c5
(d03a81e8) and of the code at 1fbea26 (10ea669c, complete upstream delta
reviewed, live LiveView probe passed). The owner chose option B earlier the
same day ("(B)", D-130; D-132 records this acceptance).

### Advisory

- **EEF-CVE-2026-105659** (HIGH), aka CVE-2026-105659, GHSA-69m6-wcv4-rwcf
  (OSV, published 2026-10-14 16:54 UTC).
- HTTP/2 sends blocked on either the connection or the stream send window
  restart their existing deadline whenever the peer permits partial
  progress. Tiny `WINDOW_UPDATE` trickles (and empty `SETTINGS` on the
  connection path) can therefore retain blocked stream processes and their
  resources indefinitely: unauthenticated resource exhaustion. The two paths
  are independent: on the connection, requeueing a pending send refreshes
  its expiry on connection `WINDOW_UPDATE` and on `SETTINGS`, including an
  empty `SETTINGS` that grants nothing; on a stream, recursive stream
  `WINDOW_UPDATE` handling re-arms its read timeout.
- The fix grants deadline credit in proportion to the bytes actually
  drained (1 s per KiB, capped at the base timeout ahead of now). It is not
  an absolute total-send limit: a legitimate send that keeps progressing
  may last longer than the base timeout.
- Affected: `bandit` from 1.4.0, with **no fixed Hex release**: 1.12.5
  (2026-08-20) is still the newest on Hex as of 2026-10-15 09:58 MDT. The fix
  is upstream commit `d88b21953c65061f21136ea76a89a4f95a2ac7a1`, with tests.
  OSV names disabling HTTP/2 as a workaround.
- Found by the blocking `mix hex.audit` step on main run 38632782130 (head
  `3b09183`), as rule 4 of the policy above intends. It blocks every merge.

### Exposure in this project

- Bandit 1.12.5 enables HTTP/2 by default and accepts the cleartext
  prior-knowledge preface, without TLS or ALPN. **Plain HTTP does not remove
  the exposure**, and no project setting disabled HTTP/2.
- Listeners: dev `127.0.0.1:4120`, test `127.0.0.1:4002`, the calibration
  console `127.0.0.1:4124`, the demo smoke server (loopback), and production,
  which binds all IPv6 interfaces (`config/runtime.exs`). The local listeners
  are loopback only. Production reachability depends on the host, firewall
  and proxy, none of which is verified here. Authentication does not help: the
  path is pre-auth.

### Options considered

- **A. Wait for a fixed Hex release.** Keeps the source unchanged, but merges
  stay blocked with no known date.
- **B. A temporary Git pin to the fixed commit, with HTTP/2 disabled
  (chosen).** Removes the vulnerable code now and the protocol that reaches
  it, at the cost of unreleased upstream code.
- **C. Ignore the HIGH.** Not allowed by rule 2 of the policy; not proposed.
- **HTTP/2 off alone** removes today's reachable path but leaves the
  vulnerable library, so it does not clear the policy gate by itself.

### Decision

1. **Source.** `{:bandit, github: "mtrudel/bandit", ref:
   "d88b21953c65061f21136ea76a89a4f95a2ac7a1", override: true}` in `mix.exs`.
   The full SHA, never a branch or tag. `override: true` is required because
   Phoenix, `websock_adapter` and `swoosh` declare Hex dependencies on
   `bandit` (`opentelemetry_bandit` 0.3.0 lists Bandit only among its own
   dev/test dependencies, so it adds no constraint here, though its
   instrumentation is still tested). Mix's `override: true` overrides every
   other dependency of the same name; it is not limited to the source, so
   the competing version requirements are reviewed explicitly against the
   pinned `mix.exs`, and the reviewed lock records the commit. Only the `bandit` entry and any
   transitive entries its `mix.exs` requires may change in `mix.lock`; any
   other movement is reverted or reviewed.
2. **HTTP/2 off on every Bandit listener.** `Bandit.PhoenixAdapter`
   passes only each scheme's list to Bandit, so the option goes **inside**
   each scheme, never as a top-level Endpoint key (which Bandit never sees):

   ```elixir
   http: [http_2_options: [enabled: false], ...]
   # and inside https: [...] wherever an HTTPS listener is configured
   ```

   It is set in the endpoint's base `http:` configuration and reapplied
   wherever a scheme list is rebuilt: the calibration console plan and the
   demo smoke server. A test asserts the effective scheme options the
   adapter receives on every listener configuration (not the presence of a
   key), and a live test sends the HTTP/2 prior-knowledge preface to an
   ordinary test listener and observes that it is not served as HTTP/2.
   This adds no HTTPS listener and changes no production binding. This
   stays after the pin is replaced, until a separate decision turns HTTP/2
   back on.
3. **Review of the whole upstream delta.** `1.12.5...d88b219` is 30 commits
   and 37 paths, including HTTP/1, HTTP/2, WebSocket and compression changes,
   not only the fix. The review covers the complete delta, the lock change,
   and compatibility with Phoenix, LiveView's WebSocket and telemetry
   (`opentelemetry_bandit`).
4. **Regression evidence for the fix itself.** Tests run only with HTTP/2
   off would prove the mitigation, not the pinned fix. So this
   repository's suite starts a separate, hermetic, ephemeral loopback
   Bandit listener **with HTTP/2 enabled**, used only by these tests, and
   covers: tiny connection `WINDOW_UPDATE` trickles and empty `SETTINGS`;
   a stream-window trickle with an ample connection window; and a
   legitimate client that keeps draining past the base timeout and
   completes. No flag enables HTTP/2 on an ordinary or deployed listener.
5. **The audit is not the proof.** A Git dependency is outside `mix
   hex.audit`'s Hex-package scan, so a green audit is necessary but does
   not show the advisory is fixed (OSV still publishes a Git
   introduced/fixed range for it). The fixed commit and the regression
   evidence above are the record. A green audit does not clear any other
   HIGH finding a live audit may report.
6. **Revisit.** When a stable Hex release contains the fix, a reviewed change
   replaces the pin with that release (a Hex source again, `override`
   removed). "No fixed Hex release" is a time-stamped observation: Hex is
   rechecked when implementing and again before merge. Owner of the
   revisit: Claude, checking Hex at each daily standup. Any lock movement
   beyond `bandit` and what its pinned `mix.exs` requires is reviewed
   separately. No `ignore_advisories` entry.

### Consequences

- Merges can resume once this is reviewed, accepted and merged.
- The project runs an unreleased Bandit commit until the Hex release; the
  delta review and the full gate are the mitigation.
- HTTP/2 is unavailable on all listeners. Nothing in this project needs it:
  the browser UI and LiveView use HTTP/1.1 and WebSocket.

## Amendment (2026-10-25, proposed): EEF-CVE-2026-114214, EEF-CVE-2026-115627, EEF-CVE-2026-115635

**Status: proposed** by Claude on 2026-10-25 (evening), under Codex's bounded preparation ruling
(reply 01a175b0-3e73-7551-930e-a41b2c4aa111) and corrected on Codex's static review of the delta
(reply 01a175c9-ea09-711e-842d-a53415500f5b: the pin and lock delta passed; this text was revised).
The owner's acceptance of this exact text is a separate answer; no pin below is accepted until then.

### Advisories

Three MEDIUM advisories (CVSS 4.0 score 6.0 each; CWE-863, incorrect authorization), published on
2026-10-25 and found by the blocking `mix hex.audit` step on CI runs 40250083053 (PR #231) and
40251110877 (PR #232), as rule 4 of the policy above intends:

- **EEF-CVE-2026-115635** (CVE-2026-115635, GHSA-36hg-wwp2-fg8w; published 19:48:43Z).
  `ash_postgres` 2.6.22 to 2.15.1. A skipped upsert (`return_skipped_upsert?: true` with a failing
  `upsert_condition`) looked up the existing row by identity without applying attribute
  multitenancy, so a resource using `multitenancy strategy :attribute` could return another
  tenant's row with the same identity values. Fixed in **2.15.2**.
- **EEF-CVE-2026-115627** (CVE-2026-115627, GHSA-gr2r-f49c-9gm2; published 19:49:50Z).
  `ash_postgres` 0.38.0 to 2.15.1. A `many_to_many` or `through` relationship loaded through a
  lateral join (a limit, offset or sort) built the join resource's query without its read action,
  where attribute multitenancy is applied, so other tenants' join rows were joined. Fixed in
  **2.15.2**.
- **EEF-CVE-2026-114214** (CVE-2026-114214, GHSA-g2h4-xp57-q863; published 19:47:30Z).
  `ash` 3.24.0 to 3.37.0. A `has_many` or unsorted `has_one` relationship declared with `through:`,
  loaded for one record with a limit of 1, dropped the filter tying destination records to the
  source, so a caller paging such a field could enumerate unrelated destination records. Fixed in
  **3.37.1**.

### Exposure in this project (a source survey, not a runtime or expanded-DSL exposure proof)

Read-only survey of `lib/` at `531259a7`:

- The scanned source has no literal `multitenancy`, `many_to_many` or `through:` declaration:
  tenancy is a `tenant_id` attribute carried in identities and filters, not Ash's multitenancy
  feature. The surveyed declarations therefore do not show the advisory-specific preconditions
  (attribute multitenancy for the two `ash_postgres` findings; a `through:` relationship for the
  `ash` finding).
- Skipped upserts are used deliberately. All twelve `return_skipped_upsert? true` DSL declarations
  in `lib/` use `upsert_condition expr(false)`. A separate `Ash.create` caller,
  `ServerStarts.open_counter`, supplies `return_skipped_upsert?: true` to `ModelServerCounter.open`,
  which declares `upsert? true`, identity `:tenant` and `upsert_fields []` with no
  `upsert_condition`. Both are inventoried below:

  | Resource.action | declaration (`lib/sdr_agent/…`) | upsert identity |
  |---|---|---|
  | WebhookEvent.receive | `operations/webhook_event.ex:133` | `:unique_valid_event` |
  | ResearchArtifact.record | `research/research_artifact.ex:98` | `:unique_source` = `[:lead_id, :source_url, :content_sha256]` |
  | SendQuotaDay.open | `outreach/send_quota_day.ex:60` | `:unique_day` |
  | DeliveryReceipt.record | `outreach/delivery_receipt.ex:95` | `:unique_kind` = `[:delivery_operation_id, :kind]` |
  | Decision.record | `agents/decision.ex:143` | `:unique_idempotency_key` = `[:tenant_id, :idempotency_key]` |
  | ModelResultRelease.decide | `agents/model_result_release.ex:190` | `:unique_invocation` = `[:model_invocation_id]` |
  | Payload.store | `audit/payload.ex:84` | (no `upsert_identity` declared with it) |
  | ProvenanceSnapshot.record | `audit/provenance_snapshot.ex:67` | `:unique_snapshot` |
  | Suppression.manual | `outreach/suppression.ex:114` | `:unique_value` |
  | Suppression.from_webhook | `outreach/suppression.ex:150` | `:unique_value` |
  | Suppression.from_classification | `outreach/suppression.ex:168` | `:unique_value` |
  | Suppression.seed | `outreach/suppression.ex:186` | `:unique_value` |
  | ServerStarts.open_counter → ModelServerCounter.open | `agents/server_starts.ex:114` (`Ash.create(return_skipped_upsert?: true)`) | `:tenant` = `[:tenant_id]` |

  The identities are the actions' own; no general claim that every such identity carries
  `tenant_id` is made (several do not), and none of these observations is a finding of an
  exploitable cross-tenant path or a request to change application policy. The inventory covers
  every declaration in `lib/`, seed actions included.

So the survey finds no declaration meeting the advisories' preconditions today, without proving
unreachability at runtime. We bump rather than ignore: fixed stable releases exist (policy 3
permits an ignore only when no acceptable fix exists), and future slices (Home, prospect search)
add relationships.

### Decision (proposed)

Pin `ash` to `== 3.37.1` and `ash_postgres` to `== 2.15.2` in `mix.exs` (two lines). `ash_postgres`
2.15.2 requires `ash ~> 3.37 and >= 3.37.1` and `ash_sql ~> 0.8 and >= 0.8.4`, which `ash_sql` 0.7.1
cannot satisfy, so `ash_sql` moves to **0.8.4** as a lock-only transitive change
(`mix deps.unlock ash ash_postgres ash_sql && mix deps.get`). The lock changes exactly those three
entries (3 removed, 3 added; `deps.get` lists `New:` ash 3.37.1, ash_postgres 2.15.2, ash_sql 0.8.4
and 120 packages unchanged); no other package moves; no override, no new direct dependency, no
`ignore_advisories` entry. Lock checksums: ash 3.37.1 `35ea962d…`, ash_postgres 2.15.2 `aa2611e8…`,
ash_sql 0.8.4 `06a75a45…`. `ash_sql` 0.8.4 newly requires `jason`, already locked; `simple_sat`
stays an optional, unlocked requirement of `ash` as before. Bandit (amendment of 2026-10-15), the
Jido/Zoi pins and ADR-0018's residuals are untouched. Requirement checks: `ash_sql` 0.8.4 needs
`ecto >= 3.13.4` (locked 3.14.2); `ash` 3.37.0 needs Elixir >= 1.17 (toolchain 1.20.4); `spark`
2.7.6 and `igniter` 0.8.4 satisfy the new requirements and do not move.

### Upstream delta (changelogs read 2026-10-26 01:00Z; the full notes are in the preparation return)

- `ash` 3.34.6 → 3.37.1 (3.35.0 to 3.37.1, Oct 13 to 25): nothing labelled breaking or deprecated;
  Elixir minimum 1.17; the fix itself (each step of a `through` relationship read the way its
  relationship reads, `through` relationships always lateral-joined, the smaller of a relationship's
  and its query's limit applied); tenant set on all action results and on upgraded changesets; an
  `upsert_condition` passed as an `Ash.create` option now applied; keyset pagination cursors signed
  (not reached: the inbox cursor is the project's own signed keyset and `lib/` has no Ash keyset
  page); policy fixes for page counts and `exists` inputs; bulk-action ordering and notification
  fixes; signals and range constraints (new, unused).
- `ash_postgres` 2.13.0 → 2.15.2 (Oct 3 to 25): nothing labelled breaking; the fixes (attribute
  multitenancy on skipped upserts and on lateral-join pass-through resources, exists subqueries
  carry the tenant, `parent` references and limits on `through` joins); `codegen --check` no longer
  infers renames or skips the dev migration check (2.14.3) and migrations create identities after
  multitenancy attributes (2.15.2), so the gate's `mix ash.codegen --check` is the check for
  snapshot drift (by a static read of the shipped generator, `--check` opens no repo connection:
  its only database path removes dev migrations, which the check exits on before reaching, and this
  project has none); `character_not_in_repertoire`, `DBConnection.EncodeError` and
  `Ecto.Query.CastError` converted to invalid-class errors on every query path (2.14.0; `lib/`
  matches none of them raw); upserts no longer use `merge` (2.13.1); atomics lock rows in the
  computing subquery; `timestamptz`, temporal and `view?` options (opt-in).
- `ash_sql` 0.7.1 → 0.8.4 (Sep 5 to Oct 25): nothing labelled breaking; grouped aggregate strategy
  (0.8.0), tenant-scoped aggregates and multitenancy bypass honoured inside aggregates (0.8.4),
  prefix on aggregate queries, `parent(rel.id)` or-filters compiled as EXISTS (0.8.3), exists-rewrite
  fixes, codepoints counted on the stored value (consistent with `default_string_length_count:
  :codepoints` above).

No intentional reliance on the corrected erroneous behaviour was identified by this source survey;
compatibility remains unverified: the full gate is the check, and no measured evidence from before
this change carries across it.

### Verification

- The lock delta was reviewed before anything compiled: exactly the three entries above.
- `mix compile --warnings-as-errors` in the declared Nix environment, `MIX_ENV=dev` then
  `MIX_ENV=test`: rc 0 in both (dev 01:04:36 to 01:05:54Z, 420 files; test 01:05:54 to 01:07:05Z,
  450 files; logs `compile-dev.log` 8d9ff6bb…, `compile-test.log` 61ae0e01…). Every `warning:` line
  in the logs (106 and 103) is a dependency's own compile output (for example `ash_sql` 0.8.4's two
  unused requires) or the Nix shell entry, none in project files; the one error-labelled line in
  each log is the devenv banner's `mix hex.info` EPIPE stack, not a compile error.
- `mix usage_rules.sync` (the doctrine's refresh after a dependency upgrade; the task takes no
  per-dependency argument and writes its whole output together): a first run without `--yes`
  stopped at its confirmation (rc 1, nothing applied), an invocation with a positional argument was
  rejected (rc 1), then a valid `--dry-run` (rc 0, 14 proposals) and `--yes` (rc 0) at 01:23Z. Only
  the output attributable to the changed dependency was kept, as a separate commit: the six
  generated `use-ash` files (`SKILL.md`, `references/ash/actions.md`, `relationships.md`,
  `testing.md`, and the new `signals.md` and `temporal.md` from `ash` 3.37.1's usage rules) and the
  two new Ash blocks in `AGENTS.md` (`ash:signals`, `ash:temporal`). The generator's unrelated
  output (the `use-ash-authentication` reference from the unchanged 4.15.0 package, three Jido
  skills never generated before, and their `AGENTS.md` blocks) was excluded mechanically (tracked
  bytes restored to the pre-sync commit, new files moved out) and preserved outside the repository;
  it is pre-existing drift for a separate slice, so the configured projection is not fully
  synchronized by this change. `.agents/skills/use-ash` remains the existing symlink into the
  `.claude` tree.
- Not run in this preparation, by Codex's ruling: tests, `ash.setup`, `ash.codegen`, migrations, any
  database, service or real call. The full gate (workflow receipt, format, compile, codegen check,
  Credo, `mix hex.audit`, the suite under `mix precommit --seed 0`, clean tree) runs at this branch's
  final head under its own pinned claim with a fresh execution ACK and a separate pair reservation;
  then hosted CI at the PR head, Codex's exact-head APPROVE, and the D-157 merge.
- Downstream revalidation obligation: `fix-151-isolation-test` (PR #231),
  `fix-230-ledger-slack-seam` (PR #232) and `suppression-fix-red` carry measured evidence at their
  current heads and the old lock. After this lands, each rebases and gets a fresh, separately
  reviewed verification plan with current CI (the suppression fix: a fresh six-mutant campaign and
  fresh seam and cold-VM proofs); no earlier result is relabelled as an execution at a new head.

### Policy

Unchanged: the audit stays blocking; no ignore list; CRITICAL and HIGH are never ignored; a LOW or
MEDIUM ignore needs no acceptable fix, a reviewed reason and a revisit trigger.

### Entity model

Trigger: no. Dependency-only scope; no application entity, attribute, relationship, policy, action
or contract changes. Had compatibility required a schema, policy or action change, the slice would
have stopped for re-scoping before implementing it.

## Addendum (2026-10-26, proposed): the first full-gate attempt and the generated ash-functions version-7 migration

Status: proposed. The amendment above, accepted by D-215 at commit `1e733839366cbe7fd71fd62ad728d8e50579525c`
(file SHA256 `fe3268c55b25b762a11e77e78c5dd8b9e61e0ee963262c064ade12d4b3d00a01`), is unchanged byte for byte.
This addendum extends the slice's scope and needs the owner's explicit acceptance at its exact commit and
file hash before any new gate execution (Codex ruling 01a1763e-39c0-75ba-af6e-14e42fca3a9b).

### What the gate found

The slice's first full-gate attempt (2026-10-26 03:13:30Z, under execution ACK
01a1762d-49f6-71c3-8ae5-00829db63a7d and reservation 01a1762d-49f6-71c3-8ae5-008357d2d32b) ended
`gate=FAIL step=codegen rc=1` before any database effect: `mix ash.codegen --check` reported "Pending Code
Generation Detected for 2 files" (evidence `deps-advisories-gate-1e73383-20261026T031330Z`, MANIFEST
`3a35e0dc…`; report `f6013665…` with its correction addendum; ruling `0d3f2e18…`). The scope statement
above ("had compatibility required a schema … change, the slice would have stopped for re-scoping") applied:
the slice stopped, and this addendum is the re-scoping.

### What is added to the slice

Commit `e80d9964652fceb9c2f9f1dc14fcd8ea9f17192d`, generated once by `mix ash.codegen ash_functions_v7`
inside the gate's pinned environment (evidence `deps-advisories-codegen-1e73383-20261026T033734Z`,
MANIFEST `a4395d93…`), exactly two files:

- `priv/repo/migrations/20261026033738_ash_functions_v7_extensions_1.exs` (SHA256
  `ef92569076b536f95cf984dcefaf58d31302fc4e945a8d5e11c1e0ddb1978d59`): `up` executes one
  `CREATE OR REPLACE FUNCTION ash_required(value ANYCOMPATIBLE, payload jsonb)`; `down` is a comment only.
- `priv/resource_snapshots/repo/extensions.json` (SHA256
  `e6b3e1386492e917f2a0c2425409ecd1d66cf13bf12cb60c43d53b11eec3c125`): `ash_functions_version` 6 → 7; the
  installed extensions (`ash-functions`, `citext`) unchanged.

### What the function change is

ash_postgres 2.15.2 ships version 7 of its `ash-functions` set ("make ash_required standalone and actually
use it", changelog v2.14.0). The repository's 2026-10-06 initialization migration already defines
`ash_required` as `STABLE` with `SET search_path = ''`, returning the value when it is not NULL and otherwise
`RETURN ash_raise_error(payload, value)`. Version 7 keeps the signature, the non-NULL identity return,
`STABLE` and the empty `search_path`, and changes only the NULL branch to
`RAISE EXCEPTION 'ash_error: %', payload::text` directly (self-contained; no call into `ash_raise_error`).
Both source definitions preserve the non-NULL identity return, the signature, `STABLE` and the empty
`search_path`. Version 6 delegates its NULL path to the unqualified helper `ash_raise_error(payload, value)`,
an application-defined function from the same initialization migration whose resolution under
`SET search_path = ''` is an additional failure point; its intended payload-error behaviour has not been
runtime-verified here. Version 7 raises the `ash_error: ` payload exception (the
`Ash.Error.Changes.Required` payload ash_postgres builds) directly; that is the contract the focused tests
below verify. No measured compatibility between the versions is claimed, and nothing here asserts which
bytes any existing database holds. Where it runs: ash_postgres emits `ash_required(?, ?::jsonb)` for Ash's
`required!/2` expression (`sql_implementation.ex`), that is, when a required attribute's atomic validation
is pushed into SQL; this application writes no `required!` expression of its own.

### Rollback consequence

The generated `down` restores nothing: rolling the migration back leaves the version-7 body installed and
the repository's snapshot at 7. Restoring the version-6 body would need a hand-written migration, which is
not proposed. Applying this migration to any environment (dev, calibration, production) requires that
environment's separately authorized procedure; the slice's merge authorizes no deployment and no migration
run.

### Unchanged

The pins (`ash` 3.37.1, `ash_postgres` 2.15.2, `ash_sql` 0.8.4; `mix.lock` `294075fa…`), the blocking audit,
the no-ignore policy, and every obligation of the amendment (fresh full gate, hosted CI, exact-head review,
downstream re-verification).

### Verification plan (proposed; nothing here has run)

1. Fresh install: the full gate at the final head creates its partition database from scratch and
   `ash.setup` applies every migration in order (version 6, then 7); the focused tests below assert the
   installed body, so a green gate at the final head is also the fresh-install proof.
2. Focused coverage, in this slice: `test/sdr_agent/repo/ash_required_v7_test.exs` (four tests, serial,
   `async: false`; predicted N 3222 → 3226, a prediction the gate measures). (a) A typed non-NULL input is
   returned unchanged (`SELECT ash_required($1::integer, $2::text::jsonb)` with `1` returns `1`; likewise a
   text value). (b) A typed NULL input raises `Postgrex.Error` with SQLSTATE P0001 (`postgres.code ==
   :raise_exception`, the intended raise, distinguished from a helper-resolution failure) and the exact
   message `ash_error: {"k": "v"}` (PostgreSQL's jsonb text rendering of the payload); the test then
   executes a further query to show the connection recovered. Recovery contract: the tests open no explicit
   transaction and do not disable sandbox subtransactions, so the installed Ecto SQL sandbox's per-query
   savepoint applies; a later revision that adds an explicit transaction must keep a savepoint around the
   expected error. (c) `pg_get_functiondef('ash_required(anycompatible, jsonb)'::regprocedure)` contains the
   direct `RAISE EXCEPTION 'ash_error: %', payload::text;`, no `ash_raise_error`, the preserved signature
   `(value anycompatible, payload jsonb)` returning `anycompatible`, `STABLE` and the empty `search_path`.
   (d) A sandboxed version-6 → version-7 model: the exact historical version-6 body is extracted from the
   tracked initialization migration (the file bound to its SHA-256 `56555cde…`) and installed, its baseline
   confirmed by (c) negatively (helper call present, no direct raise); then the actual tracked version-7
   migration's `execute` SQL is extracted from the migration file (bound to `ef925690…`) and applied, and
   (a)–(c) re-asserted; the sandbox transaction reverts the replacement. No hand-written substitute for the
   migration SQL and no `Ecto.Migration` runner is used.
3. Limits: (d) models the in-place redefinition on a database initialized at version 6; it is not a
   migration-runner upgrade/downgrade test and not an execution against any owner database. The no-op
   `down` remains a documented non-restoring consequence, not a tested rollback. Whatever atomic updates of
   required attributes the suite already performs exercise the non-NULL path implicitly; that is not
   quantified and not claimed. At the time of writing none of these tests has run; the gate at the final
   head is their first execution.

### Entity model

Trigger: no. An existing SQL helper's error path and the extensions snapshot version; no domain concept,
attribute, relationship, ownership, policy, action or lifecycle changes (the migration is SQL, not
metadata-only). No architecture-diagram trigger.

## Addendum 2 (2026-10-26, proposed): ash 3.37.2 and jose 1.11.13 after the second gate attempt

Status: proposed. The amendment (accepted as D-215) and addendum 1 (accepted as D-217 at commit
`7c7aadf0dcb8107ba937a89a504e3bbbac2d9769`, file SHA256
`c2e450a5f2390c4c9ada76a3a71a2200fd769c8a55ea003fd85207dd7b44afd9`) are unchanged byte for byte above.
This addendum is accepted only at its own exact commit and file hash; D-219 records the owner's advance
acceptance of the addenda this slice requires, effective once the exact text has passed static review.

### What the gate found

The second full-gate attempt (2026-10-27 02:57:39Z, ACK 01a17b48-…-71ae, reservation 01a17b48-…-7992)
passed workflow, format, compile, codegen and credo and ended `gate=FAIL step=audit rc=1` before any
database effect (evidence `deps-advisories-gate-7c7aadf-20261027T025739Z`, MANIFEST `d8ecdecf…`). The
audit named nine advisories published on 2026-10-26, two of them HIGH:

- `ash` 3.37.1: EEF-CVE-2026-96581 (HIGH; GHSA-vw7c-67pf-gh96): an upsert whose keys omit the
  multitenancy attribute (the primary key or an `all_tenants?` identity) could update or return another
  tenant's record under attribute multitenancy. Fixed in 3.37.2 (2026-10-26), which scopes upserts to the
  tenant and returns a stale-record error for a skipped upsert outside it.
- `jose` 1.11.12: EEF-CVE-2026-65629 (HIGH; weak PBKDF2 parameters for password-encrypted private-key
  export) and EEF-CVE-2026-65625, -65626, -65627, -65628, -65630, -65631, -65632 (MEDIUM: AES-GCM tag
  length, RSAES-PKCS1-v1_5 padding oracle, JWE zip decompression bound, mismatched shared-secret key
  recursion, X25519 fallback timing, RSA JWK factoring, ECDSA signature length). Fixed in 1.11.13
  (2026-10-26).

ADR-0008 never ignores HIGH and permits no ignore while fixes exist; the remedy is the minimal bump.

### What changes

Commit `a71e6e3060dbcb797b49ecbef62e469612498e18`: the direct pin `{:ash, "== 3.37.2"}` in `mix.exs`;
`mix.lock` changes exactly two entries, `ash` 3.37.1 → 3.37.2 (outer checksum `0f0dde3c…`) and `jose`
1.11.12 → 1.11.13 (outer checksum `15d8bd0f…`), both equal to the Hex tarballs. `jose` stays transitive
(`ash_authentication` 4.15.0 → `joken` 2.7.0, `~> 1.11.12`); no override or new direct dependency.
`ash_postgres` 2.15.2 (`~> 3.37 and >= 3.37.1`) accepts 3.37.2. Development and test
`compile --warnings-as-errors` pass. The generated usage guidance is unchanged: `ash` 3.37.2 ships
byte-identical `usage-rules.md` and `usage-rules/`, `jose` ships none, and the generator's dry run plans
no change to the `use-ash` files (only the pre-existing unrelated drift recorded in the amendment).

### Exposure (a source survey, not a runtime guarantee)

- `ash` 3.37.2's change touches the create and bulk-create upsert paths (a tenant filter applied only
  when the resource uses attribute multitenancy and a tenant is set), the bulk skipped-upsert result, and
  the ETS and Mnesia data layers (not used here). `lib/` declares no Ash `multitenancy` block, so the
  added filter is inert for every resource in this application; the application's tenant scoping is its
  own `tenant_id` attribute and policies, which this change does not touch. Behaviour change to expect:
  none for these resources; the skipped-upsert path now returns `{:ok, []}` handling internally where it
  previously returned a bare list (a crash fix).
- `jose` is reached only through `ash_authentication`'s session tokens: `joken` signs and verifies
  compact JWS with an octet secret under the default `HS256` (no `signing_algorithm` is configured). The
  application uses no JWE, no RSA, EC or OKP keys, no PEM or password-encrypted key import or export, and
  no compression. Behaviour change to expect: 1.11.13 also changes the default `crypto_fallback` from
  `true` to `false` and adds a `zip_size_maximum`; HMAC-SHA256 is native in OTP 29's `:crypto`, so the
  token path should be unaffected. The fresh full gate exercises sign-in and token verification.

### Verification

The fresh full gate at this addendum's head (re-pinned claim and driver, one control run, a new
execution ACK and reservation, one run), including the focused tests of addendum 1 and the suite's
authentication tests; then hosted CI and exact-head review. Earlier measured results stay at their own
heads. Entity Model trigger: no (dependency versions only).

## Addendum 3 (2026-10-27, proposed): a timeout classification the first upgraded full suite found

Status: proposed. The amendment (D-215), addendum 1 (D-217) and addendum 2 (D-220, accepted at commit
`4343dbef1e19e35a8e180c9219b7a2dd3a177083`, file SHA256
`b52076b9cba0eaad41bd5a8527b6ffb67436f7f66e0d058ea855620d223bd784`) are unchanged byte for byte above.
This addendum is accepted only at its own exact commit and file hash, under D-219 once its exact text has
passed static review.

### What the gate found

The first full suite on the dependency set of the amendment ran as gate `c2-20261027T041604Z-15736`
through the standing lane runner (D-221; 04:16:04Z to 04:38:25Z). The six steps before any database
effect passed, including a clean `mix hex.audit`. The suite ended `FAIL step=precommit` with 3226 of 3228
passed. Both failures were in `SdrAgent.Inbox.CountLockTest` (`count_lock_test.exs:74` and `:100`): a
statement cancelled by the read's `SET LOCAL statement_timeout` returned `:producer_error` instead of
`:timeout`, at the deadline. The same two failed when the file ran alone.

A structural diagnostic in a scratch worktree recorded only module names, field names and fixed booleans.
It showed the error reaching `SdrAgent.ReadDeadline.classify/1` as `Ash.Error.Unknown` with
`errors: [Ash.Error.Unknown.UnknownError{error: <string>}]`, and once as an `Ash.Query` whose `errors`
list holds that `UnknownError`. The string begins exactly with
`** (Postgrex.Error) ERROR 57014 (query_canceled) canceling statement due to statement timeout`.
`splode` 0.3.2 and `postgrex` 0.22.4 are unchanged, so the new shape comes with `ash` 3.37, `ash_postgres`
2.15 and `ash_sql` 0.8: their data layer passes the Postgrex error through `Ash.Error.to_ash_error`, and
`Splode.to_error/2` formats an exception it does not recognise into that string field. The classifier
recognised only the `Postgrex.Error` struct, directly or nested.

The gate's main lane database was retained at disposal because one backend was still connected, so lane c2
is quarantined. Its disposal follows a separate, reviewed one-time procedure.

### What changes

- Commit `956ddad553ea7d11fee9ae79fce3db136c034682` adds `test/sdr_agent/read_deadline_classify_test.exs`:
  eight unit cases. They cover the struct path, the wrapped head inside `Ash.Error.Unknown` and inside a
  query's `errors` list, and five near-misses that stay `:producer_error`: a user-requested cancellation,
  the phrase anywhere but at the head, unrelated text mentioning 57014, a non-string error field, and
  Forbidden precedence.
- Commit `1a3213888ecc5af95daab47145ec1877dabd1d07` adds one clause to `ReadDeadline.timeout?/1`: an
  `UnknownError` whose string `error` starts with that exact head is a timeout; every other string stays
  `:producer_error`. The struct path, the deadlines, the single query with no retry, and the restoration of
  connection settings are unchanged.
- The string match is narrower than the struct path. The struct path treats every `query_canceled` as a
  timeout, while the string path accepts only the statement-timeout message. `ReadDeadline` issues no user
  cancellation, so the narrower match restores the observed contract without widening it.
- No dependency, pin, lock, migration or other application change.

### Verification

- RED at `956ddad5` (run `c7-20261027T045240Z-9638`): 4 failures, the two wrapped-head cases and the two
  `CountLockTest` cases, with 9 passing.
- GREEN at `1a321388` (run `c7-20261027T045343Z-17403`): 13 passed, both lane databases dropped, and the
  final manifest verifies.
- Then: static review of this addendum and the code delta, its D-219 acceptance row, and one fresh full
  gate at this addendum's head on a fresh lane through the standing runner; then hosted CI and exact-head
  review.

Entity Model trigger: no. This is an internal error normalization restoring the existing timeout contract;
no persisted entity, attribute, policy, action or event contract changes.
