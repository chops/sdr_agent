---
status: accepted
date: 2026-10-30
supersedes: null
---

# ADR-0023: Owner-authorized additional prototype model-call allowance

## Status

Accepted by Charles in the current interactive session, receipt recorded
2026-10-30T15:05:40Z. Claude independently reviewed the entity delta
(`m_1793373109000000000_4fbe67e8`) and implementation plan
(`m_1793373875000000000_8af0cfb2`). Decision D-269.

## Context

The prototype's original provisioning rule required an evidenced historical
shared budget of 60 calls with at least 50 remaining. Historical consumption
on other owner routes is unknown. That is not zero, and the agents may not
invent an attestation.

The owner explicitly granted a new additional allowance:

> Authorize 100 additional SDR application model-call attempts starting now, regardless of prior consumption. Replace the historical-count prerequisite for this allowance. Count failed and uncertain attempts; stop at 100. Use subscription Claude CLI only. Capture-only; no outreach.

The exact UTF-8 receipt, including its final newline, has SHA-256
`9aba0a0c31bb77b547e0cdb9d0809fdd7aee00567509d53c691f66421d840a12`.
It is non-secret owner authorization, not private research or a credential.

## Options Considered

### Continue waiting for historical counts

Preserves the original shared-budget calculation but cannot use the new
authorization and leaves delivery blocked. Inventing zero is not an option.

### A separate owner-authorized additive allowance

Uses the explicit additional authority without rewriting historical facts.
Requires a fixed receipt, a hard persisted cap and once-only issuance.

### Disable budget admission

Rejected: it would remove the owner's 100-attempt limit and existing
admission, authorization and audit protections.

## Decision

We will implement exactly the additional allowance authorized above:

- 100 total additional application attempts; not 100 per day, restart,
  provisioning request, run or agent pane.
- Start at the recorded receipt instant, 2026-10-30T15:05:40Z. Preserve the
  existing exclusive expiry, 2026-11-07T07:00:00Z. The October 30 20:00Z
  delivery milestone does not extend or replace that expiry.
- Keep the retained binding and funding name `d237-funding/1`. Amend its
  compiled funding entry to total/allocation 100 and reference D-269.
  Do not change the binding policy-entry commitment or recreate its database.
- The closed `d237-owner-allowance/1` worksheet contains exactly `schema`,
  integer `total: 100`, and `receipt: {path, sha256}`. The private reader
  must resolve the exact compiled receipt pin. No historical routes or
  previous-binding counts are requested or synthesized for this allowance.
- The original historical worksheet is no longer accepted for this allowance.
  This supersedes that rule only; it does not declare previous consumption
  zero or authorize unrelated hosted, calibration or ordinary-route grants.
- Existing provisioning locks, original-event provenance, unchanged-term
  replay, and raw-action `grant_exists` refusal remain. A replay cannot
  add capacity or reset consumption. Conflicting or previously funded state
  is refused, never deleted or silently replaced.
- Existing admission reserves atomically before a possible launch. Every
  persisted charge remains spent, including failed or uncertain attempts;
  no refund, retry, reset or 101st attempt. Existing stricter per-run and
  tenant limits remain.
- Subscription Claude CLI only; no direct Anthropic API, no outbound
  messaging, no automatic approval or send. Capture-only.
- Historical releases retain their original recorded funding basis and
  reviewed window. New releases carry the new funding-entry digest/window;
  historical verification never substitutes current funding configuration.

## Justification

The owner owns additional usage authority. This explicitly replaces the
historical prerequisite without fabricating history or bypassing admission.
It uses existing grant, allocation and invocation resources and domain APIs,
not new persistence or a generic budget-control interface.

## Consequences

### Positive

- Missing historical counts no longer block this authorized allowance.
- Persisted accounting survives restart and replay, with an enforceable cap.
- Earlier unknown consumption and recorded releases remain truthful.

### Negative

- The owner has authorized up to 100 attempts in addition to whatever earlier
  consumption actually occurred.
- Reserved, failed and uncertain attempts remain consumed conservatively.
- Exhaustion, expiry or an integration defect still stops live execution.

### Neutral

- No migration, new resource, dependency, actor or external integration.
- No budget UI or standing authority to create later allowances.
- Delivery is not complete until an application-triggered CLI run actually
  persists a draft; imported records alone are not autonomous discovery.
