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
