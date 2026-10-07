---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0004: Model Provider Seam — Fake Default, Codex App-Server on the Owner's ChatGPT Login

## Status

Accepted (2026-10-06, owner decision recorded in ADR-0001: "Real model: Codex
app-server on the owner's ChatGPT plan; deterministic fake model is the
default"). Details amended by Codex consultations 08, 09 and 15, and by the
S6a implementation approved on 2026-10-06.

## Context

The agent needs a real model for the demo, while tests, CI and the default
demo must be deterministic, free, and hermetic. The owner has a ChatGPT plan
with an existing local Codex login and a Claude subscription, and prefers not
to provision paid API keys for the MVP.

Facts established on 2026-10-06:

- OpenAI documents `codex app-server` (JSON-RPC over stdio) as an integration
  surface; local and open-source apps may use app-server authentication, which
  exposes `account/read` and its own ChatGPT login flow
  (https://learn.chatgpt.com/docs/app-server). Hosted, multi-user, or commercial
  use is not permitted. App-server is documented as **experimental**.
- "Sign in with ChatGPT" (SIWC) for open-source apps uses dynamic client
  registration (https://developers.openai.com/siwc/token-sharing-open-source/sign-in);
  the commercial client-ID waitlist does not apply to it.
- Anthropic's Claude Code legal page says subscription OAuth is meant for
  ordinary use of Claude Code and native Anthropic apps, and that developers
  building products, including with the Agent SDK, should use API keys; it
  does not permit routing requests through Free, Pro, or Max credentials on
  behalf of users; subscription OAuth is "intended exclusively for purchasers
  of Claude" subscription plans
  (https://code.claude.com/docs/en/legal-and-compliance). Driving
  `claude -p` on a subscription from this app is therefore at best a gray
  area, and `--bare` (the isolated mode) never reads OAuth.
- ChatGPT-plan traffic follows the signed-in workspace's data controls, not
  API organization or zero-retention terms (https://learn.chatgpt.com/docs/auth).
  The owner set "Improve the model for everyone" to **OFF** (2026-10-06).
- `codex exec` sandbox flags do not fully remove harness tools, so a
  decision-only adapter must expose no executable tools at all.

## Options Considered

### Option 1: Paid API key via ReqLLM (OpenAI or Anthropic)

**Pros:** cleanest terms; documented API contracts.
**Cons:** paid; owner declined for the MVP. Remains the clean fallback.

### Option 2: `claude -p` on the owner's Claude subscription

**Pros:** available today.
**Cons:** conflicts with Anthropic's stated intent for subscription OAuth in
third-party apps; the isolated `--bare` mode cannot use OAuth; non-bare mode
loads host hooks and configuration.

### Option 3: Codex app-server on the owner's ChatGPT login (auth A now, SIWC B later)

**Pros:** documented for local and open-source use; works today on the cached
login; SIWC later swaps only the credential source behind the same JSON-RPC
protocol.
**Cons:** experimental surface; JSON-RPC is not the exact provider-bound bytes;
plan rate limits apply.

## Decision

We will define an `SdrAgent.AI.ModelProvider` behaviour with two
implementations in the MVP:

1. **Fake** — deterministic, fixture-driven; the default for tests, CI, and
   `bin/demo`. Real providers are opt-in per command.
2. **CodexAppServer** — spawns `codex app-server` over stdio.
   - **Auth A (now):** the owner's existing cached Codex ChatGPT login,
     confirmed via `account/read`; if absent, invoke app-server's own login
     flow (owner checkpoint). Never read, copy, scrape, or store tokens.
   - **Auth B (S14, before open-source release):** SIWC dynamic client
     registration with a `127.0.0.1` callback and one browser consent; tokens
     stored via sops by `bin/siwc-login`, never in plaintext.

Constraints on the real provider:

- **Personal, local, single-operator use only.** No hosted, multi-user, or
  commercial traffic on the owner's login (ADR-0001 invariant).
- **Budgets:** at most 20 model calls per agent run and 200 per UTC day,
  enforced before the call (pre-call reservation) and reconciled after it
  using provider-reported usage. Exhaustion persists a reason and requires an
  operator action; it never retries in a loop.
- **Concurrency 1:** app-server calls are serialized until trace or
  invocation-ID propagation to the wire witness is proven (ADR-0005).
- **Preflight model selection:** the model is chosen at startup from the
  app-server model catalog and recorded; never assumed.
- **No tools exposed to the model.** The model returns structured decisions
  only; **Jido is the only action executor**.
- **Zoi validation of every structured output.** Invalid output is a recorded,
  failed invocation, never coerced.
- **Provenance recorded on every ModelInvocation (ADR-0002):** app-server
  version and configuration, model catalog entry, account mode (cached login
  or SIWC, as an opaque reference, never a token), data-control setting at
  decision time ("Improve the model for everyone" = OFF, 2026-10-06), and full
  JSON-RPC request and response. JSON-RPC records what we asked app-server, not
  the exact upstream bytes; ADR-0005 covers the wire witness.
- The public README states that users bring their own login or API key.

We will not build a `claude -p` subscription adapter.

### S6a implementation amendment

S6a implements the accepted boundary without adding a dependency:

- `SdrAgent.AI.ModelProvider` owns pre-call reservation, a `gen_ai.*` span,
  provider invocation, mandatory Zoi parsing, and settlement.
- `SdrAgent.AI.BudgetStore` is the replacement seam for S3. Its S6a
  implementation is a supervised Agent with volatile 20-per-run and
  200-per-UTC-day counters. Reservations count attempts and are not refunded;
  it is safe for deterministic development but not authoritative across
  restarts, so unattended real-provider use remains blocked on S3 persistence.
- `CodexAppServer` is one GenServer owning one stdio Port, which makes
  concurrency 1 executable. It exchanges newline-delimited JSON-RPC, sends
  `clientInfo.name = "sdr_agent"`, reads `account/read`, `config/read`, and
  `model/list` before any turn, and fails closed without a cached ChatGPT
  account or selected model. It never invokes login or reads token files.
- Provenance is an allowlist: app-server user agent/version, selected model
  catalog fields, non-secret effective config fields, account mode, and the
  owner's recorded data-control setting. Raw account/config responses are
  discarded. Turn request/response records remain available for S3 audit
  persistence.
- Threads use `approvalPolicy = "never"` and `sandbox = "read-only"`, expose
  no dynamic tools, and treat tool or approval requests as provider failures.
  Structured output is requested with `Zoi.to_json_schema/1` and parsed again
  locally with `Zoi.parse/2`.
- The deterministic Fake is the configured default. A hermetic OS-process
  fake covers the JSONL contract; the real cached-login smoke test is tagged
  `:external` and excluded from normal test and CI runs.

## Justification

Option 3 is documented for this use, available now, and keeps a migration path
to SIWC without changing the provider interface. The fake default keeps tests
hermetic and the demo reproducible. Option 2 was rejected on terms; Option 1
stays available if app-server becomes unusable (fallback per ADR-0001).

## Consequences

### Positive

- Tests and CI never touch a real model.
- Provider swap (API key, SIWC) is a new behaviour implementation, not a
  redesign.

### Negative

- Experimental app-server may break between Codex releases; we pin and record
  the version.
- Plan rate limits and data handling follow ChatGPT consumer terms, not API
  terms.

### Neutral

- Usage and cost are counted in plan calls, not dollars.
