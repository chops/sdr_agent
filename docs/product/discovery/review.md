# Discovery review and scope decisions

What Claude and Codex made of [the owner's answers](answers.md), and what the
owner decided on 2026-10-08. The two reviews were written independently: first
Claude's, then Codex's, the morning of Oct 8 (Codex reply
`845106fe-8702-4ae8-b655-3ec53d2230d7`).

## The tensions Claude found

The answers ask for more than three weeks can deliver, and some of them pull
against each other or against the product's safety rules:

1. **Learning from edits vs an audit-first product.** Automatic learning would
   change the agent's behaviour without review. Proposed instead: versioned
   style changes that are proposed, accepted by a person, evaluated and can be
   rolled back.
2. **Bulk approval vs approval bound to an exact draft.** Bulk approval has to
   become many individual approvals, each still bound to its recipient and
   revision. Risky drafts are excluded from bulk.
3. **"Mostly hands-off" vs "every message approved".** Approval stays
   mandatory, so "hands-off" means alerts plus batch review.
4. **"Interested" replies with proposed times.** This needs calendar access or
   a booking link. The MVP uses a booking link only.
5. **Phone channel.** Call scripts and tasks only, with no dialling.
6. **Finding leads from an ICP.** An ICP gives no contact data and no consent;
   this needs a lawful data source.
7. **Importing your own emails for voice.** The MVP pastes or uploads samples;
   no mailbox connector.
8. **Slack, Telegram, email and desktop alerts.** ADR-0006 only covers
   build-status alerts, so runtime alerts need their own decision.
9. **Open source on a subscription CLI.** Workshop attendees need their own
   model login.
10. **Multi-customer later.** Keep tenancy in the design; no single-tenant
    shortcuts in new code.
11. **Per-region retention.** Needs an erasure design before real data.
12. **Phone review.** Claude first suggested a triage-only phone view.

## Codex's corrections and additions

- **The must-list was not credible** for about 17 working days with serial
  review. Keep a dog-food and recovery buffer.
- **One design day** can settle the core journey and a prototype, not every
  screen and state.
- **The workshop promise** should be a first-touch copilot for solo founders,
  not an autonomous SDR or a SaaS product.
- **Local and private vs phone review away from home.** These conflict. A
  responsive layout alone is not remote access.
- **Phone review** needs the full approval context, so it cannot be a stripped
  triage view.
- **Measure only what can be observed.** With sending captured, reply, meeting
  and pipeline numbers cannot be claimed.
- **Must:**
  - one import path;
  - a minimal campaign/ICP setup with brand guidelines;
  - bounded live research;
  - an evidence-backed draft;
  - individual review and edit;
  - captured delivery with clear recovery;
  - an interested-reply draft with a booking link that never claims specific
    free times;
  - a home screen showing real vs fake provider, the action queue,
    risk/evidence, budget and unknown outcomes.
- **Later:**
  - bulk approve;
  - AI edit suggestions;
  - adaptive learning;
  - phone scripts;
  - external notifications;
  - lead discovery and enrichment;
  - custom model tiers;
  - broad analytics.
- **Live web research** needs SSRF-safe fetching, fencing of untrusted text,
  immutable citations and injection evals.
- **Sending to the owner's own inbox** stays prohibited without an explicit
  charter amendment.
- **US and Canadian real data** needs privacy and erasure decisions (including
  personal data in the audit trail), suppression, and a check of the applicable
  outreach law. A written retention policy alone is not enough.

## What the owner decided (2026-10-08, chat)

| Question | Decision |
|---|---|
| Workshop promise | **First-touch copilot** for solo founders |
| Phone | **Desktop only** for this release. Screens may be responsive, but no remote access. |
| Delivery | **Captured only.** No self-send and no charter amendment. |
| HubSpot | **Optional, gated add-on.** CSV and manual entry were named as the core lead sources. Neither exists in the prototype today (only a synthetic seed); the workshop core picks one at G2, with the seed as fallback. |

## How this feeds the next steps

- The [outcome brief](../brief.md) turns the answers and these decisions into
  outcomes, non-goals and assumptions.
- The [story map](../story-map.md) lays out the core journey and marks the
  workshop slice.
- The items marked "later" above are recorded as non-goals for this release
  (NG-n in the brief), not dropped. Each needs its own decision before it
  returns.
