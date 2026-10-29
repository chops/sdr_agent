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

<!-- BEGIN ADR-0001 AMENDMENT 2: text as reviewed by Codex (PENDING) -->

## Amendment 2 (2026-10-28): the owner-only hosted research list

**Status: PROPOSED.** This amendment has not been accepted. The owner answered the retention questions on 2026-10-28 (D-258), and this text states only those answers. It becomes acceptable only after these remaining steps, in order:

1. Codex gives an independent PASS on this exact text.
2. This text is appended, unchanged, to the reconciled docs branch, under that branch's own permitted docs scope and with its branch and head rebound at that time. The append preserves accepted Amendment 1, the accepted ADR-0014 texts (including its Amendment 3 and addendum) and the D-249 interior byte for byte. The append-only diff and its pins go back for review, and Codex reviews that actual commit. The pins are:
   - the commit's 40-hex id;
   - this file's SHA256 at that commit;
   - the SHA256 and byte count of the bytes between these markers.
3. The owner accepts that actual reviewed commit in their own words, naming those three pins. A decision row records the words and the pins. The receipt commit that fills the Acceptance block is recorded separately.

   The hash of a draft or of a simulated concatenation is not an acceptance pin. A preference the owner gives on a draft is not exact-text acceptance and is not recorded as it.

D-255's direction, D-256 item 3, D-258's retention answers, D-236's acceptance of Amendment 1, D-242 and the D-219 delegation do not accept this amendment.

Accepting it is not deployment, transfer or opening. The order in Decision item 9 governs: no real byte reaches the host until the open backup precondition (Retention, P-B) is resolved, and the reviewed procedure, the backup exclusion and the readiness evidence are in place.

### Context

- **The owner's direction.** On 2026-10-28 the owner, replying to the plan for one private research file on the Mac, wrote "no, i want to be able to see it on sdr.a-z.bot" (D-255, received 18:10:22.774Z). Asked whether the site should get a read-only contact list or the whole product, the owner answered "the list" (D-256 item 3, received 22:12:37.513Z).
- **What conflicts with it.**
  - Amendment 1 keeps the hosted copy on synthetic data only: "The real-data switch of ADR-0014 Amendment 2 stays off, because this copy is not the owner's local instance." It also says "Anything more needs its own amendment: … real-data use."
  - ADR-0014 constraint 7, as amended by that charter's Amendment 2, lets real people be processed only by the owner's own local instance. That Amendment 2's retention rule keeps app-held copies on the owner's machine.
  - D-245 limits real contacts to the local prototype database, "never hosted".
- **What the list is.** Public work identity of real people at real businesses, researched in Anthropic (Claude) sessions under D-251 and D-253: name, role or title, company, a work email where one is publicly listed, and the source web address. Contact handling ends at 2026-11-07T07:00:00Z, exclusive (D-253 item 3).
- **The reviewed entity contract.** Codex's scope proposal (65a58a22) and entity disposition r2 (daf6ea0e), with Claude's independent PASS (6c381bd1). The PASS carries one clarification: at most one staged-or-active snapshot per owner.
- **The owner's retention answers.** On 2026-10-28 the owner chose exact-target removal at close (R1-a) and exclusion from backups (R2-a), and acknowledged that removal is not complete erasure (D-258). The host's source configuration declares one backup job, which leaves out the SDR data paths. Provider-level backups and images have one time-bounded observation, and whether the deployed configuration matches that source is still open (see Retention, P-B).

### Options considered

#### Option 1: a list-only copy off the Mac (chosen)

One immutable snapshot of five fields, shown read-only to the owner on the hosted copy, outside the product's data and workflow.

**Pros:** meets D-255 in the form the owner chose in D-256 item 3. It adds no model call, product processing or write surface to the hosted copy. Server delivery ends by the clock.
**Cons:** real personal data leaves the Mac and sits on a server, where the host's administrators and its backups can reach it. Encryption in transit does not change that. A transfer and install procedure, the backup inventory and the backup exclusion are owed before anything moves.

#### Option 2: a local-only file

The research stays in one private file on the Mac.

**Pros:** no copy off the Mac; the existing rules already cover it.
**Cons:** the owner rejected it (D-255).

#### Option 3: the full product journey on the hosted copy

Real leads go through research, drafting, approval and capture on the hosted copy.

**Pros:** the whole product on a real URL.
**Cons:** it needs a hosted model provider and terms decision, because the real model runs only locally (ADR-0014 constraint 5, D-237). It also needs the real-data switch on a server, real leads in the hosted database and a much larger review. The owner chose the list (D-256 item 3).

### Decision

For the one hosted copy of Amendment 1 only, we permit one read-only research list, on these terms and no others.

1. **One instance.** The owner-only instance at https://sdr.a-z.bot on ch-web-prod (Amendment 1, item 1). No other host, instance, viewer or provider.

2. **One snapshot, once.** The list is one immutable snapshot, installed once.
   - At most one snapshot is staged or active for the owner at any time. At most one is ever activated under this amendment.
   - After activation it is never replaced, corrected, extended or superseded. A new opaque id, file or path does not create a new allowance. A later or refreshed list needs its own reviewed scope and amendment.
   - A staged snapshot that failed validation and was never active may be removed and staged again, only under the retry rule of the reviewed procedure (item 9). That retry is the only repeat the procedure may allow: it is never an active replacement, and never a recurring or automatic sync. Nothing overwrites an active snapshot.
   - Lifecycle: absent → staged and validated → active → withdrawn or expired → removed (see Retention). Withdrawn and expired are final.

3. **Exactly five fields per row.**
   - name, required;
   - role or title, may be absent;
   - company, required;
   - work email, only one publicly listed at the source, may be absent;
   - source web address, required.

   A missing value stays absent; nothing is inferred or filled in. The reviewed snapshot schema fixes bounds on rows, strings and bytes.

   The whole snapshot is refused before activation if it has any of the following, so nothing is silently dropped:
   - any other field, for example a company website or a fit reason;
   - an unknown or duplicate column;
   - a value over its bound;
   - a control character or malformed text;
   - an unsafe address.

   An email address is a candidate taken from its source. It is not verified as deliverable and it is not permission to contact.

4. **Shown as text, never fetched.**
   - Every value is escaped text. No raw source HTML, remote image or embedded content.
   - An email is plain text, with no `mailto:` link and no compose or send action.
   - A source address must be an absolute `http` or `https` address with no user name or password in it. Any other scheme is refused.
     - Both kinds are shown as escaped text.
     - Only an `https` address may also be a link, after validation, with `rel="noreferrer noopener"`.
     - An `http` address is never a link and is never upgraded to `https`.
   - The application never fetches, prefetches, previews or follows a source address. The page asks the browser for no prefetch or preconnect.

5. **Installed out of band; the application only reads.**
   - An operator named in the reviewed procedure (item 9) installs the snapshot from outside the application. It goes to the exact reviewed destination: a private location outside the web root, the release and the repository, with the reviewed owner and permissions. The web service can read it and cannot write it.
   - Activation is atomic. It happens only after validation: the schema and bounds, and a SHA256 and row count that match the staging receipt.
   - The owner withdraws the snapshot by instructing the operator, who closes it at once.
   - The application has no action, endpoint, form, job or upload path that creates, changes, replaces or deletes the snapshot. It has no general file upload, and no download or export.

6. **A read gate on the server clock.**
   - The snapshot's `expires_at` is at most 2026-11-07T07:00:00Z: 00:00 MST, the end of Friday 2026-11-06 in America/Denver. It is an exclusive end and can never be extended. Withdrawal can only end access earlier.
   - **Which paths the gate covers.** It applies to every server-side path that serves rows:
     - each read and render;
     - each live-session mount, reconnect and event;
     - rows the server already holds in process memory or a cache.
   - **How it decides.** Before serving any row, the server compares its own UTC clock with the earlier of `expires_at` and 2026-11-07T07:00:00Z. At or after that instant it serves no row.
   - No timer, job or receipt has to run for the gate to deny. The installed evidence shows that the host clock is synchronised.
   - **What expiry does not do.** Expiry stops further delivery from the server. It does not erase a page already delivered to the owner's browser.

7. **Only the owner's admitted session reads it.**
   - The snapshot belongs to exactly one user: the owner whom Amendment 1's allowlist admits on this copy. It is never reassigned.
   - The read goes through the application's domain boundary. Its policy admits only an actor whose user id equals the snapshot's owner id, and that actor must pass Amendment 1's admission checks whenever a session, live session or connected event resolves the user. Being an admin, or holding any other role, is not enough.
   - Anonymous, other, stale and revoked sessions are denied, including on live-session reconnect and on every event. A hidden menu item, styling or `robots.txt` is not access control.
   - **Response controls.** These govern what the server and the proxy send:
     - every response that carries rows is marked `Cache-Control: private, no-store`;
     - the proxy keeps those responses out of every shared cache;
     - the page and its responses carry no-index directives: an `X-Robots-Tag` header and a matching meta tag.

     The controls do not reach the browser's memory, copying by the owner, or erasure. The implementation plan must prove each control.
   - No URL, query string, file name or route carries a field value or an identity. The snapshot id is opaque.
   - Display in the owner's browser is the intended disclosure. It does not permit copying the list into agent tools: no agent opens, screenshots or reads the hosted list. Readiness checks use synthetic data and metadata only.

8. **Private lifecycle receipts, metadata only.**
   - Each staging, activation, withdrawal, expiry observation and removal appends one receipt to a private, append-only log outside the application. The reviewed procedure fixes its location and permissions.
   - A receipt holds only these values:
     - the action;
     - the opaque snapshot id;
     - the content SHA256;
     - the row count;
     - the actor, the owner or the named operator;
     - the actual time of the action or observation.
   - A receipt holds no field value, credential or contact-bearing path.
   - A receipt is never back-dated. An expiry observation records when expiry was observed, not the cutoff instant.
   - Reads are not receipted, and the application writes nothing. The product's audit trail is unchanged and holds no row of the list.

9. **Transfer and install only under a separate reviewed procedure, in this order.**
   - **First, the procedure.** Codex reviews it and the owner approves it in its own decision row before anything moves. It fixes:
     - the operator;
     - the exact commands, route and destination;
     - every host location the bytes will touch, including staging and every temporary transfer location;
     - the removal targets in Retention, R1;
     - the retry rule of item 2;
     - how the R2-a exclusion and P-B1 are shown to hold from the first real staging byte through removal (Retention, R2 and P-B).

     This amendment grants no host access, credential or SSH authority. It grants no transfer beyond the one below, and it changes no decision right in ADR-0014.
   - **Next, the gate before the first real byte.** No byte of the real list is transferred to or staged on ch-web-prod, even in a temporary location, until all of these hold:
     - the open precondition P-B is resolved (see Retention): P-B1's provider evidence is re-established for the interval, and the deployed configuration is shown to match the reviewed source (P-B2). An answer of "unknown" keeps this gate closed;
     - the backup inventory is reviewed, and the R2-a exclusion is in place for every host location in the procedure (see Retention, R2);
     - synthetic tests of allow, deny, escaping, expiry, bad schema, no logging and no product job pass on a reviewed, pushed head with the full required gates;
     - the installed release has containment, admission and logging evidence.
   - **Then, one transfer.**
     - It is authenticated and encrypted, goes to the exact reviewed destination over an existing reviewed route, and is made by the owner or by the Anthropic (Claude) session that D-251 and D-253 permit.
     - The only repeat allowed is item 2's retry of a never-active staging that failed validation. It runs under the same procedure and gate, with its own receipts.
   - No content passes through Codex, the peer channel, CI, GitHub or any other session or provider. Codex sees only hashes, counts and synthetic fixtures (D-251).
   - Encryption in transit does not keep the server copy local. It does not hide that copy from the host's administrators or its backups.
   - **Last, staging, validation and activation** (item 5). The owner opens the list only after activation.

10. **No processing beyond display.**
    - No hosted model call. The hosted copy stays on the Fake model (Amendment 1).
    - No product processing of the rows: no import, research, qualification, enrichment, drafting, approval, capture, job, webhook or notification.
    - No outreach of any kind.
    - No CRM import or relation. No Sales, Research or Outreach record is created from a row, refers to one or is linked with one.

11. **The hosted product stays synthetic.** Every hosted product path stays Fake and synthetic, and the real-data switch stays OFF on this copy. The display path is not a way around the switch: no row ever enters ordinary domain processing.

12. **Logging, telemetry and credentials stay as Amendment 1 says.**
    - Amendment 1's rules for the application, the proxy and telemetry are unchanged. Production exports no telemetry.
    - In addition, no field value may reach any of these:
      - a request, LiveView, crash-report or proxy log;
      - an exception dump;
      - analytics or telemetry;
      - agent-visible output.
    - Any sink that can record a field value is an open readiness defect, and it keeps the view closed.
    - D-254 and D-256 item 2 apply only on the owner's Mac. They are not hosted waivers.

13. **Failure closes the view.** The page shows "unavailable" and serves no row if any of these fails: admission, the destination, the expiry gate, the logging controls or the data boundary.
    - That includes a snapshot that is missing, unreadable, invalid or expired, or whose SHA256 no longer matches its activation receipt.
    - A breach found after activation is handled as a withdrawal and reported to the owner the same day. Reopening needs a new owner decision.

### Retention

**The owner's answers (D-258, 2026-10-28).** The owner chose R1-a for removal and R2-a for backups, and acknowledged that removal is not complete erasure. The alternatives offered in r2, R1-b (no removal authority) and R2-b (disclose and accept a bounded backup lifecycle), were not chosen and are not terms of this amendment. The removal authority below takes effect only when the owner accepts this amendment; D-258 answered the questions and is not that acceptance. The authority covers exactly the named targets and nothing else.

**R1. Removing the hosted copy: exact-target removal (R1-a, D-258).**

At close, meaning when the gate closes at expiry (2026-11-07T07:00:00Z) or earlier after a withdrawal, the operator named in the reviewed procedure removes exactly these files:

- the hosted snapshot file at the reviewed destination;
- any staging copy not already removed;
- each transfer copy that the reviewed procedure names, meaning any file made only to carry the snapshot to ch-web-prod, on either end.

The operator does this at the first agent session after the close and records a removal receipt with the actual time. If removal has not happened within 24 hours of the close, the operator tells the owner the same day. This is an operational commitment, not a guarantee of deletion within 24 hours.

Removal never touches the owner's local source file on the Mac, the product's audit trail, the witness store or the receipts.

**R2. Backups of ch-web-prod: exclude (R2-a, D-258), from the first real staging byte through final removal.**

No byte of the real list is transferred to or staged on ch-web-prod, including in a temporary transfer location, until all of these hold: the open precondition P-B below is resolved, the host's backup behaviour has been inventoried and reviewed, and the exclusion below is in place. The exclusion must then hold without a gap from the first real byte staged on the host until R1's removal receipt.

The inventory comes from the host's infrastructure source, from evidence of the deployed state, and, for what the source does not declare, from metadata-only provider evidence (P-B1). For every host location in the procedure, the inventory states:

- which backups, snapshots or replicas cover the location, including any that image the whole disk;
- where each one is stored, including any off-host target;
- who can read it;
- how long it is kept.

**Known from the infrastructure source.** These facts come from reading the host's configuration only (`nixos-hetzner-infra` at 6303caf77a582b8e355cabda2e08af2036f910f2, `hosts/prod.nix` and `modules/sdr-agent.nix`). Nobody accessed the host. They are what the source declares, configures or comments, not an inventory of live state and not proof that this is the only live backup mechanism. The inventory review confirms them against the deployed state (P-B2).

- The source declares one BorgBackup job for ch-web-prod: daily, encrypted (`repokey-blake2`), to a Hetzner Storage Box, keeping 7 daily, 4 weekly and 6 monthly archives (`prod.nix`:199-216).
- That job's declared paths are only `/var/lib/caddy` and `/var/backups/postgresql` (`prod.nix`:201). Its pre-backup hook sets the dump directory to `/var/backups/postgresql` (`prod.nix`:226) and dumps three databases of other applications (`prod.nix`:245-277). It has no SDR dump command.
- A source comment states that the SDR data paths `/var/lib/sdr_agent_postgresql` and `/var/lib/sdr_agent` are not in that backup set (`prod.nix`:91-94). `modules/sdr-agent.nix` configures the SDR application's own PostgreSQL 18 cluster, with its data under `/var/lib/sdr_agent_postgresql` (`modules/sdr-agent.nix`:12-20, 54-60).
- The shared PostgreSQL 16 server declares an `sdr_agent_prod` database that a source comment calls unused (`prod.nix`:56-58). That comment is not a measurement of the live database. The pre-backup hook does not dump it.
- The SDR service is configured to send its standard output and error to journald (`modules/sdr-agent.nix`:150-152), which is not in the Borg set. That setting is not evidence of what the journal holds or that no other sink exists. The Caddy access-log configuration for sdr.a-z.bot deletes the request URI and the Referer header (`prod.nix`:449-460, the deletions at 457-458). Item 12 still applies: no field value may reach any log.

**The exclusion.** Before the transfer, the review shows that every host location in the procedure is outside every backup, snapshot and replica the inventory lists, and stays outside them from the first real staging byte through removal. That covers the destination, staging and every temporary transfer location. Any whole-disk mechanism that can copy a location during that interval defeats R2-a: an enabled automatic server backup, a manual or scheduled snapshot or image, or a replica.

On the known configuration this means: the snapshot, its staging copy and every transfer copy on the host live only under `/var/lib/sdr_agent` or `/var/lib/sdr_agent_postgresql`. None is ever placed under `/var/lib/caddy` or `/var/backups/postgresql`, in the shared PostgreSQL 16 server, or anywhere else on the host. Provider-level mechanisms are covered by P-B1.

**No implicit infrastructure change.** This amendment authorises no infrastructure change. It gives no permission to disable a backup, to create or delete any image or snapshot, or to change the host or the provider project. If a covering mechanism exists, the exact change that would remove it is brought back for its own approval and review, and the transfer waits for that. Its scope is brought back, not inferred from this text. Images that existed before the first real staging byte cannot hold the list, and they need not be deleted to meet R2-a.

Backups are not a retention path for the list under this amendment. No exclusion means no transfer. If any location cannot be excluded, the transfer does not happen, and there is no silent fallback to a bounded backup lifecycle. A bounded backup lifecycle, or any other alternative, needs its own reviewed amendment that the owner accepts in their own words.

**Open precondition P-B: what the configuration cannot show.**

- **P-B1. Provider-level backups and images (Hetzner Cloud).** The evidence must show each of these separately:
  - the automatic server-backup state of ch-web-prod, identified by its server id;
  - a complete inventory of backup and snapshot images, with pagination shown complete, correlated with that server id through each image's `created_from` and `bound_to`, and naming any image whose origin is ambiguous;
  - any other mechanism that could copy a host location: another snapshot or replica, or scheduled or automated image creation.

  A backup schedule is an enablement state; a snapshot is a retained image object. A null backup window does not show that no snapshot is retained, an unrelated install image does not mean snapshots are on for the server, and an existing image does not capture later writes.

  **Status of P-B1.** One metadata-only observation exists (coordinator findings f9b449f0 as corrected by 260f7e21). At 2026-10-29T00:01:18Z the provider API showed, for the project of the token used: ch-web-prod, server 119180121, with `backup_window` null; 0 backup images; and 0 snapshot images whose `created_from.id` or `bound_to` equals 119180121, with pagination complete and deprecated images included. This is a time-bounded finding about what that project's API showed. It does not prove that no off-account or historical copy exists, and it does not show that the state holds through removal.

  The reviewed procedure re-establishes P-B1 with fresh metadata-only evidence immediately before the first real byte. It also shows how no backup is enabled and no snapshot, image or replica of ch-web-prod is made from then until removal, and records P-B1 again when removal is complete. A covering mechanism found in that interval is a breach under item 13.

  Provider evidence is collected only over a reviewed, GET-only, metadata-only route, and records no credential, raw response or account detail. Collecting it is not permission to change infrastructure, and this amendment grants no credential. The owner keeps control of decisions and credentials, and may supply that evidence through an authorized metadata-only route.
- **P-B2. The deployed configuration.** Whether the configuration running on ch-web-prod matches 6303caf. The inventory review must show that it does, without the list or any field value. This is OPEN.

Until both are resolved, the transfer stays closed. "Unknown" is a valid answer, and it keeps the transfer closed until evidence resolves it. The answers are facts for the inventory, not new choices: they do not change this text, and the R2-a exclusion applies to whatever they reveal.

Backups of the owner's Mac stay the owner's to manage (ADR-0014 Amendment 2).

**Erasure is not promised (D-258).** The owner acknowledged that removal is not complete erasure. Copies may remain in the owner's browser, in any backup, and in Anthropic (Claude) sessions that already handled the list under D-251 and D-253. This amendment promises no erasure from any of them. Removal under R1 removes only the named files.

### Scope precedence

ADR-0014 supersedes this charter for product work, and its constraints stay in force "unless the owner accepts a later ADR that amends them". Once the owner accepts it, this amendment takes precedence over the following clauses, solely for this one list on this one hosted copy:

- **Amendment 1's "Synthetic data only."** The hosted copy may hold and show this list. The rest of that clause stands: the real-data switch stays off and the product stays synthetic. This is the "own amendment" for real-data use that Amendment 1 requires, for this list only.
- **ADR-0014 constraint 7, as amended by that charter's Amendment 2,** where it lets real people be processed only by the owner's local instance.
- **That Amendment 2's retention rule** that app-held copies stay on the owner's machine.
- **D-245,** where it limits real contacts to the local prototype database, "never hosted".

Unchanged:

- every invariant, stop condition and owner checkpoint of this charter;
- everything else in Amendment 1, including its mail path, admission, rate bound, logging rules, deployment grant and follow-up containment;
- ADR-0014 constraints 1 to 6, its decision rights, and its Amendment 2's other rules;
- the statement in ADR-0005's D-237 amendment that the hosted copy stays Fake-only and synthetic. It still holds for every product path, and a cross-reference there points here;
- the D-251 and D-253 fields, their Anthropic-only processing and their window;
- D-254 and D-256 item 2, which stay Mac-local;
- the local prototype's funding, readiness, capture-only, suppression, approval, idempotency and audit rules, and the provider limits on agent sessions.

ADR-0014 and ADR-0005 carry append-only cross-references to this amendment.

### Justification

Option 1 is the narrowest change that gives the owner what D-255 and D-256 item 3 ask for.

- Keeping the list outside the product's data and workflow leaves the real-data switch, the Fake model and capture-only delivery intact on the hosted copy. A displayed row cannot become a lead.
- Installing the snapshot out of band leaves the application with no write surface for it.
- Gating every row-serving path on the server clock stops server delivery at the cutoff even if nothing else runs.
- Keeping every host copy under the two SDR paths that the source's Borg job leaves out, and requiring evidence that no provider backup, snapshot or replica can copy them from the first real byte through removal, means no inventoried backup can capture the list.
- Exact-target removal at the first agent session after the close, with a same-day notice if it is late, bounds how long the server copy outlives the gate without claiming erasure.
- Metadata-only receipts record the lifecycle without making a second copy of the data.

### Consequences

- **Positive:**
  - The owner sees the research where they already use the demo.
  - The hosted product, its model and its delivery are unchanged.
  - Server delivery ends by the clock, and the server and transfer copies are removed at the first agent session after the close.
- **Negative:**
  - Real personal data sits on a server off the Mac until it is removed. The host's administrators can reach it. Encryption in transit does not prevent that.
  - Expiry stops server delivery. It does not erase a page already in the owner's browser.
  - Erasure from backups, browsers and Anthropic sessions is not promised; the owner acknowledged this (D-258).
  - P-B1 rests on one time-bounded provider observation and must be re-established for the interval from the first real byte through removal. Whether the deployed configuration matches the reviewed source (P-B2) is not yet known. Until both are resolved, the transfer stays closed.
  - Several things are owed before the first real byte reaches the server: the P-B evidence, a reviewed procedure, a reviewed backup inventory with every location excluded, and installed evidence. If backups cannot exclude the list without an infrastructure change, that exact change needs its own approval and review first. If a location cannot be excluded at all, the list does not reach the server under this amendment. This work competes with the Friday milestone.
  - The list is fixed at install. A correction after activation needs a new decision.
- **Neutral:**
  - Company context, such as a website or a fit reason, is not shown. Showing it needs its own owner and schema decision.
  - The product journey with real data stays on the Mac (ADR-0005's D-237 amendment).

### Ends

This amendment lapses at the first of these: 2026-11-07T07:00:00Z, the owner's withdrawal, or the hosted copy being taken down. The R1 removal authority, the receipt duties, and the R2 exclusion with the P-B1 conditions it depends on continue until removal is complete.

<!-- END ADR-0001 AMENDMENT 2 -->

### Acceptance of Amendment 2 (to fill)

This block is outside the hashed interior. A later receipt commit fills it in. The pins below identify the reviewed commit the owner accepted, not the receipt commit. The receipt commit cannot record its own file hash, so its id is recorded only in the decision row.

- Owner's exact words: `<OWNER WORDS>` (chat, received `<UTC TIME>`, UUID `<UUID>`).
- Independent review: Codex PASS `<REVIEW ID>` on this exact text.
- Reconciled-commit review: Codex PASS `<REVIEW ID>` on the append-only diff and pins of the accepted commit.
- Accepted commit, on the reconciled docs branch: `<40-HEX COMMIT>`.
- File: `docs/adr/0001-unattended-build-operating-charter.md`. Sha256 at the accepted commit, before this block was filled: `<64-HEX>`.
- Interior: the bytes between the BEGIN and END marker lines, starting with the BEGIN line's trailing newline and ending with the newline before the END line. Sha256 `<64-HEX>`, `<N>` bytes.
- Decision row: `<D-NNN>`. It also records the receipt commit.
