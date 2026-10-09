# Outcome brief: SDR Agent workshop release

- **Status:** draft for gate G1, revised 2026-10-08 after Codex review of
  `8e08d0a`.
- **Method step:** 1, outcomes and today's workflow.
- **Sources:** [owner answers](discovery/answers.md),
  [review and scope decisions](discovery/review.md), and the founder-interview
  notes, which are **still pending** (see "Today's workflow").

## In one sentence

SDR Agent is a first-touch copilot that lets a solo founder turn a short list
of target companies into researched, evidence-backed first emails they have
personally approved, with a full record of how each one was made.

## Who and when

- **User:** a solo founder or operator doing their own outbound. No team.
  Today that is the owner.
- **Workshop (Nov 6):** the owner demonstrates the product to solo founders.
  Attendees may optionally install and run it themselves in **fake-model mode
  on synthetic data**. Whether attendees may use a real model on their own
  login is a separate decision that has not been made (see OUT-7 and NG-15).
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
| OUT-7 | **Runs locally, described honestly.** The app and its data live on the founder's machine. | A fresh install from the guide reaches a first approved draft in **fake-model mode on synthetic data**. With real inference turned on, permitted draft content is sent to an external model provider through the proxy: local does not mean no data leaves the machine. A real-model run on an attendee's own login is **not** a release criterion (NG-15). |

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

## Today's workflow

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
| AS-6 | Workshop founders are satisfied by the owner's demo plus an optional fake-model install on synthetic data. | Install guide dry run; sign-up questions; workshop feedback |
| AS-7 | Captured (not sent) emails are still a convincing demo. | Owner judgment at G8; workshop feedback |

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
