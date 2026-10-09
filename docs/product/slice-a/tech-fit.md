# Slice A technical fit (gate G4 packet)

- **Status:** proposed, **pending the owner's G1 approval and slice choice**
  (OQ-1). Nothing here authorizes code. Drafted 2026-10-08 as method step 6
  for the slice-scoped G4 (D-020 in `docs/sdlc/decisions.md`).
- **Inputs:** [requirements.md](requirements.md) (REQ-A-1 to 18),
  [screen-matrix.md](screen-matrix.md) (SCR-A, ACT-A),
  [baseline-delta.md](baseline-delta.md) (D-A-1 to 5, G4 checks 1 to 10,
  G-A-1), ADR-0012 (live console refresh), and Codex's reviews of `40f76d4`,
  `26741f5` and `863df02`.
- **Grounding:** code at `origin/main` `98fb96e`. Line numbers will drift.
- **Build plan:** [build-plan.md](build-plan.md) (gate G5).

## 1. What each part of the stack does in slice A

| Part | Responsibility in slice A | Where it is today |
|---|---|---|
| Phoenix LiveView (`DashboardLive`) | Mounts, loads on the connected render only, renders home, owns the minute tick and the UTC rollover check. Never the source of truth. | `lib/sdr_agent_web/live/dashboard_live.ex:20-31` (mount, connected-only load), `:33-74` (load), `:96-97` (fail closed) |
| Web read composition (`ConsoleData`, new `HomeData`) | Joins public domain reads as the operator; caps lists before per-item fetches; pure bucketing and window functions over loaded rows. No Repo access, no resource internals. | `lib/sdr_agent_web/console_data.ex:18-66` |
| Ash domains | Every business read, as `actor: scope.user`, tenant-scoped, under existing policies. Slice A adds no action, policy, calculation or attribute. | `outreach.ex:82` (review queue), `:168-191` (hand-off queue: 3 reads), `:235` (guarded list); `operations.ex:142` (attention); `agents.ex:167` (runs); `sales.ex:132` (leads) |
| Two actorless reads | Provider status and today's reserved model calls, for the admin card only. They take no actor, so the role check before them is the only authorization. | `ai/model_provider/runtime.ex:133-147`; `agents.ex:257-266` (system context, `Ash.count!` raises on error) |
| Audit kernel (`AuditedView`) | One `record_view` access per auditor load, before anything is assigned; failure means nothing is served. | `audited_view.ex:30-46` |
| Live refresh (ADR-0012) | Debounced reload on committed audit events, revalidating the operator when the reload fires; ignores `access` and `auth` events. | `live_refresh.ex:43-53`, `:60-80` |
| Session revalidation | Re-reads the operator before every reload; disabled or revoked operators are signed out; role changes take effect on the next reload. | `live_user_auth.ex:45-62` (`:operator` hook), `:112-129` (`revalidate/1`) |
| Clock | UTC, injectable per process (`freeze/1`), visible to the LiveView process through `$callers` in tests. | `lib/sdr_agent/clock.ex:17-22`, `:30-34`, `:44-46` |
| Display zone | `Compliance.timezone/0` (default America/Denver) with the time zone database of ADR-0011. | `outreach/compliance.ex:15` |
| Oban, OTP | Not touched. Delivery, reconciliation and agent runs keep running in the background; home only reads their results. | |

## 2. Read contracts slice A uses

All exist; none changes. "Actor" is the freshly revalidated `current_scope.user`.

| Read | Actor and policy | Rows | Slice A use |
|---|---|---|---|
| `Sales.list_records(Lead, actor:)` | operator, tenant-scoped | all leads (D-A-2) | pipeline counts (REQ-A-9) |
| `Outreach.list_review_queue(actor:)` | operator | all pending drafts | summary count, 5 oldest (REQ-A-2, 3) |
| `Outreach.list_records(DeliveryOperation, actor:)` | operator | all deliveries (D-A-2) | nine buckets (REQ-A-7) |
| `Operations.list_attention(actor:)` | admin, reviewer, auditor (`operations/failure.ex:168`) | open and acknowledged failures | summary count, 5 newest (REQ-A-2, 5) |
| `Outreach.list_handoff_queue(actor:)` | operator; 3 reads: leads, matched replies, current assessments | all hand-off leads | summary count, 5 shown (REQ-A-2, 4) |
| `Agents.list_runs(actor:)` | any present actor (AgentRun) | all runs (D-A-2) | queued or running count, 5 latest, 24-hour stopped count (REQ-A-6, should) |
| `ConsoleData.index(scope, Contact, id: [in: ids])` | operator | at most 5 | recipient names of shown drafts |
| `ConsoleData.current_revisions(scope, drafts)` | operator; one fetch per draft | at most 5 fetches | subjects of shown drafts |
| `ConsoleData.subject_path(scope, failure)` | operator; one fetch for a delivery or run subject | at most 5, and only when the subject is not already loaded | problem links (REQ-A-5) |
| `Runtime.status/0` | **no actor**; config, ETS, and `ClaudeCLI.admission/1`, which can exit if the server is gone | n/a | admin card only (REQ-A-8, should) |
| `Agents.daily_model_calls/1`, `daily_model_call_limit/0`, `Compliance.daily_send_cap/0` | **system context** with `user.tenant_id`; config | n/a | admin card only |
| `AuditedView.record/4` | auditor only | 1 write | before assign (REQ-A-12) |

Two existing behaviours this design keeps on purpose:

- `ConsoleData.subject_path/2` turns a refused or missing subject fetch into
  `nil` instead of an error (`console_data.ex:54-66`). A nil path is a
  navigation fallback (link to `/operations`, REQ-A-5), not displayed data,
  so it does not trigger the whole-home withhold.
- Today's load calls `subject_path/2` for the **whole** attention list
  (`dashboard_live.ex:50`). Slice A caps the list at 5 first and reuses
  loaded delivery or run rows, so at most 5 fallback fetches remain.

## 3. Design

### 3.1 Modules

- **`SdrAgentWeb.HomeData`** (new, web layer, pure where possible):
  - `load(scope, now, reads \\ default_reads())`: runs the reads in §2 in a
    fixed order, caps each displayed list at 5 **before** per-item fetches,
    filters contacts to the shown drafts' `recipient_contact_id`s, builds
    the auditor's `target_ref` list (REQ-A-12), and returns
    `{:ok, home}` or `{:error, reason}`. `reads` exists only so tests can
    inject a refusing read; production passes the default.
  - `buckets(deliveries, now)`: the REQ-A-7 table as one function from
    `{state, not_before}` rows to nine disjoint counts, plus next and last
    deferral times. Pure.
  - `stopped_runs(runs, now)`: runs with status `failed` or
    `budget_exhausted` and `finished_at` within the 24 hours before `now`.
    Pure.
  - `admin_card(user, reader \\ status_reader())`: returns `:absent` unless
    `user.role == :admin`, **checked first**; otherwise
    `{:ok, card}` or `:unavailable`, or `{:withhold, reason}` (§3.3).
- **`SdrAgentWeb.HomeData.StatusReader`** (new): the default reader, calling
  `Runtime.status/0`, `Agents.daily_model_calls(tenant_id)`,
  `Agents.daily_model_call_limit/0` and `Compliance.daily_send_cap/0`. The
  reader is taken from `Application.get_env(:sdr_agent, SdrAgentWeb.HomeData)`
  so a test can install a recording reader. This is the same test-seam
  pattern as `config :sdr_agent, :capture_faults` (`test/support/capture_faults.ex`).
- **`SdrAgentWeb.LiveRefresh.request/1`** (new public function in an
  existing module): asks for one reload through the same pending flag,
  debounce and revalidation as an audit event, so a clock rollover and an
  event that arrive together coalesce into one reload.
- **`DashboardLive`** keeps its module name and route `/` (no route change).
  The navigation label follows OQ-5 ("Home" if the owner agrees).

### 3.2 Load path (each connected load and each reload)

1. Revalidated operator (`LiveRefresh` on reloads; the `:operator` hook on
   mount).
2. `HomeData.load(scope, Clock.utc_now())`: the domain reads in §2. Any
   `{:error, _}` (including `Ash.Error.Forbidden`) means `{:error, reason}`.
3. `HomeData.admin_card(user)`: role check **before** either actorless call.
4. `AuditedView.record(scope, "Dashboard", target_ref, purpose)` for an
   auditor. `{:error, _}` means withhold.
5. Only now assign. On any failure in 2 or 4, or `{:withhold, _}` from 3:
   assign `loaded?: false` and the operator-safe message, clearing every
   section (as `dashboard_live.ex:96-97` does today). No value from an
   earlier load survives.
6. Assign `data_as_of: now` and `loaded_utc_date: Date of now`.

### 3.3 Admin pre-call guard and the one degraded-card exception

```
admin_card(%{role: :admin} = user, reader):
  try reader.status(), reader.daily_calls(user.tenant_id), limits
    -> {:ok, card}
  rescue %Ash.Error.Forbidden{} -> {:withhold, :forbidden}
  rescue _other                -> :unavailable
  catch :exit, _               -> :unavailable
admin_card(_non_admin_user, _reader) -> :absent   # reader never called
```

- The guard runs against the user that `LiveRefresh` or the mount hook just
  revalidated, on **every** load and reload, so a demoted admin's next
  reload never calls the reader.
- `:unavailable` renders the fixed text "Model status unavailable", with no
  value from an earlier load and no exception text (REQ-A-8, OQ-8).
- A provider that is refusing calls is a normal `Runtime.status/0` result
  (`effective: nil, refusal: reason`) and renders as a status, never as
  `:unavailable`.
- These two reads take no actor, so they have no authorization path of
  their own. The role guard is the authorization. A `Forbidden` raised from
  them is still treated as an authorization failure and withholds the whole
  home, as REQ-A-10 requires, even though it should not occur.
- If OQ-8 is answered "every failure withholds the whole home", only the
  `rescue _other` and `catch :exit` branches change, to `{:withhold, reason}`.

### 3.4 Freshness: minute tick and UTC rollover (REQ-A-17)

- On the connected render, the view schedules `:home_tick` for the next
  whole minute (`Process.send_after/3`). The interval comes from
  `config :sdr_agent, SdrAgentWeb.DashboardLive, tick_ms:` (default 60,000);
  tests send `:home_tick` to the view directly.
- **Ordinary tick:** `now = Clock.utc_now()`. If
  `Date.of(now) == loaded_utc_date`, recompute `buckets/2` and
  `stopped_runs/2` from rows already in assigns (only `{state, not_before}`
  and `{status, finished_at}` are kept), set `checked_at: now`, reschedule.
  No domain read, no audit write, no revalidation.
- **Rollover tick:** if the UTC date changed, call
  `LiveRefresh.request(socket)`. The reload follows §3.2 exactly, including
  one audited access for an auditor. If an event-driven reload is already
  pending, the request joins it (one reload). `loaded_utc_date` is updated
  by that reload, so at most one rollover reload runs per UTC day.
- **Disconnect and reconnect:** the LiveView process ends on disconnect, so
  ticks stop. Reconnect is a new connected mount, which performs one normal
  load; if the UTC date changed meanwhile, that load is the rollover reload.
  The stale banner uses `phx-disconnected` and `phx-connected` bindings, as
  the existing client-error flash does (`components/layouts.ex:211-218`).
- **Zones:** all comparisons use UTC from `SdrAgent.Clock`. Display converts
  with `Compliance.timezone/0` and shows the zone abbreviation. The reset
  shows as 18:00 MDT before Nov 1 and 17:00 MST after; nothing hard-codes a
  local hour.

### 3.5 Bounded read composition (REQ-A-15)

Per load, independent of row counts: 9 list reads (leads; review queue;
deliveries; attention; hand-off queue as 3; runs; contacts filtered to at
most 5 ids), the admin card's status and count reads (admin only), at most
5 revision fetches, at most 5 subject-path fetches, and 1 audit write for an
auditor. If REQ-A-6 is cut, the runs read goes too. The rows of the
unbounded lists (D-A-2) are what the load target measures.

## 4. Entity-model evaluation

**D-A-1: trigger: no**, as independently evaluated by Codex for
`40f76d4` and kept at `863df02`. **Codex must confirm it again at G4**
against this design.

It holds under these conditions:

1. Every domain read passes `actor: scope.user`, except the two admin-only
   reads, which run only after the role check (§3.3).
2. No new or changed resource, attribute, relationship, calculation,
   aggregate, policy, action, lifecycle, audit-event category or `target`
   contract. The auditor record reuses `record_view` on `"Dashboard"`, with
   more ids in `target_ref` (REQ-A-12).
3. New modules are web-layer composition (`HomeData`, `StatusReader`) and a
   reload request in `LiveRefresh` that uses the existing revalidated path.
   They publish no event and read no Repo directly.
4. No admin-only value reaches a reviewer or auditor, including after a
   demotion.

**Becomes trigger: yes** (needs its own inline delta and independent PASS
before any affected code), if any of these is needed:

- a count or batch read to meet the load target (D-A-2);
- a tenant-wide read of model calls with unknown outcome (D-A-3);
- provider or budget status for non-admins (D-A-4);
- a manual delivery reconciliation control (G-A-1);
- a change to the audit-event or target contract, or to `LiveEvents`.

## 5. Threat model

| # | Threat | Surface | Mitigation | Proven by |
|---|---|---|---|---|
| TM-1 | A reviewer or auditor sees provider or budget data | admin card | Role guard on the revalidated user before the actorless reads; card absent, not hidden | T-A-14, T-A-15 |
| TM-2 | A demoted or disabled operator keeps seeing data | reloads | A role or status change appends `user.role_changed` or `user.status_changed` with category `domain_change` (`accounts/user.ex:214-228`), which ADR-0012 treats as relevant. It triggers one debounced reload that revalidates first: the card drops for a demoted admin, and a disabled operator is signed out. Between the change and the debounced reload (default 250 ms), the old values are still on screen. The minute tick does not revalidate, by REQ-A-17's no-read rule. | T-A-15; existing `live_refresh_test.exs:197-227` |
| TM-3 | An auditor is shown records without an access record | load, reload, rollover | Record before assign; failure withholds; ticks render no new records | T-A-24 to T-A-27 |
| TM-4 | An audit loop or flood | reloads | `access` and `auth` events ignored; at most one rollover reload per UTC day; ordinary ticks write nothing | T-A-26, T-A-29 |
| TM-5 | Denial of service through unbounded lists | load | Lists capped before per-item fetches; per-item fetches at most 10; query count does not grow with rows; worst-case load measured. A count read would be trigger: yes. | T-A-31, T-A-32 |
| TM-6 | Script injection through draft subjects, company names or failure messages | rendering | HEEx escaping, no `raw/1`; links built from ids with `~p` | T-A-6 |
| TM-7 | Raw internals or secrets in error text | withheld state, degraded card | `AuditedView.error_message/1` for the withheld state; a fixed string for the degraded card; `Runtime.status/0` shows no secrets | T-A-16, T-A-19 |
| TM-8 | Misleading recovery claims ("reconciled") | copy | Copy guard over rendered home and linked labels | T-A-22 |
| TM-9 | A write sneaks onto home | events | No `phx-submit`; `handle_event` accepts only client-side navigation events | T-A-21 |
| TM-10 | Wrong day or deferral state from clock or zone mistakes | buckets, card | UTC from `SdrAgent.Clock` for every comparison; zone only for display; tests at UTC midnight and across Nov 1 | T-A-10, T-A-11, T-A-28 |
| TM-11 | Another tenant's data | reads, events | Domain tenant scoping by actor; daily count from the revalidated user's `tenant_id`; tenant topics (existing test, `live_refresh_test.exs:259`) | T-A-14, existing |

No new external surface: slice A makes no network call, adds no route and
takes no input beyond navigation.

## 6. Test plan

Every test is written **red first** (Phase 4a, verified with `tdd-verify`)
and goes green in the slice named in [build-plan.md](build-plan.md). "LV"
means a LiveView test using `SdrAgentWeb.OperatorCase` (async: false).

| ID | Test (file: name) | Covers |
|---|---|---|
| T-A-1 | `navigation_test.exs`: "each role sees exactly its navigation items" | REQ-A-1 |
| T-A-2 | `navigation_test.exs`: "Skip to content is the first tab stop; the current page is marked" | REQ-A-1, 14.5 |
| T-A-3 | `dashboard_live_test.exs`: "needs-you-now shows review, replies and problems counts with links" | REQ-A-2 |
| T-A-4 | `dashboard_live_test.exs`: "nothing needs you only when all three are zero and no outcome is unknown" | REQ-A-2 |
| T-A-5 | `dashboard_live_test.exs`: "lists the 5 oldest drafts and See all N" | REQ-A-3 |
| T-A-6 | `dashboard_live_test.exs`: "a markup-shaped subject is escaped and links to its draft" | REQ-A-3, TM-6 |
| T-A-7 | `dashboard_live_test.exs`: "replies: interested first, not assessed yet, unclear, missing name and time" | REQ-A-4 |
| T-A-8 | `dashboard_live_test.exs`: "problems: 5 of N, critical as text, subject link, no page links to operations" | REQ-A-5, 18 |
| T-A-9 | `home_data_test.exs`: "stopped_runs counts failed and budget_exhausted by finished_at in the 24 hours before now" | REQ-A-6 |
| T-A-10 | `home_data_test.exs`: "buckets: one bucket per delivery for every state and not_before case; total equals rows" | REQ-A-7, check 6 |
| T-A-11 | `home_data_test.exs`: "a deferral that expires moves to Queued or Retry due, never Captured; next and last due" | REQ-A-7, 17, check 6 |
| T-A-12 | LV: "resolving an unknown delivery's Failure leaves it under Outcome unknown" | REQ-A-7, 18 |
| T-A-13 | LV: "the admin card shows configured and effective provider, reserved calls today, limit and send cap" | REQ-A-8 |
| T-A-14 | LV with recording reader: "the status reader is never called for a reviewer or an auditor" | REQ-A-8, check 2, TM-1 |
| T-A-15 | LV: "demoting the admin triggers a revalidated reload that drops the card and does not call the reader" | REQ-A-8, checks 2 and 3 |
| T-A-16 | LV with a raising and an exiting reader: "only the card says Model status unavailable; no earlier value; no internals" | REQ-A-8, 10, check 5 |
| T-A-17 | `home_data_test.exs`: "a Forbidden from the status reader withholds the whole home" | REQ-A-10, check 5 |
| T-A-18 | LV: "a provider refusing calls is a status, not the degraded card" | REQ-A-8, check 5 |
| T-A-19 | LV with an injected refusing read: "a refused read withholds the whole home; a refused reload clears earlier values" | REQ-A-10, check 5 |
| T-A-20 | LV: "each section has its empty message; capture-only and fake-model labels stay" | REQ-A-10, REQ-A-16 |
| T-A-21 | LV: "home has no form and no domain-write event for any role" | REQ-A-13, TM-9 |
| T-A-22 | LV: "no copy on home promises manual reconciliation; the unknown link says Inspect" | REQ-A-18, TM-8 |
| T-A-23 | LV: "a committed audit event reloads home once as the revalidated user" | REQ-A-11 |
| T-A-24 | LV: "an auditor's load records exactly one record_view with the REQ-A-12 references" | REQ-A-12, check 4 |
| T-A-25 | LV: "an empty home records none" | REQ-A-12, check 4 |
| T-A-26 | LV: "an event reload records one more access and causes no further reload" | REQ-A-12, check 4, TM-4 |
| T-A-27 | LV with a failing audit write: "nothing is served to the auditor" | REQ-A-12, check 5, TM-3 |
| T-A-28 | LV with a frozen clock: "an ordinary tick re-buckets from loaded rows with no read and no write; data as of is unchanged" | REQ-A-17, check 6 |
| T-A-29 | LV: "the UTC rollover tick reloads once (one access for an auditor) and coalesces with a pending event reload" | REQ-A-17, check 6 |
| T-A-30 | `live_refresh_test.exs`: "request/1 joins a pending event reload and revalidates when it fires" | REQ-A-17 |
| T-A-31 | `home_read_budget_test.exs`: "the query count is the same with 1 row and with worst-case rows, and within the read budget" | REQ-A-15, check 8, TM-5 |
| T-A-32 | `home_perf_test.exs` (`@tag :perf`, run on demand): "worst-case fixtures load in under 1 second" (measured and recorded, not a CI gate) | REQ-A-15, check 8 |
| T-A-33 | LV: "headings go h1, h2, h3; each count's accessible name includes its label; every status has text" | REQ-A-14.2 to 14.4 |
| T-A-34 | Scripted browser check (Chrome): contrast of every text pair in light and dark, visible focus ring, no smooth scrolling with reduced motion | REQ-A-14.1, 14.5, 14.6, check 9 |
| T-A-35 | LV: "reconnecting after a UTC date change performs one load that shows the new day" | REQ-A-17, check 6 |
| T-A-36 | LV: "the pipeline shows lead counts by stage group" | REQ-A-9 |
| T-A-37 | Review step: "D-A-1 still trigger: no; D-A-2 to 4 still excluded" (Codex verdict at G4 and at each slice) | check 10 |

**Notes:**

- **The read budget is enforced by query counting.** T-A-31 attaches a
  handler to the Repo's `[:sdr_agent, :repo, :query]` telemetry while
  `HomeData.load/3` runs. It asserts that the count with one row of
  everything equals the count with worst-case rows, and stays under the
  budget in §3.5. Ash's own policy queries are counted too, so the test
  records the measured constant and fails if it grows with rows.
- **The 1-second target is measured, not enforced in CI.** T-A-32 uses
  REQ-A-15's fixtures: 500 leads, 2,000 deliveries, 1,000 runs, 200
  failures, 100 hand-off leads with replies and 50 pending drafts. A timing
  assertion in CI would be flaky, so the measured time is recorded in the
  slice evidence. Adding the `:perf` tag means one change to
  `test/test_helper.exs`: excluding `:perf` beside `:external`.
- **Clock control.** Tests freeze the clock with `SdrAgent.Clock.freeze/1`,
  as `draft_live_test.exs:296` already does, and send `:home_tick` directly.
- **Prototype toggles prove nothing here.** None of T-A-14 to T-A-19,
  T-A-24 to T-A-27 or T-A-31 can be replaced by the static prototype.

### G4 check coverage

| G4 check (baseline-delta) | Tests |
|---|---|
| 1 Same data, roles and contracts | T-A-14, T-A-21, T-A-37, review of §2 |
| 2 Admin guard before actorless calls | T-A-14, T-A-15 |
| 3 Fresh user on every re-read | T-A-15, T-A-23, existing `live_refresh_test.exs:186-257` |
| 4 Audit | T-A-24 to T-A-27, T-A-29 |
| 5 Error paths | T-A-16 to T-A-19, T-A-27 |
| 6 Buckets and clock | T-A-10, T-A-11, T-A-28, T-A-29, T-A-35 |
| 7 LiveView states and links | T-A-1 to T-A-8, T-A-12, T-A-20 to T-A-22 |
| 8 Load | T-A-31, T-A-32 |
| 9 Accessibility | T-A-2, T-A-33, T-A-34 |
| 10 Entity trigger | T-A-37 |

## 7. ADRs

**None proposed.** Slice A adds no technology, dependency, domain boundary
or cross-cutting pattern:

- the composition module follows `ConsoleData`;
- the test seam follows the existing `:capture_faults` configuration;
- the clock follows ADR-0002 and ADR-0009;
- the rollover reload reuses ADR-0012's revalidated, audited reload path
  through one new entry point, without a new event or event category.

Codex is asked to confirm at G4 that `LiveRefresh.request/1` needs no
ADR-0012 amendment (Q-T-2).

## 8. Questions for G4

- **Q-T-1 (Codex):** confirm TM-2. Demotion and disabling are `domain_change` events, so they trigger a revalidated reload within the debounce window. The minute tick deliberately does not revalidate (REQ-A-17). Is that window acceptable for slice A?
- **Q-T-2 (Codex):** does `LiveRefresh.request/1` need an ADR-0012 note?
- **Q-T-3 (owner, via OQ-8):** keep the degraded-card exception, or withhold
  the whole home on every failure? §3.3 shows the one-line difference.
