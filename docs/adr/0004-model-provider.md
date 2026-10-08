---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0004: Model Provider Seam — Fake Default, Claude CLI for Personal Local Use

## Status

Accepted (2026-10-06, owner decision recorded in ADR-0001: "Real model: Codex
app-server on the owner's ChatGPT plan; deterministic fake model is the
default"). Details amended by Codex consultations 08, 09 and 15, and by the
S6a implementation approved on 2026-10-06. The owner approved the ClaudeCLI
pivot on 2026-10-07; the amendment below replaces the earlier CodexAppServer
runtime decision while retaining it as historical rationale. The Q0.1
amendment (runtime provider selection) is pending Codex review on its PR.

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
- Each adapter is started with an explicit `codex_home`; the Port receives
  that exact path as `CODEX_HOME` instead of inheriting an ambient login home.
  The production S12 command is `llm-proxy-shim codex app-server` (with no
  post-subcommand `-c` flags), so the shim can apply its routing lock and wire
  witness. Direct `codex app-server` is reserved for an explicitly configured
  local diagnostic.
- Provenance is an allowlist: app-server user agent/version, selected model
  catalog fields, non-secret effective config fields, account mode, and the
  owner's recorded data-control setting. Raw account/config responses are
  discarded. Turn request/response records remain available for S3 audit
  persistence.
- Threads use a new empty mode-0700 temporary working directory,
  `approvalPolicy = "never"`, and `sandbox = "read-only"`. Their thread config
  disables shell/unified exec, patch/file tooling, web search, MCP, apps,
  plugins/skills, browser/computer use, image tools, delegation, and other
  model-callable feature surfaces. This is required because read-only
  sandboxing limits writes but does not remove read/exfiltration tools
  (official app-server protocol documentation:
  https://developers.openai.com/codex/app-server/).
- Item streaming is independently fail-closed: only agent messages, reasoning,
  and user messages are accepted. Command execution, file changes, MCP calls,
  web search, and unknown future item types interrupt the turn, drain it, and
  return an error without a result. A monotonic per-turn deadline uses the same
  interrupt-and-drain path; callers wait for the server-enforced outcome rather
  than timing out while stale events remain queued.
- Threads expose no dynamic tools, and treat tool or approval requests as
  provider failures.
  Structured output is requested with `Zoi.to_json_schema/1` and parsed again
  locally with `Zoi.parse/2`.
- The deterministic Fake is the configured default. A hermetic OS-process
  fake covers the JSONL contract; the real cached-login smoke test is tagged
  `:external` and excluded from normal test and CI runs.

### S6a ClaudeCLI pivot amendment (2026-10-07)

The real provider is now **ClaudeCLI** and the prior CodexAppServer adapter is
disabled fail-closed. This is a personal, local, single-operator integration
with the owner's existing Claude login; it is not an SDK, hosted service,
multi-user feature, or authorization to relay subscription credentials. If
that boundary cannot be maintained, use a paid API key instead.

- Launch every call as `llm-proxy-shim claude -p` with model alias `opus`,
  structured JSON output, an empty private cwd, no session persistence, no
  permission prompting, an empty tool set, strict empty MCP configuration,
  and slash commands disabled.
- Pin the reviewed alias resolution to `claude-opus-5-5` on Claude Code
  `2.1.291`; record both alias and
  resolved ID on every `ModelInvocation`. Every process must emit a matching
  init attestation with `tools = []`, `mcp_servers = []`, and
  `slash_commands = []` before output is accepted. Missing, malformed, or
  drifted attestations fail closed.
- Serialize calls through one GenServer. Prompts are mode-0600 files consumed
  through stdin rather than process arguments. Stderr is discarded, protocol
  errors are sanitized, and timeouts terminate the observed descendant process
  tree before returning an unknown outcome.
- S3 now owns the persisted invocation lifecycle: reserve before launch, mark
  sent, then complete, fail, or mark unknown through `SdrAgent.Agents`. The
  persisted run counter enforces 20 calls/run. The replaceable in-memory seam
  remains only for the 200-per-UTC-day aggregate until that aggregate has a
  persisted S3 resource; it conservatively counts attempts and resets on VM
  restart.
- Do not pass `--json-schema`: Claude CLI implements it by adding a
  `StructuredOutput` tool, which violates the empty-tools invariant. Request
  JSON in the prompt and parse every result with Zoi before completion.
  Invalid output is persisted as failed and never returned as a successful
  result. The deterministic Fake remains the dev/test/CI default.

### S7 amendment (2026-10-07): persisted daily limit and drift attention

- The volatile `SdrAgent.AI.BudgetStore` seam is removed. The 200-per-UTC-day
  limit is enforced inside `SdrAgent.Agents.reserve_model_invocation/3`'s
  transaction: after the run counter is reserved, the tenant's audit
  chain-head row is locked and the tenant's `ModelInvocation`s whose
  `reserved_at` falls in the current UTC day (`SdrAgent.Clock`) are counted;
  at the limit the whole reservation rolls back with
  `{:error, {:budget_exhausted, :daily}}` and no provider is invoked. The
  chain-head lock is held until commit, so concurrent reservations
  serialise. Attempts (failed, invalid and unknown calls included) are never
  refunded, so the aggregate survives restarts and is recomputable from the
  ledger. `config :sdr_agent, :daily_model_call_limit` may lower the limit,
  never raise it above 200. The day is the UTC day, as this ADR and the S2
  entity model state.
- A Claude CLI failure that means the reviewed launch configuration drifted
  (missing init attestation, or one naming another model, version, tools,
  MCP servers or slash commands) fails the invocation and opens a critical
  `provider_error` operator-attention Failure in the same transaction.

### Q0.1 amendment (2026-10-07): runtime provider selection

Found live: `ClaudeCLI.complete/2` required a `:server` option that the
running application never supplied, so every `claude_cli` agent job raised
inside the provider and was recorded as `provider_outcome_unknown`. The real
model had only ever worked from tests that started their own server. The
selection is now explicit runtime configuration, with no persisted setting,
resource or policy change:

- `config/runtime.exs` reads `SDR_MODEL_PROVIDER`. Unset or `fake` keeps the
  deterministic Fake in every environment. `claude_cli` is accepted **only
  in development**. In `test` it is refused at boot, so tests stay hermetic.
  In `prod` it is refused at boot because this ADR limits ClaudeCLI to
  personal, local, single-operator use of the owner's own login; there is
  no production opt-in. Any other value is refused, never defaulted.
  `SDR_CLAUDE_CLI_TIMEOUT_MS` (an integer of at least 1000, default
  240000) sets the per-call, end-to-end timeout.
- With ClaudeCLI selected, `SdrAgent.AI.ModelProvider.Runtime.children/0`
  adds exactly one ClaudeCLI GenServer to the application tree, registered
  as `ClaudeCLI.server/0`. It starts before Oban, so no agent job can run
  before it. One server keeps concurrency at 1 (C8): the `research` queue's
  concurrency does not change that, because every call goes through the
  server.
- One validated selection serves every model-call path. `AgentWorker`,
  `ReplyWorker` and the public `ModelProvider.complete/2` all resolve the
  model through `Runtime.resolve/1`, which injects the named server. The
  following are refused before any reservation, never downgraded to the
  Fake:
  - a ClaudeCLI that is absent (`:provider_not_running`);
  - one whose admission is closed (`:provider_not_quiescent`, see below);
  - one whose launcher is missing (`:llm_proxy_shim_not_found`).
  The check applies to a named server however it is referenced, by name
  or by pid: the reference is normalised to the registered name before its
  published health is read. It is in addition to the per-call init
  attestation, which stays mandatory, and to the server's own admission
  fence.
- The workers inject the named server in the same way. For `AgentWorker` this
  covers both the default provider and one carried by the job. If ClaudeCLI
  is wanted but its server is not running, no model call or reservation is
  made. The run fails with `provider_error`, which opens its critical
  operator-attention Failure; for `AgentWorker` it is linked from the
  Operation. The job returns `{:error, :provider_not_running}`. A job that
  names a provider other than `fake` or `claude_cli` is refused the same
  way, with `{:error, :unknown_model_provider}`. Neither case raises, and
  neither falls back to the Fake. `ClaudeCLI.complete/2` without `:server`
  calls the named server, and returns the same typed error when no server
  is running.
- Process lifecycle (Codex review of PR #27):
  - The per-call `timeout` is end to end and counts from `complete/2`,
    including time spent queued. A request that reaches the front with
    less than min(1 s, timeout/2) left is refused without launching
    (`{:error, :provider_queue_timeout}`, recorded as a failed invocation).
  - A request whose caller died while it was queued is dropped without
    launching. A caller that dies during its call stops that CLI tree.
  - A call returns only after its whole process tree (root included) is
    gone and its workspace has been removed.
  - Each server has an unlinked `ClaudeCLI.Reaper` that monitors it, and
    every launch is opened by that reaper: the reaper calls `Port.open/2`,
    so it owns the OS pid before the CLI can run (there is no hand-off
    window), and it forwards the port's messages to the server in order.
    If the server dies, even by `:kill`, the reaper kills the tracked
    trees and removes their workspaces. The reaper builds the launch
    environment from the server's allowlist with `SdrAgent.ChildEnv`
    (ADR-0005 child-process amendment). Its own `ps`, `pgrep` and `kill`
    children use the same allowlist, so no parent secret reaches them. A killed call is still recorded as
    unknown and is never resent.
  - Admission is a lease, held only while proven safe. A named server takes
    a `:persistent_term` lease (written once per server start, not per
    call) through its reaper. The reaper erases it only as its cleanup
    receipt, after every tracked tree is confirmed gone; if a tree cannot
    be confirmed stopped, the reaper retries and logs an error, and the
    lease stays held. While another reaper holds the lease, the server
    refuses every call with `{:error, :provider_not_quiescent}`, and Admin
    shows the server as blocked:
    - If that reaper is still cleaning up, the server is admitted once it
      exits.
    - If that reaper died without a receipt, admission stays closed until
      an operator who has checked that no CLI process is left runs
      `ClaudeCLI.Reaper.release/1`.
    A tree the server itself cannot confirm stopped after a call also
    closes admission until the tree is gone. So does a launch whose receipt
    never arrived, because the reaper died or the handshake outlived the
    deadline. Such a launch may already be running, so its outcome is
    unknown (`{:unknown, :reaper_down}` or
    `{:unknown, :launch_handshake_timeout}`). Admission stays closed until
    either a late receipt makes the launch known and it is confirmed
    stopped, or an operator release attests that it is gone.
    One exception lets a server take over a dead reaper's lease: the
    server is still alive and affirmatively knows that none of its
    launches is unknown or unconfirmed (no launch in flight, none whose
    receipt was lost, none it failed to stop). Otherwise the lease stays
    with the dead reaper. This keeps concurrency at one across crashes and
    restarts, and a reaper's exit is never treated as proof of cleanup.
  - `timeout` must be at least 1000 ms. The deadline is absolute from
    enqueue: it is checked before dispatch, checked again after the
    workspace is prepared, and bounds both the launch handshake and the
    run. A pre-send refusal is an error; an in-flight timeout or a missing
    launch receipt is unknown.
  - Limitation: CLI helpers that re-parent away from the root before a
    kill are not found (the tree is walked with `pgrep -P`).
- Boot preflight: Claude CLI has no no-call probe for the init attestation.
  Model, version, tools, MCP servers and slash commands are reported only
  by a `-p` session, which also sends a model request. So boot spends no
  model call. It records the attestation as *pending: checked at the first
  call*, and whether `llm-proxy-shim` was found. Each call then records its
  init outcome (attested, or drift with the reason) in a protected,
  in-memory ETS table owned by the server. The table holds no prompt,
  output or credential, and is not persisted: the ModelInvocation ledger
  stays the record. Drift still fails the invocation and opens the critical
  `provider_error` Failure (S7 amendment).
- The Admin page shows the configured provider and the effective one. The
  effective provider is none, with the refusal reason, while calls are
  refused. It also shows the model alias and resolved id, the reviewed CLI
  version, the server state (running, not running, or blocked), and the
  last attestation with its time. It shows no secret. It refreshes live (ADR-0012) when an
  audit event commits. The card only reflects the attestation; the
  per-call attestation remains what refuses a drifted CLI.

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
