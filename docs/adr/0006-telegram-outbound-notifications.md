---
status: accepted
date: 2026-10-06
supersedes: null
---

# ADR-0006: Outbound-Only Telegram Notifications for the Unattended Build

## Status

Accepted (2026-10-06, owner decision recorded in ADR-0001: "Notifications are
outbound Telegram messages tagged `[sdr_agent · github.com/chops/sdr_agent]`").

## Context

The unattended build must tell the owner about milestones, checkpoints, and
stop conditions (ADR-0001). The owner already runs a Telegram bot for the
`co_startup_week` project. Its token lives in the nix-darwin sops file at
`notifications/telegram_bot_token`, and a live launchd bridge,
`ai.pair.telegram-bridge.co-startup-week`, long-polls that bot's updates and
routes inbound replies to the `co_startup_week` project.

Telegram allows exactly one consumer of a bot's updates: any `getUpdates` call
from another client competes with the bridge, and `setWebhook` or
`deleteWebhook` would break it outright.

## Options Considered

### Option 1: A new bot for sdr_agent

**Pros:** full isolation, inbound possible.
**Cons:** the owner would have to create and authorize a bot; not needed for
outbound status messages.

### Option 2: Reuse the co_startup_week bot, outbound only

**Pros:** no owner setup; the owner already watches that chat.
**Cons:** inbound replies land in the other project; shared token.

### Option 3: Desktop notifications only

**Pros:** local, no third party.
**Cons:** invisible when the owner is away from the machine.

## Decision

We will reuse the co_startup_week bot strictly **outbound** via
`bin/notify-telegram KIND MESSAGE`:

- **Only `sendMessage`.** The script hard-codes an allowlist of exactly that
  method. It never calls `getUpdates`, `setWebhook`, or `deleteWebhook`
  (ADR-0001 invariant); a test asserts those names do not appear in it.
- **Replies are not read.** A reply in Telegram routes to the co_startup_week
  project through its bridge; owner instructions to this project come through
  the agent panes.
- **Mandatory prefix** `[sdr_agent · github.com/chops/sdr_agent] KIND`, where
  KIND is `milestone`, `checkpoint`, `stop`, or `info`.
- **Content rules:** no secrets, no lead or contact data, no chat ids in
  output. Token-shaped strings are redacted before sending. Messages over 1024
  bytes (after prefix and redaction) are rejected, not truncated.
- **Credentials:** the token is decrypted into memory with
  `sops -d --extract '["notifications"]["telegram_bot_token"]'` from the
  nix-darwin sops file (the single path ADR-0001 grants); the chat id comes
  from a local recipient file (`SDR_TELEGRAM_RECIPIENT_FILE`, default
  `~/.local/state/ai-pair/pause-watch-20260911/recipient.json`, schema
  `{schema_version: 1, chat_id: int, bot_username}`). Neither is committed or
  printed.
- **Output:** only `http=<code> ok=<bool>`. A local JSON-lines log in
  `.workflow/local/notifications.jsonl` (gitignored) records UTC time, kind,
  HTTP status, ok, and the sha256 of the text, never the text.
- **Semantics:** HTTP 200 with `ok: true` means Telegram **accepted** the
  message, not that the owner saw it.
- **Tests** run against a localhost stub (`SDR_TELEGRAM_API_BASE`, accepted
  only for `127.0.0.1`/`localhost`) with a stub `sops`; tests never contact
  Telegram.

## Justification

Option 2 needs no owner setup, and the outbound-only allowlist removes the
only way this project could disturb the live bridge.

## Consequences

### Positive

- The owner gets out-of-band status with zero setup.
- The bridge's sole-consumer assumption is preserved by construction.

### Negative

- Two-way control over Telegram is not available to this project.
- Notifications share a token with another project; revoking it affects both.

### Neutral

- Delivery is best effort; the local log is the record of what was attempted.
