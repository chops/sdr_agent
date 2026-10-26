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
- Skipped upserts are used deliberately. All twelve `return_skipped_upsert? true` declarations in
  `lib/`, plus the one `Ash.create` option, each with an `upsert_condition`:

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
