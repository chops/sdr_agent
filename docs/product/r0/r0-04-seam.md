# R0-04 (#50) seam cleanup: contract draft

**Status:** draft 1, 2026-10-14, for Codex's review before RED. No code.

**Backlog acceptance:**

> One facade; documented success / known-failure / unknown; test-only
> adapter proves a new provider plugs in. Evidence: contract tests.

**Depends on** R0-03 (merged, #135). The R0 G5 (D-109) covers R0-04 as a
reviewed PR.

## 1. What exists on main (`3b09183`)

- **One facade,** `SdrAgent.AI.ModelProvider.complete/2`, which runs:
  1. `Runtime.resolve/1`;
  2. `prepare/2`;
  3. reservation;
  4. the sent boundary (the facade marks the call sent for in-process
     providers; for ClaudeCLI, the server's launch admission does);
  5. `complete/2`;
  6. Zoi validation;
  7. settlement: completed, failed or unknown.
- **The behaviour** (`@callback prepare/2`, `complete/2`) and its
  providers:
  - `Fake`;
  - `ClaudeCLI`;
  - `CodexAppServer`, a disabled legacy adapter that fails closed.
- **The only direct call outside the facade:**
  `ModelProvider.CalibrationCall` calls `ClaudeCLI.prepare/2`. This is
  the accepted R0-07 calibration exception (ADR-0005 harness amendment).
- **`Runtime.resolve/1`** accepts any provider module for an explicit
  `:provider` option; only ClaudeCLI gets a health check.
- **The ledger's provider column** (`ModelInvocation.provider`) is a
  closed enum, `[:fake, :claude_cli, :codex_app_server]`, held in Ash and
  in a DB check.

## 2. Gaps found

- **G1. A malformed provider answer crashes the call.** After the call is
  marked sent, `settle/4` matches only `{:ok, _}`, `{:error, _}` and
  `{:unknown, _}`:
  - any other return (`:ok`, `nil`, a 3-tuple) raises `CaseClauseError`
    inside the span;
  - `{:ok, map}` without `:output` or `:raw_response` raises `KeyError`
    in `settle_result/4`.

  The row stays `sent`. Whether it is ever settled depends on the
  sweeper; see the R0 packet's tracked item "`sent` rows of an already
  terminal run stay `sent`". Exceptions and exits raised by the provider
  are already turned into `{:unknown, _}`; malformed returns are not.
- **G2. A malformed `prepare/2` return** (anything but `{:ok, map}` or
  `{:error, _}`) falls through the facade's `with`, and that raw value
  goes back to the caller untyped. Nothing is written, but callers can't
  rely on the error shape. A `{:ok, non_map}` reaches reservation and
  fails there with a less clear error. To confirm in RED.
- **G3. No test shows a new provider plugging in** without changes to
  the facade.
- **G4. "One facade" is not checked.** Nothing stops a new module from
  calling a provider's `complete/2` directly.

## 3. Proposed contract

- **R0-04-1. The closed outcome set.** After send, the facade settles on
  exactly three provider outcomes:
  - **success:** `{:ok, %{output: _, raw_response: _}}`, optionally with
    `:usage`. It is completed if valid, or failed as `validation_failed`;
  - **known failure:** `{:error, reason}`. It is failed, with
    attention for the drift reasons as today;
  - **unknown:** `{:unknown, reason}`, or a raise or exit. It is marked
    unknown and never retried automatically.

  **Anything else after send is unknown**
  (`{:error, :provider_outcome_unknown}` to the caller), never a crash.
  The reason is that the call may have reached the provider, so failing
  it as "known" would be dishonest. (G1)
- **R0-04-2. Before reservation:** a malformed `prepare/2` return is
  refused as `{:error, :malformed_provider_prepare}`. No invocation is
  reserved and nothing is charged. (G2)
- **R0-04-3. A test-only adapter plugs in** without facade changes
  (G3). The adapter is a module in `test/support` implementing the
  behaviour; the test chooses its outcome. It is selected per call with
  `provider: Adapter` and goes through every facade step, with each
  outcome of R0-04-1 and R0-04-2.
  - **The ledger:** its provenance records `provider: :fake` (the
    in-process class), because the ledger enum is deliberately closed.
    Adding a real provider remains a reviewed change: the enum, the DB
    check and an ADR-0004 amendment. The test documents that, and asserts
    that an unknown `provider` value is refused at reservation.
  - **Open question OQ-1:** is `provider: :fake` acceptable for the test
    adapter, or does Codex prefer the adapter to prove the closed-enum
    refusal only?
- **R0-04-4. One facade, checked** (G4). A source-inventory test (an
  AST walk, like R0-07's `ResultAggregateInventory`) fails if any module
  under `lib/` calls `complete/2` or `prepare/2` on a module that
  implements `SdrAgent.AI.ModelProvider`. The only exceptions:
  - the facade itself;
  - the provider modules' own internals;
  - `CalibrationCall`'s `ClaudeCLI.prepare/2`, named exactly.
- **R0-04-5. Documented.** The facade's moduledoc states the closed
  outcome set, the malformed-return rules and the sent boundary in one
  section. The behaviour's callbacks document what each return means.

**Not changed:**
- `CodexAppServer` stays: it fails closed, and its enum value labels
  historical rows. Removing it is a separate cleanup if wanted.
- No migration, no new attribute, no new action, and no change to
  ClaudeCLI's launch path or calibration.

## 4. Entity Model and ADR

- **Entity Model trigger:** no, proposed for Codex to judge.
  - **No persisted change:** no new or changed resource, attribute,
    policy or action. `mark_model_invocation_unknown/2` and
    `fail_model_invocation/3` are used as they exist.
  - **The behaviour change:** the facade's handling of malformed provider
    returns, which today is a crash.
  - **Open question OQ-2:** does the facade's return contract count as a
    "backend action contract" for the trigger?
- **ADR:** none. This is within ADR-0004's accepted provider seam.

## 5. Tests (RED first)

1. **G1, real RED** (these fail on main with a crash, through the test
   adapter):
   - each malformed return after send (`:ok`, `nil`, a 3-tuple,
     `{:ok, %{}}` without `:output`) gives `{:error,
     :provider_outcome_unknown}`;
   - the row is `unknown` and no Failure is created;
   - nothing is retried.
2. **G2, real RED:** a malformed `prepare/2` gives `{:error,
   :malformed_provider_prepare}`, with no invocation row and no counter
   change.
3. **Characterization** (these pass on main):
   - the adapter's success, validation failure, known failure and
     unknown outcomes each settle as documented;
   - a raise and an exit are each unknown.
4. **G4:** the inventory test. It is a characterization test today. Its
   sensitivity check is a temporary direct call added locally, then
   reverted.
5. **The ledger enum:** a reservation with an unknown `provider` value
   is refused (characterization).

**Gate:** the full gate on an owned test partition. Fake and test adapter
only; no model calls.

## 6. Size

One PR. About a day of work including review.
