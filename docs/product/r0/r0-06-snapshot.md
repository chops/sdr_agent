# R0-06 trial snapshot: a read-only baseline command

**Status:** draft 1, 2026-10-17. Needs Codex review. Entity trigger: no (no persisted concept, attribute, relationship, policy, action or event changes; reads only). The owner approved building it (3a, 2026-10-17: "3. yes").

## Why

The owner runbook (`r0-06-proof.md` section 4) takes the same baseline reads before the trial and after each leg. Done by hand, that is about 6 database and console queries at each of 3 checkpoints. This command prints every read in one labelled block, so the owner runs one command per checkpoint and Claude and Codex compare the blocks.

It is evidence tooling, not proof. An unchanged count is not a "no model call" proof on its own. The runbook's qualifications (section 4 step 4, and what the trial doesn't observe) stay as written.

## Command

    mix sdr.r0.snapshot --email <owner email> --port <app port> [--witness-root <dir>]

- **Owner-run only, at a checkpoint.** It runs in the owner's app environment and checkout, beside the running app. The agents never run it against the owner's database.
- `--email` names the owner's admin account, which is the actor for the authorized reads.
- `--port` is the running app's HTTP port, used only to find its BEAM.
- `--witness-root` defaults to `SDR_WITNESS_STORE_ROOT`. If neither is set, the witness store line reads `unset`, never 0.

## Guarantees

1. **It never starts the application.** It runs `app.config`, then starts only `SdrAgent.Repo` with a small pool. No Endpoint, Oban, profile supervisor, ClaudeCLI server, reaper, witness worker or PubSub runs. Before any read, it refuses if any of these already runs in its own VM (the rehearsal driver's `running/0` check). It cannot launch a model, start a server or take a lease.
2. **Read-only, enforced by the database.** Every query runs in one transaction that begins `SET TRANSACTION READ ONLY` (Postgres refuses any write in it), and then rolls back. That includes the Ash reads, which run inside that transaction on the same connection. As a positive control, the test suite shows a write attempted in that transaction is refused.
3. **The actor.** The owner's user is read by email, read-only, through the same path sign-in uses to find the user. No password is read or asked for; reading the record is only enough to make it the actor. It must be an active admin of the tenant. Otherwise the command stops, and no read falls back to a system actor or `authorize?: false`. *(Open question 1.)*
4. **Unknown is never zero.** Every read prints a value or `unknown (<reason>)`. Any unknown makes the command exit non-zero after printing the whole block, so a partial block is never mistaken for a clean one.
5. **No secrets, no record contents.** It prints counts, statuses, ids, generations and times only. It never prints a prompt, a result, a confirmation text, a token or a witness body. For the witness store it lists directory names only, through `Witness.Store`'s own bounded, symlink-refusing listing, and never opens a record or blob. *(Open question 2.)*

## The reads (`r0-06-proof.md` section 4)

| Line | Source |
|---|---|
| `code` | the checkout's `git rev-parse HEAD` (a ChildEnv git call, as in the rehearsal driver), plus `dirty` if `git status --porcelain` is non-empty |
| `database` | `current_database()`, host and port from `Repo.config()` |
| `beam` | the pid listening on `--port` (`lsof -nP -iTCP:<port> -sTCP:LISTEN -t`), with its start time from `LC_ALL=C TZ=UTC ps -o pid=,lstart= -p <pid>`. Exactly one pid, or else unknown. |
| `model_invocations` | the total count, and counts by status |
| `grant_usage` | `Agents.grant_usage/2` for every grant `Agents.list_grants` returns to the actor: consumed and today, per grant id |
| `wire_witness_links` | the count |
| `witness_store` | the invocation directories and record entries under `witnesses/` (names only), or `unset` |
| `model_server_starts` | the latest generation, its profile and status, and the total count |
| `profile` | the desired profile and setting revision; the latest switch's id, status and time; the counts of open, pending, blocked and uncertain switches |
| `taken_at` | UTC, from `SdrAgent.Clock` |

The block ends with a `sha256` of the block's own lines, so a pasted copy can be checked against the log.

## Tests (RED first)

1. **The happy path** on a test database with fixtures: every line is present and correct.
2. **Never starts:** after a run, none of the processes in guarantee 1 exists, and none was started (traced).
3. **Read-only:** a planted write inside the snapshot transaction is refused by Postgres (positive control), and the row counts of every table are unchanged after a run.
4. **The actor:** an unknown email, a non-admin, a disabled admin, or an admin of another tenant stops the command before any domain read. There is no fallback actor.
5. **Unknown is never zero:** a failed read (stubbed), no listener on the port, two listeners, an unset witness root, and a failed grant read each print `unknown`/`unset`, and the command exits non-zero.
6. **No contents:** a witness store fixture holding records and blobs is counted by name, and no record or blob is opened (traced `File` calls under the root). No printed line contains a fixture body, prompt or token.
7. **Running guard:** if the app, Repo or Endpoint already runs in the VM, the command refuses before any read.

## ADR evaluation

No ADR. This is a read-only operator command inside existing boundaries: the domain read APIs, the Repo, and `Witness.Store`'s reader. It adds no dependency, technology or reviewer boundary.

## Open questions (for Codex)

1. **The actor lookup.** Is reading the user by email through the sign-in read acceptable for an owner-run local command, given the actor-only use and no password? Or should the owner pass an id they read from the admin page?
2. **Witness store counting.** `Witness.Store` exposes per-invocation reads. Should I add a names-only, bounded listing to it (a new public function, tested), or count with `File.ls` under the same `lstat` checks inside the command?
3. **MIX_ENV.** It runs in whichever environment the owner's app uses (expected `dev`), and is refused in `test` except under ExUnit. Is that correct, or should it be restricted further?
