# Prototype task connection ownership (proposed)

The source is [prototype-task-connections.mmd](prototype-task-connections.mmd).
It distinguishes setup's conditional maintenance helper and test-only fake from
operator entry's parent-owned Repo. It does not claim installed Session startup,
Repo-stop-on-return, caller-death time bounds or a real connection proof.

The maintenance success deadline covers reply and both DOWN observations;
post-expiry grace acknowledges cleanup only. See proposed ADR-0021 for the
caller-death residual and required implementation evidence.
