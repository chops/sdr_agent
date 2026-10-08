# Decision log

Owner decisions that shaped the product and the process, newest last. Each
entry says what was decided, why, and what was rejected. Architecture decisions
with lasting technical consequences also get an ADR in [`../adr/`](../adr/);
this log links to it.

Only the owner makes these decisions. Claude and Codex propose options and
recommend one; an entry is added only after the owner says yes in chat or in a
committed feedback file.

| ID | Date | Decision | Why | Rejected alternatives | Record |
|---|---|---|---|---|---|
| D-001 | 2026-10-06 | Build the MVP unattended, with Claude and Codex deciding inside a written mandate and Codex consulted on every firm decision. | Owner wanted the build to run without them between checkpoints. | Owner approving every architectural step. | [ADR-0001](../adr/0001-unattended-build-operating-charter.md) |
| D-002 | 2026-10-06 | The real model is the Claude CLI on the owner's own subscription, with tools, plugins and slash commands disabled and checked on every call. | The planned login was unavailable; an API key was not wanted. | Codex app server (could not disable built-in tools); paid API. | [ADR-0004](../adr/0004-model-provider.md) |
| D-003 | 2026-10-06 | Runtime alerts stay in the app; no outside messages about leads. The same person may edit and approve a draft. Interested replies are classified and handed to a human, not answered. A read-only Auditor role is added. | Keep personal data inside the app; one-person team; human owns every reply. | External alerts; separate editor and approver; agent-drafted replies to interested leads. | [ADR-0006](../adr/0006-telegram-outbound-notifications.md) |
| D-004 | 2026-10-07 | Keep the wire witness (S12) in the MVP and delay the demo until it is done. | Owner valued the integrity guarantee over an earlier demo. | Demo without S12. | `notes/features/s12-wire-witness.org` |
| D-005 | 2026-10-07 | Demo before 18:00. Show quiet hours by preparing deliveries and displaying the deferral. | Meetup timing; quiet hours start at 18:00 Denver time. | Overriding quiet hours for the demo. | Chat |
| D-006 | 2026-10-07 | After the demo, prioritise product quality over new features. | Demo done; owner wants a product, not a demo. | Continue building features. | Chat |
| D-007 | 2026-10-07 | The app stays a personal, local demo and test app run with the owner's own credentials. No switch to the paid API. | Owner use only; terms of the subscription CLI fit personal local use. | Switching to the API now. | ADR-0004 amendment pending |
| D-008 | 2026-10-07 | Integrate HubSpot using a free developer test account and a service key. Leads are created automatically by rule. HubSpot wins conflicts on contact and company fields. | Likely production CRM; test portal holds only synthetic data. | Private app token; manual lead creation; the app winning conflicts. | PR #29 (ADR-0013, proposed, paused) |
| D-009 | 2026-10-07 | Reject the build-first development plan. Define features, functionality and the operator experience before more production work. Feature freeze. | The product was being built before it was defined. | Continue with the build plan. | Chat; this folder |
| D-010 | 2026-10-08 | Workshop promise: a first-touch copilot for solo founders. Desktop only for this release. Emails captured, never sent. HubSpot is an optional add-on; CSV and manual entry are the core lead sources. | Fit a credible scope into the time before Nov 6; keep real recipients out of reach. | Broader SDR demo; phone review over a private network; sending to the owner's own inbox; HubSpot as a dependency. | `../product/discovery/` (to be committed) |
| D-011 | 2026-10-08 | Spend the fourth and last approved real model call on a smoke test of the child-process secret scrub. | Confirm the real CLI still works with the new environment allowlist. | Leaving it unverified. | Chat; smoke test passed 08:11 |
| D-012 | 2026-10-08 | Run a traditional SDLC, worked through by the owner, Claude and Codex together, with durable interactive artifacts committed to git. | Turn the prototype into a product deliberately, and show founders how. | Continuing ad hoc. | This folder; **pending G0 approval of the details** |
