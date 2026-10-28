# D-237 prototype runtime: the isolated cluster and the operator commands

This is the project-owned record of the D-237 local prototype's service facts
(ADR-0005 D-237 amendment item 2; interfaces r6 IF-7 "Project facts", ruling
3). It sits beside `config/runtime.exs` (the dev prototype block) and the
pinned constants of `bin/prototype-pg`, and the three must agree. A test
checks that they do (`test/scripts/prototype_pg_test.exs`, ruling 3).

`.workflow/project-facts.md` and `.workflow/receipt.json` are untouched. The
facts file is a `seed_once` unit pinned by the workflow receipt; any future
edit to it goes through the reviewed receipt-revision process.

## Two PostgreSQL services, never mixed

| Port | Service | Endpoint | Owner |
|---|---|---|---|
| 5520 | the ordinary development PostgreSQL service (devenv; `config/dev.exs`) | TCP on localhost | the owner's dev, test and calibration databases |
| 5541 | the isolated prototype cluster's socket endpoint only | the Unix socket in `/private/tmp/d237-pg`; no TCP listener | the D-237 prototype database `sdr_agent_prototype` |

- 5520 is the ordinary service. Nothing in the prototype connects to it, reads
  an owner database (`sdr_agent_dev`, `sdr_agent_calibration`) or changes its
  roles or configuration.
- 5541 names the prototype cluster's Unix socket only:
  `listen_addresses = ''`, so it has no TCP listener. Being socket-only does
  not make it any less a service fact, which is why it is recorded here.

## The prototype cluster (`bin/prototype-pg`)

| Fact | Value |
|---|---|
| Executable | `/nix/store/zndqgdxn4p28iyax8raza3pfn7lkjw64-postgresql-18.6/bin` (the devenv PostgreSQL 18 store path, recorded in the marker at init) |
| Root | `/Users/charles/.local/state/sdr-agent/prototype/d237` (mode 0700) |
| Data directory | `<root>/pgdata` (mode 0700) |
| Ownership marker | `<root>/CLUSTER` (mode 0600), one line: `{"system_identifier":"<digits>","data_dir":"<root>/pgdata","socket_dir":"/private/tmp/d237-pg","port":5541,"binary":"<executable>"}` |
| Server log | `<root>/log/postgres.log` (mode 0600; `logging_collector = off`, stderr to this one file) |
| Socket directory | `/private/tmp/d237-pg` (mode 0700) |
| Socket pair | `.s.PGSQL.5541` and `.s.PGSQL.5541.lock` |
| Superuser | `postgres`, local trust over the private 0700 socket directory only; host connections rejected |
| Database | `sdr_agent_prototype`, created by `mix sdr.prototype.setup` |

### Lifecycle

1. `bin/prototype-pg init`
   - refuses an existing data path or an existing marker, and never
     overwrites a marker;
   - creates the root and the log directory (0700) if absent;
   - creates the socket directory (0700) if absent, or verifies it: a real
     directory by `lstat`, owned by the user, mode 0700 and empty. A
     symlinked, foreign-owned, wider-mode or non-empty directory refuses init,
     unaltered;
   - runs `initdb` from the pinned executable;
   - writes the connection and logging settings below before any start;
   - writes the marker from `pg_controldata`, last, by exclusive create.
2. `bin/prototype-pg start`
   - runs the identity proof (below);
   - requires `pg_ctl status` to report not running;
   - requires both socket-pair files to be absent (a residual pair is
     refused, never removed or adopted);
   - requires `lsof -nP -iTCP:5541 -sTCP:LISTEN` to be empty;
   - starts with `pg_ctl -l <root>/log/postgres.log`, then requires the
     connected `system_identifier` and `data_directory` to equal the marker's.
3. `bin/prototype-pg status`: the identity proof, then `pg_ctl status`; a
   running cluster must answer with the marker's identity.
4. `bin/prototype-pg stop`: the identity proof, a running status and the live
   identity, all before `pg_ctl stop -m fast` may signal anything.

Start, status and stop never create a directory. A missing socket directory
fails the identity proof.

### The identity proof (before start, status and stop)

1. The marker: a regular file by `lstat`, owned by the user, mode 0600, holding
   exactly its five keys.
2. The data directory: a real directory by `lstat`, owned, mode 0700, at
   exactly the marker's `data_dir`.
3. The executable: the pinned store path equals the marker's `binary`.
4. The control file: `pg_controldata` reports the marker's "Database system
   identifier".
5. The socket directory: a real directory by `lstat`, owned, mode 0700.

The script never inspects other processes' command lines or environments,
never infers identity from a process id or name, never signals a process it
has not proven to be this cluster's postmaster, and never deletes, adopts or
cleans anything. Its children run with an empty environment.

### Settings written before the first start

```
listen_addresses = ''
unix_socket_directories = '/private/tmp/d237-pg'
port = 5541
log_min_messages = fatal
log_min_error_statement = panic
log_statement = none
log_min_duration_statement = -1
log_min_duration_sample = -1
log_transaction_sample_rate = 0
log_error_verbosity = terse
log_parameter_max_length = 0
log_parameter_max_length_on_error = 0
log_connections = ''
log_disconnections = off
log_autovacuum_min_duration = -1
log_checkpoints = off
log_lock_waits = off
log_lock_failures = off
log_temp_files = -1
shared_preload_libraries = ''
session_preload_libraries = ''
logging_collector = off
```

Before any real-data load, the item-7 logging canary proves, for the tested
paths only, that synthetic marker values do not reach `postgres.log`.

## Process kinds and commands

| Command | Kind | What it may do |
|---|---|---|
| `mix sdr.prototype.setup` | setup (Repo only, no Oban) | the one-time bootstrap into a fresh `sdr_agent_prototype` |
| `mix sdr.prototype.provision` | task | the one funded grant, after the budget worksheet |
| `mix sdr.prototype.import` | task | at most three imported contacts for the binding |
| `mix sdr.prototype.op assign\|review\|approve\|reject\|revoke\|seed\|status` | task | one operator action; `assign` and `approve` insert jobs only (insert-only Oban) |
| `mix sdr.prototype.serve` | serve | queues, the `claude_cli` provider, the endpoint on 4120 only if `lsof` shows that port free; it never stops another listener |

- `op review --draft <id>` writes the private 0600 bundle (the pending-revision
  view with the recipient contact id and exact email) and prints only the
  bundle UUID and item count.
- `op approve --revision <id> --revision-sha256 <hex> --recipient-email <addr>`
  takes all three exactly as reviewed. A missing one refuses before any action,
  and the address is never refilled from the current contact.
- With the switch set (`SDR_PROTOTYPE`, `SDR_PROTOTYPE_INSTANCE`), every task in
  `lib/mix/tasks` other than `sdr.prototype.*` and `sdr.audit.export` refuses as
  its first statement.
- Command output carries codes, counts and ids only. Content goes only to the
  private bundle under `<root>/bundles/` (directory 0700, files 0600, never
  overwritten).

## Retention

Every copy is kept until the D-239 window ends (2026-11-07T07:00:00Z) and then
until a separate owner-approved disposal step. Nothing is deleted by these
commands (plan r7 section 7).
