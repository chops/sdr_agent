# B2-02 owner walkthrough packet: finding people's emails and phones

Status: **draft for review** (Claude author, Codex reviewer). Tentative
slot: **Tue Oct 20, 10:00 to 11:30 MDT**, to be confirmed by the owner on the
standup page. Authority: D-158 starts drafting only. This packet authorizes
no build, keys, access, spend or real calls.

## Purpose

Learn how the owner finds a person's email address and phone number today,
in the owner's own words, so B2-07 ("contact candidates via the owner's
method") can be written as requirements the owner corrects before anything
is built. We have not guessed the method, and the mockups leave that step
empty on purpose (`candidates.html`, "Your method — defined at the
walkthrough").

## Before the session

- The owner reviews the five mockups in `docs/product/b2/` with the neutral
  walk script in `notes/features/b2-01-mockups.org`.
- No preparation is required. The owner chooses whether to show anything on
  screen.

## What the owner shows

The owner leads. We ask open questions only, one at a time, and do not
suggest answers, tools or services.

1. "Think of the last time you found someone's email or phone. Can you walk
   us through what you did, from the start?"
2. "Where did you look first? What made you look there?"
3. "How did you decide an address or number was right?"
4. "What did you do when you couldn't find one?"
5. "What would you never do when looking for someone's details?"
6. "What did you keep afterwards, and where?"
7. "Is there anything about this you'd want the app to do differently from
   how you do it?"

Follow-ups only restate or ask for an example ("Can you show me what you
mean?"). We do not name tools, services, data brokers, pattern guessing or
any other method unless the owner names it first.

## What we record, and where

- **Private, on the owner's machine:** the session notes, any screen the
  owner chooses to show, and any real names, addresses, numbers or
  accounts that come up. Nothing real goes into git, issues, PRs or chat
  logs that leave the machine (ADR-0014 rule 5; D-110 for citation
  screenshots).
- **In git (after the owner reviews the wording):** the method described
  with fictional examples only, the requirements, and the decisions below.
- Agents take no screenshots and copy no real data.

## Decisions the walkthrough must produce

1. **Requirements for B2-07:** the owner's method as steps, each with its
   input, its output and when it stops.
2. **Source contract inputs:** for each source the method uses, the
   skeleton below filled in, or marked "not used".
3. **Candidate rules:** confirmed already: candidates are one row per
   source, unconfirmed, never auto-promoted, never written to the CRM, and
   confirmed by the owner on Home. The walkthrough decides how candidates
   are described (for example "seen on one source") and what the owner
   needs to see to confirm one.
4. **Attended sources:** which steps, if any, the owner must do personally
   (as with LinkedIn), and where each must stop.
5. **"Not a fit":** what setting a suggested person aside should do (keep a reason, stop suggesting them for the account, or something else). The mockup shows it as an open question.
6. **LinkedIn citation handling:** already decided by D-110 (private
   citation screenshots allowed, stored only on the owner's machine, never
   shared). The walkthrough only confirms it still fits.

## Source-contract skeleton (one per source, to be filled after the session)

| Field | Value |
|---|---|
| Source name | TBD |
| What it provides (email, phone, profile URL, other) | TBD |
| How it is reached (owner-attended, owner-supplied file, provider API) | TBD |
| Needs keys or an account? Whose? | TBD; nothing is set up by this packet |
| Cost and quota, and who approves spend | TBD; no spend authorized |
| Applicable terms, access restrictions and required compliance decisions | TBD; the owner's preference alone is not access authorization |
| Retention (keep or wipe), role access, allowed processing and export, and what queries disclose to the provider | TBD; reuse C5 and ADR-0014, not assumed implemented |
| What is stored, and where | TBD |
| Citation kept with each candidate | TBD |
| How it fails, and what the user sees | TBD |
| Stop conditions (CAPTCHA, rate limit, refusal) | TBD |

## Boundaries that hold whatever the walkthrough finds

- Contact candidates are never used automatically, never auto-promoted and
  never overwrite CRM data; only the owner's confirmation on Home makes one
  the contact.
- Attended sources run in the owner's own browser under the owner's own
  sign-in, deterministic and human-paced, stop on any CAPTCHA or bot check,
  never evade one, and are never driven by a model.
- No search or provider keys, account access, spend or real model calls are
  authorized by this packet or the session.
- Real people's data never enters the public repository.

## After the session

1. Claude writes the requirements and the filled source contracts with
   fictional examples, and the owner corrects them.
2. Claude produces the B2 entity delta (entity-discovery), and Codex
   reviews it independently.
3. Codex reviews the requirements and source contracts.
4. The owner decides B2's G5, which is the only step that permits a build.
