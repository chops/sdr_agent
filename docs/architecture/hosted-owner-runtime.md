# Hosted-owner runtime

Source-only S-B5 implementation (ADR-0024/P2), not a deployed topology.
The domain, owner migration, inert GET/JavaScript and database-backed POST
have focused synthetic verification against the S-B2 dependency. See
[the Mermaid source](hosted-owner-runtime.mmd).

Operations owns HostedOwner. It uses existing Accounts User/Token actions;
Accounts does not own or query Operations persistence. Its policies call the
lower Audit.HumanAuthority interface for role eligibility and the narrow write
scope. Audit.Tenant and Audit.ProvenanceSnapshot also use its human metadata
freshness and live-owner callbacks, with Audit-owned checks. The Tenant owner
filter remains its tenant id; provenance snapshots remain global metadata.
Prototype builds explicitly select Operations.HostedOwners as the
compile-time implementation; ordinary builds use the lower constant provider.
The configured upper implementation performs owner/history lookups: inversion
does not remove those runtime reads. Missing prototype selection fails closed,
and runtime config cannot swap the provider. Enrollment is console
only, with a generated unknown password and an ordinary reviewer role.
Mutations require a privately registered exact transaction/process scope.

The link's bearer lives in a browser fragment, not an HTTP path/query. The
inert GET returns only local bundles and an empty disabled CSRF form. JavaScript
scrubs history before filling it, without automatic submission or storage.
The POST exchanges a signed, stored, purpose-bound link once, then
clears and renews the session before storing a normal user token.

Every hosted permission rereads persisted authority for the live activation.
Terminal disable revokes every token and disables the User atomically. Boot
admits a historical disabled owner only as a disabled same-tenant reviewer
with no unexpired unrevoked tokens; that history grants no authority. An active
owner on an old activation refuses boot.

Hosted User identities, including terminal history, never inherit legacy
reviewer/admin role grants. Metadata reads revalidate human identity at all
eight actor-present sites without changing system/delegation access. Owner
reads carry tenant filters (Tenant by id; ProvenanceSnapshot is global).
Unrelated persisted nonowner prototype humans retain their historical domain
rights after fresh id/tenant/role/status checks; real boot rejects such extra
Users and the hosted web boundary rejects their sessions. The website admits
only a live owner or exact bound persisted auditor. Normal runtime is unchanged.

Mac worker enrol/list/pause/resume/disable are source implemented through
an owner-only action namespace, with current-binding filters and fresh
checks after worker/head locks. Second active enrollment is refused; disable
is terminal and pause affects new intake only. The ordinary marked console
path remains available. Explicit remote transcript diagnostics are source
implemented too: the API takes the head, rechecks the owner, opens an exact
private named-action/field scope, reads and records AuditAccess in one
transaction, and returns only after commit. Caller transactions are refused.
Direct named reads, copied contexts and roles alone expose no bytes; ordinary
production has refusal stubs. Metadata lists never contain transcripts and
no business output release is implied. Claim-time owner revocation and
owner-safe LiveViews remain pending; this is not end-to-end completion.

Generated generic diagrams were inspected in a temporary preview. Their
resource grouping/counts and omitted runtime conditions are not authoritative;
the maintained boundary diagram was amended narrowly instead of replaced.
