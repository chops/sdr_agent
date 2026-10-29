---
status: proposed
date: 2026-10-29
supersedes: null
---

# ADR-0021: Prototype task connection ownership and cleanup uncertainty

## Status

Proposed. Number checked against the S1 branch (highest existing: 0020);
coordinator confirms no conflicting reservation before installation.
Independent entity review: Claude, `7d46adaa`, scoped PASS with E1-E3.
This is not source acceptance or a runtime grant. Acceptance requires the
existing delegated architecture approval path, not this draft declaring itself accepted.

## Context

Setup needs fixed local maintenance-cluster facts before storage effects.
Operator task entry needs a Repo in a fresh VM without starting the application
tree. Both create transient process ownership and failure states that a pure
decision function does not prove. A successful SQL read alone does not prove
that its helper, client pool or owned connection supervisor has ended.

## Options considered

1. Caller-owned direct read: simple, but joins the connection lifetime and
   failure handling to the caller and lacks the reviewed cleanup protocol.
2. Monitored unlinked helper, a revocable reply alias, and an announced linked
   pool: adds explicit ownership and uncertainty, without a new service or
   dependency. Caller death remains a VM-lifetime residual.
3. Persistent global helper/service: requires a new durable supervision and
   concurrency boundary; unnecessary for one setup task.

## Decision

We propose option 2 for maintenance and the existing parent-owned Ecto Repo
supervisor pattern for task entry.

Maintenance uses only the fixed Unix-socket target and constant options. No
target, host, URL, password or connector is supplied by a production caller.
Test-seam builds accept only the reviewed socket-free fake; absent or foreign
seams refuse. This is a trusted-test-code restriction, not isolation from
arbitrary code already executing in the VM.

One absolute monotonic **success deadline** is established at entry to the
maintenance-read function, after local Postgrex application startup. The local
application startup is unbounded. The default success window is 15 seconds and
covers reply receipt plus observation of the helper and announced pool DOWNs.
Every wait uses that same deadline; it is not reset by a message or a reply.
At or past the deadline a saved reply is invalidated. Two cleanup-only grace
waits, at most 5 seconds each, can acknowledge helper and pool death; they can
never restore success. Helper grace begins at the kill request. Pool grace
begins when pool acknowledgement is needed after success expiry, including
after helper grace if that was required. Receive deadlines are not real-time
scheduler guarantees.

Facts require a valid reply, normal helper DOWN and pool DOWN, all observed
within the success window. Query failure or timeout with acknowledged cleanup
returns unavailable. Missing helper/pool acknowledgement returns
cleanup-unacknowledged. A generic start failure after the starting announcement
and without an announced pool is conservatively cleanup-unacknowledged: init
may have created a supervisor before failing. No start-error tuple proves
that no connection existed. Owned aliases/monitors/tags are revoked, consumed
or explicitly removed before a normal return; unrelated messages are untouched.

**Caller-death residual:** the unlinked helper does not monitor its caller.
It may finish its connector steps and stop its pool, or remain until the task
VM exits. This function gives no caller-death time bound or acknowledgement.
No facts are delivered to a surviving caller after that caller has died.
This residual is separate from D-263, which accepts only real CLI-descendant
lifetimes; D-263 does not waive maintenance ownership obligations.

Task entry uses the accepted RepoState observation and pure repo decision.
Only not-started attempts a Repo start. Reuse never acquires ownership or stops
the existing Repo. An already-started race raises the fixed value-free
RepoStartError; the loser never adopts or stops the winner. A Repo started by
the body has that process as its OTP parent, and terminates through
parent-specific supervisor semantics or task-VM shutdown. There is no
synchronous Repo-stop-on-return claim. Dependency apps stay until VM shutdown.
The production branch retains its existing nesting refusal and no RepoState
dependency. Insert-only Oban wiring is not part of this decision.

## Justification and source limits

Pinned db_connection 2.10.2 uses ConnectionPool.terminate/2 ->
ConnectionPool.Pool.stop_supervised/1 -> Watcher.unwatch/1, whose termination
path waits for the child supervisor to end. The Watcher's pool-kill path follows
the supervised tree's DOWN. These exact mechanics support the owned-tree
claim only under the fixed source/options and normal reviewed paths. They are
not a universal guarantee against external kills, corrupted state or a wedged
VM. Generic start failures deliberately receive no absence credit.
Ecto 3.14.2 starts the Repo supervisor from the task body as its OTP parent;
the fresh-VM and raced-start proofs remain required before Session GREEN.

## Consequences

Positive: explicit ownership, conservative failure states, closed targets,
no new service/dependency, and discriminating regression oracles.

Negative: more protocol code; false-negative unavailability under delayed
scheduling; local application startup and caller-death helper lifetime are
not bounded by this function; cleanup can be unacknowledged.

Neutral: no new persistence, actor grant, outreach authority, API billing or
credential. Setup result mappings, S1b SafeLog additions, S4 IF-7 source ACK,
readiness, full verification and the capture-only journey remain separate work.

## Required evidence before implementation acceptance

Reached RED for the new foreign-connector and saved-reply deadline oracles and
the strengthened generic-start-failure outcome; exact-source independent PASS;
focused GREEN plus scoped statics; conditional diagram review; fresh-VM and
owned/reused/raced Repo proof before Session GREEN; later full gate and journey.
