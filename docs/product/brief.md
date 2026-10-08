# Outcome brief: SDR Agent workshop release

- **Status:** draft for gate G1, written 2026-10-08.
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
  Today that is the owner. On Nov 6 it is the workshop's solo founders, each
  running their own local copy.
- **Situation:** they have a product and an idea of who should buy it. They
  have a handful of target companies, from a spreadsheet, a CRM or memory, and
  limited hours for outreach that has to sound like them and be accurate.
- **Job to be done:** "When I sit down to do outbound, help me go from a list
  of companies to first emails I would actually send, quickly, without
  inventing facts or losing control of what goes out."

## Outcomes

Each outcome is observable in the workshop release. Delivery is captured, not
sent, so nothing below claims replies, meetings or pipeline.

| ID | Outcome | How we observe it |
|---|---|---|
| OUT-1 | **Prepared faster.** The founder gets a reviewed first email for each target company in less time than by hand. | Time from importing N companies to N approved drafts, measured in the app and compared with the founder's own manual baseline (pending interview notes). |
| OUT-2 | **Credible.** Every factual claim in a draft points to evidence the founder can open. | Share of draft sentences with citations; claims without evidence are flagged before review. |
| OUT-3 | **In control.** Nothing is captured for delivery without the founder approving that exact draft for that exact recipient. | Approval binding enforced in the domain; refused stale approvals are visible. Already true in the prototype. |
| OUT-4 | **Sounds like them.** Drafts follow the campaign's brand guidelines and the founder's writing samples. | Approval rate and size of the founder's edits per draft (lower is better); tone/brand check results. |
| OUT-5 | **Knows what happened.** The founder can see what the agent did, what it cost and what failed, and recover without guessing. | Home shows the action queue, provider (real or fake), budget and unknown outcomes; every failure has a next step. |
| OUT-6 | **Handles "interested".** A positive reply produces a drafted response with the founder's booking link, for approval. | Interested replies get a draft within one run; the draft never asserts specific free times. |
| OUT-7 | **Runs privately.** Everything works on the founder's own machine, with their own model login and data. | A fresh install from the guide reaches a first approved draft using fake data, then a real-model run on the founder's login. |

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
| NG-11 | Real prospects' personal data | Waits for HubSpot plus privacy, erasure and outreach-law decisions |
| NG-12 | Multi-customer hosting | Local personal app; keep the design tenancy-ready |
| NG-13 | Per-campaign model cost tiers and personalization-depth settings | Later; one sensible default for the workshop |

## Today's workflow

**Pending.** The owner has notes from a conversation with one other solo
founder. Until those notes are in, this section has no evidence and invents
none. When they arrive we record:

- how that founder does outbound today: tools, steps, time taken;
- what is painful or slow;
- what they would need to trust a drafted email;
- **what kind of evidence it is:** an interview, a reaction to a demo, or
  watched tasks. Each supports different claims.

The owner's own answers name the tools they benchmark against (Apollo,
Outreach, HubSpot sequences and Breeze agents), but not their current routine.

## Assumptions to check

| ID | We assume | How we find out |
|---|---|---|
| AS-1 | A solo founder starts from a short list (5 to 20 companies), not a large database. | Founder notes; the owner's walkthrough on the shaping page |
| AS-2 | Evidence they can open builds more trust than a confident score. | Prototype task test: do they open citations before approving? |
| AS-3 | Reviewing one draft at a time is acceptable for 10 to 20 drafts. | Prototype timing with the owner |
| AS-4 | Brand guidelines plus pasted writing samples are enough to set the voice. | Approval rate and edit size on the owner's own campaign |
| AS-5 | CSV and manual entry cover the workshop founders' lead sources. | Founder notes; ask at the workshop |
| AS-6 | Founders will bring their own Claude login and accept a local install. | Install guide dry run; workshop sign-up questions |
| AS-7 | Captured (not sent) emails are still a convincing demo. | Owner judgment at G8; workshop feedback |

## What this brief does not decide

- Which screens exist. That comes from the story map and the screen/action/
  state matrix.
- The first build slice. That is the separate [first-slice](first-slice.md)
  proposal.
- How each part of the stack implements any of this. That is technical fit,
  method step 6.
