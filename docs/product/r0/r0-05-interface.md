# R0-05 interface: the admin model card, switch and resolver UI

**Status:** draft 4, 2026-10-16: the MF3 amendment for option B (D-141),
in section 3 (step 2, results, crash reports), section 5, the ADR
evaluation and tests 9, 12, 15a–15c. Needs Codex review. Draft 3 had the
**Interface PASS** (Codex `232bd20d`, exact
`fbc3203`, `codex-r005-fbc3203-interface-pass.md`). Entity trigger: no.
This permits scoped RED only. The b2β owner ADR, b2β and C2-02c GREEN, and
the staged checks remain prerequisites. Draft 2
(`c7767b7`) was a narrow NEEDS-REVIEW (Codex `c05d20d9`): a retry-local timeout
after uncertainty. Draft 1
(`a0ffefe`) was NEEDS-REVIEW (Codex `a9d27e99`): the source of the setting revision
and the frozen review lifecycle. Codex accepted OQ-1 with the lag
qualification (section 1). Issue #53.
Slice plan: `c2-02-slices.md`, row R0-05, last after the integrated switch
and status. It builds on C2-02a, b1 and b2α (merged), b2β
(`c2-02b2b-interface.md`, PASS) and C2-02c (`c2-02c-interface.md`, PASS).
It is implemented after b2β and c GREEN.

**Acceptance (#53):**
- shows the configured and effective profile, the CLI version and the
  last check, without a model call;
- a switch button with confirmation;
- LiveView tests;
- the owner tries it.

## 0. Scope

This is the UI only, over existing domain and runtime APIs. It adds no
resource, attribute, action, policy or event.

| Part | Calls |
|---|---|
| The model card (read) | `Runtime.status/0` (C2-02c, section 2b) |
| Requesting a switch | `Coordinator.request_switch(%{to_profile_id, expected_revision}, actor:)` (b2α) |
| Resolving a blocked switch | `Agents.blocked_switch_facts/2` and `Agents.resolve_blocked_switch/3` (b2β) |

**Not in R0-05:**
- an attended action for `:cleanup_unprovable` (C2-02c OQ-5 recommends
  none for R0; the card only explains it);
- any model call or spend, and any change to grants;
- any other page.

## 1. The model card (read-only)

The card replaces the current "Model provider" card's profile lines with
the C2-02c fields. It keeps the existing configured and effective
provider, model alias and id, reviewed CLI version, pinned CLI path and
last attestation lines.

**What it shows:**

| Line | Source | Shown as |
|---|---|---|
| Desired profile | `desired_profile` | the profile's name, "(saved setting)" or "(default)", and "confirmed <time>"; **"unknown"** when `:unknown`; hidden for the Fake |
| Running profile | `observed_profile` | the name; "none" for `:none`; "unknown" |
| Accepting calls | `effective_profile`, with `refusal` | "yes, on <profile>", or "no", with the refusal in words (existing `refusal_message/1`, plus words for `:provider_held`, `:status_unavailable`, `:status_inconsistent`) |
| Hold | `hold`, `stage` | "held", "released" or "pending", with the stage in words. `:cleanup_unprovable` gets its own banner (below) |
| Open switch | `switch` | "none (confirmed <time>)", "<from> → <to>, pending", "<from> → <to>, blocked: <reason>", or "unknown" |
| As of | `published_at` | "coordinator published <time>". This is the ledger and runtime publication time, not the sampling instant, and not a guarantee about admission. Each ledger line shows its own `confirmed_at`. Runtime lines are marked as sampled |
| Last check | `attestation` | unchanged: the last per-call init attestation with its time, or "not yet attested" |

**Rules:**
- **No guessed values:** `:unknown` and `:unavailable` show as "unknown",
  never the default profile.
- **A held server never reads as ready.** Lines with no data show
  "unknown", never a blank or a default.

The `:cleanup_unprovable` banner is defined in section 3.

**Refresh:**
- **On audit events:** the card re-reads `Runtime.status/0` through the
  existing `SdrAgentWeb.LiveRefresh` whenever an audit event commits.
  Switch requests, blocks, completions, failures, resolutions and start
  transitions are all audited.
- **The "Refresh status" button** re-reads it on demand.
- **No timer** and no polling.
- **The lag (OQ-1 ruling):** an audit commit doesn't prove that the
  coordinator has already handled the outcome, published it, or released
  a hold. Some runtime-only changes are followed by no audit event. So an
  audit-driven refresh can show an earlier observation until a manual
  refresh. The card's timestamps disclose this.
- **Card fields** come only from C2-02c's single bracketed sample, never
  from fresh reads by name, and never from a default profile.

Rendering calls only `Runtime.status/0`, which makes no database query
and no coordinator call (C2-02c).

## 2. Requesting a switch

**The control.** "Change model profile" shows only when, in the last
status read, the provider is ClaudeCLI, `desired_profile` is confirmed,
and `switch` is `%{state: :none}`. It shows nothing when a switch is open
or the status is unknown ("status unknown; refresh"), or for the Fake.

**The revision comes from the setting itself (R1-MF1).** Opening the
control reads `Agents.get_profile_setting(actor: user)` and branches:
- **Present:** from = its `desired_profile_id`, and the revision is its
  `revision`.
- **Positively absent** (`{:ok, nil}`): from = the registry default, and
  `expected_revision: 1`, the existing initialize-at-request convention.
- **A failed read:** "the setting can't be read; try again", with no
  review. A failed read is never treated as absent.

The passive card stays `Runtime.status/0` only, and no status field is
added.

**Steps,** on the C9-05 `GrantForm` pattern: staged in the page, with no
browser dialog.
1. **Choose** a target from the reviewed real profiles except `from`
   (`ModelProfiles.real_ids/0`).
2. **Review:**
   - "Switch from <from> to <target>." Then: "Calls in progress finish
     first. While the switch runs, new calls are paused. The new profile
     is checked without a model call. If it can't start cleanly, the app
     returns to <from>, or blocks the switch for you to resolve."
   - It shows the revision.
   - The socket stores exactly what was shown: `%{from, to_profile_id,
     expected_revision}`.
3. **Confirm:**
   - **What it sends:** the **stored** review, never values supplied by
     the browser, and never a revision refreshed in the background.
   - **A forged `confirm_switch`** with no review does nothing.
   - **If the setting changed** after the review, the existing stale
     refusal applies, and the page shows a reload prompt. It never
     rewrites the review the admin saw.

**Results.** Words come from the existing operator-safe mapping
(`AuditedView.error_message/1`, plus the typed refusals), never from
`inspect` or a raw exception message:

| Result (actual shape) | Shown |
|---|---|
| `{:ok, switch}` | "Switch requested". The card follows the status as it is refreshed (section 1, the lag note) |
| an Ash Invalid on stale `expected_revision` | a reload prompt; nothing retried by itself |
| `{:error, :switch_open}` | "Another switch is open", then a re-read |
| `{:error, :coordinator_not_ready}` | "The model server isn't ready to switch; try again shortly" |
| Forbidden | the refusal. A demoted or signed-out user is redirected by `LiveUserAuth` before any event reaches the domain |
| other | the mapped message, next to the control |

## 3. Resolving a blocked switch

**When it shows:** "Resolve blocked switch" appears when `switch` is
`%{state: :open, status: :blocked}`.

**Review states.** These are socket-local, for one resolution at a time:

| State | Entered by | What refresh may do |
|---|---|---|
| `:facts` | opening the control | replace the facts; no confirmation is kept |
| `:editing` | the facts are shown, the statement too, and the input is open | an audit or manual refresh updates the **status card** only. A change in the facts (a new latest start, a different lease kind) shows "the facts changed; review again", clears the input, and needs a new review |
| `:submitting` | the confirm click | **frozen**: nothing in the review changes, and further clicks are ignored |
| `:uncertain` | `:resolve_uncertain` | **frozen**, as in `:submitting`. Only "Check again" acts |
| `:terminal` | a definite outcome or refusal | the review is discarded. A new resolution needs a new review, a new id and a new typed confirmation |

**Frozen means** the attestation id, the switch, the shown start range,
the lease kind and the confirmed statement can't be replaced. Opening a
second review, or sending a fresh id by itself, is also impossible. The
status card may still update.

**Steps:**
1. **Facts.** `Agents.blocked_switch_facts/2`, called as the user, shows:
   - the switch (from, to, the reason in words, when it was requested and
     by whom);
   - every covered start (generation, reason, profile, status, and its
     recorded pid, node and reaper, or "not recorded");
   - the lease kind in words.

   `{:error, :observation_unknown}` → "The server's state can't be read
   right now; try again".
2. **The statement and the typed confirmation.**
   - The page shows b2β's section 3 statement word for word, and an
     input.
   - The button enables only while the input is exactly
     `STOPPED <switch id>`. The server checks again.
   - The input's parameter key is `resolution_confirmation`, which is
     filtered (section 5).
   - **The page checks the text itself (D-141, option B).** It compares
     the submitted binary byte for byte with `"STOPPED " <>
     review.switch_id`, using the switch id in the socket's review, never
     one from the browser: no trimming, case folding or synthesis. A
     `change_resolution` event keeps only whether the text matches, never
     the text. A `confirm_resolution` whose text doesn't match is refused
     by the page: no attestation is built, nothing is stored, and no task,
     domain or coordinator call is made. The review stays in `:editing`
     with the same attestation id, the input is cleared, and
     `#resolution-mismatch` says "That text doesn't match. Type STOPPED,
     a space and the switch id shown above." It never repeats the text and
     claims no recorded or refused attempt.
   - Only the original matching bytes are wrapped in `Confirmation` and
     revealed at the domain call. The domain's own exact-confirmation
     check is unchanged.
3. **Confirm** sends the stored review: the facts shown, and the
   `attestation_id` generated once, when `:editing` began. A forged
   `confirm_resolution` with no review does nothing.

**Results** (b2β section 1, `{:error, tag}` shapes):

| Result | Shown | Next state |
|---|---|---|
| `{:ok, %{switch: s}}`, or a replay | "The resolution was recorded: the switch is failed. Readiness is checked separately; calls stay paused until the status shows the server accepting calls. A dead lease may still need an operator." It never says ready | `:terminal` |
| `:resolve_uncertain` | "The result isn't known yet." The "Check again" button resends **exactly** the frozen semantic identity, under the current authorization | `:uncertain` |
| `:resolve_timeout`, on a **first** attempt (no earlier unknown under this review) | "Not recorded. Start a new review." | `:terminal` |
| `:stale_attestation`, `:live_work_observed`, `:observation_unknown`, `:coordinator_busy`, `:attestation_invalid`, `:attestation_conflict`, `:switch_not_blocked`, Forbidden, NotFound | the refusal in words | `:terminal` |
| (no call) a text that doesn't match, refused by the page | `#resolution-mismatch` (step 2) | stays `:editing` |

`:attestation_invalid` keeps its mapping, but the page no longer sends a
mismatched text, so it arises only if the domain's check disagrees with
the page's.

**Retrying after an unknown outcome (R2 residual).** Once a review has an
unresolved earlier attempt (it entered `:uncertain`), a refusal of the
retry proves nothing about that attempt. b2β can expire "Check again"
before its coordinator replay lookup, while the earlier attempt commits
meanwhile. So, for a retry from `:uncertain`:
- **What the retry does:** "Check again" moves the review to
  `:submitting`, so duplicate clicks send nothing.
- **A result that settles the earlier attempt:** an exact success or
  replay (`{:ok, …}`) is `:terminal` with the recorded message.
  `:switch_not_blocked` and `:attestation_conflict` also end the review.
  A conflict does **not** mean the target switch is no longer blocked: it
  can be an id collision with another switch, or a different semantic
  identity. In both cases the page re-reads the stored switch, as the
  actor, and shows only what is recorded. A failed re-read shows
  "unknown", never an inferred resolution or rollback.
- **Any other retry refusal returns to `:uncertain`,** with the same
  frozen identity and the unknown-outcome wording ("The result still isn't
  known"). That covers `:resolve_timeout`, `:resolve_uncertain`,
  `:coordinator_busy`, `:observation_unknown` and `:stale_attestation`.
  Such a refusal is never "Not recorded". It never discards the id, and
  never opens a new review by itself.
- **An authorization loss** (Forbidden, or a redirect by `LiveUserAuth`)
  ends the session's review immediately. It is never described as proof of
  rollback.

The page adds no backend guarantee. It is only conservative about the
shapes it already gets.

**Losing the socket.** A reconnect or a reload loses the socket-only
review. No durable recovery of the same id is promised. On reconnect the
page re-reads the stored state: the switch is still blocked, or it is
resolved. It never invents or submits a replacement attestation. An
admin who lost an uncertain review starts a new one, and b2β's replay and
settlement rules cover the earlier request.

**Safety.** The page has no lease release action. The confirmation text
never appears in error messages, URLs, ordinary logs (the parameter is
filtered, section 5), stored rows, audit payloads, the application's
captured telemetry or exported spans. The page never forwards a
mismatched text to a resolution task, the domain or the coordinator
(step 2); the crash-report exceptions below still apply.

**Crash reports (ADR-0005, R0-05 amendment; D-141).** The AdminLive
channel is tagged, so its own crash and error reports become a fixed,
content-free diagnostic at any level. The owner accepted what that does
not cover:
- the valid phrase `STOPPED <switch id>` may appear in crash or error
  reports of untagged downstream processes (the resolution task, the
  coordinator and its retained settlement state);
- a mismatched text can be anything, and a report another process writes
  about the channel (a supervisor's) is not classified. SASL reports being
  off by default is not a control;
- the channel's error-or-higher diagnostics lose their detail.

The page doesn't deliberately retain or forward a mismatched text after
handling the event. It doesn't claim the text exists nowhere else
(browser and transport buffers, raw `handle_event` telemetry, VM terms
before collection).

**The telemetry boundary (test 15 qualification, Codex RED verification
at `00c4998`, ruling 5).** Phoenix LiveView's own in-process
`[:phoenix, :live_view, :handle_event, :start | :stop]` telemetry carries
the submitted params, including `resolution_confirmation`, by design. It
is excluded: parameter filtering sanitizes Phoenix's and LiveView's logs,
not arbitrary telemetry subscribers, so a handler attached to that event
would see the text. The verified scope, for the ordinary flow (crash
reports are covered separately below), is: no logged or exported copy, no
URI or router copy, no stored copy, no copy in the captured application
telemetry (the `[:sdr_agent | _]` events registered when the test runs,
and repo queries with their parameters) and no exported span. It is not a
claim of universal event capture. R0-05 adds no telemetry event, log line,
subscription or export path.

**The `:cleanup_unprovable` banner:** "A model server's cleanup can't be
confirmed. Calls stay paused. An operator must check the machine and
release the old reaper's lease from a console. Normal reconciliation then
checks readiness again." It promises no unconditional automatic restart.

## 4. Access

- **Who:** the page stays admin-only (`LiveUserAuth` `{:roles,
  [:admin]}`). Every action is re-authorized by the domain with the role
  re-read.
- **Non-admins:** reviewers, auditors and signed-out users are redirected
  before any event reaches the domain (the existing pattern).

## 5. Logging

`config :phoenix, :filter_parameters` gains `"resolution_confirmation"`.
The pinned LiveView logger uses `Phoenix.filter_values/1`. Tests cover
the change, submit and refusal events at `:debug`.

The AdminLive channel sets `Logger.metadata(sdr_sensitive_input: true)`
in `mount/3`, before any input, and never clears it. `ExceptionFilter`
(C4-01a, #165) replaces the tagged process's crash, termination and
error-or-higher events (ADR-0005, R0-05 amendment). R0-05 therefore lands
after #165.

## Entity Model

**Entity Model trigger: no.** It also consumes the existing
`Agents.get_profile_setting/1`. Reason:
- no new or changed attributes, relationships, calculations, aggregates,
  policies, actions or backend event contracts;
- R0-05 is LiveView UI over the existing, reviewed domain and runtime
  APIs: `Runtime.status/0` (C2-02c), `request_switch/2` (b2α), and
  `blocked_switch_facts/2` and `resolve_blocked_switch/3` (b2β).

## ADR evaluation

The UI is within ADR-0004's status card and the C2-02b2 and b2β
amendments. The crash-report rule is a cross-cutting logging change: the
ADR-0005 R0-05 amendment (option B, D-141, proposed; needs Codex review
and owner acceptance before the MF3 implementation).

## Tests (RED first)

File: `test/sdr_agent_web/live/admin_live_switch_test.exs`, with LiveView
tests, the Fake provider and coordinator fixtures. No model call, no
spend, synthetic data only.

**The card:**
1. **Each C2-02c shape renders as specified:** Fake, unavailable,
   inconsistent, no server, held, pending hold, released and eligible,
   released and refused, `:cleanup_unprovable`, unknown ledger.
   "unknown" is never a default profile.
2. **No model call:** across mount, refresh and the whole flow
   (launches traced: zero).
3. **Refresh:** an audit event commit re-renders the card; "Refresh
   status" re-reads it.

**The switch:**
4. **The control** shows only under the conditions in section 2.
5. **The setting read:**
   - a present setting → its from and revision;
   - absent → the default, and revision 1;
   - a failed read → a message, with no review;
   - the setting changed between review and confirm → the stale refusal
     and a reload prompt, never a rewritten review.
6. **Confirm** sends the stored review only. Browser-supplied
   `to_profile_id` and `expected_revision` are ignored. A forged
   `confirm_switch` with no review does nothing.
7. **Results:**
   - an Ash Invalid that is stale → a reload prompt;
   - `{:error, :switch_open}` → its message;
   - `:coordinator_not_ready` → its message;
   - every message comes from the mapping, never from `inspect`.

**The resolver:**
8. **The facts:** every covered start (nil identity shows "not
   recorded"), and the lease kind. `:observation_unknown` shows a message.
9. **The confirmation:** the button enables only for the exact text. A
   forced submit of a wrong text is refused by the page: no call to the
   domain (traced), `#resolution-mismatch` without the text, still
   `:editing` with the same attestation id, the input cleared. The exact
   text is then sent as the operator's own bytes. (Amended for D-141: the
   verified RED expected the server's `:attestation_invalid`.)
10. **Frozen states:** while `:submitting` and `:uncertain`:
    - an audit refresh and a manual refresh leave the attestation id,
      facts and statement unchanged;
    - a duplicate click sends nothing;
    - no second review opens.

    "Check again" after `:resolve_uncertain` resends exactly the same
    identity, and that is a replay or a settlement.
10a. **A refused retry after uncertainty:** attempt A comes back
     `:resolve_uncertain`. "Check again" (B) is barriered after its caller
     replay lookup. A then commits, and B expires with `:resolve_timeout`.
     The page must show the unknown-outcome wording, never "Not recorded".
     It keeps the same id, opens no new review, and returns to
     `:uncertain`. A further "Check again" shows the recorded result
     (replay). Duplicate "Check again" clicks while B is in flight send
     nothing.
11. **Stale facts:** in `:editing`, a refresh that changes the facts clears
    the input and asks for a new review.
12. **Forged and terminal:**
    - a forged `confirm_resolution` with no review does nothing;
    - after a terminal result, a new resolution needs a new review, id and
      confirmation. (Amended for D-141: the terminal result comes from a
      server refusal of the exact text, such as `:stale_attestation`, not
      from a wrong text.)
13. **Results:** each result in section 3 shows its message. A resolution
    never shows "ready".
14. **Reconnect:** a remount re-reads the stored state, and no
    attestation is invented or submitted.
15. **Never logged:** the confirmation text is absent from captured logs
    (LiveView and Phoenix at `:debug`) on change, submit and refusal, and
    is absent from URLs, stored rows (audit payloads included), the
    captured application telemetry and exported spans. Phoenix LiveView's
    in-process `handle_event` telemetry carries the params by design and is
    excluded (section 3, the telemetry boundary).
15a. **Minimization (D-141):** an arbitrary mismatched canary, typed and
     force-submitted, is never in the socket's assigns or review and is
     never passed to a task, `Agents`, `ProfileSwitches` or the
     coordinator (traced calls). Positive control: the exact text is
     passed, so an empty trace can't pass.
15b. **The tagged channel (ADR-0005 R0-05 amendment):** a channel crash
     while handling `change_resolution` and `confirm_resolution` (the real
     form-encoded payload, valid and mismatched canaries), and while frozen
     in `:submitting` and `:uncertain`. At `:debug` and at `:warning`
     minimum the canary is absent from the captured message, report,
     format arguments and metadata; the fixed diagnostic is present at its
     level. Controls: an untagged crash keeps its report; the C4
     database-error path is unchanged; a tagged `:info` event is unchanged;
     a failed classification is replaced; the filter stays attached.
15c. **The accepted limit (shown, not asserted absent):** a
     supervisor-emitted report about the tagged channel is not classified.
     This pins D-141's residual; no absence assertion is weakened for it.
16. **The lag:** an audit event commits before the coordinator publishes.
    The card shows the earlier observation, and a manual refresh then
    shows the newer state.

**Access:**
17. Reviewers, auditors, a demoted admin and a signed-out user are
    redirected. No event reaches the domain (allow and deny pairs).

**The owner tries it (acceptance, by hand).** The owner runs the dev app
with ClaudeCLI on their own checkout, at a time they choose, and:
- sees the card;
- requests a switch Opus → Sonnet and back;
- sees no model call.

No grant attempt is spent: a switch makes no model call. The agents
never run it.

## Open questions

- **OQ-1 (Codex, accepted for R0):** audit-event refresh plus the manual
  button, with the lag qualification in section 1. No coordinator PubSub
  is added.
