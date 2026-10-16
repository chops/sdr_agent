# R0-05 interface: the admin model card, switch and resolver UI

**Status:** draft 1, 2026-10-15, for Codex's interface review. Issue #53.
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
| As of | `published_at` | "status published <time>". The card says the status can lag and is not a guarantee (C2-02c section 2) |
| Last check | `attestation` | unchanged: the last per-call init attestation with its time, or "not yet attested" |

**Rules:**
- **No guessed values:** `:unknown` and `:unavailable` show as "unknown",
  never the default profile.
- **A held server never reads as ready.** Lines with no data show
  "unknown", never a blank or a default.

**The `:cleanup_unprovable` banner:** "A model server's cleanup can't be
confirmed. Calls stay paused. An operator must check the machine and
release the old reaper's lease from a console; the app then restarts the
server by itself." The page has no button for it.

**Refresh:**
- **On audit events:** the card re-reads `Runtime.status/0` through the
  existing `SdrAgentWeb.LiveRefresh` whenever an audit event commits.
  Switch requests, blocks, completions, failures, resolutions and start
  transitions are all audited.
- **The "Refresh status" button** re-reads it on demand.
- **No timer** and no polling.

Rendering calls only `Runtime.status/0`, which makes no database query
and no coordinator call (C2-02c).

## 2. Requesting a switch

**The control.** "Change model profile" shows only when all of these hold
in the last status read:
- the provider is ClaudeCLI;
- `desired_profile` is confirmed;
- `switch` is `%{state: :none}`.

**It shows nothing when:**
- a switch is open (the open-switch line shows instead);
- the desired profile or switch is unknown (with "status unknown;
  refresh");
- the provider is the Fake.

**Steps**, on the C9-05 `GrantForm` pattern: staged in the page, with no
browser dialog.
1. **Choose.** A select of the reviewed real profiles, excluding the
   desired one (`ModelProfiles.real_ids/0`).
2. **Review.** "Switch from <desired> to <target>." Then: "Calls in
   progress finish first. While the switch runs, new calls are paused.
   The new profile is checked without a model call. If it can't start
   cleanly, the app returns to <desired>, or blocks the switch for you to
   resolve." It also shows the setting revision the admin saw. The socket
   holds `%{to_profile_id, expected_revision}`.
3. **Confirm.** This acts only on the socket's review state. A forged
   `confirm_switch` with no review step does nothing. It calls
   `Coordinator.request_switch/2` as the signed-in user.

**Results:**

| Result | Shown |
|---|---|
| `{:ok, switch}` | "Switch requested" and the open-switch line. The card updates as the coordinator publishes (C2-02c, the lag intervals) |
| `{:stale_revision, _}` or a revision error | a reload prompt (the GrantForm stale pattern); nothing retried by itself |
| an open-switch conflict (`:switch_blocked` or an open-switch refusal) | "Another switch is open", and a re-read |
| `{:error, :coordinator_not_ready}` | "The model server isn't ready to switch; try again shortly" |
| Forbidden | the domain refusal. A demoted or signed-out user is already redirected by `LiveUserAuth` before any event reaches the domain |
| any other error | its message, next to the control |

## 3. Resolving a blocked switch

**When it shows:** "Resolve blocked switch" appears when `switch` is
`%{state: :open, status: :blocked}`.

**Steps:**
1. **Facts.** Opening the control calls `Agents.blocked_switch_facts/2`,
   as the user. It shows:
   - the switch (from, to, the block reason in words, when it was
     requested and by whom);
   - every covered start (generation, reason, profile, status, and its
     recorded pid, node and reaper, or "not recorded");
   - the observed lease kind in words.

   `{:error, :observation_unknown}` → "The server's state can't be read
   right now; try again." There is no confirmation step.
2. **The statement and the typed confirmation.** The page shows the b2β
   section 3 statement word for word, and a text input. The confirm
   button enables only while the input is exactly `STOPPED <switch id>`.
   The server checks it again, so the client check is only convenience.
3. **Confirm.** The socket holds the facts it showed (`attested_start_id`,
   `attested_generation`, `attested_lease_kind`) and an `attestation_id`
   generated **once** when the review opened. A forged
   `confirm_resolution` with no review state does nothing. It calls
   `Agents.resolve_blocked_switch/3` as the user, with outcome `:failed`.

**Results** (b2β section 1):

| Result | Shown |
|---|---|
| `{:ok, %{switch: s}}` | "Switch resolved as failed. Calls stay paused until the server restarts cleanly." It never says ready. The card follows the status |
| `{:ok, %{replay: true}}` | the same message ("already recorded") |
| `:resolve_uncertain` | "The result isn't known yet." A "Check again" button resends **the same** `attestation_id` and facts, which is a replay or a settlement. It is never a new id |
| `:resolve_timeout` | "Not recorded. Try again." This starts a new review with a new id |
| `:stale_attestation`, `:live_work_observed`, `:observation_unknown`, `:coordinator_busy` | the refusal in words, and a fresh facts read; nothing kept |
| `:attestation_invalid`, `:attestation_conflict`, `:switch_not_blocked` | the refusal in words, and a re-read |
| Forbidden or NotFound | the refusal |

**Safety:**
- The UI never shows a lease release action.
- The confirmation text is never logged: the form parameter is filtered,
  like `settings_content` in C4.
- The confirmation text is never put in a URL.

## 4. Access

- **Who:** the page stays admin-only (`LiveUserAuth` `{:roles,
  [:admin]}`). Every action is re-authorized by the domain with the role
  re-read.
- **Non-admins:** reviewers, auditors and signed-out users are redirected
  before any event reaches the domain (the existing pattern).

## Entity Model

**Entity Model trigger: no.** Reason:
- no new or changed attributes, relationships, calculations, aggregates,
  policies, actions or backend event contracts;
- R0-05 is LiveView UI over the existing, reviewed domain and runtime
  APIs: `Runtime.status/0` (C2-02c), `request_switch/2` (b2α), and
  `blocked_switch_facts/2` and `resolve_blocked_switch/3` (b2β).

## ADR evaluation

None. This is within ADR-0004's status card and the C2-02b2 and b2β
amendments.

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
4. **The control shows** only under the conditions in section 2.
5. **Choose, review, confirm** calls `request_switch/2` with the target
   and the revision seen. The open-switch line appears.
6. **A forged `confirm_switch`** with no review state does nothing.
7. **Stale revision** → a reload prompt with nothing retried;
   `:coordinator_not_ready` → its message; an open-switch conflict → its
   message.

**The resolver:**
8. **The facts** render every covered start, with "not recorded" for nil
   identity, and the lease kind. `:observation_unknown` → a message with
   no confirmation step.
9. **The confirmation:** the button enables only for the exact text. A
   server refusal of a wrong text shows `:attestation_invalid`.
10. **Confirm** calls `resolve_blocked_switch/3` with the facts shown and
    one `attestation_id`. "Check again" after `:resolve_uncertain` resends
    the same id and facts.
11. **A forged `confirm_resolution`** with no review state does nothing.
12. **Results:** each one in section 3 shows its message. A resolution
    never shows "ready".
13. **Never logged:** the confirmation text doesn't appear in captured
    logs (LiveView and Phoenix at `:debug`), and the form parameter is
    filtered.

**Access:**
14. Reviewers, auditors, a demoted admin and a signed-out user are
    redirected. No event reaches the domain (allow and deny pairs).

**The owner tries it (acceptance, by hand).** The owner runs the dev app
with ClaudeCLI on their own checkout, at a time they choose, and:
- sees the card;
- requests a switch Opus → Sonnet and back;
- sees no model call.

No grant attempt is spent: a switch makes no model call. The agents
never run it.

## Open questions

- **OQ-1 (for Codex):** is refresh on audit events plus a manual button
  enough? Or should the card refresh on coordinator publications (a
  PubSub broadcast from `publish/1`), so a hold release with no audit
  event is visible? **Recommendation: audit events plus the button,**
  since every lifecycle step is audited. Any gap shows the "as of" time
  honestly.
