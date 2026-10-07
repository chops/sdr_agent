---
status: accepted
date: 2026-10-07
supersedes: null
---

# ADR-0011: Time Zone Database for Compliance Windows (`tz` 0.28.4)

## Status

Accepted (2026-10-07). Codex approved the design on the S8b pull request:
https://github.com/chops/sdr_agent/pull/14#issuecomment-6042419798. Codex
independently verified the Hex archive SHA-256 and the LICENSE hash below,
and confirmed that no updater is started. Under ADR-0001, a design ADR is
accepted on the peer's approval and the owner can veto. Claude proposed it
earlier the same day in slice S8b.

## Context

The accepted MVP checklist (1.6) fixes these compliance defaults. They are
local-time rules:

- quiet hours run from 18:00 to 08:00 in the campaign time zone (default
  `America/Denver`);
- the cap is 25 sends per day, and the day is the calendar day in the
  compliance time zone (S2 `SendQuotaDay.local_date`);
- a follow-up is due `delay_days` after acceptance, evaluated in the campaign
  time zone (S2 `CampaignEnrollment.advance_step`).

Elixir ships only `Calendar.UTCOnlyTimeZoneDatabase`. With it,
`DateTime.shift_zone/3` and `DateTime.new/4` fail for any zone except
`Etc/UTC`. S5 (choice 14) deferred the time zone database to S8, the only
caller. A fixed UTC offset would be wrong for about half the year in
`America/Denver`, which observes DST. On 2026-03-08 and 2026-11-01 a fixed
offset would open a send window an hour early or late and would move the
quota day boundary.

Constraints: the CI gate is hermetic, with outbound network blocked
(ADR-0007). Dependencies are pinned exactly and audited (ADR-0008). The
license must be compatible with this Apache-2.0 repository.

## Options Considered

### Option 1: `tzdata` (Hex, MIT)

**Pros:** the most widely used database, and the one the Elixir docs mention.
**Cons:** it requires `hackney` and its transitive dependencies, which this
project does not otherwise lock. By default it downloads new IANA releases at
run time, which must be disabled by config for hermetic CI, and it keeps the
data in an ETS table it writes at boot.

### Option 2: `tz` 0.28.4 (Hex, Apache-2.0)

**Pros:** it has no required dependencies. Its two optional dependencies,
`mint` and `castore`, are already in the lock (through Req/Finch) and are used
only by an updater that runs only when started explicitly. The IANA data
(`tzdata2026d`) ships inside the package and is compiled into function
clauses, so there is no network at compile time or run time and no process
state. It implements `Calendar.TimeZoneDatabase`, so the standard `DateTime`
API works with it.
**Cons:** the maintainer is a single developer. An IANA update means a
reviewed version bump, which is intended here.

### Option 3: hand-rolled US DST rules for the default zone

**Pros:** no dependency.
**Cons:** it covers one zone, campaign time zones are free IANA names (S5
validates them by shape), and it re-implements public data. It would be easy
to get subtly wrong.

## Decision

We will add `{:tz, "== 0.28.4"}` and pass `Tz.TimeZoneDatabase` to the
`DateTime` calls that need a zone. The global `:elixir, :time_zone_database`
setting stays unchanged. All local-time arithmetic lives in
`SdrAgent.Sales.LocalTime`: local date, local wall time, the next instant at a
local wall time, and adding local calendar days. That module resolves DST
gaps (the later instant) and folds (the earlier instant) explicitly. The
updater (`Tz.UpdatePeriodically` / `Tz.WatchPeriodically`) is never started,
and no `:tz` config key is set.

Provenance (verified 2026-10-07):

| Item | Value |
|---|---|
| Package | `tz` 0.28.4, Hex, released 2026-09-15, latest stable, not retired |
| License | Apache-2.0 (Hex metadata), LICENSE sha256 `42cd0b937ef70c2dd2a228d6b574e1459f5ac83c2cfac7ea687d97569412ea27` |
| Source | https://github.com/mathieuprog/tz (tag `v0.28.4`) |
| Lock checksums | inner `f5433914dcf8619d593979ec65bbe878158cad818bc2b53b44d9e4bda509753f`, outer `72fe8d526cf30fcc4e07cec4ceb583ba5f2d69c6334c9533419c836a6acd1c56` |
| Bundled data | IANA `tzdata2026d` |
| Advisories | `mix hex.audit` clean; OSV `v1/query` (Hex `tz` 0.28.4) returns none |
| New lock entries | `tz` only (optional `mint`/`castore` already locked) |

## Justification

`tz` is the only option that is correct for every IANA zone, needs no network
in any phase, and adds no transitive packages. Its license matches the
repository.

## Consequences

### Positive

- Quiet hours, the quota day and follow-up due times are correct across DST
  changes. Tests pin the 2026 `America/Denver` transitions.
- Hermetic builds stay hermetic, because the data is compiled from the package
  and nothing is fetched.

### Negative

- IANA updates arrive only through a reviewed version bump. A zone rule change
  after `2026d` is not seen until then. This is acceptable for synthetic MVP
  data.
- A new third-party package is now covered by the blocking audit
  (ADR-0008).

### Neutral

- S5 validated campaign and contact time zones by shape only, and left the
  tightening to the slice that adds a database. S8b now requires the zone to
  exist (`SdrAgent.Sales.Validations.Timezone` calls
  `LocalTime.valid_zone?/1`), so no stored zone can fail to resolve at send
  time.
