# Outcome brief: SDR Agent workshop release

- **Status:** draft for gate G1. Revised 2026-10-08 after Codex review of
  `8e08d0a`, then again after the owner's notes on the shaping discussion
  page (2026-10-08, 13:15 to 13:32 MDT).
- **Method step:** 1, outcomes and today's workflow.
- **Sources:** [owner answers](discovery/answers.md),
  [review and scope decisions](discovery/review.md), the owner's shaping-page
  notes (quoted below with permission, decision D-018), and the
  founder-interview notes, which are **still pending** (see "Today's
  workflow").
- **Where to answer:** open owner decisions for this packet now live on one
  page, the owner decisions page (`docs/product/decisions/index.html`).

## In one sentence

SDR Agent is a first-touch copilot that lets a solo founder turn a short list
of target companies into researched, evidence-backed first emails they have
personally approved, with a full record of how each one was made.

## Who and when

- **User:** a solo founder or operator doing their own outbound. No team.
  Today that is the owner.
- **Workshop (Nov 6):** the owner gives a **live demo**, then walks the room
  through the **documented process of building it**, including the missteps.
  Attendees do not install or run it for the workshop (NG-16). The open-source
  repository and its build record are the evidence they take away (OUT-8).
  In the owner's words: "the workshop will show a live demo and then follow up
  the demo with the process we're going through to build this agent ... we
  need to document all of the steps (and missteps) we take to get from here
  and now to demo day."
- **Situation:** they have a product and an idea of who should buy it. They
  have a handful of target companies, from a spreadsheet, a CRM or memory, and
  limited hours for outreach that has to sound like them and be accurate.
- **Job to be done:** "When I sit down to do outbound, help me go from a list
  of companies to first emails I would actually send, quickly, without
  inventing facts or losing control of what goes out."

## Outcomes

Each outcome is observable in the workshop release. Delivery is captured, not
sent, so nothing below claims replies, meetings or pipeline. Targets and
thresholds are set at G2 and in the eval plan, not here.

| ID | Outcome | How we observe it |
|---|---|---|
| OUT-1 | **Prepared faster.** The founder gets a reviewed first email for each target company with less of their own time than by hand. | The founder's **active** time (not model or queue time) from loading N companies to N approved drafts, on matched tasks of the same size, compared with a measured manual baseline. "Faster" is a hypothesis until that baseline exists (pending the owner's walkthrough or founder notes). |
| OUT-2 | **Credible.** Every factual claim in a draft points to evidence the founder can open. | **Factual-claim coverage:** the share of factual claims (not greetings or calls to action) that carry a citation, plus a sampled check that each cited source actually supports its claim in context. Unsupported claims are flagged before review. |
| OUT-3 | **In control.** Nothing is captured for delivery without the founder approving that exact draft for that exact recipient. | Approval binding enforced in the domain; refused stale approvals are visible. Already true in the prototype. |
| OUT-4 | **Sounds like them.** Drafts follow the campaign's brand guidelines and the founder's writing samples. | A tone and grounding rubric applied to sampled drafts, plus observed review tasks. Approval rate and edit size are **indicators only**: they fall when drafts improve but also when review gets careless, and they rise for legitimate corrections. |
| OUT-5 | **Knows what happened.** The founder can see what the agent did, what it used and what failed, and recover without guessing. | Home shows the action queue, provider (real or fake), budget and unknown outcomes; every failure has a next step. "What it used" means recorded model calls and tokens, not a dollar figure: the subscription CLI gives no reliable per-draft price. |
| OUT-6 | **Handles "interested".** An interested reply produces a drafted response with the founder's booking link, for approval. | In acceptance, a **simulated, signed test reply** classified as interested gets a draft within one run, and the draft never asserts specific free times. Captured delivery produces no real replies. Today's prototype only classifies and hands off, so this is new work. |
| OUT-7 | **Runs locally, described honestly.** The app and its data live on the founder's machine. | A fresh install from the repository's guide, on a clean machine, reaches a first approved draft in **fake-model mode on synthetic data**; this is for readers of the open-source repository, not a workshop step (NG-16). With real inference turned on, permitted draft content is sent to an external model provider through the proxy: local does not mean no data leaves the machine. A real-model run on anyone else's login is **not** a release criterion (NG-15). |
| OUT-8 | **The build story is documented.** Founders can follow how the product went from a one-shot demo to a working release, including what went wrong. | The public repository holds, for every phase up to demo day: the project journal with a retrospective per phase, the decision log, a gate record per gate, the review findings and how each was handled, and an honest list of missteps. Checked at G8 against the phases actually run; nothing is rewritten after the fact. |

## Non-goals for this release

These came from the owner's answers but are deliberately left out. Each needs
its own decision to come back.

| ID | Not in the workshop release | Why |
|---|---|---|
| NG-1 | Sending real email, including to the owner's own inbox | Captured delivery only (owner decision, Oct 8) |
| NG-2 | Finding leads from an ICP | An ICP gives no contact data or consent; needs a lawful source |
| NG-3 | Bulk approval | Needs per-draft binding, risk exclusion and partial-failure design |
| NG-4 | Learning automatically from edits | Must become proposed, accepted, versioned style changes |
| NG-5 | AI suggestions while editing | Later convenience; not core to trust |
| NG-6 | Phone channel (call scripts and tasks) | Second channel; email first |
| NG-7 | Slack, Telegram, email-digest or desktop alerts | Need a separate decision; alerts stay in the app |
| NG-8 | Phone review, remote access | Desktop only (owner decision, Oct 8) |
| NG-9 | Built-in scheduling or calendar access | Booking link only; no calendar API |
| NG-10 | Reply, meeting or pipeline metrics | Not observable with captured delivery |
| NG-11 | Real prospects' personal data | Needs lawful-source, privacy, retention, erasure and outreach-law decisions. The owner once tied this to HubSpot working; an optional HubSpot import does not by itself authorize real data. |
| NG-12 | Multi-customer hosting | Local personal app; keep the design tenancy-ready |
| NG-13 | Per-campaign model cost tiers and personalization-depth settings | Later; one sensible default for the workshop |
| NG-14 | Attendees loading their own prospect lists | Release constraint: synthetic or owner-provided test data only. Every intake path admits only reserved synthetic or owner test contacts. |
| NG-15 | Attendees using a real model on their own login, as a release promise | ADR-0004 covers only the owner's personal local use. Other people's use needs a reviewed provider, terms and budget decision first. |
| NG-16 | Attendees installing or running it for the workshop | Owner decision (shaping page, 2026-10-08): the workshop is a live demo plus the build story. An install guide still exists for readers of the open-source repository (OUT-7). |

## Primary input: the owner's feature vision

The owner already knows what the MVP should do and which premium features
could follow it. In the owner's words: "instead of relying on claude and
codex to suggest features and functionalities based on \"today's workflow\",
i have a pretty good idea of what i want the MVP to do, as well as what
premium features we could release post-MVP."

So the must-list starts from the owner's feature list, captured on the owner
decisions page ("Your MVP and post-MVP features"). The outcomes, story map and
failure cases above are our draft for the owner to check against that list,
not a substitute for it. Founder evidence (next section) supports or
challenges the list; it does not generate it.

## Today's workflow (supporting evidence)

**Pending.** The owner has notes from a conversation with one other solo
founder. Until those notes are in, this section has no evidence and invents
none. We do not infer anyone's routine from the tools they benchmark against
(Apollo, Outreach, HubSpot sequences and Breeze agents).

When notes arrive we record:

- how that founder does outbound today: tools, steps, time taken;
- what is painful or slow;
- what they would need to trust a drafted email;
- **what kind of evidence it is:** an interview, a reaction to a demo, or
  watched tasks. Each supports different claims, and only watched tasks say
  anything about usability.

**Owner decision at G1.** Either:

1. paste the founder notes and say what kind of evidence they are; or
2. walk through your own current outbound routine on the shaping page, and
   accept this evidence limit for the first scope: "the owner's own routine
   plus one founder conversation of unclassified type; outside-user evidence
   is limited."

The reviewer does not manufacture confidence either way.

## Assumptions to check

| ID | We assume | How we find out |
|---|---|---|
| AS-1 | A solo founder starts from a short list (5 to 20 companies), not a large database. | Founder notes; the owner's walkthrough on the shaping page |
| AS-2 | Evidence they can open builds more trust than a confident score. | Prototype task test: do they open citations before approving? |
| AS-3 | Reviewing one draft at a time is acceptable for 10 to 20 drafts. | Prototype timing with the owner |
| AS-4 | Brand guidelines plus pasted writing samples are enough to set the voice. | Tone and grounding rubric on the owner's own campaign, with approval rate and edit size as indicators |
| AS-5 | One intake path (CSV upload or add-by-hand) plus the synthetic seed covers the workshop. | Owner choice at G2; founder notes |
| AS-6 | *Superseded 2026-10-08 by AS-8 (owner: no attendee install).* Workshop founders are satisfied by the owner's demo plus an optional fake-model install on synthetic data. | Not checked; kept for history |
| AS-7 | Captured (not sent) emails are still a convincing demo. | Owner judgment at G8; workshop feedback |
| AS-8 | A live demo plus the documented build story, including missteps, is what workshop founders value most. | Owner judgment at G8; workshop feedback; which parts of the build record attendees open afterwards |

## Domain language (domain-driven design)

The owner suggested describing the product with domain-driven design methods
as well. The code already follows them: each Ash domain is a bounded context
with its own resources, rules and vocabulary, and dependencies point one way
(see [domain boundaries](../architecture/domain-boundaries.md)). P2's event
storming (method step 3) uses these contexts and this vocabulary, and adds
the events and commands between them.

### Bounded contexts

| ID | Context (Ash domain) | What it is responsible for | Main resources |
|---|---|---|---|
| BC-1 | Sales (`SdrAgent.Sales`) | Who is targeted, against which profile, through which program | IcpDefinition, Account, Contact, Lead, Campaign, Sequence, SequenceStep, CampaignEnrollment |
| BC-2 | Research (`SdrAgent.Research`) | The evidence gathered about a lead and the qualification resting on it | ResearchArtifact, EvidenceClaim, Qualification, QualificationEvidence |
| BC-3 | Outreach (`SdrAgent.Outreach`) | What may be sent, to whom, on whose authority, and who must never be contacted | Draft, DraftRevision, RevisionCitation, Approval, Suppression, DeliveryOperation, DeliveryReceipt, SendQuotaDay, Reply, ReplyAssessment |
| BC-4 | Agents (`SdrAgent.Agents`) | Agent provenance: which agent ran, which model calls and decisions it made | AgentDefinition, AgentRun, ModelInvocation, ToolInvocation, Decision, WireWitnessLink |
| BC-5 | Operations (`SdrAgent.Operations`) | Durable background work as operators see it, and failures that need a human | Operation, Failure, WebhookEvent |
| BC-6 | Accounts (`SdrAgent.Accounts`) | Operator identity, sign-in and roles | User, Token |
| BC-7 | Audit (`SdrAgent.Audit`) | The system of record: hash-chained events, payloads, anchors, exports and audited access | AuditEvent, Payload, AuditAccess, AuditAnchor, AuditExport and supporting resources |

### Glossary seed (ubiquitous language)

Words the product, the screens and the code should use the same way. P2
extends this list; a screen label that disagrees with it is a defect.

| Term | Meaning | Context |
|---|---|---|
| Lead | A target contact at a target account, in the pipeline | Sales |
| Campaign | A program with an ICP, voice, sender, time zone and quiet hours | Sales |
| Enrollment | A lead's place in a campaign | Sales |
| Evidence claim | A fact found during research, with its source | Research |
| Draft / revision | A first email; every edit makes a new revision | Outreach |
| Citation | The link from a sentence in a draft to its evidence | Outreach |
| Approval | The owner's consent to capture one exact revision for one exact recipient | Outreach |
| Suppression | A rule that a contact must never be contacted | Outreach |
| Delivery (outbox entry) | One approved email on its way to capture; never sent to a real person | Outreach |
| Capture | Storing the exact email the app would have sent, instead of sending it | Outreach |
| Reply / assessment | An inbound reply and the agent's classification of it | Outreach |
| Handoff | An interested or unclear reply passed to the owner | Outreach |
| Agent run | One piece of agent work on a lead, with its model calls and decisions | Agents |
| Model invocation | One call to the model, with its attested provider and outcome | Agents |
| Unknown outcome | A step whose result could not be confirmed; resolved by reconciliation, never by a blind retry | Outreach, Agents |
| Failure | Something that needs a human, shown as attention on the operations screen | Operations |
| Audit event | An append-only record of a change, in a hash chain | Audit |

## What this brief does not decide

- Which screens exist. That comes from the story map and the screen/action/
  state matrix.
- The must-list and its size. The workshop line in the
  [story map](story-map.md) is a candidate backlog; sizing happens at G2 and
  G5.
- The first build slice. That is the separate [first-slice](first-slice.md)
  proposal.
- How each part of the stack implements any of this. That is technical fit,
  method step 6.
