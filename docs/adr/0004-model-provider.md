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
The agent-environment amendment (2026-10-27, at the end of the Decision
section) is accepted as D-224, owner acceptance delegated by D-219, after
Codex's static PASS (ca0e5bec); its text is published as reviewed, so its own
Status line still reads PROPOSED. Acceptance is not activation or spend
approval.
The agent-environment D-240 addendum (2026-10-28, after the amendment) moves
only the environment's exclusive end, from 2026-11-01T06:00:00Z to
2026-11-07T07:00:00Z. It is accepted as D-247 on the owner's direct decision
D-240, after Codex's independent exact-text PASS
(m_codex_d240_0004_r2_pass_1793158419375), not under the D-219 delegation;
its text is published as reviewed, so its own Status line still reads
PROPOSED. The amendment's text and its accepted hashes (D-224) are unchanged.

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
- Accepted (2026-10-27, D-224): for the D-218 scope through 2026-11-01T06:00:00Z, the
  attested agent environment `agentenv-1` may make real calls within one owner
  authorization that agents materialize but never set (agent-environment amendment).
- D-240 (2026-10-28, owner decision; addendum accepted as D-247): the
  agent-environment end moves to 2026-11-07T07:00:00Z exclusive (Saturday Nov 7
  00:00 MST, the end of Friday Nov 6 in Denver). Only the end changes. The code
  keeps 2026-11-01T06:00:00Z until its own reviewed edit lands.

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
  *C4 note (2026-10-14, owner decision D-062 / C4 OQ-2; in force when C4
  merges): the 20-per-run figure is the built-in default of the owner-editable
  `run_max_model_calls` limit, frozen per run in its settings snapshot; the
  200-per-UTC-day limit, C9 grants and pre-call reservation are unchanged.*
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
   - Note (L2 E3, 2026-10-18; plan PASS Codex `cad33c66`): each line of
     `nix/app-claude-cli.identity` also records the reviewed CLI version of
     that exact store path and hash. The app refuses ordinary calls
     (`:pinned_cli_version_mismatch`) unless it equals the profiles'
     reviewed version, at resolution and before each launch. This is
     reviewed artifact metadata inside the same immutable-pin trust, not an
     observed version; the per-call init check stays mandatory.
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

### C2-02b2β amendment (2026-10-15, accepted): the attended resolver for a blocked switch

**Status: ACCEPTED.**
- **Accepted by:** the owner, on 2026-10-15 (D-138), at the text Codex
  passed at `e60943c`.
- **Contract:** `docs/product/r0/c2-02b2b-interface.md` (draft 4,
  interface and entity PASS).
- **Approves:** b2β GREEN only. It is not merge, activation or spend
  approval.

**Context.**
- The C2-02b2 amendment leaves a blocked switch without an exit
  (decision 6). The server stays held, and the switch occupies the
  tenant's single open-switch slot.
- A switch blocks when its outcome can't be proven: an unconfirmed
  cleanup, a worker or coordinator death, an uncertain finalization, or a
  drain or veto failure. Most of these have no receipt that could ever
  arrive.

**Decision.**
1. **The only exit from blocked** is an attended resolution to
   `:failed`.
   - An active human admin decides, with the role and tenant re-read.
     Any active admin may do this (C2-02b2β OQ-2).
   - The registered coordinator executes it, in a new `:resolve` phase.
     `model_runtime` gains no write.
   - It needs a typed attestation (`STOPPED <switch id>`).
   - The setting is unchanged, and there is no blocked → completed path.
2. **The attestation binds:**
   - the switch and the tenant;
   - the covered range of starts, from the switch's generation to the
     latest start. That start must be the coordinator's current start of
     its own boot, re-checked after the locks;
   - the observed lease kind (none, the current server's own live
     reaper, or a dead holder);
   - the outcome.

   Replay is idempotent by id and authorizes nothing. It is checked in
   the caller, in the coordinator, and after the locks, against the
   persisted semantic identity.
3. **An unknown outcome** is settled only through a serialization
   barrier (the original write's locks, in its order) and an exact
   re-read. Elapsed time is never proof. Until the outcome is settled,
   the server stays held and nothing acts.
4. **No new cleanup authority. C2-02b2 decision 5 stands:**
   `Reaper.release/1` is never called by this code.
   - The resolution releases no lease and no hold.
   - A dead lease is a held hard conflict (`:cleanup_unprovable`). Its
     exit is the existing operator path.
   - The coordinator resumes its cold-boot path once no lease and no
     server exist.
   - Only the C2-02b2 reconciliation releases the hold.
5. **Unchanged:**
   - `complete` and `fail` refuse a blocked switch;
   - `block` keeps its no-write replay;
   - the lock order, the Fake default and the call grants.

   One narrow change: `fail` on a resolved switch is refused, after the
   existing owner, boot and generation guards, rather than read as a
   replay.

**Consequences.**
- **Positive:** a blocked switch has a safe, audited exit that frees the
  slot, with no new authority over cleanup.
- **Negative:** a human attestation is trusted for work the system can't
  observe. A resolution can commit without restoring readiness: with a
  dead lease, it still needs the operator path.
- **Neutral:** no new table, dependency or process.

<!-- BEGIN ADR-0004 AGENT-ENVIRONMENT AMENDMENT: text as reviewed by Codex (ca0e5bec) -->

### Agent-environment amendment (2026-10-27, PROPOSED): one agent-owned development instance for unattended real-model research and drafting, with delegated grant provisioning

**Status: PROPOSED.** This amendment has not been accepted or implemented.

To be accepted, it follows ADR-0014 Amendment 3 (accepted, D-222; D-219; D-221 item 5):

- Codex gives an independent static PASS of this exact text and of its entity/action delta, reviewed together with the ADR-0005 C2* amendment.
- A decision row then cites D-219, D-221, the commit and this file's SHA256, and records "owner acceptance delegated by D-219".

Accepting this amendment sets no budget. Real calls stay at zero until an owner caps row exists (D-218 item 6; D-219).

**Context.**

- **Where real calls run today.**
  - `claude_cli` is accepted in development only (`config/runtime.exs:56-123`).
  - The only real-call instance is the owner's: `sdr_agent_dev` on 5520, HTTP 4120 (`config/dev.exs:15-23,97-104`; `bin/demo:83-122`).
  - Agents never connect to the owner's databases (D-219).
- **Test builds are not usable for real calls.** They compile fake launchers and witness overrides (`config/test.exs:14-18,63-73`), and they refuse real providers at boot (`config/runtime.exs:115-119`).
- **Grant and allocation writes need a human admin.**
  - Grant writes require an active human admin and refuse every system actor (`lib/sdr_agent/agents/model_call_grant.ex:21-24,152-155`; `lib/sdr_agent/agents/checks/current_admin.ex:17-24`).
  - `created_by_id` and `updated_by_id` are NOT NULL (`priv/repo/migrations/20261012181602_c9_model_call_grants.exs:109-127`).
  - Revocation relates `updated_by` (`model_call_grant.ex:136-149`).
  - Allocation writes need both the grant-bundle marker and a current admin (`lib/sdr_agent/agents/model_call_allocation.ex:107-115`).
  - `GrantBundle` forwards the calling actor to those writes (`lib/sdr_agent/agents/changes/grant_bundle.ex:228-245`).
- **Allocations are matched by usage bucket.** Every assignment purpose maps to `b1` (`lib/sdr_agent/agents/usage_bucket.ex:28`), and exactly one allocation must match a call (`lib/sdr_agent/agents/admission.ex:28-41`). So allocations alone cannot restrict which purposes a grant funds.
- **Consumption is per database.** Consumption and the daily limit are derived from that database's invocations (`admission.ex:38-41`; `lib/sdr_agent/agents.ex:510-543`).
  - A refused reservation rolls back and is not charged (`agents.ex:291-307`).
  - A refused launch stays charged (`agents.ex:585-597`).
- **Concurrency 1 holds within one VM only** (Q0.1; C2-02b2 item 1).
- **The demo seed** writes fixed fixtures as the seeder actor, including a seeded admin operator (`lib/sdr_agent/demo/seed.ex:2-20`; `lib/sdr_agent/demo/fixtures.ex:31-52`).

**Decision.**

1. **One environment, `agentenv-1`.** It is a native `MIX_ENV=dev` build with:
   - the database `sdr_agent_agentenv` on `localhost:5520`;
   - HTTP on `127.0.0.1:4130` (a proposed project port);
   - the private root `~/.local/state/sdr-agent/agent-env/agentenv-1/` (mode 0700), holding `build/`, `deps/`, `state/`, `evidence/`, `anchors/` and `tmp/`;
   - one dedicated worktree.

   Port 4130 is verified free at the actual launch and recorded in `.workflow/project-facts.md`. A collision refuses; the port is never moved silently.

   The environment is selected by `SDR_AGENT_ENV=agentenv-1`, which `config/runtime.exs` reads in `dev` only. Any other value, or the variable in another environment, refuses boot. Unset, development behaviour is unchanged. The workflow-managed `config/dev.exs` block and `devenv.nix` are not edited.

   All new real-call authority is bound to `agentenv-1`. Old unused allowances, G-DEMO's included, are not new-call authority here.

2. **Launcher `bin/agent-env`.** `bin/demo` is unchanged.
   - **Positive checks before any command that creates, migrates, seeds or starts.**
     - `MIX_ENV=dev`, and no `DATABASE_URL`.
     - The Repo actually resolves to exactly `sdr_agent_agentenv` on `localhost`/`127.0.0.1:5520`.
     - Port 4130, loopback only, and not already listening. The launcher refuses 4120, 4122, every runner-registered lane port, and a non-loopback bind.
     - `MIX_BUILD_ROOT`, `MIX_DEPS_PATH` and the state and evidence roots resolve, as real paths, under the private root, never into a shared `.devenv`.
     - `SDR_WITNESS_STORE_ROOT` is set explicitly.
     - `SDR_ANCHOR_SINKS=file`, under the private root.
     - The suppression check is the Store.
     - The database holds no migration the build lacks.
   - **Refused targets.** It refuses `sdr_agent_dev`, every `sdr_agent_test*` name, and any name other than the exact one.
   - **No reset or drop.** There is no reset or drop command, and agents never reset or drop this database.

3. **Environment identity lifecycle (create-only files under `state/`; `bin/agent-env provision`).** Initial provisioning runs under a no-spend, Fake-only `bootstrap` lease (item 5). It is the only phase before a binding exists. Steps, in order:
   1. **Preflight.** No state file, no lease and no database named `sdr_agent_agentenv` exist. Otherwise, quarantine.
   2. **Pending marker.** Create `environment.pending` (environment id, nonce, start time).
   3. **Bootstrap lease.** Create `instance.lease`. It records `mode: "bootstrap"`, the pending nonce as its nonce, and the exact target database: name `sdr_agent_agentenv`, host and port 5520. It records no port and no `binding_sha256`, because none exists yet.
   4. **Create the database.** Run an exclusive `CREATE DATABASE sdr_agent_agentenv`. "Already exists" means quarantine. Then create `environment.created.json` (nonce, database name, database oid).
   5. **Migrate and seed.** Run `mix ecto.migrate`, then `mix sdr.demo.seed` (the existing demo seed, which bootstraps the singleton tenant and the fixtures).
      - **Mode.** Each runs as a separate bootstrap-mode Mix task under `SDR_AGENT_ENV=agentenv-1`.
      - **Boot checks.** At boot each task checks that the lease is `bootstrap` with its nonce, and that the Repo's database name and oid equal `environment.created.json`.
      - **Refusals.** Each refuses `SDR_MODEL_PROVIDER=claude_cli` and `SDR_DEMO_EXCEPTION`.
      - **What it starts.** No HTTP server, Oban queues or Oban plugins.
      - **Exit receipt.** Each creates its exit receipt `instance.<nonce>.<step>.exit` only after success.
   6. **Tenant probe.** Run one read-only bootstrap-mode probe that prints only the tenant id.
   7. **Publish.** While the lease is still held, create `environment.json` (environment id, database name and oid, tenant id, pending nonce, creation time). Its `sdr-canonical-json/1` SHA256 is the environment `binding_sha256`.
   8. **Release.** Remove the bootstrap lease only when every step's exit receipt exists and `environment.json` is published.

   **What `bootstrap` mode allows.** It permits exactly the step 4 CREATE, the step 5 migrate and seed, and the step 6 probe, and nothing else.
   - No other Mix task, no VM with a server, and no `provisioning` or `run` mode while it is held.
   - No real provider, reservation, model call, grant or release.

   **Valid states** are exactly two:
   - nothing exists, so fresh provisioning is allowed;
   - `environment.json` exists, equals the live database name, oid and tenant, and no bootstrap lease remains.

   **Every other state quarantines the environment.** For example: `environment.pending` without `environment.json`; a bootstrap lease without every exit receipt (stale); `environment.created.json` whose oid differs from the live database; a mismatch; a database without `pending`. Quarantine is resolved outside this amendment, and dropping a database is owner-only.

   **Fake use** of a bound environment may begin before any authorization exists, under a `run` lease (item 5).

4. **One authorization, its binding, and the no-spend provisioning mode.** The registry (item 8) holds at most one authorization for `agentenv-1`, and all approved windows are allocations of it. A second authorization needs a further amendment.

   **Two attestation levels.**
   - **Provisioning (no spend).** This level requires:
     - a bound environment that matches the live database (item 3);
     - the exact compiled registry entry;
     - a claim file naming that entry's id and digest;
     - a provisioning-mode lease (item 5).

     It authorizes exactly one thing: running the idempotent `:provision_delegated` transaction (item 9). The VM or Mix task in this mode runs with the Fake provider only. `SDR_MODEL_PROVIDER=claude_cli` and `SDR_DEMO_EXCEPTION` are refused at boot in this mode, so no model call, reservation or release can happen.
   - **Spend-ready.** This level requires a complete final authorization binding (step 4 below) consistent with the database's grant, plus a run-mode lease. Only this level lets the runtime start the real provider or admit a real call.

   **Binding steps** (`bin/agent-env authorize`, in order):
   1. Observe, outside any lock: the environment is bound and matches, and the registry entry exists and has not expired.
   2. Create `authorization.claim.json` (authorization id and SHA256, environment `binding_sha256`, nonce, claim time).
   3. Take a provisioning-mode lease and run the `:provision_delegated` transaction in provisioning mode. Its event carries the claim nonce. Release the lease with its exit receipt.
   4. Create `authorization.json` (authorization id and SHA256, `binding_sha256`, grant id, revision 1, event id, nonce). Spend-ready is now possible.

   **Re-running `authorize`** with a claim but no `authorization.json` repeats steps 3 and 4 against the same bound database. That includes the case where the grant transaction committed but the final file was not published. An identical grant is a replay that writes nothing. An absent grant is created once, under the unique index.

   **Every other state quarantines real calls:** a final binding whose grant is missing or different, a claim naming another authorization, or a registry digest different from the claim's.

   **Real calls require** a complete authorization binding consistent with the database's grant.

   **What these files are.** Create-only files are cooperative launcher controls. They are not an immutable security boundary against the same OS account deliberately altering state.

5. **Instance lease (agent instances only).**
   - **Taking it.** Before starting any VM or Mix task against the database, or before the item 3 CREATE, the launcher creates `state/instance.lease`. It records the nonce, `mode`, the target identity, the port (or none) and the start time. There are three modes, and each lease holds exactly one:
     - `bootstrap`: the item 3 initial provisioning only. Its target identity is the exact target database (name, host, port; then the oid in `environment.created.json`), and its nonce is the `environment.pending` nonce.
     - `provisioning`: the item 4 authorization transaction only. Its target identity is `binding_sha256`.
     - `run`: a bound environment's VM. Its target identity is `binding_sha256`.
   - **Holding it.**
     - `bootstrap` and `provisioning` leases are Fake-only and no-spend. In them, `claude_cli` and the selector are refused at boot, and no HTTP server is started.
     - A `run` lease needs a bound environment (item 3). It permits Fake use without any authorization.
     - In this environment, `claude_cli` is refused at boot unless all of these hold: the lease's nonce equals the one the launcher passed; its `mode` is `run`; the environment is spend-ready (item 4).
     - Each launch admission observes the lease in its own process, before any lock (ADR-0005 C2* item 2), and compares it with no I/O under locks (`:agent_env_lease_mismatch`).
   - **One VM or task at a time.** A second launcher refuses while any lease exists, in any mode.
   - **Orderly exit.**
     - In `run` mode, after its model supervision tree has terminated with every Reaper cleanup receipt, the VM creates `state/instance.<nonce>.exit`.
     - In `bootstrap` and `provisioning` modes, each permitted step creates its own exit receipt after success.
     - Only once every expected receipt exists, and for `bootstrap` only after `environment.json` is published, does the launcher remove the lease.
   - **Stale lease.** A lease without its expected receipts is stale. It quarantines the real lane and is never reclaimed automatically. There is no process-name kill and no backend termination. A bounded recovery command may follow under its own technical review.
   - **Concurrency.** Within the VM, concurrency 1 and the C2-02b2 hold are unchanged.
   - **The owner's instance.** The lease coordinates agent instances only. It does not exclude the owner's untouched instance. Keeping that instance free of real calls during agent windows is a procedural residual, not machine-wide enforcement.

6. **Provider path, storage and jobs.**
   - **Unchanged.**
     - The pinned CLI, used by its absolute path.
     - Per-call attestation.
     - No tools, MCP servers or slash commands.
     - `SdrAgent.ChildEnv`.
     - The cached login is never read, copied or dumped.
     - Admission (gate, trusted store, promoted tuple).
     - Grants and the per-run and per-day limits.
     - The result gate and ADR-0005's C2*.
     - The synthetic guard and capture-only delivery.
   - **Witness store.** Reconciliation uses the existing invocation-scoped reader on the shared deployed proxy store. The root is configured explicitly, and the reader reads only `witnesses/<invocation id>` and digest-addressed blobs (`lib/sdr_agent/agents/witness/store.ex:155-176`). Invocation ids come from this environment's own database. There is no root-wide enumeration and no manual raw read or dump. This is reader scoping, not filesystem isolation.
   - **Other storage.** OpenTelemetry content capture is off. Anchors use the file sink only.
   - **Queues and jobs.**
     - Running: the research queue, the delivery queue (capture), the reconciliation queue (concurrency 1), the witness scan, the stale-run sweeper and the stale-delivery sweeper.
     - Absent: `followup`, `integration` and the OpenTimestamps upgrade.
     - The Store suppression check is verified before each phase.

7. **Persistent ledger.** `sdr_agent_agentenv` persists for the whole window. It is not a runner lane database.
   - Consumption stays derived from the invocations charged to the grant.
   - A refused reservation rolls back and is not charged. A refused launch stays charged.
   - No consumed attempt is refunded.
   - Restarts, rebuilds and new worktrees never reset consumption, because the database persists.
   - A recreated or second database fails the environment binding and refuses real calls, so an allowance is never cloned or regenerated.
   - A lost database ends real calls for the authorization.

8. **Authorization registry: enforced units only.** The authorization is one reviewed code entry with:
   - an id, and the decision row that records the owner's literal caps, plus D-219 and D-221;
   - `environment_id: "agentenv-1"`;
   - `starts_at` and `expires_at`;
   - `funded_scope`: exactly `[{:assignment, [:qualification, :evidence_extraction, :outreach_proposal]}]`, enforced at admission (item 9a). It is a funding restriction, not a counter;
   - `total_attempts`: one aggregate across the funded scope;
   - an optional `per_utc_day_attempts`;
   - `profile_ids`, which must include `claude_cli_opus` for C2*;
   - one allocation per approved window. Each allocation has: a key from the existing closed set; `applies_to: [:b1]`; an attempt count; `available_from` and `available_until`. The windows must not overlap, so exactly one allocation matches. Allocation attempts sum to at most the total.

   These are the only caps, and nothing else is claimed. There is no dollar, token or per-purpose ceiling. Any such ceiling needs a new, separately reviewed counter and matching contract that guarantees its unit. The values are copied verbatim from the owner's recorded caps, and the non-author reviewer verifies the copy. The registry is empty until those caps exist; until then nothing can be spent, while building and Fake use continue.

9. **Delegated provisioning (amends R0 item 5 for `agentenv-1` only).**
   - **Actor and action.** A new system actor type, `:grant_provisioner` (PRV), has one creating action: `ModelCallGrant :provision_delegated`. The action's only argument is `authorization_id`.
   - **What the action does.** It runs `GrantBundle` in a delegated mode, with exactly the registry entry's terms. It records `provisioning: :delegated`, the authorization id and its SHA256, and NULL `created_by_id` and `updated_by_id`, under a provenance CHECK. It appends `model.grant.provisioned`, with actor type `grant_provisioner` and, as arguments, the authorization id, its digest, the claim nonce and the decision references.
   - **When the action is refused.** It is refused in each of these cases:
     - the environment has neither provisioning nor spend-ready attestation (item 4), or a binding does not match;
     - the id is unknown, or `now ≥ expires_at`;
     - a different grant for the authorization exists.

     An identical replay returns the existing grant.
   - **Allocations (affected side).** An allocation may be created only inside a registered delegated-bundle context. That context is bound to the process and transaction, as `Prelocked` is, and records the tenant, the parent grant id, the authorization id, its digest and `binding_sha256`. Allocation creation is permitted for PRV only, only during that action, and only for that parent grant. Refused: any bare or forged context, any other parent, and any update or release of an allocation of a delegated grant, by any actor. Owner-form allocation policies are unchanged.
   - **Delegated grants: what can change.**
     - `:update_terms` and `:release_allocation` are refused for every actor.
     - PRV may revoke: `updated_by_id` stays NULL, the revision is bumped by `GrantRevision`, and the event records actor type `grant_provisioner`.
     - A current human admin may also revoke. That admin is recorded in `updated_by_id`, which the CHECK allows only on a revoked delegated row. Revocation only narrows.
   - **Agent environment: no other route.** The ordinary `:create` action, `:update_terms`, `:release_allocation` and the admin grant form are refused for every actor, so the seeded admin cannot mint or enlarge an allowance. Nothing impersonates a user, and nothing writes raw SQL.
   - **Owner's instance.** The owner's instance keeps the owner-form path unchanged.

9a. **Funded scope at admission (before spend and before launch).**
   - **Where it applies.** For every call funded by a delegated grant, whether the C2* selector is on or off, admission requires all of the following:
     - the run's `usage_origin` and the invocation's `purpose` are inside the authorization's `funded_scope`;
     - the profile is in the grant's `profile_ids`;
     - the grant's `delegated_authorization_id` and SHA256 equal the compiled registry entry (a pure comparison);
     - the operation snapshot (ADR-0005 C2* item 2) attests spend-ready `agentenv-1` with matching bindings.
   - **When it is checked.**
     - At reservation, it runs inside `reserve_model_invocation/3`'s transaction, in the existing lock order, before any charge. A refusal (`:outside_funded_scope`) rolls the reservation back, so nothing is charged. It is then recorded as the existing refusal Failure and event (`agents.ex:291-307`).
     - At launch, it runs again inside `admit_launch/3`. A refusal there moves the reserved row to `failed` without sending. It keeps the reservation's existing charge (`agents.ex:585-597`).
   - **Why it is needed.** Usage buckets cannot express this: every assignment purpose is `b1`. So the scope is checked directly, with no per-purpose counter and no new cap unit.
   - **Unchanged.** Other admission checks are unchanged. ADR-0005's C2* E1 re-checks the same scope at release.

10. **Human roles and final sign-in.**
    - The owner signs in for final inspection and approval as the seeded admin operator (`Fixtures.users/0`). This path is built and checked while the environment is built.
    - Automation uses only the seeded reviewer, and only for Fake coverage. It never approves or captures a real-model draft. Any action it takes is recorded under the reviewer identity and is never presented as the owner's.
    - Real-model drafts wait for the owner.

11. **Windows and expiry.**
    - **Per-call deadlines.** Each call is funded by exactly one allocation. Its own deadlines are that allocation's window intersected with the authorization and grant windows:
      - admission at reservation and at launch (`admission.ex:28-41`; `agents.ex:585-597`);
      - the ADR-0005 launch margin;
      - ADR-0005's per-invocation effective window.
    - **Gaps between windows.** In a gap, no allocation is available, so admission refuses (`:no_allocation`). A later approved window's allocation may fund new calls once it opens.
    - **Completion and use.** Windows constrain launches, not completion. A call that completes later is charged. Its output is usable only within its own invocation's effective window, checked at release and at capture instants. An output funded by an earlier window never gains a later window's authority.
    - **Terminal runtime expiry.** Real calls here end, terminally, at the earliest of: the authorization's `expires_at`, the grant's `expires_at`, revocation, and 2026-11-01T06:00:00Z (exclusive). The end of one allocation window is never a terminal expiry. After the terminal instant the runtime refuses `claude_cli` here (`:agent_env_expired`).
    - **What stays.** Rows, bindings and receipts are kept, and Fake use may continue.
    - **No extension.** There is no automatic extension.

12. **Terms boundary (unchanged).** This is personal, local, single-operator use of the owner's own login on the owner's machine, by the owner's agents on the owner's instruction (D-219, D-221). It does not extend to other users, hosts or deployments.

**Unchanged.**

- The Fake default, and test/CI hermeticity.
- `claude_cli` is refused in `test` and `prod`.
- The owner's instance and its grant path.
- The profile registry and the admin-only switch.
- Attempts are never refunded.
- The daily limit of at most 200.
- C2-02b2 and C2-02b2β.
- The witness and result-gate rules.

**Consequences.**

- **Positive:** unattended real research and drafting fit inside one owner authorization that can be neither multiplied nor reset. Provenance never claims a human acted.
- **Negative:**
  - a long-lived database and cooperative state files that agents must not dispose of;
  - any crash or partial state quarantines the real lane;
  - one more system actor, one grant action, an allocation policy branch and a provenance CHECK.
- **Neutral:** no new dependency. Writes stay Ash actions with audit (ADR-0009).

<!-- END ADR-0004 AGENT-ENVIRONMENT AMENDMENT -->

<!-- BEGIN ADR-0004 AGENT-ENVIRONMENT ADDENDUM D-240: text as reviewed by Codex (m_codex_d240_0004_r2_pass_1793158419375) -->

### Agent-environment amendment, D-240 addendum (2026-10-28, PROPOSED): the environment end moves to 2026-11-07T07:00:00Z

**Status: PROPOSED.** The owner decided this change (D-240). To be accepted, this exact text needs Codex's independent PASS and a decision row that cites D-240, the commit, this file's SHA256 and the hash of the bytes between these markers.

**The owner's decision.** D-240 (2026-10-28). The owner answered "yes to both" (chat, received 2026-10-28T02:38:32Z) to Claude's pick "extend all four through 2026-11-07 07:00 UTC". This is the explicit owner decision that ADR-0014 Amendment 3 requires for an extension ("an extension needs an explicit owner decision").

**The change.** Two instants in the agent-environment amendment are read as **2026-11-07T07:00:00Z (exclusive)**:

- the scope end, 2026-11-01T06:00:00Z, in the current-policy summary;
- the fourth operand of item 11's terminal runtime expiry, 2026-11-01T06:00:00Z (exclusive).

The new end is epoch 1794034800: Saturday 2026-11-07 00:00 MST, the end of Friday Nov 6 in America/Denver. The old end was epoch 1793512800 (Sunday 2026-11-01 00:00 MDT). The difference is 522000 s, six days plus one hour across the end of daylight saving time.

**Only the end changes.**

- Everything else in the amendment stays as accepted (D-224): the environment identity, database, port and roots; the one authorization and its binding; the no-spend provisioning mode; delegated provisioning; the per-call deadlines; and the terms boundary.
- Real calls stay at zero until an owner caps row exists.
- The terminal runtime expiry is still the earliest of the authorization's `expires_at`, the grant's `expires_at`, revocation and the environment end. An earlier authorization expiry, grant expiry or revocation still makes the runtime expire first. An allocation's earlier end bounds only the calls funded by that allocation; it is not terminal runtime expiry, and a later approved allocation may become available on its own terms.
- D-240 grants no calls, spend, scope or new authority. A later extension needs another explicit owner decision.

**Records keep their values.** Existing authorizations, grants, allocations, revocations, bindings and receipts keep their recorded windows and expiries. Nothing is rewritten, renewed or re-funded, and no consumption is reset.

**Code bindings take effect only when they land.** The environment end is compiled into `SdrAgent.AgentEnv` (`@environment_end`, read through `environment_end/0`) and duplicated in `SdrAgent.Agents.DemoException` (`@environment_end`). Each takes the new end only when its own reviewed edit, with boundary tests, lands on the reviewed head. Until then the code still ends the environment at 2026-11-01T06:00:00Z, and that earlier instant governs.

**The text above is unchanged.** The amendment keeps its reviewed bytes and its accepted hashes (D-224). This addendum supersedes only that end, in the two places listed above.

<!-- END ADR-0004 AGENT-ENVIRONMENT ADDENDUM D-240 -->

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
