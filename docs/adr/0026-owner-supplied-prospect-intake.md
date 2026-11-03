---
status: accepted
date: 2026-11-03
supersedes: null
---

# ADR-0026: Owner-supplied prospect intake

## Status

Accepted scoped decision: Charles replied "approve that scope" to the explicit
owner-only unverified-intake proposal. No unrelated discovery ADR-0025 acceptance.

## Context

The importer accepts independently spot-checked dossiers only from delegated
operators. A hosted owner is not that operator. Exposing it directly would either
refuse the owner or misattribute provenance. A request queue without a deployed
dossier-builder would not provide real self-service addition.

## Options considered

1. Assisted request queue: preserves dossier admission, still needs agent work.
2. Dossier/manifest/artifact upload: preserves checks but cumbersome, wider uploads.
3. Separate owner-supplied unverified intake: usable form, explicitly new owner
   permission, distinct durable provenance. Selected.

## Decision

We will add owner-only preview/commit through Ash actions with immutable
OwnerProspectIntake/Source records, actual HostedOwner user and current
binding/relocation attribution. No borrowed/minted operator delegation.
Company/contact plus 1..3 HTTPS source excerpts; preview is ephemeral; commit
freshly checks owner, tenant, input digest and Account outcome under the shared
binding lock. One atomic transaction stores exact Payload bytes and creates a
Contact, new Lead and provenance. Reuse an active same-tenant Account without
changing ANY existing field; archived account refused. Existing email conflicts
except identical replay. No lifetime/company/contact quota.

A lead has exactly one input origin, dossier OR owner intake, checked at write
and read. New provider owner_intake, trust unverified, freshness unknown; actual
owner/submission time and declared retrieval date distinct. Preserve origin in
evidence/bundle/decisions; draft/review disclose owner-supplied unverified sources.
Evidence ranks last. Excerpts are data, never a new instruction/note channel.

## Input and replay contract

Version owner-intake/1; SHA256 of existing sdr-canonical-json/1 encoding of
string-key normalized input map with source order retained. Domain/work-email
ASCII lower case, refuse non-ASCII/IDN domain input; trimmed NFC names/title.
Validated HTTPS source URLs retained exactly; UTF-8 excerpt bytes NEVER trimmed
or normalized. Dates ISO; no server ids/times in submission hash. Freeze version,
never re-encode historical inputs. Preview outcome drift returns preview_stale.

One contact, 1..3 sources per request; URL <=2048 bytes, raw excerpt <=2000 bytes,
whole serialized request <=16 KiB. These are request bounds, not record quotas.
No uploads/network fetch/caller paths. Refusals are closed codes. Events/logs/
span status contain ids/hashes/codes, never submitted name/email/URL/excerpt.

## Justification

Separate provenance leaves operator dossier meanings intact while allowing real
owner self-service. Narrow Account reuse supports multiple contacts per company
without replacing facts or falsely making provenance account-wide.

## Consequences

Positive: usable owner intake with tenant isolation, dedup, exact-byte grounding.
Negative: owner facts may be wrong/adversarial, not independently verified, valid
mailboxes, current employment or ICP fit. No correction/withdraw/edit UI in v1;
state this honestly.
Neutral: save does NOT assign, open worker intake, run models, spend allowance,
or send outreach. Subscription Claude CLI/capture-only/owner-run controls remain.
Tests/public evidence synthetic. Existing SDR-only deployment authority requires
reviewed source/gate/migration/ACL readiness; no live validation implied.

## Related records

notes/features/owner-prospect-intake.org contains independently reviewed entity
delta, P1-P6/R1-R8 acceptance tests and evidence. Extend ADR-0014 hosted data only
for this expressly owner-supplied input class; independent dossier checks unchanged.

