# Owner self-service prospect intake

ADR-0026 source implementation; deployment is a separate reviewed step.
See [the Mermaid source](owner-prospect-intake.mmd).

The existing Leads page calls the owner-only coordinator, not persistence
directly. Preview writes nothing. Explicit save locks the binding and audit
head, rechecks the current owner and preview, then atomically creates the new
manual prospect and immutable provenance through scoped domain actions.
An active Account may be reused without changing any field. Identical replay
writes nothing. There are no lifetime company or contact quotas; one contact
and one to three excerpts bound an individual request.

An owner-entered excerpt is not fetched, spot-checked, mailbox-validated or
automatically qualified. Its exact bytes, declared retrieval date and server
submission time remain distinct. Audit events contain ids and hashes, not
submitted prospect values.

Intake save does not assign a lead, call a model or send outreach. A later,
separately authorized run selects exactly one origin by lead id. Legacy dossier
sources retain their reader. Owner sources use a run-bound Payload action that
revalidates running run, tenant, lead, intake in the live binding and content hash
at consumption; read errors refuse. Two leads sharing an Account do not share
provenance. Owner-origin artifact metadata is server-bound; evidence preserves
artifact lineage, and cited owner material is disclosed as owner-supplied and
unverified in draft review.

The generic architecture generator was run in a temporary preview. It detected
the two Research resources but overcounted generic resource matches and omitted
runtime conditions. Maintained domain diagrams were updated narrowly rather
than overwritten.
