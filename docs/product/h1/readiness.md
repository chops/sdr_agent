# H1 Home inbox: owner-review packet

Status: **draft 1, entity/action review requested; H1 G5 not approved**.
Author Codex, independent reviewer Claude, under owner D-154. This is a
packet, not a screen implementation or a request to make a model call.
Baseline: main `6f271abef7b3cfefa2c7eb6defcb07602c003181` (C1-02 reads
merged; C1-03 commands not implemented). D-155 retains the full Nov 6 core,
including B2; this packet moves no RC, S6 or acceptance date.

## Outcome and limits

The owner opens Home to decide what needs a human now: review an email,
approve it **for local capture**, edit or reject it, or inspect a failure
and explicitly re-run only when its source recovery rules permit. Home is
an inbox, not a second task database or a replacement for the agent doing
research. Provider status and budgets remain outside the task list.

Initial coverage is the two producers and three exact metrics in the
[accepted C1 contract](../c1/readiness.md). H1 does not add producers for
unbuilt channels, imply real-email delivery, start research/model work on
page load, settle unknown invocations or change grants. Real-data activation
and B1 end-to-end acceptance remain separate. No G-DEMO authority is
created, used or requested by this packet.

## What is already accepted, and what is not

- The owner selected concept A, collapsible navigation, an explicit email
  comparison, and the compact phone behavior. The static preview at
  `0b740d87a686532de84ae0a8ba5a7d08441a704a`
  (`docs/product/h1/concept-a*.html` on branch `h1-concept-a`) is the visual
  reference, not runtime or backend evidence. It is not on this baseline;
  retrieve that exact artifact rather than inventing a replacement layout.
- That walk was prompted. It did not prove uncoached usability. A new
  neutral task walk and keyboard/accessibility check remain H1 obligations.
- ADR-0015 and scoped C1 G5 cover C1-02/03, **not H1 screens**. D-154
  authorizes this packet, not an inferred H1 implementation approval.
- C1-03's slice A plan/RED passed Claude review (`c0d042d9`); its retry
  slice B still needs its separate preview/eligibility contract. Neither
  adapter is claimed present on main.
- Reviewer gen-2 projection withholding (#152) remains. H1 must consume
  real-data withholding (#153), not bypass it to populate the prototype.

## Entity Model

Entity Model trigger: **yes**.
Reason: a new UI consumer holds review/input state and exact command
bindings, and needs a source-authorized detail/comparison read contract.
No new persisted entity, attribute, session, role or task lifecycle.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy/Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| Home page observation | Existing C1 projection, new consumer contract | Render bounded current work and exact totals | Existing page items, cursor, completeness, errors, per-metric value/status/observed_at; no persisted cache | Consumes the two fixed C1 producers and three metric readers; never queries resources directly | First load is loading, not empty. Refresh clears stale action authority immediately. Later cursor pages are not whole-queue emptiness. Old response cannot overwrite a newer request or scope | Current authenticated human; current session/tenant/role remains authoritative; auditor post-read audit must succeed before display | No new producer or metric; required coverage stays explicit |
| Home review snapshot / comparison | New ephemeral value object | Show exactly what the user is deciding about and what changed since that displayed review | Server-held item/source id, token, revision id/hash, exact displayed email/channel and authorized current subject/body; optional earlier snapshot actually shown in this same connected session; no last-viewed column | References one immutable DraftRevision and its current source context; no new FK/ownership. Both sides must remain authorized and released before a comparison is rendered | Detail is loaded only on an explicit review, never into list/count reads. Bind displayed content to its immutable revision/hash and the recipient context in one reviewed source read; an inconsistent read is unavailable, never a fresh review. Comparison is deterministic, escaped text, not an LLM call; missing baseline means 'Previous review unavailable', not invented N-1 history. No persisted historical recipient snapshot or cross-session last-opened history is promised | Same current source read, release, synthetic and real-data constraints as C1; revalidate both snapshots before redisplay. Reviewer #152 and real-data #153 withholding applies to detail and diff too | Exact source-owned detail API/query/recipient consistency contract needs separate review after this entity gate, before RED; do not assume the static preview proves it exists |
| Home edit / command interaction | New ephemeral consumer state | Preserve the user's exact reviewed decision through a write | Server-held source/item/token/binding and permitted edit or rejection fields; request generation/ref, phase loading/reviewing/editing/submitting/uncertain/terminal; no durable command receipt | Calls only the fixed C1-03 gateway; retry binds the displayed Failure, never a browser-selected run. Ack/resolve use existing authorized source navigation | No browser-supplied actor, tenant, module, URL or replacement binding. Freeze submitted binding and disable duplicate dispatch. Committed result triggers fresh projection, never optimistic deletion. Source refusal does not silently retarget input. Lost reply/task exit/producer_error may have committed: show uncertainty, never claim rollback or automatically resubmit. Reconnect discards socket-only input and reads source; it does not claim the old command failed or replay it | Current authenticated human on every event and completion; source domain rechecks current actor and locks. Admin/reviewer draft actions only as permitted; retry active admin only; auditor read-only | Reuse C1-03 closed outcome categories and stale-for-duplicate behavior; exact event/task state machine is reviewed before RED |
| Sensitive Home process input | Existing privacy boundary, new participant | Keep edits, reasons and displayed content out of automatic diagnostics | Existing process metadata sdr_sensitive_input: true; no new content-bearing log field | Connected Home process and every child task that can hold operator/content input use accepted ADR-0005 protections | Tag before first input/content enters and never clear while the process may retain it. Tasks tag themselves before receiving sensitive payload; inheritance is not assumed. No raw content in task exits, telemetry, inspect-based diagnostics or URL/query string | Existing exception filter, source audit payload rules and authenticated session checks remain; no logging-policy bypass | Confirm that use fits accepted ADR-0005 participant scope; amend for owner acceptance before implementation if it does not |
| InboxItem / InboxCommand / source draft, Failure and retry actions | Existing dependency | Existing source truth, command authority and audit | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. H1 consumes C1-03; it adds no source mutation, automatic retry, settlement, refund, grant or Reaper operation | Source ownership, read/write policies, guarded denial audit and exact freshness rules unchanged | Any new source action or changed command semantics returns for its own delta |
| Accounts session / Tenant / model release and grant ledgers | Existing dependency | Authentication and existing data/spend boundaries | unchanged | unchanged | existing dependency: unchanged — relationship/policy/lifecycle impact checked, none found. Home does not become an attestation, grant selector, model launcher or release authority | Existing policies and current user-token authentication unchanged | none |

Configured capabilities: `.workflow/recipe.json` has `ai_pair=true` and
`codex_review=true`. Reviewer precedence: ai-pair, **Claude**. Verdict:
**UNREVIEWED**. No affected-module design or H1 RED starts before PASS;
owner G5 and the detailed producer-consumer plan are additional gates.

## Display and interaction contract

1. Keep the selected concept A hierarchy: collapsible navigation, three
   compact exact tiles, bounded task rows and a review area. Use current
   email, failure and capture nouns, not a count of distinct people.
2. Tiles read **Pending email drafts**, **Live failures** and **Local
   captures this week**. A value is exact for its authorized observation,
   not the page length. A failed read shows unavailable with no old/zero/
   estimated number. Capture is history, not pending work or external send.
3. Mixed observations are labeled honestly; a tile is not a transactionally
   simultaneous snapshot of all rows. Counts never enable a command.
4. Draft rows open a deliberate review of the exact email and recipient.
   The primary approval label remains **Approve for local capture**.
   Editing shows subject/body and the existing permitted optional fields;
   rejection requires a note. Review content is escaped, never trusted HTML.
5. What changed compares the user's actually shown baseline to the current
   authorized revision, including multiple intervening edits when known.
   Recipient differences can use only the earlier displayed recipient and
   current reviewed context, never a fabricated historical revision field.
   Show complete current email independently of the comparison; color is
   not the sole addition/removal signal. Comparing never approves.
6. Refresh during editing does not overwrite typed content or substitute
   the latest token. Show source-changed state; require an explicit new
   review before applying text to a new revision/recipient. Confirmation
   dispatches the frozen reviewed command only once.
7. On committed approval/rejection, refresh source membership; while the
   refresh fails, retain a safe committed-outcome notice but no stale
   enabled row. On successful edit, load and review the new revision before
   any approval. No 'already applied' assertion from matching text alone.
8. A lost command reply is **Outcome not confirmed**. Refresh is read-only,
   not a hidden retry. A changed source can be shown as current state,
   not proof which writer committed. An unchanged source after a read is
   not proof an in-flight transaction rolled back; keep re-dispatch held
   until a reviewed settlement rule or a definite command outcome exists.
9. Failure rows keep distinct live causes separate. Acknowledged remains
   pending. Inspect/acknowledge/resolve navigate to existing source screens;
   no new in-row gateway actions for those are implied. Explicit retry
   shows its current block or a separate human confirmation, and calls
   C1-03 only after slice B is merged. Unknown/reserved/sent blocks remain
   even on terminal runs, independently of E1 ledger normalization.
10. A partial producer/metric read is visible alongside healthy fresh rows.
    Withheld is not empty. The initial all-clear is only **No drafts or
    failures need your attention in this view**, after the complete first
    page has no cursor and both pending totals are ready at zero; required
    capture-history read must also succeed. Later pages say **No more
    items**. Never claim every future founder task is covered.
11. A rejected session/scope clears rows, numbers, review content, input and
    pending completion authority, then follows existing sign-in behavior.
    Demotion during a task cannot restore old controls or content. Returned
    or raised errors expose fixed safe copy, not raw domain exceptions.
12. Move the existing dashboard/status experience to a separately named
    Status destination when Home owns `/`; do not silently delete useful
    runtime information or duplicate budget/profile mutation controls.
    Exact route migration and navigation are plan-review items, not code
    authorized by this packet.

## Owner task walk and G5 request

Use only isolated synthetic examples. No live model, grant edit, external
delivery, owner database or private witness-store read is part of the walk.
The static comparison examples remain fictional, not source-history proof.

Ask neutral prompts, record the owner's first action, expectation and
confusion before explaining anything. Do not pre-teach the correct action.

| Scenario | Neutral task | Evidence to record |
|---|---|---|
| Fresh email | Decide what you would do with this email | Chosen action and what the owner expects it to cause; do not supply the capture answer |
| Concurrent edit/recipient change | You return to an email after someone else changed it. Continue your review | Whether the owner finds both current content and changes and notices the recipient; no coached approval |
| Blocked recovery | This task says a previous run stopped. Decide what to do next | Whether the block and source inspection route are understandable; no suggestion to bypass it |
| Partial/unavailable | You open this Home state. Tell us what you know and what you would do | Distinguishes unavailable totals/coverage from zero/complete |
| Quiet first page and later page | Examine each empty view | Distinguishes scoped initial empty, no more rows and hidden/withheld coverage |
| Phone + keyboard | Complete the same review on a narrow view and using keyboard only | Focus order/visible focus, labels, expand/collapse, comparison access, reachable controls, no horizontal overflow |

Separate walkthrough evidence from the owner's decision. G5 asks approval
to implement only this initial Home scope, using merged C1 contracts and
the selected visual direction. It excludes new producers/channels, real
data, ordinary-call enablement, model spend and B1 product acceptance.
Any owner change to the source contract or scope returns for review.

## Gates, tests and handoff

Before H1 RED: entity/action PASS; any necessary privacy ADR amendment
accepted; exact detail/comparison and event-state plan reviewed; owner H1
G5 recorded; C1-03 required slice(s) merged. Authoring this packet does not
authorize building around an unmerged consumer contract.

Required RED cases include real allowed and denied roles; stale revision
and recipient; duplicate submission; revocation/demotion while waiting;
old refresh/task completion arriving last; count-only and list failures;
auditor audit withholding; #152 and #153 withholding for rows/detail/diff;
uncertain write with late commit and unchanged intermediate read;
reconnect without replay; canary operator/model content in actual crash/
task/logger paths; scoped empty and pagination; accessible desktop/phone
interactions. Use real source APIs with synthetic fixtures; no all-blocked
dispatcher or static screenshot substitutes for executable behavior.

After independently verified RED: minimal GREEN, focused/full gate,
architecture evaluation for Home/status runtime paths, peer code review,
exact-head CI, owner merge and uncoached hands-on acceptance. H1 cannot be
reported complete merely because its packet, prototype or backend passed.

ADR evaluation: ADR-0015 already owns stateless source projection and fixed
commands. No new durable boundary is proposed here. The participant-scope
question for ADR-0005 above is open; no claim that a new privacy mechanism
is preaccepted. No architecture diagram is changed for this docs-only draft.

Owner Codex prepares the packet and implementation; Claude reviews. Current
next action: independent entity/consumer review, then exact module plan and
an explicit owner G5 request. No dates, approvals or test results inferred.
