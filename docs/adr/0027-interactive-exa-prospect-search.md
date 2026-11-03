---
status: accepted
date: 2026-11-03
supersedes: null
---

# ADR-0027: Interactive company and people discovery using Exa

## Status

Accepted by Charles: "Approve the Exa plan and existing key/credit use"
(2026-11-03, following the bundled plan/provider/key/credit/deployment ask).
Entity r2 PASS and plan direction PASS/P1-P4 are recorded in the feature plan.
This accepts the scoped implementation, selected key provisioning, existing
account usage and reviewed SDR-only deployment after verification. It does not
authorize enrichment, automatic save, assignment, model calls or outreach.
At acceptance, no paid request or secret provisioning had occurred.

## Context

The hosted app accepts owner-supplied prospects but has no website discovery.
Earlier public-fetch foundations never became an end-to-end search workflow.
Free public-directory probes have poor named-contact/work-email coverage.
Exa documents company and people retrieval via its Search API. This is a
search/data provider, not permission to switch application models to an API.

## Options considered

1. Public HN/Wikidata search and direct site crawling: no API key, but narrow
   coverage and additional crawling/extraction work. Prior strict import rules
   yielded almost no importable contacts. Not selected for website v1.
2. Brave Web Search: broad indexed pages/snippets; useful later for general
   research, but more work to turn pages into company/person suggestions.
3. Exa company/people Search API: uses an existing key and supplies source URLs,
   excerpts and optional structured entity fields. Selected for v1, subject to
   real API verification. Does not guarantee a valid work email.
4. Exa Agent/Websets/email enrichment or a durable automatic discovery worker:
   potentially useful later, but creates additional spend/lifecycle scope.
   Not selected or authorized by this proposal.

## Proposed decision

We will add an owner-only interactive company-first flow using Exa /search.
The owner selects/confirms an official company website before a separate people
search at that company. One explicit search requests one bounded result batch;
no automatic retries, fallback providers, synthesized answers or model calls.
An explicit Get company page action requests source text via Exa /contents
for exactly the confirmed website_url, supplying the company_site source.

All egress goes to the fixed TLS api.exa.ai service; the app never directly
fetches result URLs. Existing Req uses TLS peer verification, redirects/retries
disabled, raw byte-capped response streaming before JSON parsing and a total
task deadline. A dedicated Finch pool isolates this provider; the unmerged
arbitrary-host discovery transport/robots stack is not reused.
A server-only key is provisioned separately through the
existing root-private hosted secret mechanism after approval. Query text is
sent to Exa only by the owner's explicit action; unrelated CRM data is not.

Candidates are ephemeral, session/owner/request-bound and visibly unverified.
Names/company affiliations may be stale. An employer match requires provider
history to=null and exact NFC/trim/casefold company-name equality; it is a
provider assertion, not independent verification. Nonmatches cannot prefill an
employer. Unknown values remain blank. Email is intentionally never prefilled
in v1; owner enters it, not a guessed/automatically enriched address. A
selected result can prefill the existing Add prospect form, but the owner must
review/complete it and use unchanged OwnerIntake preview/save. Required personal
work email and company-site evidence are not waived. Provider-indexed excerpts
are identified as such, not described as a fresh independent site verification.
Company-site attribution requires the actual source URL to be that company's
website, never a directory/profile URL. No guessed email or employer match.
Person profile excerpts are directory sources. retrieved_on is the UTC receipt
date; source published dates remain separate. Excerpts are literal UTF-8-safe
slices of provider text, never synthetic renderings of structured entity fields.
Cards label provider fields separately from excerpts as unverified provider data.

No migration, new grants, delegation, automatic save, assignment, model spend
or outreach. Runtime diagrams will describe this new provider boundary. The
older discovery-worker proposal remains unaccepted and is not implemented here.

## Consequences

The website can find source-backed companies and named people without waiting
for Mac model execution. Website search works with the Mac offline, subject to
Exa availability/key/quota. Application research models remain subscription CLI.

Search/open requests consume Exa credits and share query text with Exa. One
in-flight operation per owner, explicit actions, byte/time bounds and no retry
limit accidental spend; they are not a contractual monthly spending cap.
Provider dashboard budget controls remain separate and no plan is changed.
There is no durable in-app per-request charge/disclosure ledger in v1; only
value-free telemetry counters/outcomes. The Exa dashboard remains the billing
record. Reusing the owner-selected SOPS key shares quota and rotation with
research_harness; a dedicated SDR key is optional, not a delivery prerequisite.
One temporary search subtree under the existing top one_for_one owns dedicated
Finch, the monitored owner-keyed limiter and Task.Supervisor (one_for_all, its
own bounded restart intensity of 3 in 10s). After that intensity is exhausted
the subtree stays down and search returns :unavailable until the SDR service
restarts; it never counts against the root intensity (implementation
refinement F1; scope, provider and data unchanged). Disabled search starts no subtree and returns
:unavailable. Repo/Endpoint remain siblings. A subtree restart terminates in-flight tasks and clears its
transient limiter state; it never retries an uncertain paid request. Cancellation
or task failure cannot undo a request already received/billed by Exa.

Deployment validation permits at most three backend-only ExaClient requests
with output limited to status/count/cost, not a fabricated owner session. The
owner's first browser clicks provide live website proof; up to two additional
test requests fit the five-request total allowance. No claim that backend smoke
proves the UI. Secret provisioning uses decrypt-to-stdin, root-private temporary
file and validated atomic replacement preserving previous entries without
printing values; prior private env is kept for rollback. Only SDR restarts.

Exa/source terms still apply. API documentation describes company/people search
and retrieval; this decision is not a blanket license to resell/store arbitrary
third-party content. Only explicit owner-selected intake excerpts are retained,
not a bulk provider cache. The owner accepts ordinary use under the existing
account terms, including any account-specific restrictions; this ADR does not
waive third-party rights or certify legal compliance.

Unsaved results disappear on disconnect/restart. Some contacts will need owner
completion, especially email; no promise of email deliverability, current role,
ICP verification or exhaustive coverage. Saved inputs retain existing immutable
owner-supplied/unverified provenance; search alone persists no prospect data.

## References

- https://exa.ai/docs/search/data/companies-people
- https://exa.ai/docs/reference/search
- https://api-dashboard.search.brave.com/app/documentation/web-search
- notes/features/website-prospect-search.org
- ADR-0026: owner-supplied prospect intake
