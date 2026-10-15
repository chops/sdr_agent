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
The R0 amendment (2026-10-12, at the end of the Decision section) is
**accepted**: owner acceptance in the private Claude session chat on
2026-10-12 ("accept PR #39"), after Codex's independent approval of 6f2fab2.
The C2-02b2 amendment (2026-10-15, at the end of the Decision section) is
**accepted**: owner acceptance in the private Claude session chat on
2026-10-15 at about 10:06 MDT ("i accept the ADR-0004 C2-02b2 amendment at
80771e5"), after Codex's independent approval of 65d7308 (16c1a6fe) and of
the exact text at 80771e5 (61492fe0). Acceptance is not merge, activation
or spend approval.

### Current policy (summary, 2026-10-12)

The sections below are kept in the order they were decided, so early text is
historical. What applies today:

- The deterministic Fake is the default for development, tests, CI and the
  demo seed. A real model is used only in the owner's own local demo.
- The real provider is the Claude CLI on the owner's own Claude subscription,
  for personal, local, single-operator use only. This is the owner's accepted
  terms risk, not vendor approval or permission for anyone else. Nobody else
  may use the owner's login; another user needs their own provider and terms
  decision (Option 1, a paid API key, is the clean route).
- The CodexAppServer adapter is disabled fail-closed.
- Every call has no tools, no MCP servers and no slash commands, attested per
  call, and is serialized (one call at a time).
- Accepted for R0 (being built): an app-owned pinned CLI, closed reviewed model profiles
  (Opus and Sonnet), an audited in-app switch, and owner-granted call budgets.

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

> **Superseded (2026-10-07).** This was the original decision, made on terms
> and on non-bare mode loading host configuration. The owner approved the
> ClaudeCLI pivot below for personal local use; hardening and per-call
> attestation reduce the configuration risk and are re-reviewed on every CLI
> upgrade. The original reasoning is kept as history.

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

### R0 amendment (2026-10-12, accepted): app-owned CLI runtime, closed model profiles, audited switch, call grants

**Context.** On 2026-10-08 the agents' own Claude CLI was updated system-wide
to 2.1.294. The app resolves `claude` from the same system installation and
is pinned to the reviewed 2.1.291, so every real-model call now fails closed
on attestation drift. The agent CLIs will update again before the Nov 6
workshop. The owner decided (walkthrough rows 14-19c, 14-19d, 21b, 22;
D-087, D-088, D-096, D-098, D-099):

- keep the Claude CLI on the owner's subscription as the tested path;
- make the model layer flexible enough to add other models and providers
  later, without redesign;
- switch models from the admin page without restarting the app;
- launch with two reviewed profiles, Opus and Sonnet, each proven with its own
  budgeted synthetic calls;
- included subscription usage only (paid extra usage kept off by the owner);
- every real call admitted against an owner-created budget grant that only
  the owner can change.

**Decision.**

1. **App-owned CLI runtime.**
   - The app launches the Claude CLI from an app-owned, content-addressed
     installation pinned in this repository: a Nix store path built from a
     pinned source and hash. It passes the absolute path to `llm-proxy-shim`
     and never resolves `claude` from `PATH`. System and agent CLI updates
     therefore cannot change the app's CLI.
   - Allowing the CLI's unfree licence is scoped to that one package.
   - Changing the pin (version, source or hash) is a reviewed pull request.
     It records the candidate version's evidence (release, and that the flags
     and init attestation fields it relies on are unchanged or adapted),
     updates the reviewed version in the profile registry, and handles witness
     disposition (item 6). This amendment authorizes the mechanism; each bump
     still needs its own review.
   - If the pinned build is missing, or the shim cannot launch it by absolute
     path, ClaudeCLI is refused with a typed error. It never falls back to the
     system CLI or to the Fake. A wrapper, if the shim needs one, is reviewed
     code that also never uses `PATH`.
   - The per-call init attestation stays mandatory: expected model and CLI
     version, empty tools, empty MCP servers, empty slash commands.

2. **Closed profile registry.**
   - Model profiles are reviewed entries in code: profile id, adapter, CLI
     alias, resolved model id, reviewed CLI version and witness disposition.
   - Initial profiles, both on the one pinned CLI version:
     - `claude_cli_opus`: alias `opus`, resolved `claude-opus-5-5`;
     - `claude_cli_sonnet`: alias `sonnet`, resolved `claude-sonnet-5-5`.
   - Adding a profile is a reviewed code change plus its own proof. There is
     no free-text model, no user-supplied alias and no runtime-loaded plugin.
   - Each ModelInvocation also records its profile id, alongside the existing
     alias, resolved id and CLI version fields.
   - The Fake stays the default. `SDR_MODEL_PROVIDER` semantics are unchanged:
     `claude_cli` is accepted only in development.

3. **Active profile and in-app switch.**
   - **Persisted setting.** A persisted desired profile (default
     `claude_cli_opus`), distinct from the effective profile of the running
     server.
   - **Admin view.** The Admin page shows desired, effective, pending and
     blocked (with reason). Rendering it makes no model call.
   - **Who and how.** The switch is an admin-only action with audited
     confirmation. It restarts only the supervised ClaudeCLI server, not the
     application.
   - **Fencing and draining.** The switch fences new admission. It waits, for
     a bounded time, for prepared, reserved, queued and in-flight calls under
     the old profile to finish or be refused. Abandoned prepared callers are
     drained or refused.
   - **Reaper lease.** The switch never releases a Reaper lease whose cleanup
     is unconfirmed.
   - **Profile frozen per call.** Each invocation freezes its expected profile
     at reservation. Its launch is refused if the effective profile differs.
   - **Failed activation.** The previous profile is restored only when the
     candidate's work is confirmed clean. Otherwise the provider is shown
     blocked, with the reason, until an admin acts. Restoring never starts a
     process over unconfirmed work.
   - **Restart.** A restart restores the persisted desired profile.
   - **History.** Old invocations keep their original provenance and are
     never relabelled.
   - **No fallback.** There is no silent fallback between profiles or to the
     Fake.
   - **Review first.** The entity delta for this setting and action needs an
     independent PASS before implementation.

4. **Provider seam.**
   - `SdrAgent.AI.ModelProvider` stays the single facade. The adapter contract
     is documented: prepare and complete; outcomes success, known failure or
     unknown; the reserve, sent and record lifecycle; attestation or an
     equivalent check of the launched configuration.
   - A test-only adapter proves that a new provider plugs in without changing
     callers.
   - API-key providers (Anthropic API, OpenAI, Gemini, OpenRouter) are future
     adapters. Each needs its own amendment covering terms, data handling and
     credentials. None is part of R0.

5. **Call grants.**
   - Every real-model attempt is admitted against an owner-created grant, in
     addition to the 20-per-run and 200-per-UTC-day limits. A grant has a
     purpose, profiles, a total, a per-UTC-day limit, allocations, an expiry
     and a reserve.
   - Admission is checked in the same reservation transaction, under the
     existing lock order, and checked again at launch. Attempts count
     whatever their outcome and are never refunded.
   - Only the owner creates or changes a grant, through an audited admin form.
     Agents never change a grant. With no eligible grant, no real call is
     made.
   - Fake calls need no grant.
   - The app's counters cover only this app. The owner's other Claude
     sessions share the same plan, and the owner keeps paid extra usage
     disabled.

6. **Wire witness.**
   - The S12d enabled tuple (CLI 2.1.291, `opus`, `prompt-builder/1`) does
     not carry over to a new CLI version or profile.
   - Each (profile, CLI version, prompt builder) tuple needs its own reviewed
     projection and enablement under ADR-0005 before its calls can be
     reconciled. Until then, the witness labels those calls inferred.
   - The profile proof attempts are made with the witness capturing, and
     their reconciliation evidence is recorded per profile.

7. **Terms boundary (unchanged).** Personal, local, single-operator use of the
   owner's own login. The boundary does not extend to other users,
   deployments or hosted use.

**Consequences.**

- Agent CLI updates no longer break the app. The app's CLI changes only
  through a reviewed bump.
- The owner can choose Opus or Sonnet at run time, and every call records
  which one ran.
- Each new model or provider costs a reviewed profile or adapter plus its own
  proof. Each CLI bump costs a pin review and a witness disposition.
- The Nix store path ties the real-model path to this machine's Nix setup,
  which is acceptable for personal, local use.

### C2-02b2 amendment (2026-10-15, accepted): a coordinator-owned server lifecycle with allocated generations

**Context.**
- The R0 amendment accepted an audited in-app switch without a restart
  (C2-02, #52).
- Slices a and b1 built the switch records, the admission fence and the
  drain.
- The remaining step stops one supervised ClaudeCLI server and starts
  another at a different profile. It must prove which server and which
  owner a finalization belongs to. It must never open launches over
  unconfirmed CLI work, or over an outcome it can't read.
- Today a bare supervisor child restarts the server on its own, and the
  server's generation can't be told apart across restarts.
- The contract is `docs/product/r0/c2-02b2-interface.md` (interface and
  entity PASS at `c00ed69`, Codex).

**Decision.**

1. **A coordinator owns the server lifecycle.** `Runtime.children/0`'s
   bare ClaudeCLI child becomes a `ProfileSupervisor` (`:rest_for_one`):
   - a `ServerSupervisor` whose server child is `:temporary` (never
     restarted by a supervisor);
   - a `Coordinator`, the only process that starts, stops or replaces a
     server;
   - an `OperationSupervisor` for at most one switch worker, which dies
     with its coordinator.

   Concurrency stays one call at a time (ADR-0005, C8).
2. **Generations are allocated, never derived.**
   - Every server start (boot, replacement, activation, rollback,
     adoption) is first an audited `ModelServerStart` row.
   - Its generation is allocated under a per-tenant counter row, in one
     global lock order.
   - A row's identity is immutable, and its status is forward-only:
     `allocated → started → ready`, or `allocated | started → failed`.
   - Readiness evidence is truthful: `:spawn_preflight` or `:adopted`.
3. **Only the coordinator writes the lifecycle ledger.**
   - These writes run in the registered coordinator's own process, are
     bounded end to end like the b1 drain, and are fenced in the
     transaction by the stored latest start's boot: allocation, start
     transitions and the switch's `complete`, `fail` and `block`.
   - A new coordinator boot's first allocation fences every older boot.
   - Runtime code never initializes the admin-owned setting.
4. **A server-side launch hold.**
   - Every server the coordinator starts, or adopts after a restart,
     refuses newly dequeued calls before launch admission
     (`:provider_held`).
   - Only a fresh reconciled read by the current owner releases it.
   - An unknown outcome stays held.
   - The hold is separate from the Reaper's cleanup admission, which
     remains an independent veto.
5. **Cleanup proof is an acknowledged, correlated Reaper receipt.**
   - Before a stop, the coordinator registers a private single-use ref
     with the server's own reaper.
   - Only that ref's receipt, sent after confirmed cleanup and the
     reaper's own lease release, counts.
   - Anything else blocks the switch (a missing lease, a `DOWN` without
     the receipt, a dead holder, a timeout).
   - `Reaper.release/1` is never called by this code.
6. **Unchanged:**
   - the Fake default and the test/CI hermeticity;
   - the pinned CLI;
   - the per-call init attestation (never reset by a start or an
     adoption);
   - the call grants;
   - the no-call preflight;
   - a blocked switch has no exit until slice b2β's attended resolver.

**Consequences.**
- **Positive:** a switch or a coordinator crash can't reuse a generation,
  can't let a stale owner finalize, and can't reopen calls over
  unconfirmed work or an unknown commit.
- **Negative:**
  - four new named runtime processes (`ProfileSupervisor`,
    `ServerSupervisor`, `Coordinator`, `OperationSupervisor`) and two new
    tables;
  - a coordinator ledger call can delay its other messages for up to its
    bound (its status is read from ETS, so status never waits);
  - a crash during a switch leaves it blocked until b2β.
- **Neutral:** no new dependency. Domain writes stay Ash actions with
  audit (ADR-0009).

### C2-02b2β amendment (2026-10-15, proposed): the attended resolver for a blocked switch

**Status: proposed.** It needs the owner's acceptance before b2β's
implementation approval. Contract: `docs/product/r0/c2-02b2b-interface.md`
(draft 3, in Codex review).

**Context.**
- The C2-02b2 amendment leaves a blocked switch without an exit
  (decision 6), with the server held, and forbids `Reaper.release/1`
  (decision 5).
- A switch blocks when its outcome can't be proven: an unconfirmed
  cleanup, a worker or coordinator death, an uncertain finalization, or a
  drain or veto failure. Most of these have no receipt that could ever
  arrive.
- A blocked switch also occupies the tenant's single open-switch slot.

**Decision.**
1. **The only exit from blocked** is an attended resolution to
   `:failed`.
   - **Who:** an active human admin decides, with the role and tenant
     re-read; any active admin may do it (C2-02b2β OQ-2).
   - **Where:** the registered coordinator executes it, in a new
     `:resolve` phase. `model_runtime` gains no authority.
   - **What:** a typed attestation (`STOPPED <switch id>`). The setting is
     unchanged, and there is no blocked → completed path.
2. **The attestation binds:**
   - the switch and the tenant;
   - the covered range of starts, from the switch's generation to the
     latest start, which must be the coordinator's current start of its
     own boot, re-checked after the locks;
   - the observed lease state: none, the current server's own live
     reaper, or one dead holder recorded by a covered start;
   - the outcome.

   It is replay-idempotent by id. A replay writes nothing and authorizes
   nothing new.
3. **A narrow exception to C2-02b2 decision 5.** The coordinator may call
   `Reaper.release/1` only under the cleanup authority R:
   - the resolved switch is the tenant's newest;
   - no switch is open;
   - no start has been allocated since the resolution;
   - the lease is held by a dead process exactly equal to the attested
     holder;
   - no named server is live.

   R is evaluated after the commit and before a boot's first allocation.
   The first later allocation, or the next open switch, consumes it.
   Otherwise decision 5 stands.
4. **The current server's work is never attested.** Stopping that server
   still needs a fresh receipt. When cleanup can't be proven otherwise,
   the result is a held hard conflict (`:cleanup_unprovable`), with the
   existing operator path as its exit.
5. **Unknown outcomes stay held.** An unknown commit is settled by a
   stored read before any other action. Only the C2-02b2 reconciliation
   releases the hold.
6. **Unchanged:**
   - `complete` and `fail` refuse a blocked switch;
   - `block` keeps its no-write replay;
   - one narrow change: `fail` on a resolved switch is refused rather
     than read as a replay;
   - the lock order, the Fake default and the call grants.

**Consequences.**
- **Positive:** a blocked switch has a safe, audited exit, and its lease
  can be cleared without a manual console step when the attestation binds
  it exactly.
- **Negative:**
  - a human attestation is trusted for work the system can't observe;
  - the hard conflict still needs the operator path;
  - the coordinator boot gains one read-only check and at most one
    release before its first allocation.
- **Neutral:** no new table, dependency or process.

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

### Deterministic schema generation amendment (2026-10-07)

`Zoi.to_json_schema/1` emits an object's `required` list in an order that
varies across BEAM VM runs. As a result, `output_schema_sha256` and the
rendered schema could differ between processes for an unchanged schema.

New schemas are now generated by a single function,
`SdrAgent.AI.JsonSchema.render/1`: `Zoi.to_json_schema/1` with string keys,
followed by schema-aware normalisation.

- Normalisation sorts only the `required` keyword of schema nodes, in byte
  order, without deduplicating.
- It recurses only into schema positions, and keeps the order of every
  other list.
- Literal `const`, `default`, `enum` and `examples` values and unknown
  keywords are never modified.

`SDR.Schemas.ref/1` (provenance hash), `ModelProvider` (the stored request)
and `ClaudeCLI` (stdin) all use it, so the hashed, stored and sent schemas
are the same canonical bytes in every VM.

`SDR.Schemas` version `"2"` tags the new regime on `output_schema_version`.
Rows recorded under `"1"` keep their original hashes and are never
relabelled. The global `Canonical` version is unchanged.

`ClaudeCLI.render_prompt/2` (`prompt-builder/1`) is unchanged: it renders
whatever schema it is given. Historical stored schemas are never
normalised, the wire-witness projections still re-derive old rows byte for
byte, and the enabled v3 witness tuple is unaffected. Moving normalisation
into `render_prompt/2` would require `prompt-builder/2` and a reviewed
projection and enablement.

The schema refs are part of the immutable `SDRAgent` definition body, so
the agent definition moves to **v3**; the entity PASS is Codex `0b73763d`.

- Existing v1 and v2 definition rows, with their bodies, hashes and
  statuses, are untouched, and the hash-conflict guard is unchanged.
- New assignment and reply-intake runs pin v3.
- Existing and pending runs, and operator retries of them, keep their pinned
  definition, which is their admission snapshot.
- Their later model invocations record the schema version actually used
  (`"2"`) and the hash of the stored schema.

This admission-snapshot reading holds **only** for this
semantics-preserving normalisation of the `required` order. It does not
license old runs to acquire different tools, permissions, model policies,
prompts or schema constraints in a later upgrade.

Entity PASS: Codex `d24051f1` (schema regime) and `0b73763d` (definition v3).
