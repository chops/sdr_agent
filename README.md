# SdrAgent

An audit-first SDR (sales development) agent MVP. The model is Jido for
decisions, Ash for governance, Oban for durable execution, Postgres as the
system of record, and Phoenix LiveView for operator control. Every step the
agent takes can be reconstructed from Postgres, the audit chain is hash-linked
and verifiable, and every outbound message needs a human approval bound to
the exact revision. Delivery is **local capture only**.

All data is fictional (`*.example.test`, `*.test` domains). This is a local
demo, not a hosted service.

## Prerequisites

- Nix with flakes, plus [direnv](https://direnv.net/) with nix-direnv. The
  toolchain is pinned in `devenv.nix` and `flake.lock`: Elixir 1.20.4,
  OTP 29 and PostgreSQL 18.
- Ports **5520** (Postgres) and **4120** (Phoenix) must be free:
  `lsof -nP -iTCP:5520 -sTCP:LISTEN`.
- Optional: a local Grafana with Tempo for trace links
  (`http://localhost:3000`, Tempo datasource uid `tempo`, OTLP/HTTP on
  `127.0.0.1:4318`). The app runs without it.

## One-time setup

```sh
direnv allow                 # enter the devenv shell (Mix deps live in .devenv/state)
devenv up                    # start Postgres on 127.0.0.1:5520 (leave it running)
mix deps.get
mix assets.setup             # one-time download of the pinned asset binaries
```

`mix assets.setup` downloads **tailwind 4.3.0** from GitHub releases and
**esbuild 0.25.4** from the npm registry. Both versions are pinned in
`config/config.exs`. This is the only network step besides `mix deps.get`.
Run it once while online. If it is skipped, the dev server's asset watchers
download the binaries on first start.

## Run the demo

```sh
bin/demo reset --yes && bin/demo seed && bin/demo run
```

Then open <http://localhost:4120>. Run `bin/demo status` in another terminal
at any time.

| Command | What it does |
|---|---|
| `bin/demo reset --yes` | Drops, creates and migrates `sdr_agent_dev`. Destructive, so it needs `--yes`, and it refuses while anything is connected to the database (a server on any port, IEx, psql). The drop is never forced. |
| `bin/demo seed` | Seeds the fictional ICP, campaign, 10 accounts and contacts with leads, 3 operators and one suppression. Idempotent. |
| `bin/demo run` | Checks that the port is free and the database is reachable, migrated and seeded, then starts Phoenix on `PORT` (default 4120). |
| `bin/demo predeliver` | Runs fixture lead 01 (Brightpath Freight Systems) through research, qualification and drafting, and prints the `/drafts/…` path of the draft awaiting review. It **never approves**: every outbound message needs a human approval (ADR-0001 Tier 0). Idempotent; a re-run reports the stage (awaiting review, queued, deferred, captured). |
| `bin/demo status` | Shows the database, migrations, server, Oban queues and job counts, leads by status, drafts awaiting review, captured messages and the audit chain verification. |

`bin/demo` refuses to run against anything except the local demo database: it
needs `MIX_ENV=dev` (or unset), no `DATABASE_URL`, and a Repo of
`sdr_agent_dev` on `localhost`/`127.0.0.1:5520`. The `--test` flag is for the
script's own tests only. It uses a separate throw-away database.

### Before an evening demo

The campaign's quiet hours start at 18:00 America/Denver. To show a captured
email after that, prepare **before 18:00**:

1. With `bin/demo run` serving, run `bin/demo predeliver`. It prints the
   `/drafts/…` path of lead 01's draft.
2. Sign in as the reviewer, open that draft and **approve it yourself**. This
   also rehearses the demo. The server's delivery queue captures the email
   within seconds, and `bin/demo predeliver` (re-run) or the draft page then
   shows "captured".

During the demo, walk through lead 01's evidence, the approved draft and its
captured message. Assign a second qualifying lead (02, 03, 09 or 10) live to
show the agent working. An approval made inside quiet hours is deferred by
the send gate, which is itself worth showing.

### Demo operators

Three operators are seeded: `admin@example.test`, `reviewer@example.test` and
`auditor@example.test`. Their passwords are fixtures in
`lib/sdr_agent/demo/fixtures.ex` (`users/0`). They are dev and test data, and
seeding is refused in other environments.

### Demo script

The steps below use the element ids from the console, so the same path can
be scripted.

1. **Sign in** as the reviewer at `/sign-in`. The Dashboard shows the
   pipeline: 10 leads, of which 1 is stopped because Harborline Routing is
   suppressed.
2. **Leads → Brightpath Freight Systems** (lead 01). Click **Assign to agent**
   (`#assign-lead`). Using the deterministic fake model, the agent researches
   fixture sources, extracts evidence, qualifies the lead, and drafts an
   email. The page updates live as each step commits: `#lead-runs`,
   `#qualification` and `#lead-drafts`.
3. Open the run (`/runs/:id`) to see every decision, model invocation and
   tool call. It also updates live.
4. **Review queue** (`/review`) now lists the draft. Open it (`/drafts/:id`).
   Click a highlighted sentence to see the evidence claim and source quote
   behind it.
5. Optionally **edit** the draft (`#edit-toggle`). This creates a new human
   revision with an AI-vs-human diff.
6. **Approve** (`#approve-form`). The approval binds the revision id and
   content hash shown on screen. If the draft changed in the meantime, the
   page says so (`#newer-revision`) and the domain refuses the stale verdict.
   The delivery is queued, captured by the local capture adapter, and its
   receipts and exact RFC 5322 message appear on the draft page ("Captured
   message").
7. **Runs & operations** (`/operations`) shows the durable work and anything
   that needs attention.
8. Sign in as the **admin** or **auditor** and open **Audit** (`/audit`) for
   the hash-chained timeline. Click **Verify chain** (`#verify-chain`) and
   open payloads (`/audit/payloads/:sha256`). Every auditor view is itself
   recorded as an AuditAccess.

Replies (one interested, one unsubscribe) are simulated by signed webhooks.
That arrives with the S9 slice and is not part of this runbook yet. See
`notes/features/s13-acceptance.org`.

### Audit verification and export

```sh
bin/demo status                     # includes the chain verification result
bin/with-secrets SDR_AUDIT_ANCHOR_PRIVATE_KEY -- mix sdr.audit.export --lead <LEAD_ID>
mix sdr.audit.verify audit-export-lead-<LEAD_ID>.json   # pinned key set: docs/audit/trusted-keys.json
```

The export task needs the Ed25519 anchor key, which only `bin/with-secrets`
provides (sops). The verifier needs no secret. Anchoring runs every minute
when the server has the key: `bin/with-secrets SDR_AUDIT_ANCHOR_PRIVATE_KEY --
bin/demo run`. Without the key, anchoring does not run, and the chain itself
still verifies. Offline (for example on conference Wi-Fi), set
`SDR_ANCHOR_SINKS=file` (anchors go to `tmp/audit-anchors`) or `none`. The
default `git+ots` pushes to the private anchors repository and the
OpenTimestamps calendars.

### Traces

Every console page with a trace id links to Grafana Explore on Tempo
(`http://localhost:3000`, datasource `tempo`). You can change both with
`config :sdr_agent, SdrAgentWeb.Trace, grafana_url: ..., datasource_uid: ...`.
In dev the app exports OTLP/HTTP to `127.0.0.1:4318`, with prompt and
completion content as span events (synthetic data only, per ADR-0005).

## What is real and what is simulated

- **Model:** a deterministic fake model by default
  (`SdrAgent.AI.ModelProvider.Fake`), so the demo needs no account or
  network.
- **Research sources:** fixture CRM, search and web providers. Nothing is
  fetched from the internet.
- **Email:** local capture only (`CaptureAdapter`). No adapter or
  configuration can reach a real recipient, and a test enforces that.
- **Replies:** simulated, signed (HMAC) and deduplicated webhooks (S9).
- **Real:** the Jido agent and flows, Ash policies, Oban jobs, the
  hash-chained audit ledger and its verification, approval binding,
  suppression, quotas and quiet hours.

### Real-model opt-in (personal local demo only)

The `ClaudeCLI` provider (ADR-0004) calls Claude Code through
`llm-proxy-shim`, using **your own** local Claude Code login. It is for a
personal local demo only: never hosted, shared or multi-user traffic. To use
it, start the server with `iex -S mix phx.server` and, before you assign a
lead, run:

```elixir
Application.put_env(:sdr_agent, SdrAgent.SDR,
  model: [provider: SdrAgent.AI.ModelProvider.ClaudeCLI])
```

Budgets still apply: 20 model calls per run and 200 per UTC day.

## Troubleshooting

- **`bin/demo run` says the port is in use.** Run
  `lsof -nP -iTCP:4120 -sTCP:LISTEN` and stop that process, or use
  `PORT=4122 bin/demo run`. `bin/demo` never picks another port silently.
- **The database is unreachable.** Start Postgres with `devenv up`.
  `bin/demo status` shows the connection error.
- **Migrations are pending or the tenant is not seeded.** Run
  `bin/demo reset --yes && bin/demo seed`.
- **Tailwind or daisyUI does not resolve, or icons are missing.** Run
  `mix assets.setup` once while online, then `mix assets.build`. Asset paths
  come from `MIX_DEPS_PATH` and `MIX_BUILD_ROOT` under devenv, so run Mix
  inside the devenv shell.
- **A delivery stays pending.** The campaign honours quiet hours from 18:00
  to 08:00 America/Denver, and a daily cap of 25. The send gate defers until
  the window opens, and the deferral is recorded as a `send_gate` decision in
  the audit timeline.
- **Anchoring errors in the log.** The anchor key is not set. See
  "Audit verification and export" above.

## Development

```sh
bin/verify                          # format, compile --warnings-as-errors, tests
mix ash.codegen --check && mix credo
```

Parallel worktrees share the devenv Postgres: run tests with a partition, for
example `MIX_TEST_PARTITION=_s13 mix test`. Architecture decisions are in
`docs/adr/`, and slice notes are in `notes/features/`.
