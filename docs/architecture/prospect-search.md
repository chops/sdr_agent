# Interactive prospect discovery

See [the runtime diagram](prospect-search.mmd) and accepted ADR-0027.

The existing authenticated Leads page obtains ephemeral company and people
findings through the fresh-hosted-owner facade. Each paid action is explicit.
Company confirmation precedes people search; company-page text is a separate
explicit request through Exa, never a direct fetch to a result URL.

The dedicated `one_for_all` subtree contains Finch, Task.Supervisor and Limiter.
The limiter monitors both temporary worker and caller, uses a private completion
capability, and releases permits only on worker death. Cancel, caller death and
deadline stop the worker before release. A subtree restart never replays an
uncertain paid operation. A five-second cooldown follows each terminal action;
transient state resets on restart, not a durable spending limit.

Only fixed verified-TLS Exa endpoints receive credentials. Provider bodies are
byte-bounded before decoding. No redirects, automatic retries, enrichment or
model calls occur. Structured entity fields are unverified suggestions; excerpts
are literal bounded text, not synthesized evidence. Unknown data remains unknown.

Only a current request result may populate the view after another owner check.
Server-held selected cards can prefill the unchanged Add prospect form, clearing
old previews and leaving email blank. Search and prefill write nothing. Existing
intake validation and explicit preview/save remain the only persistence path.

Ordinary builds expose constant-refusal facade entries. Runtime fake clients,
transport plugs and UI adapters are available only in compiled test-seam builds.
The root-private Exa secret is read at runtime; feature activation is hosted-only.

The generic generator was run in a temporary preview and reviewed: its seven
domains/resource counts overinclude generic matches and it omits conditional
runtime integrations. Existing domain diagrams remain unchanged; this maintained
runtime diagram records the new provider and supervision boundary precisely.
