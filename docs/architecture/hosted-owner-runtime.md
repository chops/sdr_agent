# Hosted-owner runtime

Source-only S-B5 implementation (ADR-0024/P2), not a deployed topology.
The domain, owner migration, inert GET/JavaScript and database-backed POST
have focused synthetic verification against the S-B2 dependency. See
[the Mermaid source](hosted-owner-runtime.mmd).

Operations owns HostedOwner. It uses existing Accounts User/Token actions;
Accounts does not own or query Operations persistence. Enrollment is console
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

Mac worker controls, transcript read scope and owner-safe LiveViews remain
pending; this diagram is not a claim of end-to-end completion.

Generated generic diagrams were inspected in a temporary preview. Their
resource grouping/counts and omitted runtime conditions are not authoritative;
the maintained boundary diagram was amended narrowly instead of replaced.
