# R0-04 (#50) seam cleanup: contract draft

**Status:** draft 3, 2026-10-15, for Codex's review before RED. No code.
- **Draft 1** (`d6e9f34`): Codex NEEDS-REVIEW. The findings:
  - the entity trigger is yes;
  - the malformed-reply boundary needs a full definition, and the
    invocation states must keep their precedence;
  - the inventory missed `Runtime.prepared/1`;
  - G3 is a partial gap, not a missing adapter.
- **Draft 2** (`d24f724`): Codex NEEDS-REVIEW. The findings:
  - a Zoi-valid output that isn't a map has no defined storage;
  - the reserved-row reasons were misstated;
  - "castable" usage needs a definition.
- **This draft** answers them. Section 4 holds the narrow entity delta,
  and section 7 holds the soft-stop record.

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
  6. a re-read of the row for ClaudeCLI;
  7. settlement: completed, failed or unknown, or nothing for a terminal
     row.
- **The behaviour** (`prepare/2`, `complete/2`) and its providers:
  - `Fake`;
  - `ClaudeCLI`;
  - `CodexAppServer`, a disabled legacy adapter that fails closed.
- **Calls to `prepare/2` or `complete/2` outside the facade:**
  - `ModelProvider.CalibrationCall` calls `ClaudeCLI.prepare/2`. This is
    the accepted R0-07 calibration exception, and it uses the facade's
    shared invoke and settle path.
  - `Runtime.prepared/1` (`runtime.ex`, the `prepared/1` helper) calls
    `module.prepare(%{}, [])` on a **dynamic** receiver. It reads the
    fixed provenance of an in-process provider for `Runtime.status/0`.
    It reserves nothing and calls nothing.
- **A test adapter already exists:** `ModelProviderTest.UnknownProvider`
  (`test/sdr_agent/ai/model_provider_test.exs`) implements the behaviour
  with Fake's `prepare/2`. It covers one outcome ("an ambiguous provider
  outcome is persisted as unknown").
- **The ledger's provider column** (`ModelInvocation.provider`) is a
  closed enum, `[:fake, :claude_cli, :codex_app_server]`, held in Ash and
  in a DB check.
- **Settlement** goes through `Agents.finish_model_invocation/4`, in one
  transaction:
  1. lock the run (`FOR UPDATE`);
  2. store the response body;
  3. run the invocation action;
  4. settle the run's budget (`BudgetCounter`).

  The transitions:
  - `:complete`: sent → completed;
  - `:fail`: reserved or sent → failed;
  - `:mark_unknown`: sent → unknown.

## 2. Gaps

- **G1. A malformed reply after send crashes the call.** `settle/4`'s
  sent branch matches only `{:ok, _}`, `{:error, _}` and `{:unknown, _}`.
  - Any other return raises `CaseClauseError` inside the span.
  - An `{:ok, map}` without `:output` or `:raw_response` raises
    `KeyError`.
  - A non-binary `raw_response` or a malformed `:usage` fails inside
    settlement.

  The row stays `sent`, and the run's budget isn't settled. Whether it
  ever is depends on the sweeper; see the R0 packet's tracked item
  "`sent` rows of an already terminal run stay `sent`".
- **G1b. A non-map output can't be stored, valid or not.** A non-map
  parsed or invalid output written to `parsed_output` (a `:map` field)
  fails settlement instead of being recorded. This covers a Zoi-valid
  scalar or list from a non-object schema (the request contract allows
  any `Zoi.schema()`) as well as a Zoi-invalid non-map.
- **G2. A malformed `prepare/2` return** falls through the facade's
  `with` and goes back to the caller untyped. Nothing is written. A
  `{:ok, non_map}` reaches reservation and fails there less clearly. To
  confirm in RED.
- **G3. The full outcome matrix is untested** through a plugged-in
  adapter. Only "unknown" is tested today.
- **G4. "One facade" is not checked,** including the dynamic receiver in
  `Runtime.prepared/1`.

## 3. Contract

### R0-04-1. The provider reply envelope, after `complete/2`

**A valid reply is exactly one of:**

| Reply | Shape | Settles as |
|---|---|---|
| **Success** | `{:ok, result}`. `result` is a map with `:output` (any term) and `:raw_response` (a binary). An optional `:usage`, if present, must pass `Ash.Type.cast_input/3` and `Ash.Type.apply_constraints/3` for the embedded `SdrAgent.Agents.Usage` type, with its non-null, nonnegative integer fields; the **normalized** value is what settlement writes. | Zoi-valid and the parsed value is a map: completed. Otherwise failed as `validation_failed` (R0-04-2) |
| **Known failure** | `{:error, reason}`, any term | failed, `provider_error` with `safe_reason/1`; the drift reasons open their attention Failure as today |
| **Unknown** | `{:unknown, reason}`, any term; or a raise or exit from the provider (as today) | unknown |

**Anything else is protocol-malformed:**
- another tag or arity: `:ok`, `nil`, a 3-tuple;
- `{:ok, non_map}`;
- `:output` missing;
- `:raw_response` missing or not a binary;
- `:usage` present but failing the embedded type's cast or constraints
  (for example negative, nil or incomplete fields; numeric strings
  follow the type's actual cast rules, and RED records the result).

The facade checks the envelope **before** any settlement write. It
doesn't rescue the settlement write.

**How a malformed reply settles depends on the re-read invocation state,
which takes precedence over the reply:**

| Row state when settling | Malformed reply | Unchanged for valid replies |
|---|---|---|
| `sent` | **Unknown.** `mark_model_invocation_unknown`; the caller gets `{:error, :provider_outcome_unknown}`. The call may have reached the provider, so a "known" failure would be untrue. No Failure is opened. | yes |
| `reserved` (ClaudeCLI never launched) | **Failed, never sent,** with `:launch_not_admitted`. Never marked sent or unknown. | **Yes, kept exactly:** a valid `{:ok, _}` fails with `:launch_not_admitted`, and valid `{:error, reason}` and `{:unknown, reason}` fail with their own `reason`, as today |
| terminal (launch-refused, recovered, already settled) | **No write:** no second settlement, event or Failure. The caller gets `{:error, :invocation_already_settled}`, as today for non-error replies. | yes |

**Only provider and protocol outcomes are normalized.** A database,
authorization, audit or Ash error from `Agents` settlement, the body
store or the chain still comes back as that error. It is not relabeled
as a provider "unknown", and there is no broad `rescue` around
settlement.

### R0-04-2. Validation and storable output (G1b)

`ModelInvocation.parsed_output` is a `:map`, and that is unchanged: the
persisted type is not widened. A valid envelope settles like this:

| Zoi result | Parsed value | Settles as |
|---|---|---|
| valid | a map | **completed,** as today |
| valid | not a map (a scalar, a list, or a transform that produces a non-map) | **failed as `validation_failed`**, with `parsed_output: nil` and one `validation_errors` entry `%{"message" => "output is not an object", "type" => <type name>}` |
| invalid | a map | **failed as `validation_failed`,** with `parsed_output` the output, as today |
| invalid | not a map | **failed as `validation_failed`,** with `parsed_output: nil`, Zoi's errors and the same type-only entry |

- **The type name** is one of `"string"`, `"number"`, `"boolean"`,
  `"list"`, `"nil"` or `"other"`. The extra entry names only the type,
  never the output itself.
- **`response`** keeps the raw response unchanged.
- **This is a validation outcome of a well-formed reply.** It is neither
  protocol-malformed nor unknown, so it gives a known failure, `{:error,
  {:validation_failed, errors}}`.
- **It is never a crash,** and never a hidden settlement error.

### R0-04-3. Before reservation (G2)

`prepare/2` must return `{:ok, provenance_map}` or `{:error, reason}`.
Anything else gives `{:error, :malformed_provider_prepare}`: no
reservation, no counter change, no event. A valid `{:error, reason}` is
returned as today.

### R0-04-4. The plugged-in adapter (G3)

The existing `UnknownProvider` pattern is extended into one synthetic,
in-process test adapter in `test/support`, whose outcome each test
chooses.

- **Its provenance:** `provider: :fake`, `profile_id: :fake`, and Fake's
  synthetic provenance. Codex's OQ-1 answer: this proves the callback and
  facade seam within the closed ledger classes. It is no authority for a
  real provider.
- **No external I/O and no model calls.**
- **Adding a real provider** stays a reviewed change: the enum, the DB
  check, admission and an ADR-0004 amendment.
- **One test** asserts that an unknown `provider` value is refused at
  reservation.

### R0-04-5. One facade, checked (G4)

An AST inventory test of `lib/**/*.ex` flags any call to `prepare` or
`complete` with arity 2 in these forms:

- a remote call on an aliased or fully qualified module that implements
  `SdrAgent.AI.ModelProvider`;
- a remote call on a **dynamic receiver** (`var.prepare(_, _)` or
  `var.complete(_, _)`), whatever the receiver;
- a capture, `&Mod.prepare/2` or `&Mod.complete/2`;
- `apply/3` or `Kernel.apply/3` with a literal `:prepare` or `:complete`.

**Exceptions,** each named exactly as module, function and receiver form:
1. the facade's `run/3` (`provider.prepare/2`) and `provider_call/3`
   (`provider.complete/2`);
2. `CalibrationCall` → `ClaudeCLI.prepare/2`, the accepted calibration
   exception;
3. `Runtime.prepared/1` → `module.prepare(%{}, [])`. It is status-only:
   it reads fixed in-process provenance and reserves nothing. It is
   classified, not changed, and never routed through `complete`.

A provider module's own internals are exempt only for calls to its own
functions, not calls into another provider.

**Limits, stated in the test:** it can't see a call whose function name
is computed at runtime (for example `apply(m, String.to_atom(...), _)`).
No such call exists in `lib/` today. Beyond the exceptions it enforces
nothing for dynamic receivers named anything other than `prepare` or
`complete`.

### R0-04-6. Documented

The facade's moduledoc gains one section stating:
- the envelope;
- the state precedence table;
- the no-relabel rule.

The behaviour's callback docs say what each return means.

**Calibration:** `CalibrationCall` shares the invoke and settle path, so
R0-04-1 applies to it too: a malformed reply after send becomes unknown,
which the calibration flow already handles. Its guards, authority,
witness and launch path, and the state precedence, are unchanged.

## 4. Entity Model delta (narrow; trigger: yes)

**Entity Model trigger: yes.** The facade's backend return contract
changes, and the lifecycle and accounting outcome of a malformed reply
after send changes from a crash to sent → unknown with the run budget
settled. Codex's OQ-2 answer.

| Entity | New / Existing | Purpose | Attributes | Relationships | Invariants / Lifecycle | Policy / Actor | Open Questions |
|---|---|---|---|---|---|---|---|
| `ModelProvider` facade (backend contract, not persisted) | Existing (contract delta) | The one public model call entry | The returns: `{:ok, %{output, invocation, ...}}`; `{:error, reason}`, adding `:malformed_provider_prepare` and adding malformed replies to the existing `:provider_outcome_unknown`; existing refusals unchanged | unchanged | R0-04-1 envelope and state precedence; R0-04-3 before reservation. A malformed reply is never retried | unchanged: the caller's actor; settlement as `agent_runtime` of the invocation's tenant (existing `actor/1`) | none |
| `ModelInvocation` | Existing (lifecycle and value delta; no schema change) | Ledger row per attempt | No new attribute. **Values:** `parsed_output` is nil whenever the parsed or invalid output is not a map, whether Zoi-valid or not (R0-04-2); `validation_errors` gains the type-only entry; the persisted `:map` type is unchanged. `usage` is the normalized embedded value | unchanged | **sent → unknown** now also on a malformed reply after send, in the same settlement transaction (run `FOR UPDATE` → body → transition → budget settle). Previously a crash, and the row stayed `sent`. reserved → failed: `:launch_not_admitted` for valid success and for malformed replies, and the reply's own reason for valid `{:error, _}` and `{:unknown, _}` (unchanged). **completed is reached only with a map parsed output**; a Zoi-valid non-map is `validation_failed`. Terminal rows: no write. Existing actions only (`:mark_unknown`, `:fail`). Event `model.invocation.unknown` or `failed`, as today | unchanged | none |
| `AgentRun` | Existing (accounting timing delta) | Per-run budget | unchanged | unchanged | For a malformed reply after send, the budget is settled at once by the existing `BudgetCounter` in the settlement transaction, instead of waiting for sweeper recovery. Counter rules and limits are unchanged; nothing is refunded | unchanged | none |

`existing dependency: unchanged — relationship/policy/lifecycle impact
checked, none found` applies to:
- `ModelCallGrant` and `ModelCallAllocation`: the charge at reservation
  is unchanged, with no refund or second charge;
- `Operations.Failure`: no Failure for an unknown or malformed reply;
  drift and launch Failures are unchanged;
- `AuditEvent`: the same events;
- the R0-07 result gate and release.

**Lock and transaction boundaries:** unchanged. Settlement keeps run →
chain; the envelope check is pure and happens before it. **ADR:** none.
This is correctness work within ADR-0004's seam and ADR-0005's existing
calibration and result-gate boundaries.

## 5. Tests

**Real RED, after the delta passes:**
1. **After send:** each malformed reply gives `unknown` with exactly
   one `model.invocation.unknown` event, the run budget settled once, no
   Failure, no retry, and `{:error, :provider_outcome_unknown}`. The
   malformed replies: `:ok`, `nil`, a 3-tuple, `{:ok, "x"}`, `{:ok, %{}}`
   without `:output`, a missing or non-binary `raw_response`, and a
   malformed `:usage`.
2. **A reserved ClaudeCLI row** with a malformed reply is failed
   (`:launch_not_admitted`) and never marked sent or unknown. It uses
   the hermetic fake CLI server with a stubbed launch admission.
3. **A terminal row** (launch-refused) with a malformed reply gets no
   second write, event or Failure.
4. **Non-map outputs:**
   - a Zoi-valid string and a Zoi-valid list (from non-object schemas),
     and, if supported, a transform producing a non-map: each gives
     `validation_failed` with `parsed_output` nil and exactly the
     type-only entry, never completed;
   - a Zoi-invalid non-map: the same, plus Zoi's errors.
4b. **Usage:** negative, nil and incomplete fields are protocol-malformed
   (unknown after send); a numeric string follows the embedded type's
   cast, recorded in RED; a valid usage is stored normalized.
5. **A malformed `prepare/2`** gives `{:error,
   :malformed_provider_prepare}`, with no row, counter or event.

**Characterization (passes on main):**
- the three valid reserved-row branches keep their reasons (`{:ok, _}`
  gives `:launch_not_admitted`; `{:error, r}` gives `r`; `{:unknown, r}`
  gives `r`);
- through the adapter, success, validation failure (map output), known
  failure, drift failure with its Failure, unknown, raise and exit;
- an unknown `provider` value is refused at reservation;
- a settlement error is not relabeled. A forced Agents-side error
  propagates as itself, via a narrow test seam or an invalid actor.

**Inventory (R0-04-5):**
- the baseline passes with exactly the three exceptions;
- a sensitivity check, with temporary local changes that are reverted:
  a direct `ClaudeCLI.complete/2`, a dynamic `mod.complete/2`, a capture
  and a literal `apply/3` each fail it.

**Gate:** the full gate on an owned test partition. Fake and test adapter
only; no model calls.

## 6. Size

One PR. About a day to a day and a half, including review.

## 7. Soft-stop record

Configured: `ai_pair=true`, `codex_review=true`, so the correlated peer
review applies.

| Round | Exact head | Reviewer | Correlation | Verdict |
|---|---|---|---|---|
| 1 | `d6e9f34` | Codex | ask `m_1792043415015174000_4abaade2` → 70d98160 | NEEDS-REVIEW |
| 2 | `d24f724` | Codex | ask `m_1792043838535062000_77c36653` → 7263fed7 | NEEDS-REVIEW |
| 3 | this draft | Codex | pending | pending |
