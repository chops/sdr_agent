---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0001: Unattended MVP Build Operating Charter

## Status

Accepted (2026-10-06, Charles — decisions given interactively to Claude, with
Codex consulted on each, during the session that scaffolded this repository).

## Context

The MVP is built by two agents (Claude Code and Codex CLI in an ai-pair tmux
session) with no human in the loop between explicit checkpoints. The project
doctrine says humans own correctness, security, public interfaces, and
architecture, and that ADR acceptance requires approval. An unattended build
therefore needs a written mandate: which decisions the owner already made,
what the agents may decide inside that envelope, and what must stop the run.
This record is that mandate, so an auditor can trace every later agent action
to an authority granted here.

## Options Considered

### Option 1: Ask the owner before every architectural step

**Pros:** maximal human control.
**Cons:** not unattended; the owner explicitly asked for an unattended build.

### Option 2: Written charter with bounded agent authority and stop conditions

**Pros:** unattended between checkpoints; every grant is explicit and auditable.
**Cons:** agents make detailed design choices the owner has not individually
reviewed; mitigated by peer review, CI gates, and owner veto.

## Decision

We will run the build under this charter.

### Decisions made by the owner (accepted architecture)

- Spec: Jido decides, Ash governs, Oban executes durably, Postgres remembers,
  OTP keeps it alive, Phoenix lets humans operate it.
- Jido v3 pinned (ADR-0003). Real model: Codex app-server on the owner's
  ChatGPT plan; deterministic fake model is the default (ADR-0004).
- Audit-first architecture with OpenTelemetry as a first-class concern,
  model-content spans and an independent wire witness both in the MVP, and
  audit-chain anchoring to a private Git repository plus OpenTimestamps
  (ADR-0002, ADR-0005).
- Tier 0 autonomy: every outbound message, follow-ups included, requires
  human approval bound to an immutable revision. No real email delivery.
- Single tenant; admin and reviewer roles; password authentication; synthetic
  fictional data only.
- All recommendations in the agreed MVP checklist (scope, compliance
  defaults, budgets, hermetic tests, supply-chain gates, definition of done)
  are accepted as written.

### Authority granted to the agents

- Create and change code, docs, ADRs, CI, and branch protection in
  `chops/sdr_agent`; create the private repository
  `chops/sdr_agent-audit-anchors`.
- One short-lived branch per slice; merge to `main` only through a pull
  request with green CI and a recorded approving verdict from the other agent.
  Both agents act as GitHub user `chops`, so the verdict is a PR comment, not a
  GitHub approval. Direct pushes to `main` are not permitted.
- Create the project-local sops file and generate the audit-anchor ed25519
  key, encrypting it directly to the owner's age recipient. Read exactly the
  nix-darwin sops path `notifications/telegram_bot_token` for outbound
  notifications.
- Change and deploy `~/src/nix-darwin/packages/llm-otel-proxy` for the wire
  witness.
- Detailed design inside the accepted architecture. New ADRs for such choices
  may be accepted on the peer's recorded approval; the owner can veto by
  reverting or marking them superseded.
- Fallback: when a dependency or provider is unavailable, substitute a
  behaviour-backed fake and record an ADR.

### Invariants no authority overrides

- Never weaken suppression, approval binding, idempotency, or the audit trail.
- Never enable a delivery path capable of reaching a real recipient.
- Never change a dependency source or pin without a reviewed ADR.
- Never print, log, commit, or transmit secret values; never copy OAuth tokens.
- Never call Telegram `getUpdates`, `setWebhook`, or `deleteWebhook` (the
  co_startup_week bridge owns inbound updates for the shared bot).
- No hosted, multi-user, or commercial traffic on the owner's ChatGPT login.

### Stop conditions

The run halts, writes `notes/run-status.org` (last green SHA, failing command,
redacted logs) and notifies the owner when: a security or invariant test
fails; any external-send capability appears; a secret is exposed; a dependency
source drifts; a model budget is exhausted; unrelated files are modified; or
the same blocker recurs three times.

### Owner checkpoints

- `sudo darwin-rebuild switch` for the proxy deploy (needs the owner's password).
- A one-time Codex sign-in only if the app-server finds no cached login.
- SIWC browser consent when the open-source auth slice lands.

### Operating posture (owner's choices, recorded with their risk)

- Both agent panes run with permission prompts bypassed. Guardrails are the
  project hooks, these stop conditions, CI, peer review, and branch protection.
- No wall-clock cap. Notifications are outbound Telegram messages tagged
  `[sdr_agent · github.com/chops/sdr_agent]`. A Telegram HTTP 200 means the
  message was accepted, not that the owner saw it.

## Justification

Option 2 is the only one that satisfies the owner's request for an unattended
build while keeping each grant explicit, reviewable, and revocable.

## Consequences

### Positive

- Every agent action traces to a named grant or an accepted ADR.
- Stop conditions turn silent failure modes into notified halts.

### Negative

- Bypassed permission prompts leave hooks and gates as the only interactive
  guardrails; a hook error fails open.
- Same-account GitHub review cannot be enforced by branch protection.

### Neutral

- Owner checkpoints make the run unattended between checkpoints, not
  end-to-end.

## Amendment 1 (2026-10-27): the hosted owner-only demo and its sign-in email

**Status: PROPOSED.** It is accepted only when the owner accepts this exact text in a decision row that pins the commit and file hash. Source directive: D-231 (owner chat 2026-10-27T16:21:43Z and 16:24:04Z). Reviewed by Codex. Nothing outside the one hosted copy named below changes.

### Why

The owner asked to try the product on a real URL: "what about deploying to sdr.a-z.bot and testing behind a passwordless log-in i can authenticate with my email? charles@charlesholloway.io", and "host it on hetzner … just deploy it right now". Three things conflict with that:
- **The sign-in link must reach a real inbox.** This charter's invariant "Never enable a delivery path capable of reaching a real recipient" and ADR-0014 constraint 1 forbid that.
- **That link carries a credential.** The invariant "Never print, log, commit, or transmit secret values" applies to it.
- **Someone must deploy the copy.** An external-send capability is a stop condition here, and ADR-0014 makes deployment an owner-only decision.

### Precedence

ADR-0014 supersedes this charter for product work. This later, owner-accepted amendment changes two things in ADR-0014, and only for the one hosted copy and the one sign-in purpose named below:
- constraint 1;
- its deployment decision right.

It extends no other constraint, authority window or owner right. ADR-0014 carries a cross-reference to this amendment.

### What it permits, and nothing more

1. **One hosted copy:** the instance at https://sdr.a-z.bot on the owner's Hetzner host ch-web-prod, built from a reviewed, pushed commit.

2. **One transactional mail path:** the single-use sign-in link of `SdrAgent.Accounts.User`'s `:magic_link` strategy. `SdrAgent.Accounts.Senders.MagicLink` mails it through `SdrAgent.Mailer` and Postmark.
   - **Recipients.** Only addresses on `SDR_LOGIN_ALLOWLIST`. For this copy that is exactly the owner, charles@charlesholloway.io.
   - **Intended credential transfer.** The link carries a short-lived bearer credential, deliberately sent by Postmark to the owner's inbox and back to the hosted sign-in endpoint over authenticated TLS. That transfer is part of this sign-in path. It does not authorise sending API keys, OAuth tokens or any other secret, nor putting a credential in logs or evidence. Email is not promised to be end-to-end secret; the link's protection is that it is single-use and expires after 10 minutes.
   - **Admission.** With `config :sdr_agent, login_allowlist_enforced: true` (prod), `SdrAgent.Accounts.LoginAllowlist` and the `AllowlistedOnly` preparation admit a user only if their email is on a valid allowlist. The check runs:
     - before a link token is minted (`:request_magic_link`);
     - at both sign-in actions;
     - whenever a session, live session or connected console event resolves the user (`:get_by_subject`).
     
     A missing, empty or malformed allowlist admits nobody. The two sign-in actions audit their outcomes through `AuditSignIn`. This does not claim that every rejected link request, rate-limited request or session lookup appends an audit event; the limiter logs a warning instead. The sender's own check is not the boundary.
   - **Rate bound.** `SdrAgent.Accounts.Preparations.LimitLinkRequests` and `SdrAgent.RateLimiter` must bound link requests before any token is minted or mail is sent. The bounds are per trusted client address, global, and per destination. The public response must not reveal whether a link was sent.
   - **No credential in logs.** The application must keep the sign-in token and the session token out of its request, LiveView and crash-report logs. That includes percent-encoded spellings of the sign-in route and the HTTP error-report boundary.
     - The proxy's access log for this host omits request URIs and the Referer header.
     - The proxy answers its own errors for this host, so at its global ERROR level they are not logged with the request.
     - Raising the proxy's global log level to DEBUG, or enabling a telemetry exporter, is outside this amendment until URL and exception redaction are in place for it. Production exports no telemetry.
     - This is not an exception to the no-secrets invariant: any remaining sink that can record a token is an open readiness defect, and it blocks opening the host.

3. **Agent-run deployment of this copy only,** under the owner's D-231 directive, by `scripts/deploy.sh`, from a pushed, reviewed commit. The owner's first sign-in waits for Codex's PASS on the combined head and the installed release.

### What stays exactly as it was

- **Outreach delivery is captured only.** It never uses `SdrAgent.Mailer` or an HTTP mail client.
  - Tests assert that the delivery adapter is the capture adapter.
  - Tests assert that the only application module that references the mailer is the sign-in sender.
- **Fake model only.** The release refuses `claude_cli` in production (ADR-0004; ADR-0014 constraint 5). No hosted traffic uses the owner's ChatGPT login.
- **Synthetic data only.** The real-data switch of ADR-0014 Amendment 2 stays off, because this copy is not the owner's local instance. The only real personal data is the owner's own email address, as the operator.
- **Follow-ups stay contained until the suppression fix (D-206) is on this copy.**
  - `config :sdr_agent, :follow_ups, :disabled` in prod; anything other than exactly `:enabled` means off.
  - The switch blocks follow-up scheduling (`Delivery`) and execution (`FollowupWorker`).
  - The hosted seed creates a first-touch step only.
  - `SdrAgent.Release.verify_hosted_containment/0` must pass before every deploy switches releases.
  - Turning the switch on is not authorised by this amendment. Doing so does not recreate omitted or cancelled follow-up jobs.
- **Every other invariant, stop condition and owner checkpoint is unchanged.** That includes suppression, approval binding, idempotency, the append-only audit trail, secrets and dependency pins.
- **Anything more needs its own amendment:** another mail purpose, another recipient class, prospect mail, another host, or real-data use.

### Ends

This amendment lapses when the hosted copy is taken down or when the owner withdraws it.

Until then, the stop condition "any external-send capability appears" does not fire for this one sign-in path. It still fires for any other path.
